use super::*;
#[test]
fn original_arguments_variants_and_exceptions() {
    for variant in VARIANTS {
        let actual = arguments(
            Path::new("/engine/Project/E.4DProject"),
            Path::new("/output/in.4dm"),
            Path::new("/output/out.4dm"),
            variant,
            "Übersicht",
        )
        .unwrap();
        assert_eq!(
            actual,
            vec![
                "--project",
                "/engine/Project/E.4DProject",
                "--dataless",
                "--skip-onstartup",
                "--opening-mode",
                "interpreted",
                "--startup-method",
                "MacroRun",
                "--user-param",
                &format!("/output/in.4dm|/output/out.4dm|{variant}|Übersicht")
            ]
            .into_iter()
            .map(OsString::from)
            .collect::<Vec<_>>()
        );
    }
    for method in ["00_DM_Info", "Compiler_Test", "a|b", "bad\nname", ""] {
        assert!(validate(VARIANTS[0], method).is_err());
    }
    assert!(validate("future", "Method").is_err());
    assert!(arguments(
        Path::new("/p"),
        Path::new("/a|b"),
        Path::new("/o"),
        VARIANTS[0],
        "Method"
    )
    .is_err());
}
#[test]
fn original_status_is_authoritative_and_missing_empty_or_foreign_status_fails() {
    assert_eq!(
        interpret(Some("OK\n"), Some("new".into())).unwrap(),
        Outcome::Changed("new".into())
    );
    assert_eq!(
        interpret(Some("UNVERAENDERT\n"), None).unwrap(),
        Outcome::Unchanged
    );
    assert_eq!(
        interpret(Some(" FEHLER details "), None).unwrap_err(),
        "details"
    );
    for status in [None, Some(""), Some("unexpected"), Some("FEHLER")] {
        assert!(interpret(status, None).is_err());
    }
    for output in [None, Some(String::new())] {
        assert!(interpret(Some("OK"), output).is_err());
    }
}
#[test]
fn bounded_result_rejects_symlink_fifo_invalid_utf8_and_oversize() {
    use std::os::unix::fs::symlink;
    let root = tempfile::tempdir().unwrap();
    let p = root.path().join("out");
    fs::write(&p, b"\xef\xbb\xbfOK\n").unwrap();
    assert_eq!(bounded_file(&p, 16).unwrap().as_deref(), Some("OK\n"));
    fs::write(&p, [255]).unwrap();
    assert!(bounded_file(&p, 16).is_err());
    fs::write(&p, [0; 17]).unwrap();
    assert!(bounded_file(&p, 16).is_err());
    fs::remove_file(&p).unwrap();
    symlink("/etc/passwd", &p).unwrap();
    assert!(bounded_file(&p, 16384).is_err());
    fs::remove_file(&p).unwrap();
    let path = std::ffi::CString::new(p.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    assert!(bounded_file(&p, 16).is_err());
}
fn fixture() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("original");
    fs::create_dir_all(root.join("Project/Sources/Methods")).unwrap();
    fs::write(root.join("Project/Probe.4DProject"), "{}").unwrap();
    fs::write(
        root.join("Project/Sources/Methods/MacroRun.4dm"),
        "// synthetic",
    )
    .unwrap();
    (dir, root)
}
#[test]
fn engine_copy_preserves_original_watches_and_rejects_symlink_escape_and_large_files() {
    use std::os::unix::fs::symlink;
    let (dir, root) = fixture();
    fs::create_dir(root.join("userPreferences.original")).unwrap();
    let watches = root.join("userPreferences.original/debuggerWatches.json");
    fs::write(&watches, "original watches").unwrap();
    let copy = dir.path().join("copy");
    let project = private_project::copy(&root, &copy, &Cancellation::default()).unwrap();
    assert_eq!(project, Path::new("Project/Probe.4DProject"));
    assert!(!copy.join("userPreferences.original").exists());
    assert_eq!(fs::read_to_string(&watches).unwrap(), "original watches");
    fs::write(
        copy.join("Project/Sources/Methods/MacroRun.4dm"),
        "changed private copy",
    )
    .unwrap();
    assert_eq!(
        fs::read_to_string(root.join("Project/Sources/Methods/MacroRun.4dm")).unwrap(),
        "// synthetic"
    );
    symlink("/etc/passwd", root.join("outside")).unwrap();
    assert!(
        private_project::copy(&root, &dir.path().join("escape"), &Cancellation::default()).is_err()
    );
    fs::remove_file(root.join("outside")).unwrap();
    let f = fs::File::create(root.join("large")).unwrap();
    f.set_len(32 * 1024 * 1024 + 1).unwrap();
    assert!(private_project::copy(
        &root,
        &dir.path().join("large-copy"),
        &Cancellation::default()
    )
    .is_err());
}
#[test]
fn fifo_serializes_and_cancelled_queued_owner_never_starts() {
    let first = Slot::acquire(&Cancellation::default()).unwrap();
    let cancelled = Cancellation::default();
    let child = cancelled.clone();
    let (tx, rx) = std::sync::mpsc::channel();
    let waiting = std::thread::spawn(move || {
        let result = Slot::acquire(&child);
        tx.send(result.is_ok()).unwrap();
    });
    std::thread::sleep(Duration::from_millis(30));
    assert!(rx.try_recv().is_err());
    cancelled.cancel();
    assert!(!rx.recv_timeout(Duration::from_secs(1)).unwrap());
    waiting.join().unwrap();
    drop(first);
    let _next = Slot::acquire(&Cancellation::default()).unwrap();
}
#[test]
fn stale_owner_is_rechecked_after_queue_before_any_files_or_runtime_are_opened() {
    let first = Slot::acquire(&Cancellation::default()).unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let waiting = std::thread::spawn(move || {
        let result = execute(Query {
            runtime: Path::new("/never-open-runtime"),
            engine: Path::new("/never-open-engine"),
            original: "ALERT:C41(1)",
            variant: VARIANTS[0],
            method: "Method",
            cancel: &Cancellation::default(),
            process_cancel: &process::Cancellation::default(),
            should_start: &|| false,
        });
        tx.send(result.unwrap_err()).unwrap();
    });
    assert!(rx.recv_timeout(Duration::from_millis(30)).is_err());
    drop(first);
    assert!(rx
        .recv_timeout(Duration::from_secs(1))
        .unwrap()
        .contains("changed before MacroRun"));
    waiting.join().unwrap();
}

#[test]
#[ignore = "Requires explicitly provided external engine and a private destination"]
fn external_engine_private_copy_probe() {
    let source = PathBuf::from(std::env::var_os("FASTRA_MACRO_ENGINE_COPY_SOURCE").unwrap());
    let destination =
        PathBuf::from(std::env::var_os("FASTRA_MACRO_ENGINE_COPY_DESTINATION").unwrap());
    let relative = private_project::copy(&source, &destination, &Cancellation::default()).unwrap();
    fs::write(
        destination.parent().unwrap().join("project-relative.json"),
        serde_json::to_vec(&relative).unwrap(),
    )
    .unwrap();
}
