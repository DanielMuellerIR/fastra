use super::*;

fn caller_name(uid: libc::uid_t) -> Result<String, String> {
    let mut record = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut buffer = vec![0u8; 64 * 1024];
    let mut found = std::ptr::null_mut();
    let result = unsafe {
        libc::getpwuid_r(
            uid,
            record.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut found,
        )
    };
    if result != 0 || found.is_null() {
        return Err("Reliable operating-system user identity unavailable".into());
    }
    let record = unsafe { record.assume_init() };
    if record.pw_name.is_null() || record.pw_uid != uid {
        return Err("Reliable operating-system user identity unavailable".into());
    }
    let name = unsafe { std::ffi::CStr::from_ptr(record.pw_name) }.to_bytes();
    if name.is_empty() || name.len() > 1024 || name.iter().any(|b| b":\r\n".contains(b)) {
        return Err(
            "Operating-system username cannot be represented in the private account file".into(),
        );
    }
    std::str::from_utf8(name)
        .map(str::to_owned)
        .map_err(|_| "Operating-system username is not UTF-8".into())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn execute(
    runtime: &runtime::Runtime,
    directory: &Path,
    project: &Path,
    code: &str,
    variant: &str,
    method: &str,
    token: &str,
    cancel: &Cancellation,
    process_cancel: &process::Cancellation,
    verify: &dyn Fn() -> Result<(), String>,
) -> Result<Outcome, String> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let (app, app_lib) = crate::worker_layout()?;
    for name in [
        "libicuuc.so.78.3",
        "libicui18n.so.78.3",
        "libicudata.so.78.3",
    ] {
        if !app_lib.join(name).is_file() {
            return Err("Packaged application sibling lib/ with ICU 78.3 required".into());
        }
    }
    // MacroRun darf SystemWorker mit der POSIX-Shell nutzen. Nur dieses Systembinary
    // wird eingebunden, keine zusätzlichen Werkzeuge oder Benutzerverzeichnisse.
    let shell = Path::new("/bin/sh").canonicalize().map_err(io)?;
    let _shell_file = crate::open_path(&shell, false)?;
    let shell_meta = _shell_file.metadata().map_err(io)?;
    if !shell_meta.is_file() || shell_meta.mode() & 0o111 == 0 {
        return Err("System shell is not executable".into());
    }
    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };
    // Kopfautoren stammen vom tatsächlichen Aufrufer. Ein erfundener Sandbox-
    // Benutzer würde Current system user und damit die Makroausgabe verfälschen.
    let caller = caller_name(uid)?;
    for (name, content) in [
        (
            "passwd",
            format!("{caller}:x:{uid}:{gid}:{caller}:/home/fastra:/nonexistent\n"),
        ),
        ("group", format!("fastra:x:{gid}:\n")),
    ] {
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(directory.join(name))
            .map_err(io)?
            .write_all(content.as_bytes())
            .map_err(io)?;
    }
    let output = directory.join("output");
    fs::create_dir(&output).map_err(io)?;
    let engine = directory.join("engine");
    let meta = fs::symlink_metadata(&engine).map_err(io)?;
    let request = Request {
        runtime: runtime.proofs(),
        parent_net: fs::read_link("/proc/self/ns/net")
            .map_err(io)?
            .to_string_lossy()
            .into_owned(),
        project: project
            .to_str()
            .ok_or("UTF-8 engine project path required")?
            .into(),
        project_identity: (meta.dev(), meta.ino()),
        code: code.into(),
        variant: variant.into(),
        method: method.into(),
        token: token.into(),
    };
    let input = serde_json::to_vec(&request).map_err(io)?;
    if input.len() > JSON_LIMIT {
        return Err("Macro worker input limit".into());
    }
    let mut args: Vec<OsString> = [
        "--as=3221225472",
        "--cpu=60",
        "--fsize=8388608",
        "--nofile=128",
        "--",
        "/usr/bin/bwrap",
        "--unshare-all",
        "--die-with-parent",
        "--new-session",
        "--cap-drop",
        "ALL",
        "--clearenv",
    ]
    .into_iter()
    .map(Into::into)
    .collect();
    for path in [
        "/usr/lib",
        "/usr/lib64",
        "/lib",
        "/lib64",
        "/etc/ld.so.cache",
        "/usr/share/zoneinfo",
    ] {
        if Path::new(path).exists() {
            args.extend(["--ro-bind".into(), path.into(), path.into()]);
        }
    }
    for (from, to) in [
        (&app, "/app/libexec/fastra-linux"),
        (&app_lib, "/app/lib"),
        (&runtime.executable.path, "/runtime/tool4d"),
        (&runtime.resources.path, "/runtime/Resources"),
        (&directory.join("passwd"), "/etc/passwd"),
        (&directory.join("group"), "/etc/group"),
    ] {
        args.extend(["--ro-bind".into(), from.as_os_str().to_owned(), to.into()]);
    }
    args.extend([
        "--ro-bind".into(),
        shell.as_os_str().to_owned(),
        "/bin/sh".into(),
    ]);
    if let Some(lib) = &runtime.lib {
        args.extend([
            "--ro-bind".into(),
            lib.path.as_os_str().to_owned(),
            "/runtime/lib".into(),
        ]);
    }
    for (from, to) in [(&engine, "/engine"), (&output, "/output")] {
        args.extend(["--bind".into(), from.as_os_str().to_owned(), to.into()]);
    }
    for variable in ["USER", "LOGNAME"] {
        args.extend(["--setenv".into(), variable.into(), caller.clone().into()]);
    }
    args.extend(
        [
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--tmpfs",
            "/tmp",
            "--tmpfs",
            "/home/fastra",
            "--dir",
            "/home/fastra/.local/share/tool4d",
            "--setenv",
            "HOME",
            "/home/fastra",
            "--setenv",
            "LANG",
            "C.UTF-8",
            "--setenv",
            "LD_LIBRARY_PATH",
            "/app/lib",
            "--chdir",
            "/tmp",
            "--",
            "/app/libexec/fastra-linux",
            "--fastra-4d-macro-worker",
        ]
        .into_iter()
        .map(Into::into),
    );
    verify()?;
    let output = process::run_with_input(
        Path::new("/usr/bin/prlimit"),
        directory,
        &args,
        &input,
        Policy {
            timeout: TIMEOUT + Duration::from_secs(5),
            termination_grace: Duration::from_millis(100),
            stdout_bytes: JSON_LIMIT,
            stderr_bytes: 32 * 1024,
        },
        process_cancel,
        &Environment {
            remove_prefixes: vec!["LD_".into(), "GCONV_PATH".into()],
            set: vec![],
        },
    )
    .map_err(io)?;
    check(cancel)?;
    if !output.success() {
        return Err(format!(
            "Macro sandbox failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let envelope: Envelope = serde_json::from_slice(&output.stdout)
        .map_err(|_| "Invalid MacroRun worker response".to_owned())?;
    if envelope.version != 1 || envelope.token != token {
        return Err("Foreign MacroRun worker response".into());
    }
    envelope.result
}
