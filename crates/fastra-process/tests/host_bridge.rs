#![cfg(target_os = "linux")]
use fastra_process::{Cancellation, Domain, Environment, Error, Policy};
use std::os::fd::FromRawFd;
use std::{
    ffi::{OsStr, OsString},
    os::unix::{
        ffi::{OsStrExt, OsStringExt},
        fs::PermissionsExt,
        net::UnixListener,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};
fn policy() -> Policy {
    Policy {
        timeout: Duration::from_secs(5),
        ..Default::default()
    }
}
fn run(
    exe: &Path,
    cwd: &Path,
    args: &[OsString],
    p: Policy,
    c: &Cancellation,
    e: &Environment,
) -> Result<fastra_process::Output, Error> {
    fastra_process::run(exe, cwd, args, p, c, e)
}
fn py(
    cwd: &Path,
    code: &str,
    p: Policy,
    c: &Cancellation,
) -> Result<fastra_process::Output, Error> {
    run(
        Path::new("/usr/bin/python3"),
        cwd,
        &["-c".into(), code.into()],
        p,
        c,
        &Environment::default(),
    )
}
fn dead(pid: i32) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/stat")).map_or(true, |s| {
        s.rsplit_once(')')
            .is_some_and(|(_, s)| s.starts_with(" Z") || s.starts_with(" X"))
    })
}
fn owned_ui_pid(launcher: u32) -> Option<i32> {
    let executable = std::env::current_exe().ok()?;
    let mut pending = vec![launcher];
    let mut seen = std::collections::HashSet::new();
    while let Some(pid) = pending.pop() {
        if !seen.insert(pid) {
            continue;
        }
        if pid != launcher
            && std::fs::read_link(format!("/proc/{pid}/exe")).ok().as_ref() == Some(&executable)
        {
            return i32::try_from(pid).ok();
        }
        if let Ok(children) = std::fs::read_to_string(format!("/proc/{pid}/task/{pid}/children")) {
            pending.extend(
                children
                    .split_whitespace()
                    .filter_map(|v| v.parse::<u32>().ok()),
            );
        }
    }
    None
}
fn wait_for(mut f: impl FnMut() -> bool) {
    let at = Instant::now();
    while !f() {
        assert!(at.elapsed() < Duration::from_secs(5), "condition timed out");
        std::thread::sleep(Duration::from_millis(5));
    }
}
const RESIST:&str="import os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\np=os.fork()\nif p==0:\n while True: time.sleep(.01)\nopen('owned-pids','w').write(str(os.getpid())+' '+str(p))\nwhile True: time.sleep(.01)";
#[test]
fn bridge_driver() {
    let Some(role) = std::env::var_os("HOST_BRIDGE_TEST_ROLE") else {
        return;
    };
    let root = PathBuf::from(std::env::var_os("HOST_BRIDGE_TEST_ROOT").unwrap());
    if role == "isolated" {
        assert!(std::env::var_os("FASTRA_INTERNAL_HOST_FD").is_none());
        assert!(!fastra_process::host::is_active().unwrap());
        assert_eq!(std::env::var_os("LD_LIBRARY_PATH").unwrap(), "/runtime/lib");
        let forbidden = std::env::var_os("HOST_BRIDGE_FORBIDDEN_SOCKET").unwrap();
        for entry in std::fs::read_dir("/proc/self/fd").unwrap().flatten() {
            assert_ne!(
                std::fs::read_link(entry.path())
                    .ok()
                    .map(|p| p.into_os_string()),
                Some(forbidden.clone())
            );
        }
        println!("ISOLATED_NO_HOST_CAPABILITY_OK");
        return;
    }
    std::fs::write(root.join("ui-pid"), std::process::id().to_string()).unwrap();
    std::env::set_var("PATH", root.join("private-bin"));
    std::env::set_var("LD_LIBRARY_PATH", "/private-runtime/lib");
    std::env::set_var("SSH_AUTH_SOCK", "/private-runtime/not-the-host-agent");
    if role == "hold" {
        std::fs::write(root.join("holder-pid"), std::process::id().to_string()).unwrap();
        std::thread::sleep(Duration::from_secs(20));
        return;
    }
    if role == "parallel-nested" {
        let id = std::env::var("HOST_BRIDGE_PARALLEL_ID").unwrap();
        for round in 0..5 {
            let marker = format!("helper-{id}-{round}");
            let out = run(
                Path::new("/usr/bin/python3"),
                &root,
                &[
                    "-c".into(),
                    "import sys,time;time.sleep(.01);sys.stdout.write(sys.argv[1])".into(),
                    marker.clone().into(),
                ],
                policy(),
                &Cancellation::default(),
                &Environment::default(),
            )
            .unwrap();
            assert_eq!(out.stdout, marker.as_bytes());
        }
        println!("PARALLEL_HELPER_{id}_OK");
        return;
    }
    if role == "owner-holding" {
        let held = root.clone();
        let _holder = std::thread::spawn(move || {
            fastra_process::run_in(
                Domain::Bundled,
                &std::env::current_exe().unwrap(),
                &held,
                &[
                    "--exact".into(),
                    "bridge_driver".into(),
                    "--nocapture".into(),
                ],
                Policy {
                    timeout: Duration::from_secs(25),
                    ..policy()
                },
                &Cancellation::default(),
                &Environment {
                    remove_prefixes: vec![],
                    set: vec![("HOST_BRIDGE_TEST_ROLE".into(), "hold".into())],
                },
            )
        });
        wait_for(|| root.join("holder-pid").exists());
        let _ = py(
            &root,
            RESIST,
            Policy {
                timeout: Duration::from_secs(25),
                ..policy()
            },
            &Cancellation::default(),
        );
        return;
    }
    if role == "nested" {
        let git = fastra_process::host::resolve_program(OsStr::new("git"))
            .unwrap()
            .unwrap();
        let output = run(
            &git,
            &root,
            &["--version".into()],
            policy(),
            &Cancellation::default(),
            &Environment::default(),
        )
        .unwrap();
        assert!(output.stdout.starts_with(b"git version "));
        println!("NESTED_BUNDLED_HOST_OK");
        return;
    }
    if role == "owner" || role == "owner-cleanup" {
        let code = if role == "owner-cleanup" {
            "import os,signal,time\ndef stop(s,f):\n open('term-cleaned','w').write('clean')\n raise SystemExit(0)\nsignal.signal(signal.SIGTERM,stop)\nopen('owned-pids','w').write(str(os.getpid()))\nwhile True: time.sleep(.01)"
        } else {
            RESIST
        };
        let _ = py(
            &root,
            code,
            Policy {
                timeout: Duration::from_secs(25),
                ..policy()
            },
            &Cancellation::default(),
        );
        return;
    }
    let socket = std::fs::read_link("/proc/self/fd/3").unwrap();
    let isolated = fastra_process::run_in(
        Domain::Isolated,
        &std::env::current_exe().unwrap(),
        &root,
        &[
            "--exact".into(),
            "bridge_driver".into(),
            "--nocapture".into(),
        ],
        policy(),
        &Cancellation::default(),
        &Environment {
            remove_prefixes: vec!["LD_".into()],
            set: vec![
                ("LD_LIBRARY_PATH".into(), "/runtime/lib".into()),
                ("HOST_BRIDGE_TEST_ROLE".into(), "isolated".into()),
                (
                    "HOST_BRIDGE_FORBIDDEN_SOCKET".into(),
                    socket.into_os_string(),
                ),
            ],
        },
    )
    .unwrap();
    assert!(isolated.success(), "{isolated:?}");
    assert!(isolated
        .stdout
        .windows(31)
        .any(|s| s == b"ISOLATED_NO_HOST_CAPABILITY_OK\n"));
    let discovered = fastra_process::host::resolve_program(OsStr::new("git"))
        .unwrap()
        .unwrap();
    assert_eq!(discovered, Path::new("/usr/bin/git"));
    assert!(
        fastra_process::host::resolve_program(OsStr::new("fastra-no-such-tool"))
            .unwrap()
            .is_none()
    );
    for name in ["tool4d", "poormans-text"] {
        let tool = fastra_process::host::resolve_program(OsStr::new(name))
            .unwrap()
            .unwrap();
        assert_eq!(tool, root.join("host-bin").join(name));
        assert_eq!(
            fastra_process::host::resolve_program(tool.as_os_str()).unwrap(),
            Some(tool.clone())
        );
        let output = run(
            &tool,
            &root,
            &["--version".into()],
            policy(),
            &Cancellation::default(),
            &Environment::default(),
        )
        .unwrap();
        assert!(output.success());
        assert_eq!(output.stdout, b"HOST_TOOL_WITHOUT_GUI_LD\n");
    }
    println!("HOST_DISCOVERY_PMT_TOOL4D_AND_ISOLATED_LD_GATE PASS");
    let cwd = root.join(OsString::from_vec(b"directory-\xff".to_vec()));
    std::fs::create_dir(&cwd).unwrap();
    let c = Cancellation::default();
    let env = Environment {
        remove_prefixes: vec!["GIT_".into()],
        set: vec![],
    };
    assert!(run(
        &discovered,
        &cwd,
        &["init".into(), "--quiet".into()],
        policy(),
        &c,
        &env
    )
    .unwrap()
    .success());
    let out = run(
        Path::new("git"),
        &cwd,
        &["rev-parse".into(), "--show-toplevel".into()],
        policy(),
        &c,
        &env,
    )
    .unwrap();
    assert_eq!(out.stdout, [cwd.as_os_str().as_bytes(), b"\n"].concat());
    let out=run(Path::new("/usr/bin/python3"),&cwd,&["-c".into(),"import os,sys;sys.stdout.buffer.write(os.fsencode(sys.argv[1]));assert 'LD_LIBRARY_PATH' not in os.environ;assert 'FASTRA_INTERNAL_HOST_FD' not in os.environ".into(),OsString::from_vec(b"raw-\xff".to_vec())],policy(),&c,&Environment::default()).unwrap();
    assert_eq!(out.stdout, b"raw-\xff");
    let out = fastra_process::run_with_input(
        Path::new("/usr/bin/python3"),
        &cwd,
        &[
            "-c".into(),
            "import sys;sys.stdout.buffer.write(sys.stdin.buffer.read())".into(),
        ],
        b"input\0\xff",
        policy(),
        &c,
        &Environment::default(),
    )
    .unwrap();
    assert_eq!(out.stdout, b"input\0\xff");
    let preparation = Cancellation::default();
    let trigger = preparation.clone();
    let trigger = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(1));
        trigger.cancel();
    });
    let result = fastra_process::run_with_input(
        Path::new("/usr/bin/python3"),
        &cwd,
        &["-c".into(), "import sys;sys.stdin.buffer.read()".into()],
        &vec![b'x'; fastra_process::MAX_INPUT_BYTES],
        policy(),
        &preparation,
        &Environment::default(),
    );
    trigger.join().unwrap();
    assert!(matches!(result, Err(Error::Cancelled(_))));
    let clear = Environment {
        remove_prefixes: vec!["".into()],
        set: vec![("EXPLICIT".into(), "1".into())],
    };
    assert!(run(
        Path::new("/usr/bin/python3"),
        &cwd,
        &[
            "-c".into(),
            "import os;assert 'PATH' not in os.environ;assert os.environ['EXPLICIT']=='1'".into()
        ],
        policy(),
        &c,
        &clear
    )
    .unwrap()
    .success());
    assert!(py(&root,"import os,socket;s=socket.socket(socket.AF_UNIX);s.connect(os.environ['SSH_AUTH_SOCK']);s.close()",policy(),&c).unwrap().success());
    let bundled = fastra_process::run_in(
        Domain::Bundled,
        Path::new("git"),
        &root,
        &[],
        policy(),
        &c,
        &Environment::default(),
    )
    .unwrap();
    assert_eq!(bundled.stdout, b"PRIVATE_TOOL\n");
    let nested = fastra_process::run_in(
        Domain::Bundled,
        &std::env::current_exe().unwrap(),
        &root,
        &[
            "--exact".into(),
            "bridge_driver".into(),
            "--nocapture".into(),
        ],
        policy(),
        &c,
        &Environment {
            remove_prefixes: vec![],
            set: vec![("HOST_BRIDGE_TEST_ROLE".into(), "nested".into())],
        },
    )
    .unwrap();
    assert!(nested.success());
    assert!(String::from_utf8_lossy(&nested.stdout).contains("NESTED_BUNDLED_HOST_OK"));
    assert!(matches!(
        run(
            Path::new("/usr/bin/true"),
            &root,
            &[OsString::from_vec(b"invalid\0argument".to_vec())],
            policy(),
            &c,
            &Environment::default()
        ),
        Err(Error::InvalidPolicy)
    ));
    assert!(matches!(
        run(
            Path::new("/usr/bin/true"),
            &root,
            &[OsString::from("x".repeat(2 * 1024 * 1024))],
            policy(),
            &c,
            &Environment::default()
        ),
        Err(Error::InvalidPolicy)
    ));
    assert!(matches!(
        run(
            Path::new("/usr/bin/true"),
            &root,
            &[],
            policy(),
            &c,
            &Environment {
                remove_prefixes: vec![],
                set: vec![("LD_LIBRARY_PATH".into(), "/private-runtime/lib".into())]
            }
        ),
        Err(Error::InvalidPolicy)
    ));
    let shared = std::sync::Arc::new(std::sync::Barrier::new(4));
    let failed = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut stress = Vec::new();
    for sender in 0..4 {
        let root = root.clone();
        let barrier = shared.clone();
        let failed = failed.clone();
        stress.push(std::thread::spawn(move || {
            for round in 0..25 {
                barrier.wait();
                let marker = format!("sender-{sender}-{round}");
                let result = run(
                    Path::new("/usr/bin/python3"),
                    &root,
                    &[
                        "-c".into(),
                        "import sys,time;time.sleep(.01);sys.stdout.write(sys.argv[1])".into(),
                        marker.clone().into(),
                    ],
                    policy(),
                    &Cancellation::default(),
                    &Environment::default(),
                );
                if !result
                    .as_ref()
                    .is_ok_and(|o| o.success() && o.stdout == marker.as_bytes())
                {
                    eprintln!("STRESS_FAILURE sender={sender} round={round} result={result:?}");
                    failed.store(true, std::sync::atomic::Ordering::Release)
                }
                barrier.wait();
                if failed.load(std::sync::atomic::Ordering::Acquire) {
                    break;
                }
            }
        }));
    }
    for thread in stress {
        thread.join().unwrap();
    }
    assert!(
        !failed.load(std::sync::atomic::Ordering::Acquire),
        "four valid concurrent senders failed"
    );
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(3));
    let mut parallel = Vec::new();
    for id in 0..2 {
        let root = root.clone();
        let barrier = barrier.clone();
        parallel.push(std::thread::spawn(move || {
            barrier.wait();
            let out = fastra_process::run_in(
                Domain::Bundled,
                &std::env::current_exe().unwrap(),
                &root,
                &[
                    "--exact".into(),
                    "bridge_driver".into(),
                    "--nocapture".into(),
                ],
                policy(),
                &Cancellation::default(),
                &Environment {
                    remove_prefixes: vec![],
                    set: vec![
                        ("HOST_BRIDGE_TEST_ROLE".into(), "parallel-nested".into()),
                        ("HOST_BRIDGE_PARALLEL_ID".into(), id.to_string().into()),
                    ],
                },
            )
            .unwrap();
            assert!(out.success());
            assert!(
                String::from_utf8_lossy(&out.stdout).contains(&format!("PARALLEL_HELPER_{id}_OK"))
            );
        }));
    }
    barrier.wait();
    for round in 0..5 {
        let marker = format!("ui-{round}");
        let out = run(
            Path::new("/usr/bin/python3"),
            &root,
            &[
                "-c".into(),
                "import sys,time;time.sleep(.01);sys.stdout.write(sys.argv[1])".into(),
                marker.clone().into(),
            ],
            policy(),
            &c,
            &Environment::default(),
        )
        .unwrap();
        assert_eq!(out.stdout, marker.as_bytes());
    }
    for child in parallel {
        child.join().unwrap();
    }
    let started = Instant::now();
    let mut seen = Vec::new();
    let mut observed = None;
    let out = fastra_process::run_with_stderr(
        Path::new("/usr/bin/python3"),
        &root,
        &[
            "-c".into(),
            "import sys,time;sys.stderr.write('early');sys.stderr.flush();time.sleep(.4)".into(),
        ],
        policy(),
        &c,
        &Environment::default(),
        fastra_process::ParentLoss::Unchanged,
        &mut |b| {
            observed = Some(started.elapsed());
            seen.extend_from_slice(b)
        },
    )
    .unwrap();
    assert!(out.success());
    assert_eq!(seen, b"early");
    assert!(observed.unwrap() < Duration::from_millis(350));
    assert!(matches!(
        py(
            &root,
            "import sys;sys.stdout.write('x'*100000)",
            Policy {
                stdout_bytes: 16,
                ..policy()
            },
            &c
        ),
        Err(Error::OutputLimit(_))
    ));
    assert!(matches!(
        py(
            &root,
            "import sys;sys.stderr.write('x'*100000)",
            Policy {
                stderr_bytes: 16,
                ..policy()
            },
            &c
        ),
        Err(Error::OutputLimit(_))
    ));
    let failure = py(
        &root,
        RESIST,
        Policy {
            timeout: Duration::from_millis(200),
            ..policy()
        },
        &c,
    );
    assert!(matches!(failure, Err(Error::TimedOut(_))));
    let pids = std::fs::read_to_string(root.join("owned-pids")).unwrap();
    for pid in pids.split_whitespace() {
        wait_for(|| dead(pid.parse().unwrap()));
    }
    std::fs::remove_file(root.join("owned-pids")).unwrap();
    let cancel = Cancellation::default();
    let worker = cancel.clone();
    let path = root.clone();
    let trigger = std::thread::spawn(move || {
        wait_for(|| path.join("owned-pids").exists());
        worker.cancel();
    });
    let failure = py(&root, RESIST, policy(), &cancel);
    trigger.join().unwrap();
    assert!(matches!(failure, Err(Error::Cancelled(_))));
    let pids = std::fs::read_to_string(root.join("owned-pids")).unwrap();
    for pid in pids.split_whitespace() {
        wait_for(|| dead(pid.parse().unwrap()));
    }
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
    let mut threads = Vec::new();
    for _ in 0..8 {
        let root = root.clone();
        let barrier = barrier.clone();
        threads.push(std::thread::spawn(move || {
            barrier.wait();
            py(
                &root,
                "import time;time.sleep(.5)",
                policy(),
                &Cancellation::default(),
            )
        }));
    }
    let mut accepted = 0;
    let mut rejected = 0;
    for t in threads {
        match t.join().unwrap() {
            Ok(o) => {
                assert!(o.success());
                accepted += 1
            }
            Err(Error::InvalidPolicy) => rejected += 1,
            other => panic!("unexpected bounded-concurrency result: {other:?}"),
        }
    }
    assert!((1..=4).contains(&accepted));
    assert_eq!(accepted + rejected, 8);
    println!("HOST_BRIDGE_PARALLEL four_senders=25_rounds requests=100 ui_plus_helpers=2 PASS");
    println!("HOST_BRIDGE_GATE discovery git raw_paths raw_argv stdin clear_environment agent_socket bundled_domain streaming_stderr output_limits timeout cancel concurrency PASS");
}
fn launch(role: &str, root: &Path) -> std::process::Child {
    let mut command = Command::new(env!("CARGO_BIN_EXE_fastra-runtime-host"));
    command.arg("--");
    if role != "owner-holding" {
        if let Some(namespace) = std::env::var_os("HOST_BRIDGE_NAMESPACE") {
            command.arg(namespace);
        }
    }
    command
        .arg(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "bridge_driver",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_remove("FASTRA_INTERNAL_HOST_FD")
        .env_remove("LD_LIBRARY_PATH")
        .env(
            "PATH",
            format!("{}:/usr/bin:/bin", root.join("host-bin").display()),
        )
        .env("HOME", root)
        .env("XDG_CACHE_HOME", root.join("host-cache"))
        .env("XDG_CONFIG_HOME", root.join("host-config"))
        .env("HOST_BRIDGE_TEST_ROOT", root)
        .env("HOST_BRIDGE_TEST_ROLE", role)
        .env("SSH_AUTH_SOCK", root.join("agent.sock"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}
fn fixture() -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    std::fs::create_dir(root.path().join("private-bin")).unwrap();
    std::fs::create_dir(root.path().join("host-bin")).unwrap();
    for name in ["tool4d", "poormans-text"] {
        let path = root.path().join("host-bin").join(name);
        std::fs::write(&path, "#!/bin/sh\n[ -z \"$LD_LIBRARY_PATH\" ] || exit 9\nprintf 'HOST_TOOL_WITHOUT_GUI_LD\\n'\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    let path = root.path().join("private-bin/git");
    std::fs::write(&path, "#!/bin/sh\nprintf 'PRIVATE_TOOL\\n'\n").unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
    root
}
#[test]
fn host_snapshot_and_bounded_runner_gate() {
    let root = fixture();
    let listener = UnixListener::bind(root.path().join("agent.sock")).unwrap();
    listener.set_nonblocking(true).unwrap();
    let at = Instant::now();
    let accept = std::thread::spawn(move || loop {
        match listener.accept() {
            Ok(_) => break,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(at.elapsed() < Duration::from_secs(12));
                std::thread::sleep(Duration::from_millis(5))
            }
            Err(e) => panic!("{e}"),
        }
    });
    let output = launch("normal", root.path()).wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    accept.join().unwrap();
    assert!(String::from_utf8_lossy(&output.stdout).contains("HOST_BRIDGE_GATE"));
    for line in String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|line| line.contains("HOST_BRIDGE_") || line.contains("HOST_DISCOVERY_"))
    {
        let marker = line
            .find("HOST_BRIDGE_")
            .or_else(|| line.find("HOST_DISCOVERY_"))
            .unwrap();
        println!("{}", &line[marker..]);
    }
}
#[test]
fn ui_owner_loss_kills_only_owned_term_resistant_group() {
    let root = fixture();
    let child = launch("owner", root.path());
    wait_for(|| root.path().join("owned-pids").exists());
    let pids = std::fs::read_to_string(root.path().join("owned-pids")).unwrap();
    // PID-Namespaces verändern die sichtbare UI-PID. Nur den eigenen Launcherbaum verfolgen.
    let ui = owned_ui_pid(child.id()).expect("owned UI child missing");
    assert_eq!(unsafe { libc::kill(ui, libc::SIGKILL) }, 0);
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(137));
    for pid in pids.split_whitespace() {
        wait_for(|| dead(pid.parse().unwrap()));
    }
    println!("HOST_BRIDGE_OWNER_LOSS PASS");
}

#[test]
fn owner_loss_is_independent_of_inherited_helper_fd() {
    let root = fixture();
    let child = launch("owner-holding", root.path());
    wait_for(|| {
        std::fs::read_to_string(root.path().join("owned-pids"))
            .is_ok_and(|v| v.split_whitespace().count() == 2)
    });
    let holder = std::fs::read_to_string(root.path().join("holder-pid"))
        .unwrap()
        .parse::<i32>()
        .unwrap();
    let holder_fd = unsafe { libc::syscall(libc::SYS_pidfd_open, holder, 0) };
    assert!(holder_fd >= 0);
    let holder_fd = unsafe { std::os::fd::OwnedFd::from_raw_fd(holder_fd as i32) };
    let pids = std::fs::read_to_string(root.path().join("owned-pids")).unwrap();
    let ui = owned_ui_pid(child.id()).unwrap();
    assert_eq!(unsafe { libc::kill(ui, libc::SIGKILL) }, 0);
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(137));
    assert!(
        !dead(holder),
        "helper must still hold inherited control FD after UI loss"
    );
    for pid in pids.split_whitespace() {
        wait_for(|| dead(pid.parse().unwrap()));
    }
    use std::os::fd::AsRawFd;
    assert_eq!(
        unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                holder_fd.as_raw_fd(),
                libc::SIGKILL,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        },
        0
    );
    println!("HOST_BRIDGE_HELD_HELPER_FD_OWNER_LOSS PASS");
}

#[test]
fn regular_broker_stop_reaps_ui_and_host_descendants() {
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        let root = fixture();
        let child = launch("owner", root.path());
        wait_for(|| root.path().join("owned-pids").exists());
        let pids = std::fs::read_to_string(root.path().join("owned-pids")).unwrap();
        let ui = owned_ui_pid(child.id()).expect("owned UI child missing");
        let started = Instant::now();
        assert_eq!(unsafe { libc::kill(child.id() as i32, signal) }, 0);
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(128 + signal));
        assert!(started.elapsed() < Duration::from_secs(5));
        wait_for(|| dead(ui));
        for pid in pids.split_whitespace() {
            wait_for(|| dead(pid.parse().unwrap()));
        }
    }
    println!("HOST_BRIDGE_REGULAR_STOP TERM INT HUP UI_HOST_DESCENDANTS PASS");
}

#[test]
fn regular_broker_stop_preserves_host_term_cleanup() {
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        let root = fixture();
        let child = launch("owner-cleanup", root.path());
        wait_for(|| root.path().join("owned-pids").exists());
        let pid = std::fs::read_to_string(root.path().join("owned-pids"))
            .unwrap()
            .parse()
            .unwrap();
        let ui = owned_ui_pid(child.id()).expect("owned UI child missing");
        assert_eq!(unsafe { libc::kill(child.id() as i32, signal) }, 0);
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(128 + signal));
        assert_eq!(
            std::fs::read_to_string(root.path().join("term-cleaned")).unwrap(),
            "clean"
        );
        wait_for(|| dead(ui) && dead(pid));
    }
    println!("HOST_BRIDGE_REGULAR_STOP HOST_TERM_CLEANUP PASS");
}
