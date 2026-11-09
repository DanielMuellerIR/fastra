//! Interner Hilfsmodus des vorhandenen Programms; keine GTK-Initialisierung im Git-Hook.
use crate::{commit::*, *};
use std::{
    io::{Read, Write},
    os::unix::process::CommandExt,
    os::unix::{ffi::OsStrExt, fs::OpenOptionsExt},
    process::{Command, Stdio},
    sync::atomic::{AtomicI32, Ordering},
    time::Duration,
};
#[cfg(target_os = "linux")]
static EXPECTED_PARENT: AtomicI32 = AtomicI32::new(0);
#[cfg(target_os = "linux")]
static OWNED_GROUP: AtomicI32 = AtomicI32::new(0);
#[cfg(target_os = "linux")]
extern "C" fn parent_signal(signal: libc::c_int) {
    // Nach Gitverlust reserviert unsere eigene Gruppenzugehörigkeit noch die Vorgangsgruppe.
    let expected = EXPECTED_PARENT.load(Ordering::Relaxed);
    let group = OWNED_GROUP.load(Ordering::Relaxed);
    unsafe {
        if expected > 1 && group > 1 && libc::getppid() != expected {
            libc::kill(-group, libc::SIGKILL);
        }
        libc::_exit(128 + signal);
    }
}
#[cfg(target_os = "linux")]
fn arm_helper() -> Result<(), Error> {
    let parent = unsafe { libc::getppid() };
    let group = unsafe { libc::getpgrp() };
    if parent <= 1 || group <= 1 {
        return Err(Error::InvalidInput("owning Git process has ended"));
    }
    EXPECTED_PARENT.store(parent, Ordering::Relaxed);
    OWNED_GROUP.store(group, Ordering::Relaxed);
    let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
    action.sa_sigaction = parent_signal as *const () as usize;
    unsafe {
        libc::sigemptyset(&mut action.sa_mask);
    }
    if unsafe { libc::sigaction(libc::SIGTERM, &action, std::ptr::null_mut()) } != 0
        || unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) } != 0
    {
        return Err(io(std::io::Error::last_os_error()));
    }
    if unsafe { libc::getppid() } != parent {
        return Err(Error::InvalidInput("owning Git process changed"));
    }
    let mut state = String::new();
    std::fs::File::open(format!("/proc/{group}/stat"))
        .map_err(io)?
        .take(4096)
        .read_to_string(&mut state)
        .map_err(io)?;
    let state = state
        .rsplit_once(") ")
        .map(|x| x.1.as_bytes().first().copied());
    if matches!(state, Some(Some(b'Z' | b'X')) | None) {
        return Err(Error::InvalidInput("owning Git process group has ended"));
    }
    Ok(())
}
#[cfg(not(target_os = "linux"))]
fn arm_helper() -> Result<(), Error> {
    Err(Error::InvalidInput(
        "commit helper parent-loss ownership requires Linux",
    ))
}
fn diagnostic(e: Error) -> i32 {
    eprintln!("Fastra commit validation refused: {e}");
    1
}
fn original(
    ctx: &Context,
    name: &std::ffi::OsStr,
    native: &[OsString],
    input: Option<&[u8]>,
) -> Result<i32, Error> {
    let target = path(&ctx.original).join(name);
    let meta = match fs::metadata(&target) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(e) => return Err(io(e)),
    };
    if meta.mode() & 0o111 == 0 {
        return Ok(0);
    }
    let mut cmd = Command::new(&target);
    cmd.current_dir(path(&ctx.roots[0]))
        .args(native)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    // Nur die vom äußeren -c hinzugefügte Konfiguration entfällt. Der äußere Gitprozess behält seinen Wrapper.
    for (key, _) in std::env::vars_os() {
        let k = key.as_bytes();
        if k == b"GIT_CONFIG_PARAMETERS"
            || k == b"GIT_CONFIG_COUNT"
            || k.starts_with(b"GIT_CONFIG_KEY_")
            || k.starts_with(b"GIT_CONFIG_VALUE_")
            || k.starts_with(b"FASTRA_COMMIT_")
        {
            cmd.env_remove(key);
        }
    }
    if input.is_some() {
        cmd.stdin(Stdio::piped());
    } else {
        cmd.stdin(Stdio::inherit());
    }
    // Kein eigener Prozessverband: normale Hookkinder bleiben im besessenen äußeren Gitverband.
    #[cfg(target_os = "linux")]
    unsafe {
        let expected = libc::getpid();
        cmd.pre_exec(move || {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::getppid() != expected {
                return Err(std::io::Error::from_raw_os_error(libc::ECHILD));
            }
            Ok(())
        });
    }
    let mut child = cmd.spawn().map_err(io)?;
    if let Some(bytes) = input {
        if let Some(mut stdin) = child.stdin.take() {
            if let Err(e) = stdin.write_all(bytes) {
                let status = child.wait().map_err(io)?;
                if !status.success() {
                    return Ok(status.code().unwrap_or(1));
                }
                return Err(io(e));
            }
        }
    }
    let status = child.wait().map_err(io)?;
    Ok(status.code().unwrap_or(1))
}
fn run() -> Result<i32, Error> {
    arm_helper()?;
    let argv: Vec<_> = std::env::args_os().collect();
    if argv.len() < 3 {
        return Err(Error::InvalidInput("missing native hook name"));
    }
    let hook_path = std::path::PathBuf::from(&argv[2]);
    let name = hook_path
        .file_name()
        .ok_or(Error::InvalidInput("missing hook name"))?;
    let context_path = std::env::var_os("FASTRA_COMMIT_CONTEXT")
        .ok_or(Error::InvalidInput("missing commit approval"))?;
    let expected = std::env::var("FASTRA_COMMIT_DIGEST")
        .map_err(|_| Error::InvalidInput("missing commit approval digest"))?;
    let f = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(context_path)
        .map_err(io)?;
    let (_, serialized) = file_bytes(&f, META_LIMIT, &Cancellation::default())?;
    if expected.len() != 64 || hex(&hash(&serialized)) != expected {
        return Err(Error::StalePreview);
    }
    let ctx: Context = serde_json::from_slice(&serialized)
        .map_err(|_| Error::InvalidInput("invalid commit approval context"))?;
    if ctx.version != 1
        || ctx.roots.len() != 3
        || ctx.identities.len() != 3
        || hook_path.parent() != Some(path(&ctx.hook_dir).as_path())
    {
        return Err(Error::InvalidInput("invalid commit helper context"));
    }
    let native = &argv[3..];
    if name != std::ffi::OsStr::new("reference-transaction") {
        return original(&ctx, name, native, None);
    }
    let phase = native
        .first()
        .and_then(|x| x.to_str())
        .ok_or(Error::InvalidInput("missing native reference phase"))?;
    let mut input = Vec::new();
    std::io::stdin()
        .take(4097)
        .read_to_end(&mut input)
        .map_err(io)?;
    if input.len() > 4096 {
        return Err(Error::InvalidInput(
            "native commit reference transaction limit",
        ));
    }
    let rows: Vec<_> = input
        .split(|b| *b == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| line.split(|b| *b == b' ').collect::<Vec<_>>())
        .collect();
    if rows.iter().any(|r| r.len() != 3) {
        return Err(Error::MalformedOutput("native reference transaction"));
    }
    let targets: Vec<_> = rows
        .iter()
        .filter(|r| r[2] == ctx.branch.as_slice() || r[2] == b"HEAD")
        .collect();
    if phase == "committed" && !targets.is_empty() {
        let oid = targets[0][1];
        check_oid(oid)?;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path(&ctx.marker))
            .map_err(io)?;
        f.write_all(oid).map_err(io)?;
        f.write_all(b"\n").map_err(io)?;
    }
    let original_result = original(&ctx, name, native, Some(&input))?;
    if original_result != 0 {
        return Ok(original_result);
    }
    // Die Hauptveröffentlichung wird immer geprüft; eine Markierungsdatei darf sie nie überspringen.
    if phase != "prepared" || (targets.is_empty() && read_published(&ctx).is_some()) {
        return Ok(0);
    }
    let cancel = Cancellation::default();
    let policy = Policy {
        timeout: Duration::from_secs(15),
        stdout_bytes: 1024 * 1024,
        stderr_bytes: 128 * 1024,
        ..Default::default()
    };
    let mut git = Git::new(path(&ctx.git))?;
    git.terminate_on_parent_loss = true;
    let repo = git.discover(&path(&ctx.roots[0]), policy, &cancel)?;
    let mut budget = Budget::new(policy);
    repo.commit_verify(&ctx, &mut budget, &cancel)?;
    if targets.is_empty() {
        if rows.iter().any(|r| {
            !matches!(
                r[2],
                b"AUTO_MERGE"
                    | b"MERGE_HEAD"
                    | b"CHERRY_PICK_HEAD"
                    | b"REVERT_HEAD"
                    | b"REBASE_HEAD"
            ) || !r[1].iter().all(|b| *b == b'0')
        }) {
            return Err(Error::InvalidInput(
                "unexpected native commit reference transaction",
            ));
        }
        return Ok(0);
    }
    let new = targets[0][1];
    check_oid(new)?;
    for row in targets {
        if row[0] != ctx.old || row[1] != new {
            return Err(Error::InvalidInput(
                "native old OID or commit transaction differs from approval",
            ));
        }
    }
    let mut a = args(&["cat-file", "commit"]);
    a.push(OsString::from_vec(new.to_vec()));
    let out = repo.commit_read(a, &mut budget, &cancel)?;
    let split = out
        .stdout
        .windows(2)
        .position(|p| p == b"\n\n")
        .ok_or(Error::MalformedOutput("commit headers"))?;
    let headers = &out.stdout[..split];
    let message = &out.stdout[split + 2..];
    let fields = |prefix: &[u8]| -> Vec<Vec<u8>> {
        headers
            .split(|b| *b == b'\n')
            .filter_map(|l| l.strip_prefix(prefix).map(|x| x.to_vec()))
            .collect()
    };
    if fields(b"tree ") != vec![ctx.tree] {
        return Err(Error::InvalidInput(
            "commit tree differs from approved full index tree",
        ));
    }
    if fields(b"parent ") != ctx.parents {
        return Err(Error::InvalidInput(
            "commit parent list differs from approval",
        ));
    }
    if message != ctx.message {
        return Err(Error::InvalidInput(
            "commit message differs from approval; original hooks were executed",
        ));
    }
    if fields(b"author ") != vec![ctx.author.full]
        || fields(b"committer ") != vec![ctx.committer.full]
    {
        return Err(Error::InvalidInput(
            "commit author or committer differs from approval",
        ));
    }
    Ok(0)
}
pub fn entry() -> Option<i32> {
    if std::env::args_os().nth(1).as_deref()
        != Some(std::ffi::OsStr::new("--fastra-git-commit-hook"))
    {
        return None;
    }
    Some(match run() {
        Ok(code) => code,
        Err(e) => diagnostic(e),
    })
}
