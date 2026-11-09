use fastra_git::*;
use std::{
    ffi::OsStr,
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};
// Der Pakettest kann den separat ausgelieferten GTK-freien Hook statt des Testprogramms verwenden.
fn helper_binary() -> PathBuf {
    std::env::var_os("FASTRA_GIT_COMMIT_TEST_HELPER")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_exe().unwrap())
}
fn git(p: &Path, a: &[&OsStr]) -> Vec<u8> {
    let out = Command::new("/usr/bin/git")
        .current_dir(p)
        .args(a)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "Fixture")
        .env("GIT_AUTHOR_EMAIL", "fixture@example.invalid")
        .env("GIT_COMMITTER_NAME", "Fixture")
        .env("GIT_COMMITTER_EMAIL", "fixture@example.invalid")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{a:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out.stdout
}
fn cli(p: &Path, a: &[&str]) -> Vec<u8> {
    git(p, &a.iter().map(OsStr::new).collect::<Vec<_>>())
}
fn exe(p: &Path, s: &str) {
    fs::write(p, s).unwrap();
    fs::set_permissions(p, fs::Permissions::from_mode(0o700)).unwrap();
}
struct F {
    _temp: tempfile::TempDir,
    root: PathBuf,
    main: PathBuf,
    hooks: PathBuf,
    log: PathBuf,
    repo: Repository,
    head: Vec<u8>,
}
impl F {
    fn new(format: &str, kind: &str) -> Self {
        let temp = tempfile::tempdir().unwrap();
        let main = temp.path().join(if kind == "literal" {
            "work é:semi;line\n"
        } else {
            "work"
        });
        fs::create_dir(&main).unwrap();
        cli(
            &main,
            &[
                "init",
                "-q",
                "-b",
                "main",
                &format!("--object-format={format}"),
            ],
        );
        cli(&main, &["config", "user.name", "Fixture"]);
        cli(&main, &["config", "user.email", "fixture@example.invalid"]);
        fs::create_dir(main.join("folder")).unwrap();
        fs::create_dir(main.join("other")).unwrap();
        fs::write(main.join("folder/file"), "initial\n").unwrap();
        fs::write(main.join("other/file"), "stable\n").unwrap();
        cli(&main, &["add", "."]);
        cli(&main, &["commit", "-qm", "initial"]);
        cli(&main, &["branch", "alias"]);
        let root = if kind == "linked" {
            let linked = temp.path().join("linked");
            cli(
                &main,
                &[
                    "worktree",
                    "add",
                    "-qb",
                    "linked-source",
                    linked.to_str().unwrap(),
                    "main",
                ],
            );
            linked
        } else {
            main.clone()
        };
        if kind == "sparse" {
            cli(
                &root,
                &["sparse-checkout", "init", "--cone", "--sparse-index"],
            );
            cli(&root, &["sparse-checkout", "set", "folder"]);
        }
        fs::write(root.join("folder/file"), "approved\n").unwrap();
        cli(&root, &["add", "folder/file"]);
        if kind == "split" {
            cli(&root, &["update-index", "--split-index"]);
        }
        let hooks = main.join(".git/original-hooks");
        fs::create_dir(&hooks).unwrap();
        cli(
            &root,
            &["config", "core.hooksPath", hooks.to_str().unwrap()],
        );
        let log_path = PathBuf::from(
            String::from_utf8(cli(
                &root,
                &[
                    "rev-parse",
                    "--path-format=absolute",
                    "--git-path",
                    "fastra-hook-log",
                ],
            ))
            .unwrap()
            .trim_end_matches('\n'),
        );
        for name in [
            "pre-commit",
            "prepare-commit-msg",
            "commit-msg",
            "post-commit",
            "post-index-change",
            "reference-transaction",
        ] {
            exe(&hooks.join(name),"#!/usr/bin/python3\nimport os,sys,pathlib,subprocess,json\np=pathlib.Path(os.fsdecode(subprocess.check_output(['/usr/bin/git','rev-parse','--path-format=absolute','--git-path','fastra-hook-log'])[:-1]))\nraw=sys.stdin.buffer.read() if pathlib.Path(sys.argv[0]).name=='reference-transaction' else b''\nwith p.open('a') as f:f.write(json.dumps({'hook':pathlib.Path(sys.argv[0]).name,'args':sys.argv[1:],'stdin':raw.hex(),'index':os.environ.get('GIT_INDEX_FILE'),'hookpath':subprocess.check_output(['/usr/bin/git','config','core.hooksPath']).decode().strip()})+'\\n')\n");
        }
        let wrapper = temp.path().join("git");
        exe(&wrapper,"#!/bin/sh\nexport GIT_CONFIG_GLOBAL=/dev/null\nexport GIT_CONFIG_NOSYSTEM=1\nexec /usr/bin/git \"$@\"\n");
        let repo = Git::new(wrapper)
            .unwrap()
            .discover(&root, Policy::default(), &Cancellation::default())
            .unwrap();
        let head = cli(&root, &["rev-parse", "HEAD"])
            .strip_suffix(b"\n")
            .unwrap()
            .to_vec();
        Self {
            _temp: temp,
            root,
            main,
            hooks,
            log: log_path,
            repo,
            head,
        }
    }
    fn prepare(&self) -> CommitPreview {
        self.repo
            .prepare_commit(
                "approved · Grüße 🚀\n\ncomplete body\n".as_bytes().to_vec(),
                helper_binary(),
                Policy::default(),
                &Cancellation::default(),
            )
            .unwrap()
    }
    fn index(&self) -> Vec<u8> {
        let p = cli(
            &self.root,
            &["rev-parse", "--path-format=absolute", "--git-path", "index"],
        );
        fs::read(PathBuf::from(
            String::from_utf8(p[..p.len() - 1].to_vec()).unwrap(),
        ))
        .unwrap()
    }
    fn head(&self) -> Vec<u8> {
        cli(&self.root, &["rev-parse", "HEAD"])
            .strip_suffix(b"\n")
            .unwrap()
            .to_vec()
    }
}
fn run(p: CommitPreview) -> CommitReport {
    p.execute(Policy::default(), &Cancellation::default(), &mut |_| {})
}
fn objects(p: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    fn walk(base: &Path, p: &Path, v: &mut Vec<(PathBuf, Vec<u8>)>) {
        for e in fs::read_dir(p).unwrap() {
            let e = e.unwrap();
            if e.path().is_dir() {
                walk(base, &e.path(), v);
            } else {
                v.push((
                    e.path().strip_prefix(base).unwrap().to_owned(),
                    fs::read(e.path()).unwrap(),
                ));
            }
        }
    }
    let mut v = Vec::new();
    walk(p, p, &mut v);
    v.sort_by(|a, b| a.0.cmp(&b.0));
    v
}
fn exact(format: &str, kind: &str) {
    let f = F::new(format, kind);
    let before_objects = objects(&f.main.join(".git/objects"));
    let index = f.index();
    let main_index = fs::read(f.main.join(".git/index")).unwrap();
    let main_head = fs::read(f.main.join(".git/HEAD")).unwrap();
    let p = f.prepare();
    assert!(!f.log.exists(), "preview ran original hooks");
    assert_eq!(before_objects, objects(&f.main.join(".git/objects")));
    assert_eq!(f.index(), index);
    let tree = p.tree().to_vec();
    let message = p.message().to_vec();
    assert_eq!(p.parents(), std::slice::from_ref(&f.head));
    assert!(p.diff().stdout.windows(9).any(|x| x == b"+approved"));
    assert!(!p.entries().stdout.is_empty());
    let target = f.root.join("other/file");
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(&target, "later staging\n").unwrap();
    cli(&f.root, &["add", "--sparse", "other/file"]);
    fs::write(&target, "later dirty\n").unwrap();
    let index = f.index();
    let report = run(p);
    assert!(report.result.is_ok(), "{report:?}");
    assert!(report.published.is_some());
    assert_eq!(f.index(), index);
    assert_eq!(fs::read(target).unwrap(), b"later dirty\n");
    assert_eq!(
        cli(&f.root, &["rev-parse", "HEAD^{tree}"])
            .strip_suffix(b"\n")
            .unwrap(),
        tree
    );
    let object = cli(&f.root, &["cat-file", "commit", "HEAD"]);
    let offset = object.windows(2).position(|x| x == b"\n\n").unwrap() + 2;
    assert_eq!(&object[offset..], message);
    assert_ne!(f.head(), f.head);
    cli(&f.root, &["fsck", "--no-dangling", "--no-reflogs"]);
    let log = fs::read_to_string(&f.log).unwrap();
    assert!(log.contains("post-index-change"));
    assert!(log.contains("prepared"));
    assert!(log.contains("committed"));
    assert!(log.lines().all(|l| {
        let j: serde_json::Value = serde_json::from_str(l).unwrap();
        j["hookpath"] == f.hooks.to_str().unwrap()
    }));
    if kind == "linked" {
        assert_eq!(fs::read(f.main.join(".git/index")).unwrap(), main_index);
        assert_eq!(fs::read(f.main.join(".git/HEAD")).unwrap(), main_head);
    }
}
fn changed_hook(kind: &str) {
    let f = F::new("sha1", "ordinary");
    let name = if kind == "message" {
        "commit-msg"
    } else {
        "pre-commit"
    };
    let script = if kind == "message" {
        "#!/usr/bin/python3\nimport sys\nwith open(sys.argv[1],'ab') as f:f.write(b'hook-message\\n')\n"
    } else {
        "#!/bin/sh\nprintf 'hook tree\\n' > folder/file\ngit add folder/file\n"
    };
    exe(&f.hooks.join(name), script);
    let p = f.prepare();
    let index = f.index();
    let report = run(p);
    assert!(
        matches!(report.result, Err(Error::GitFailed(_))),
        "{report:?}"
    );
    assert!(report.published.is_none());
    assert_eq!(f.head(), f.head);
    assert_eq!(f.index(), index);
    let out = match report.result {
        Err(Error::GitFailed(out)) => out,
        _ => unreachable!(),
    };
    assert!(
        String::from_utf8_lossy(&out.stderr).contains(if kind == "message" {
            "message differs"
        } else {
            "tree differs"
        }),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}
fn drift(kind: &str) {
    let f = F::new("sha1", "ordinary");
    let p = f.prepare();
    match kind {
        "branch" => {
            cli(&f.root, &["switch", "-q", "alias"]);
        }
        "aba" => {
            cli(&f.root, &["switch", "-q", "alias"]);
            cli(&f.root, &["switch", "-q", "main"]);
        }
        "hook" => {
            fs::write(f.hooks.join("commit-msg"), "#!/bin/sh\n# changed\n").unwrap();
        }
        "config" => {
            cli(&f.root, &["config", "user.name", "Changed"]);
        }
        _ => unreachable!(),
    };
    let before = f.head();
    let index = f.index();
    let report = run(p);
    assert!(
        matches!(report.result, Err(Error::StalePreview)),
        "{kind} {report:?}"
    );
    assert!(report.published.is_none());
    assert_eq!(f.head(), before);
    assert_eq!(f.index(), index);
}
fn parent_hook() {
    let f = F::new("sha1", "ordinary");
    cli(&f.root, &["switch", "-q", "alias"]);
    cli(
        &f.root,
        &["commit", "--allow-empty", "-qm", "external parent"],
    );
    let other = f.head();
    cli(&f.root, &["switch", "-q", "main"]);
    exe(
        &f.hooks.join("pre-commit"),
        "#!/bin/sh\ngit update-ref HEAD refs/heads/alias\n",
    );
    let p = f.prepare();
    let index = f.index();
    let report = run(p);
    assert!(report.result.is_err(), "{report:?}");
    assert!(report.published.is_none());
    assert_eq!(f.head(), other);
    assert_eq!(f.index(), index);
}
fn cancel() {
    let f = F::new("sha1", "ordinary");
    exe(
        &f.hooks.join("post-index-change"),
        "#!/bin/sh\necho commit-cancel-ready >&2\nsleep 30\n",
    );
    let p = f.prepare();
    let index = f.index();
    let c = Cancellation::default();
    let mut live = Vec::new();
    let start = std::time::Instant::now();
    let report = p.execute(Policy::default(), &c, &mut |b| {
        live.extend_from_slice(b);
        if live.windows(19).any(|x| x == b"commit-cancel-ready") {
            c.cancel();
        }
    });
    assert!(
        matches!(report.result, Err(Error::Cancelled(_))),
        "{report:?}"
    );
    assert!(start.elapsed() < Duration::from_secs(3));
    assert!(report.state.is_ok());
    assert_eq!(f.head(), f.head);
    assert_eq!(f.index(), index);
}
fn lease() {
    let f = F::new("sha1", "ordinary");
    let p = f.prepare();
    let _lease = f.repo.try_operation().unwrap();
    let r = run(p);
    assert!(matches!(r.result, Err(Error::InvalidInput(_))));
    assert_eq!(f.head(), f.head);
}
fn ref_aba() {
    let f = F::new("sha1", "ordinary");
    cli(&f.root, &["switch", "-q", "alias"]);
    cli(&f.root, &["commit", "--allow-empty", "-qm", "other"]);
    let other = f.head();
    cli(&f.root, &["switch", "-q", "main"]);
    fs::write(f.root.join("folder/file"), "approved\n").unwrap();
    cli(&f.root, &["add", "folder/file"]);
    let p = f.prepare();
    let index = f.index();
    git(
        &f.root,
        &[
            OsStr::new("update-ref"),
            OsStr::new("refs/heads/main"),
            OsStr::new(std::str::from_utf8(&other).unwrap()),
        ],
    );
    git(
        &f.root,
        &[
            OsStr::new("update-ref"),
            OsStr::new("refs/heads/main"),
            OsStr::new(std::str::from_utf8(&f.head).unwrap()),
        ],
    );
    let r = run(p);
    assert!(matches!(r.result, Err(Error::StalePreview)), "{r:?}");
    assert_eq!(f.head(), f.head);
    assert_eq!(f.index(), index);
}
fn scratch_symlink() {
    let mut f = F::new("sha1", "ordinary");
    let wrapper = f._temp.path().join("fake-git");
    exe(&wrapper,&format!("#!/usr/bin/python3\nimport os,sys\nos.environ['GIT_CONFIG_GLOBAL']='/dev/null'\nos.environ['GIT_CONFIG_NOSYSTEM']='1'\nif 'init' in sys.argv[1:] and '--bare' in sys.argv[1:]:\n os.symlink({:?},sys.argv[-1]);sys.exit(0)\nos.execv('/usr/bin/git',['git']+sys.argv[1:])\n",f.main.join(".git").to_str().unwrap()));
    f.repo = Git::new(wrapper)
        .unwrap()
        .discover(&f.root, Policy::default(), &Cancellation::default())
        .unwrap();
    let index = f.index();
    let before = objects(&f.main.join(".git/objects"));
    let result = f.repo.prepare_commit(
        b"message\n".to_vec(),
        helper_binary(),
        Policy::default(),
        &Cancellation::default(),
    );
    assert!(matches!(result, Err(Error::InvalidInput(_))), "{result:?}");
    assert_eq!(f.index(), index);
    assert_eq!(objects(&f.main.join(".git/objects")), before);
    assert_eq!(f.head(), f.head);
}
fn owner_driver(root: &Path, program: PathBuf) {
    let repo = Git::new(program)
        .unwrap()
        .discover(root, Policy::default(), &Cancellation::default())
        .unwrap();
    let p = repo
        .prepare_commit(
            b"parent loss probe\n".to_vec(),
            helper_binary(),
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    let r = run(p);
    assert!(r.result.is_err(), "{r:?}");
}
fn inactive(pid: i64) -> bool {
    let p = format!("/proc/{pid}/stat");
    match fs::read_to_string(p) {
        Err(_) => true,
        Ok(s) => s
            .rsplit_once(") ")
            .is_some_and(|(_, tail)| matches!(tail.as_bytes().first(), Some(b'Z' | b'X'))),
    }
}
fn parent_loss(mode: &str) {
    let f = F::new("sha1", "ordinary");
    exe(&f.hooks.join("pre-commit"),"#!/usr/bin/python3\nimport os,time,json,pathlib\npathlib.Path('.git/loss-ready.tmp').write_text(json.dumps({'hook':os.getpid(),'helper':os.getppid(),'group':os.getpgrp(),'index':os.environ['GIT_INDEX_FILE']}));os.replace('.git/loss-ready.tmp','.git/loss-ready')\ntime.sleep(2)\npathlib.Path('.git/loss-late').write_text('late action')\n");
    let index = f.index();
    let mut child = Command::new(std::env::current_exe().unwrap())
        .arg("--owner-driver")
        .arg(&f.root)
        .arg(f._temp.path().join("git"))
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let ready = f.root.join(".git/loss-ready");
    let start = std::time::Instant::now();
    while !ready.exists() {
        assert!(
            start.elapsed() < Duration::from_secs(8),
            "owner probe did not start hook"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    let record: serde_json::Value = serde_json::from_slice(&fs::read(&ready).unwrap()).unwrap();
    let group = record["group"].as_i64().unwrap();
    if mode == "app" {
        child.kill().unwrap();
        assert!(!child.wait().unwrap().success());
    } else {
        assert_eq!(unsafe { libc::kill(group as i32, libc::SIGTERM) }, 0);
        assert!(child.wait().unwrap().success());
    }
    std::thread::sleep(Duration::from_millis(2500));
    assert!(
        !f.root.join(".git/loss-late").exists(),
        "ordinary original hook continued after {mode} loss"
    );
    assert!(
        inactive(record["hook"].as_i64().unwrap()),
        "original hook still active"
    );
    assert!(
        inactive(record["helper"].as_i64().unwrap()),
        "helper still active"
    );
    assert!(inactive(group), "Git still active");
    assert_eq!(f.head(), f.head);
    assert_eq!(f.index(), index);
    if let Some(directory) = Path::new(record["index"].as_str().unwrap()).parent() {
        if directory.parent() == Some(Path::new("/tmp"))
            && directory
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("fastra-commit-")
            && fs::symlink_metadata(directory).is_ok_and(|m| m.file_type().is_dir())
        {
            fs::remove_dir_all(directory).unwrap();
        }
    }
}
fn parent_modes(mode: &str) {
    let f = F::new("sha1", "ordinary");
    if mode == "initial" {
        cli(&f.root, &["commit", "-qm", "finish fixture staging"]);
        cli(&f.root, &["switch", "--orphan", "unborn"]);
        fs::write(f.root.join("first"), "first\n").unwrap();
        cli(&f.root, &["add", "first"]);
    } else if mode == "detached" {
        cli(&f.root, &["switch", "--detach", "HEAD"]);
    } else {
        cli(&f.root, &["commit", "-qm", "main approved"]);
        cli(&f.root, &["switch", "alias"]);
        fs::write(f.root.join("side"), "side\n").unwrap();
        cli(&f.root, &["add", "side"]);
        cli(&f.root, &["commit", "-qm", "side"]);
        cli(&f.root, &["switch", "main"]);
        cli(&f.root, &["merge", "--no-commit", "--no-ff", "alias"]);
    }
    let p = f.prepare();
    assert_eq!(
        p.parents().len(),
        if mode == "initial" {
            0
        } else if mode == "merge" {
            2
        } else {
            1
        }
    );
    let index = f.index();
    let r = run(p);
    assert!(r.result.is_ok(), "{mode} {r:?}");
    assert!(r.published.is_some());
    assert_eq!(f.index(), index);
}
fn no_shebang() {
    let f = F::new("sha1", "ordinary");
    exe(
        &f.hooks.join("pre-commit"),
        "echo original-no-shebang >&2\n",
    );
    let p = f.prepare();
    let r = run(p);
    assert!(r.result.is_ok(), "{r:?}");
}
fn signing() {
    let f = F::new("sha1", "ordinary");
    let key = f._temp.path().join("key");
    let out = Command::new("/usr/bin/ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "", "-f"])
        .arg(&key)
        .output()
        .unwrap();
    assert!(out.status.success());
    cli(&f.root, &["config", "gpg.format", "ssh"]);
    cli(
        &f.root,
        &["config", "user.signingkey", key.to_str().unwrap()],
    );
    cli(&f.root, &["config", "commit.gpgSign", "true"]);
    let p = f.prepare();
    let index = f.index();
    let r = run(p);
    assert!(r.result.is_ok(), "{r:?}");
    assert_eq!(f.index(), index);
    let allowed = f._temp.path().join("allowed");
    fs::write(
        &allowed,
        format!(
            "fixture@example.invalid {}",
            fs::read_to_string(key.with_extension("pub")).unwrap()
        ),
    )
    .unwrap();
    git(
        &f.root,
        &[
            OsStr::new("-c"),
            OsStr::new(&format!("gpg.ssh.allowedSignersFile={}", allowed.display())),
            OsStr::new("verify-commit"),
            OsStr::new("HEAD"),
        ],
    );
}
fn main() {
    if let Some(code) = fastra_git::commit_hook_entry() {
        std::process::exit(code);
    }
    let argv: Vec<_> = std::env::args_os().collect();
    if argv.get(1).is_some_and(|a| a == "--runtime-commit-driver") {
        std::env::set_var("PATH", "/private-runtime/invalid-bin");
        std::env::set_var("LD_LIBRARY_PATH", "/private-runtime/invalid-lib");
        let executable = fastra_process::host::resolve_program(OsStr::new("git"))
            .unwrap()
            .unwrap();
        assert_eq!(executable, Path::new("/usr/bin/git"));
        let repository = Git::new(executable)
            .unwrap()
            .discover(
                Path::new(&argv[2]),
                Policy::default(),
                &Cancellation::default(),
            )
            .unwrap();
        let preview = repository
            .prepare_commit(
                b"runtime host commit\n".to_vec(),
                PathBuf::from(&argv[3]),
                Policy::default(),
                &Cancellation::default(),
            )
            .unwrap();
        let report = run(preview);
        assert!(report.result.is_ok(), "{report:?}");
        assert!(report.published.is_some());
        println!("HOST_RUNTIME_GTK_FREE_COMMIT_OK");
        return;
    }
    if argv.get(1).is_some_and(|a| a == "--runtime-commit-gate") {
        let fixture = F::new("sha1", "ordinary");
        let mut command = Command::new(&argv[2]);
        command.arg("--");
        if let Some(namespace) = std::env::var_os("HOST_BRIDGE_NAMESPACE") {
            command.arg(namespace);
        }
        let output = command
            .arg(std::env::current_exe().unwrap())
            .arg("--runtime-commit-driver")
            .arg(&fixture.root)
            .arg(helper_binary())
            .env_remove("FASTRA_INTERNAL_HOST_FD")
            .env_remove("LD_LIBRARY_PATH")
            .env("PATH", "/usr/bin:/bin")
            .env("XDG_CACHE_HOME", fixture.root.join("runtime-cache"))
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert_ne!(fixture.head(), fixture.head);
        println!("{}", String::from_utf8_lossy(&output.stdout));
        println!("HOST_RUNTIME_GTK_FREE_COMMIT_GATE PASS");
        return;
    }
    if argv.get(1).is_some_and(|a| a == "--owner-driver") {
        owner_driver(Path::new(&argv[2]), PathBuf::from(&argv[3]));
        return;
    }
    if std::env::args().any(|a| a == "--ssh-sign") {
        signing();
        println!("PASS genuine native SSH signature + original hooks + exact commit");
        return;
    }
    let mut count = 0;
    for format in ["sha1", "sha256"] {
        for kind in ["ordinary", "split", "sparse", "linked"] {
            exact(format, kind);
            count += 1;
            println!("PASS commit exact {format} {kind}");
        }
    }
    exact("sha1", "literal");
    count += 1;
    for kind in ["tree", "message"] {
        changed_hook(kind);
        count += 1;
        println!("PASS original hook {kind} rejected");
    }
    for kind in ["branch", "aba", "hook", "config"] {
        drift(kind);
        count += 1;
        println!("PASS commit drift {kind}");
    }
    parent_hook();
    count += 1;
    println!("PASS native parent hook side effect without outer commit");
    cancel();
    count += 1;
    println!("PASS native hook cancellation and actual scan");
    lease();
    count += 1;
    println!("PASS common operation lease");
    ref_aba();
    count += 1;
    println!("PASS source ref OID ABA");
    scratch_symlink();
    count += 1;
    println!("PASS untrusted Git scratch symlink rejected");
    for mode in ["git", "app"] {
        parent_loss(mode);
        count += 1;
        println!(
            "PASS actual {mode} loss stops helper and ordinary original hook without late action"
        );
    }
    for mode in ["initial", "detached", "merge"] {
        parent_modes(mode);
        count += 1;
        println!("PASS complete parent mode {mode}");
    }
    no_shebang();
    count += 1;
    println!("PASS original executable hook without shebang");
    println!("COMMIT_BACKEND_OK {count}");
}
