use fastra_process::{run_with_stderr, Cancellation, Environment, ParentLoss, Policy};
use std::{
    fs,
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant},
};
#[test]
fn parent_loss_child_driver() {
    let Some(root) = std::env::var_os("FASTRA_PARENT_LOSS_CHILD") else {
        return;
    };
    let root = std::path::PathBuf::from(root);
    let script="import os,signal,time,sys\nsignal.signal(signal.SIGTERM,lambda a,b: (open('terminated','w').write(str(a)),sys.exit(130)))\nopen('pid','w').write(str(os.getpid()))\nwhile True: time.sleep(.01)";
    let _ = run_with_stderr(
        Path::new("/usr/bin/python3"),
        &root,
        &["-c".into(), script.into()],
        Policy {
            timeout: Duration::from_secs(8),
            ..Default::default()
        },
        &Cancellation::default(),
        &Environment::default(),
        ParentLoss::Terminate,
        &mut |_| {},
    );
}
#[test]
fn hard_host_loss_delivers_term_to_direct_cli() {
    let root = tempfile::tempdir().unwrap();
    let mut host = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "parent_loss_child_driver", "--nocapture"])
        .env("FASTRA_PARENT_LOSS_CHILD", root.path())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let started = Instant::now();
    let pid = loop {
        if let Ok(pid) = fs::read_to_string(root.path().join("pid")) {
            if let Ok(pid) = pid.parse::<u32>() {
                break pid;
            }
        }
        if started.elapsed() >= Duration::from_secs(3) {
            let _ = host.kill();
            let _ = host.wait();
            panic!("direct CLI did not publish its PID");
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    host.kill().unwrap();
    host.wait().unwrap();
    let started = Instant::now();
    loop {
        if fs::read_to_string(root.path().join("terminated")).is_ok_and(|value| value == "15") {
            break;
        }
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "direct CLI did not acknowledge SIGTERM"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    let started = Instant::now();
    loop {
        let dead = fs::read_to_string(format!("/proc/{pid}/stat")).map_or(true, |s| {
            s.rsplit_once(')')
                .is_some_and(|(_, s)| s.starts_with(" Z") || s.starts_with(" X"))
        });
        if dead {
            break;
        }
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "direct CLI survived parent-loss TERM"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}
#[test]
fn parent_loss_policy_preserves_normal_exit_and_signal() {
    for (script, code, signal) in [
        ("import sys;sys.exit(23)", Some(23), None),
        (
            "import os,signal;os.kill(os.getpid(),signal.SIGUSR1)",
            None,
            Some(10),
        ),
    ] {
        let output = run_with_stderr(
            Path::new("/usr/bin/python3"),
            Path::new("/"),
            &["-c".into(), script.into()],
            Policy::default(),
            &Cancellation::default(),
            &Environment::default(),
            ParentLoss::Terminate,
            &mut |_| {},
        )
        .unwrap();
        assert_eq!(output.exit_code, code);
        assert_eq!(output.signal, signal);
    }
}
