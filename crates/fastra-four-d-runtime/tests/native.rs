//! Echter privater Prozess-/Namespaceweg mit ausdrücklich synthetischem Engineprotokoll.
use fastra_four_d_runtime::{macro_run, read};
use std::{
    fs,
    io::{Read, Write},
    os::{
        fd::AsRawFd,
        unix::{fs::MetadataExt, net::UnixStream, process::CommandExt},
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};
fn children_for(engine: &Path) -> usize {
    let meta = fs::metadata(engine).unwrap();
    fs::read_dir("/proc")
        .unwrap()
        .flatten()
        .filter(|e| {
            fs::metadata(e.path().join("exe"))
                .is_ok_and(|m| m.dev() == meta.dev() && m.ino() == meta.ino())
        })
        .count()
}
fn run_ui(root: &Path, optional: bool) {
    assert_eq!(fastra_process::host::is_active().unwrap(), optional);
    if optional {
        assert!(fastra_four_d_runtime::open_path(Path::new("/usr/bin/bwrap"), false).is_err());
    }

    if optional {
        std::env::set_var("PATH", "/private/wrong/path");
    }
    let project = root.join("workspace");
    let path = project.join("Project/Sources/Methods/Probe.4dm");
    let original = fs::read_to_string(&path).unwrap();
    let snapshot = fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default()).unwrap();
    let meta = fs::metadata(&project).unwrap();
    let tool = root.join("tool/tool4d");
    for operation in [read::Operation::Diagnostics, read::Operation::Signature] {
        let result = read::execute(read::Query {
            runtime_path: &tool,
            root: &project,
            root_identity: (meta.dev(), meta.ino()),
            snapshot: &snapshot,
            source: &original,
            operation,
            cursor: 0,
            token: "native-fixture".into(),
            cancel: &fastra_core::Cancellation::default(),
            process_cancel: &fastra_process::Cancellation::default(),
        })
        .unwrap();
        assert_eq!(result.server, "fixture-not-real-tool4d");
        assert_eq!(result.token, "native-fixture");
        assert_eq!(result.diagnostics.len() + result.signatures.len(), 1);
    }
    let engine = root.join("engine");
    let run = |source: &str, process_cancel: &fastra_process::Cancellation| {
        macro_run::execute(macro_run::Query {
            runtime: &tool,
            engine: &engine,
            original: source,
            variant: "komplettieren",
            method: "Probe",
            cancel: &fastra_core::Cancellation::default(),
            process_cancel,
            should_start: &|| true,
        })
    };
    let source = "// fixture input\nFutureCommand:C9999(1)\n";
    let macro_run::Outcome::Changed(result) =
        run(source, &fastra_process::Cancellation::default()).unwrap()
    else {
        panic!("changed result required")
    };
    assert!(result.starts_with("// isolated result\n"));
    assert!(result.contains("FutureCommand:C9999"));
    assert_eq!(fs::read_to_string(&path).unwrap(), original);
    assert_eq!(
        fs::read_to_string(engine.join("userPreferences.original/debuggerWatches.json")).unwrap(),
        "original watches"
    );
    assert!(!engine.join("private-runtime-write").exists());
    let cancel = fastra_process::Cancellation::default();
    let trigger = cancel.clone();
    let thread = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        trigger.cancel();
    });
    let cancelled = run("// SLOW\n", &cancel).unwrap_err();
    assert!(
        cancelled.to_ascii_lowercase().contains("cancel"),
        "{cancelled}"
    );
    thread.join().unwrap();
    assert_eq!(children_for(&tool), 0);
    println!("FOUR_D_NATIVE_GATE optional={optional} diagnostics signature macro_nonzero_status retokenize source_identity original_watches cancellation_setsid_cleanup no_broker_fd PASS");
}
fn fd_gate(helper: &Path) {
    let (mut parent, child) = UnixStream::pair().unwrap();
    parent
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let fd = child.as_raw_fd();
    let mut command = Command::new(helper);
    command
        .arg("--fastra-4d-worker")
        .env_remove("FASTRA_INTERNAL_HOST_FD")
        .env_remove("LD_LIBRARY_PATH")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped());
    unsafe {
        command.pre_exec(move || {
            if libc::dup2(fd, 77) < 0 || libc::fcntl(77, libc::F_SETFD, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut process = command.spawn().unwrap();
    drop(child);
    assert_eq!(
        parent.read(&mut [0]).unwrap(),
        0,
        "injected FD77 must close before stdin/protocol"
    );
    assert!(process.try_wait().unwrap().is_none());
    process.stdin.take().unwrap().write_all(b"{}").unwrap();
    assert!(process.wait_with_output().unwrap().status.success());
    println!("FOUR_D_UNMARKED_FD77_CLOSED_BEFORE_PROTOCOL PASS");
}
fn main() {
    if let Some(code) = read::worker_entry().or_else(macro_run::worker_entry) {
        std::process::exit(code);
    }
    let args: Vec<_> = std::env::args_os().collect();
    if args.get(1).is_some_and(|v| v == "--ui-driver") {
        run_ui(Path::new(&args[2]), args[3] == "true");
        return;
    }
    if !args.get(1).is_some_and(|v| v == "--gate") {
        println!(
            "SKIP native namespace gate requires explicit fixture/worker/owner/entry/ICU paths"
        );
        return;
    }
    let fixture = PathBuf::from(&args[2]);
    let helper = PathBuf::from(&args[3]);
    let owner = PathBuf::from(&args[4]);
    let entry = PathBuf::from(&args[5]);
    let icu = PathBuf::from(&args[6]);
    fd_gate(&helper);
    for optional in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let bin = root.join("app/libexec");
        fs::create_dir_all(&bin).unwrap();
        fs::create_dir(root.join("app/lib")).unwrap();
        for entry in fs::read_dir(&icu).unwrap().flatten() {
            let path = entry.path();
            if path.is_file() {
                fs::copy(&path, root.join("app/lib").join(entry.file_name())).unwrap();
            }
        }
        let driver = bin.join("driver");
        fs::copy(std::env::current_exe().unwrap(), &driver).unwrap();
        fs::copy(&helper, bin.join("fastra-4d-worker")).unwrap();
        fs::create_dir_all(root.join("tool/Resources")).unwrap();
        fs::copy(&fixture, root.join("tool/tool4d")).unwrap();
        for dir in [
            "workspace/Project/Sources/Methods",
            "engine/Project/Sources/Methods",
            "engine/userPreferences.original",
        ] {
            fs::create_dir_all(root.join(dir)).unwrap();
        }
        fs::write(root.join("workspace/Project/Test.4DProject"), "{}").unwrap();
        fs::write(
            root.join("workspace/Project/Sources/Methods/Probe.4dm"),
            "// Grüße 🚀\r\nProbe()\r\n",
        )
        .unwrap();
        fs::write(root.join("engine/Project/Test.4DProject"), "{}").unwrap();
        fs::write(
            root.join("engine/Project/Sources/Methods/MacroRun.4dm"),
            "// synthetic engine only",
        )
        .unwrap();
        fs::write(
            root.join("engine/userPreferences.original/debuggerWatches.json"),
            "original watches",
        )
        .unwrap();
        let mut command = if optional {
            let mut c = Command::new(&owner);
            c.arg("--").arg(&entry);
            c
        } else {
            Command::new(&driver)
        };
        if optional {
            command.arg(&driver);
        }
        command
            .arg("--ui-driver")
            .arg(root)
            .arg(optional.to_string())
            .env_remove("FASTRA_INTERNAL_HOST_FD")
            .env_remove("LD_PRELOAD")
            .env("XDG_CACHE_HOME", root.join("cache"));
        if optional {
            command
                .env_remove("LD_LIBRARY_PATH")
                .env("FASTRA_RUNTIME_CONTROL_LIBS", root.join("app/lib"));
        } else {
            command.env("LD_LIBRARY_PATH", root.join("app/lib"));
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        print!("{}", String::from_utf8_lossy(&output.stdout));
        assert_eq!(children_for(&root.join("tool/tool4d")), 0);
    }
}
