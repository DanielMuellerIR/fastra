use super::*;
fn read(path: &Path) -> Config {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}
#[test]
fn two_stale_hubs_merge_disjoint_fields_and_queued_saves_keep_submission_order() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("settings/4d-macros.json");
    let store = SettingsStore::new();
    fn detached_hub() -> Hub {
        Hub {
            ui: Weak::new(),
            config: RefCell::new(Config::default()),
            catalog: RefCell::new(None),
            key: RefCell::new(None),
            generation: Cell::new(0),
            cancel: RefCell::new(Cancellation::default()),
            busy: Cell::new(false),
            settings_loaded: Cell::new(true),
            dialog: RefCell::new(Weak::new()),
            problem: RefCell::new(None),
        }
    }
    let hub_a = detached_hub();
    let hub_b = detached_hub();
    assert_eq!(*hub_a.config.borrow(), *hub_b.config.borrow());
    // Beide Clients stammen vom selben alten Stand; übertragen werden ausschließlich ihre Feldänderungen.
    let user = store.submit(
        path.clone(),
        Change::Set(Field::User, Some("/user-macros".into())),
    );
    let installation = store.submit(
        path.clone(),
        Change::Set(Field::Installation, Some("/installation".into())),
    );
    let first_runtime = store.submit(
        path.clone(),
        Change::Set(Field::Runtime, Some("/old-runtime".into())),
    );
    let last_runtime = store.submit(
        path.clone(),
        Change::Set(Field::Runtime, Some("/new-runtime".into())),
    );
    let engine = store.submit(
        path.clone(),
        Change::Set(Field::Engine, Some("/engine".into())),
    );
    // Antworten absichtlich in umgekehrter Reihenfolge abholen: die Schreibfolge bleibt die UI-Einreihfolge.
    let final_config = engine.recv().unwrap().unwrap();
    assert_eq!(
        last_runtime.recv().unwrap().unwrap().runtime,
        Some("/new-runtime".into())
    );
    assert_eq!(
        first_runtime.recv().unwrap().unwrap().runtime,
        Some("/old-runtime".into())
    );
    *hub_b.config.borrow_mut() = installation.recv().unwrap().unwrap();
    *hub_a.config.borrow_mut() = user.recv().unwrap().unwrap();
    assert_eq!(
        final_config,
        Config {
            user: Some("/user-macros".into()),
            installation: Some("/installation".into()),
            runtime: Some("/new-runtime".into()),
            engine: Some("/engine".into())
        }
    );
    assert_eq!(read(&path), final_config);
    // Ein fremder neuer Diskstand darf nicht durch einen langlebigen Clientzustand verschwinden.
    let mut external = final_config;
    external.user = Some("/external-user".into());
    fs::write(&path, serde_json::to_vec(&external).unwrap()).unwrap();
    let merged = store
        .submit(
            path.clone(),
            Change::Set(Field::Engine, Some("/another-engine".into())),
        )
        .recv()
        .unwrap()
        .unwrap();
    assert_eq!(merged.user, external.user);
    assert_eq!(read(&path), merged);
    store
        .submit(path.clone(), Change::Reset)
        .recv()
        .unwrap()
        .unwrap();
    assert_eq!(read(&path), Config::default());
}
#[test]
fn failed_settings_write_returns_no_new_config_and_preserves_existing_target() {
    use std::os::unix::fs::symlink;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("4d-macros.json");
    let original = dir.path().join("original.json");
    fs::write(
        &original,
        serde_json::to_vec(&Config {
            runtime: Some("/original-runtime".into()),
            ..Default::default()
        })
        .unwrap(),
    )
    .unwrap();
    let before = fs::read(&original).unwrap();
    symlink(&original, &path).unwrap();
    let store = SettingsStore::new();
    let result = store
        .submit(
            path.clone(),
            Change::Set(Field::Runtime, Some("/uncommitted-runtime".into())),
        )
        .recv()
        .unwrap();
    assert!(result.is_err());
    assert_eq!(fs::read(&original).unwrap(), before);
    assert!(fs::symlink_metadata(&path).unwrap().is_symlink());
    fs::remove_file(&path).unwrap();
    fs::write(&path, "{invalid-json").unwrap();
    let before = fs::read(&path).unwrap();
    assert!(store
        .submit(
            path.clone(),
            Change::Set(Field::Engine, Some("/new".into()))
        )
        .recv()
        .unwrap()
        .is_err());
    assert_eq!(fs::read(&path).unwrap(), before);
}

#[test]
fn settings_write_does_not_create_an_unreadably_large_configuration() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("4d-macros.json");
    let result = SettingsStore::new()
        .submit(
            path.clone(),
            Change::Set(Field::User, Some("x".repeat(SETTINGS_BYTES).into())),
        )
        .recv()
        .unwrap();
    assert!(result.is_err());
    assert!(!path.exists());
}

#[test]
fn cross_process_settings_child() {
    let Some(directory) = std::env::var_os("FASTRA_MACRO_SETTINGS_CHILD_DIR") else {
        return;
    };
    let directory = PathBuf::from(directory);
    let role = std::env::var("FASTRA_MACRO_SETTINGS_CHILD_ROLE").unwrap();
    let field = if role == "user" {
        Field::User
    } else {
        Field::Installation
    };
    fs::write(directory.join(format!("ready-{role}")), "ready").unwrap();
    SettingsStore::new()
        .submit(
            directory.join("4d-macros.json"),
            Change::Set(field, Some(format!("/{role}-process-choice").into())),
        )
        .recv()
        .unwrap()
        .unwrap();
    fs::write(directory.join(format!("done-{role}")), "done").unwrap();
}

#[test]
fn independent_processes_lock_before_fresh_read_and_keep_disjoint_fields() {
    use std::{
        os::fd::AsRawFd,
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("4d-macros.json");
    let original = Config {
        runtime: Some("/existing-runtime".into()),
        ..Default::default()
    };
    fs::write(&path, serde_json::to_vec(&original).unwrap()).unwrap();
    let parent = fs::File::open(dir.path()).unwrap();
    assert_eq!(unsafe { libc::flock(parent.as_raw_fd(), libc::LOCK_EX) }, 0);
    let executable = std::env::current_exe().unwrap();
    struct Children(Vec<std::process::Child>);
    impl Drop for Children {
        fn drop(&mut self) {
            for child in &mut self.0 {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
    let mut children = Children(Vec::new());
    for role in ["user", "installation"] {
        children.0.push(
            Command::new(&executable)
                .args([
                    "--exact",
                    "four_d_macros::discovery::settings_tests::cross_process_settings_child",
                    "--nocapture",
                ])
                .env("FASTRA_MACRO_SETTINGS_CHILD_DIR", dir.path())
                .env("FASTRA_MACRO_SETTINGS_CHILD_ROLE", role)
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .unwrap(),
        );
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while !["user", "installation"]
        .iter()
        .all(|role| dir.path().join(format!("ready-{role}")).exists())
    {
        assert!(
            Instant::now() < deadline,
            "Both independent settings processes must start"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    // Ein alter Writer ohne Prozesssperre würde trotz unserer gehaltenen Sperre bereits umbenennen.
    std::thread::sleep(Duration::from_millis(150));
    let unchanged_while_locked = read(&path) == original
        && ["user", "installation"]
            .iter()
            .all(|role| !dir.path().join(format!("done-{role}")).exists());
    assert_eq!(unsafe { libc::flock(parent.as_raw_fd(), libc::LOCK_UN) }, 0);
    for child in &mut children.0 {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("Settings child did not finish");
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    assert!(
        unchanged_while_locked,
        "Every process must acquire the bound parent lock before its fresh read/write"
    );
    assert_eq!(
        read(&path),
        Config {
            user: Some("/user-process-choice".into()),
            installation: Some("/installation-process-choice".into()),
            runtime: original.runtime,
            engine: None
        }
    );
}
