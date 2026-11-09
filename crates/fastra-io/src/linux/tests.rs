use super::*;
use fastra_core::{preview, Limits, SearchMode, SearchRequest};
use std::os::unix::{
    ffi::OsStringExt,
    fs::{symlink, PermissionsExt},
    process::ExitStatusExt,
};

fn fixture() -> tempfile::TempDir {
    let root = std::env::var_os("FASTRA_IO_TEST_ROOT").unwrap_or_else(|| "/var/tmp".into());
    tempfile::Builder::new()
        .prefix("fastra-io-test-")
        .tempdir_in(root)
        .unwrap()
}
fn initial(root: &Path) {
    std::fs::write(root.join("a"), "old 😀\r\n").unwrap();
    std::fs::write(root.join("b"), "old e\u{301}\n").unwrap();
}
fn change(path: &Path, find: &str, replace: &str) -> Change {
    let cancel = Cancellation::default();
    let snapshot = Snapshot::read(path, &cancel).unwrap();
    let request = SearchRequest {
        pattern: find.into(),
        replacement: replace.into(),
        mode: SearchMode::Literal,
        case_sensitive: true,
        range: None,
    };
    let p = preview(
        std::str::from_utf8(snapshot.bytes()).unwrap(),
        17,
        23,
        &request,
        Limits::default(),
        &cancel,
    )
    .unwrap();
    let indices = (0..p.matches().len()).collect::<Vec<_>>();
    Change::from_preview(snapshot, &p, 17, 23, &indices, &cancel).unwrap()
}
fn changes(root: &Path) -> Vec<Change> {
    ["a", "b"]
        .map(|name| change(&root.join(name), "old", "new"))
        .into()
}
fn assert_original(root: &Path) {
    assert_eq!(
        std::fs::read(root.join("a")).unwrap(),
        "old 😀\r\n".as_bytes()
    );
    assert_eq!(
        std::fs::read(root.join("b")).unwrap(),
        "old e\u{301}\n".as_bytes()
    );
}
fn journals(root: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(root)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| {
            p.file_name()
                .unwrap()
                .as_bytes()
                .starts_with(b".fastra-transaction-")
        })
        .collect()
}

#[test]
fn real_multifile_apply_reopen_undo_and_cleanup() {
    let root = fixture();
    initial(root.path());
    let cancel = Cancellation::default();
    let transaction = Transaction::apply(changes(root.path()), &cancel)
        .unwrap()
        .unwrap();
    assert_eq!(transaction.phase(), Phase::Applied);
    assert_eq!(
        std::fs::read(root.path().join("a")).unwrap(),
        "new 😀\r\n".as_bytes()
    );
    assert_eq!(
        std::fs::read(root.path().join("b")).unwrap(),
        "new e\u{301}\n".as_bytes()
    );
    assert_eq!(
        transaction.inspect(&cancel).unwrap(),
        [FileState::Replaced, FileState::Replaced]
    );
    let location = transaction.path().to_owned();
    drop(transaction);
    let mut transaction = Transaction::reopen(&location).unwrap();
    transaction.undo(&cancel).unwrap();
    assert_original(root.path());
    transaction.discard(&cancel).unwrap();
    assert!(!location.exists());
}

#[test]
fn changed_source_rejects_apply_before_any_write() {
    let root = fixture();
    initial(root.path());
    let plan = changes(root.path());
    std::fs::write(root.path().join("b"), b"foreign").unwrap();
    assert!(matches!(
        Transaction::apply(plan, &Cancellation::default()),
        Err(Error::Stale)
    ));
    assert_eq!(
        std::fs::read(root.path().join("a")).unwrap(),
        "old 😀\r\n".as_bytes()
    );
    assert_eq!(std::fs::read(root.path().join("b")).unwrap(), b"foreign");
    assert!(journals(root.path()).is_empty());
}

#[test]
fn noop_input_remains_in_final_preflight() {
    let root = fixture();
    initial(root.path());
    let plan = vec![
        change(&root.path().join("a"), "old", "new"),
        change(&root.path().join("b"), "old", "old"),
    ];
    let result =
        Transaction::apply_observing(plan, &Cancellation::default(), &mut |point, _, _| {
            if point == "prepared" {
                std::fs::write(root.path().join("b"), b"foreign").unwrap();
            }
        });
    assert!(matches!(result, Err(Error::Stale)));
    assert_eq!(
        std::fs::read(root.path().join("a")).unwrap(),
        "old 😀\r\n".as_bytes()
    );
    assert_eq!(std::fs::read(root.path().join("b")).unwrap(), b"foreign");
    assert!(journals(root.path()).is_empty());
}

#[test]
fn cancelled_after_first_exchange_rolls_back_both_files() {
    let root = fixture();
    initial(root.path());
    let cancel = Cancellation::default();
    let result = Transaction::apply_observing(changes(root.path()), &cancel, &mut |point, _, _| {
        if point == "exchanged" {
            cancel.cancel();
        }
    });
    assert!(matches!(
        result,
        Err(Error::Core(fastra_core::Error::Cancelled))
    ));
    assert_original(root.path());
    let locations = journals(root.path());
    assert_eq!(locations.len(), 1);
    Transaction::reopen(&locations[0])
        .unwrap()
        .discard(&Cancellation::default())
        .unwrap();
}

#[test]
fn cancellation_before_apply_creates_nothing() {
    let root = fixture();
    initial(root.path());
    let plan = changes(root.path());
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(matches!(
        Transaction::apply(plan, &cancel),
        Err(Error::Core(fastra_core::Error::Cancelled))
    ));
    assert_original(root.path());
    assert!(journals(root.path()).is_empty());
}

#[test]
fn same_bytes_at_new_inode_are_stale() {
    let root = fixture();
    initial(root.path());
    let plan = changes(root.path());
    std::fs::write(root.path().join("other"), "old 😀\r\n").unwrap();
    std::fs::rename(root.path().join("other"), root.path().join("a")).unwrap();
    assert!(matches!(
        Transaction::apply(plan, &Cancellation::default()),
        Err(Error::Stale)
    ));
    assert_original(root.path());
}

#[test]
fn symlink_parent_and_source_are_rejected() {
    let root = fixture();
    initial(root.path());
    symlink(root.path().join("a"), root.path().join("link")).unwrap();
    assert!(Snapshot::read(&root.path().join("link"), &Cancellation::default()).is_err());
    symlink(root.path(), root.path().join("parent-link")).unwrap();
    assert!(Snapshot::read(&root.path().join("parent-link/a"), &Cancellation::default()).is_err());
    assert_original(root.path());
}

#[test]
fn fifo_is_rejected_without_waiting_for_a_writer() {
    let root = fixture();
    let path = root.path().join("fifo");
    let value = CString::new(path.as_os_str().as_bytes()).unwrap();
    syscall(unsafe { libc::mkfifo(value.as_ptr(), 0o600) }).unwrap();
    assert!(matches!(
        Snapshot::read(&path, &Cancellation::default()),
        Err(Error::UnsupportedMetadata)
    ));
}

#[test]
fn hardlinked_file_is_rejected() {
    let root = fixture();
    initial(root.path());
    std::fs::hard_link(root.path().join("a"), root.path().join("alias")).unwrap();
    assert!(matches!(
        Snapshot::read(&root.path().join("a"), &Cancellation::default()),
        Err(Error::UnsupportedMetadata)
    ));
}

#[test]
fn changed_parent_identity_cannot_redirect_writes() {
    let root = fixture();
    let parent = root.path().join("parent");
    std::fs::create_dir(&parent).unwrap();
    initial(&parent);
    let plan = changes(&parent);
    std::fs::rename(&parent, root.path().join("moved")).unwrap();
    std::fs::create_dir(&parent).unwrap();
    initial(&parent);
    assert!(matches!(
        Transaction::apply(plan, &Cancellation::default()),
        Err(Error::Stale)
    ));
    assert_original(&parent);
    assert_original(&root.path().join("moved"));
}

#[test]
fn mode_and_xattrs_survive_apply_and_undo() {
    let root = fixture();
    initial(root.path());
    let path = root.path().join("a");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
    let file = File::open(&path).unwrap();
    let key = CString::new("user.fastra-test").unwrap();
    syscall(unsafe {
        libc::fsetxattr(
            file.as_raw_fd(),
            key.as_ptr(),
            b"metadata".as_ptr().cast(),
            8,
            0,
        )
    })
    .unwrap();
    let original = attributes(&file).unwrap();
    let cancel = Cancellation::default();
    let mut transaction = Transaction::apply(changes(root.path()), &cancel)
        .unwrap()
        .unwrap();
    assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o640);
    assert_eq!(attributes(&File::open(&path).unwrap()).unwrap(), original);
    let location = transaction.path().to_owned();
    drop(transaction);
    transaction = Transaction::reopen(&location).unwrap();
    transaction.undo(&cancel).unwrap();
    assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o640);
    assert_eq!(attributes(&File::open(&path).unwrap()).unwrap(), original);
    assert_original(root.path());
    transaction.discard(&cancel).unwrap();
}

#[test]
fn non_utf8_filenames_roundtrip_through_journal() {
    let root = fixture();
    let path = root.path().join(OsString::from_vec(b"file-\xff".to_vec()));
    std::fs::write(&path, b"old").unwrap();
    let cancel = Cancellation::default();
    let transaction = Transaction::apply(vec![change(&path, "old", "new")], &cancel)
        .unwrap()
        .unwrap();
    let location = transaction.path().to_owned();
    drop(transaction);
    let mut transaction = Transaction::reopen(&location).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), b"new");
    transaction.undo(&cancel).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), b"old");
    transaction.discard(&cancel).unwrap();
}

#[test]
fn undo_refuses_foreign_target_and_retains_all_versions() {
    let root = fixture();
    initial(root.path());
    let cancel = Cancellation::default();
    let mut transaction = Transaction::apply(changes(root.path()), &cancel)
        .unwrap()
        .unwrap();
    std::fs::write(root.path().join("a"), b"foreign").unwrap();
    assert!(matches!(
        transaction.undo(&cancel),
        Err(Error::RecoveryRequired(_))
    ));
    assert_eq!(std::fs::read(root.path().join("a")).unwrap(), b"foreign");
    assert_eq!(
        std::fs::read(root.path().join("b")).unwrap(),
        "new e\u{301}\n".as_bytes()
    );
    assert_eq!(
        std::fs::read(transaction.path().join("replacement-0")).unwrap(),
        "old 😀\r\n".as_bytes()
    );
    assert_eq!(
        std::fs::read(transaction.path().join("original-copy-0")).unwrap(),
        "old 😀\r\n".as_bytes()
    );
    assert!(transaction.path().exists());
}

#[test]
fn private_journal_and_symlinks_are_validated_on_reopen() {
    let root = fixture();
    initial(root.path());
    let cancel = Cancellation::default();
    let transaction = Transaction::apply(changes(root.path()), &cancel)
        .unwrap()
        .unwrap();
    let location = transaction.path().to_owned();
    drop(transaction);
    let alias = root
        .path()
        .join(".fastra-transaction-00000000000000000000000000000000");
    symlink(&location, &alias).unwrap();
    assert!(Transaction::reopen(&alias).is_err());
    std::fs::set_permissions(&location, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(matches!(
        Transaction::reopen(&location),
        Err(Error::InvalidJournal)
    ));
    std::fs::set_permissions(&location, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::rename(location.join("intent.json"), location.join("other")).unwrap();
    symlink("other", location.join("intent.json")).unwrap();
    assert!(Transaction::reopen(&location).is_err());
    assert!(location.join("replacement-0").exists());
}

#[test]
fn truncated_or_escaping_journal_is_rejected() {
    for escaping in [false, true] {
        let root = fixture();
        initial(root.path());
        let cancel = Cancellation::default();
        let transaction = Transaction::apply(changes(root.path()), &cancel)
            .unwrap()
            .unwrap();
        let location = transaction.path().to_owned();
        drop(transaction);
        if escaping {
            let mut value: serde_json::Value =
                serde_json::from_slice(&std::fs::read(location.join("intent.json")).unwrap())
                    .unwrap();
            value["entries"][0]["name"] = serde_json::json!(b"../foreign".to_vec());
            std::fs::write(
                location.join("intent.json"),
                serde_json::to_vec(&value).unwrap(),
            )
            .unwrap();
        } else {
            std::fs::write(location.join("intent.json"), b"{").unwrap();
        }
        assert!(matches!(
            Transaction::reopen(&location),
            Err(Error::InvalidJournal)
        ));
        assert_eq!(
            std::fs::read(location.join("original-copy-0")).unwrap(),
            "old 😀\r\n".as_bytes()
        );
    }
}

#[test]
fn duplicate_inputs_and_oversized_files_are_rejected() {
    let root = fixture();
    initial(root.path());
    assert!(matches!(
        Transaction::apply(
            vec![
                change(&root.path().join("a"), "old", "new"),
                change(&root.path().join("a"), "old", "new")
            ],
            &Cancellation::default()
        ),
        Err(Error::InvalidPath)
    ));
    let big = File::create(root.path().join("large")).unwrap();
    big.set_len(MAX_BYTES as u64 + 1).unwrap();
    assert!(matches!(
        Snapshot::read(&root.path().join("large"), &Cancellation::default()),
        Err(Error::Limit)
    ));
}

#[test]
fn entirely_noop_plan_validates_without_creating_journal() {
    let root = fixture();
    initial(root.path());
    assert!(Transaction::apply(
        vec![change(&root.path().join("a"), "old", "old")],
        &Cancellation::default()
    )
    .unwrap()
    .is_none());
    assert_original(root.path());
    assert!(journals(root.path()).is_empty());
}

#[test]
fn late_noop_change_is_not_reported_as_success() {
    let root = fixture();
    initial(root.path());
    let plan = vec![
        change(&root.path().join("a"), "old", "new"),
        change(&root.path().join("b"), "old", "old"),
    ];
    let result =
        Transaction::apply_observing(plan, &Cancellation::default(), &mut |point, _, _| {
            if point == "exchanged" {
                std::fs::write(root.path().join("b"), b"foreign").unwrap();
            }
        });
    assert!(matches!(result, Err(Error::RecoveryRequired(_))));
    assert_eq!(std::fs::read(root.path().join("b")).unwrap(), b"foreign");
    let locations = journals(root.path());
    assert_eq!(locations.len(), 1);
    assert_eq!(
        std::fs::read(locations[0].join("original-copy-0")).unwrap(),
        "old 😀\r\n".as_bytes()
    );
}

#[test]
fn late_change_of_an_earlier_written_file_is_not_reported_as_success() {
    let root = fixture();
    initial(root.path());
    let result = Transaction::apply_observing(
        changes(root.path()),
        &Cancellation::default(),
        &mut |point, index, _| {
            if point == "exchanged" && index == 1 {
                std::fs::write(root.path().join("a"), b"foreign").unwrap();
            }
        },
    );
    assert!(matches!(result, Err(Error::RecoveryRequired(_))));
    assert_eq!(std::fs::read(root.path().join("a")).unwrap(), b"foreign");
    assert_eq!(journals(root.path()).len(), 1);
}

#[test]
fn single_document_save_preserves_bytes_and_can_finish_without_search_undo() {
    let root = fixture();
    initial(root.path());
    let cancel = Cancellation::default();
    let snapshot = Snapshot::read(&root.path().join("a"), &cancel).unwrap();
    let edited = b"\xef\xbb\xbfedited\r\n";
    let transaction = Transaction::save_document(snapshot, edited, &cancel)
        .unwrap()
        .unwrap();
    let location = transaction.path().to_owned();
    let saved_snapshot = transaction.saved_document_snapshot(&cancel).unwrap();
    assert_eq!(saved_snapshot.bytes(), edited);
    assert_eq!(std::fs::read(root.path().join("a")).unwrap(), edited);
    transaction.finish_document_save(&cancel).unwrap();
    assert!(!location.exists());
}

#[test]
fn save_snapshot_does_not_adopt_an_unseen_inode_with_identical_bytes() {
    let root = fixture();
    initial(root.path());
    let cancel = Cancellation::default();
    let snapshot = Snapshot::read(&root.path().join("a"), &cancel).unwrap();
    let transaction = Transaction::save_document(snapshot, b"edited", &cancel)
        .unwrap()
        .unwrap();
    std::fs::write(root.path().join("foreign"), b"edited").unwrap();
    std::fs::rename(root.path().join("foreign"), root.path().join("a")).unwrap();
    assert!(matches!(
        transaction.saved_document_snapshot(&cancel),
        Err(Error::RecoveryRequired(_))
    ));
    assert_eq!(std::fs::read(root.path().join("a")).unwrap(), b"edited");
    assert!(transaction.path().join("original-copy-0").exists());
}

#[test]
fn preview_apply_preserves_original_encoding_bom_and_mixed_line_endings() {
    for bytes in [
        b"\xff\xfeo\0l\0d\0\r\0\n\0".to_vec(),
        b"\0\0\xfe\xff\0\0\0o\0\0\0l\0\0\0d\0\0\0\r\0\0\0\n".to_vec(),
        b"\xef\xbb\xbfold\r\n".to_vec(),
        b"old \x80\r\n".to_vec(),
        b"old \xff\r\n".to_vec(),
    ] {
        let root = fixture();
        let path = root.path().join("encoded");
        std::fs::write(&path, &bytes).unwrap();
        let cancel = Cancellation::default();
        let snapshot = Snapshot::read(&path, &cancel).unwrap();
        let decoded = fastra_core::encoding::decode(snapshot.bytes(), None).unwrap();
        let request = SearchRequest {
            pattern: "old".into(),
            replacement: "new".into(),
            mode: SearchMode::Literal,
            case_sensitive: true,
            range: None,
        };
        let preview = preview(decoded.text(), 0, 0, &request, Limits::default(), &cancel).unwrap();
        let expected = decoded
            .encode(&decoded.text().replace("old", "new"))
            .unwrap();
        let change = Change::from_preview(snapshot, &preview, 0, 0, &[0], &cancel).unwrap();
        let mut transaction = Transaction::apply(vec![change], &cancel).unwrap().unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), expected);
        transaction.undo(&cancel).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        transaction.discard(&cancel).unwrap();
    }
}

#[test]
fn unrepresentable_replacement_refuses_before_any_file_write() {
    let root = fixture();
    let path = root.path().join("latin1");
    let original = b"old \xff";
    std::fs::write(&path, original).unwrap();
    let cancel = Cancellation::default();
    let snapshot = Snapshot::read(&path, &cancel).unwrap();
    let decoded = fastra_core::encoding::decode(snapshot.bytes(), None).unwrap();
    let request = SearchRequest {
        pattern: "old".into(),
        replacement: "😀".into(),
        mode: SearchMode::Literal,
        case_sensitive: true,
        range: None,
    };
    let preview = preview(decoded.text(), 0, 0, &request, Limits::default(), &cancel).unwrap();
    assert!(matches!(
        Change::from_preview(snapshot, &preview, 0, 0, &[0], &cancel),
        Err(Error::Encoding(
            fastra_core::encoding::EncodingError::Unrepresentable('😀')
        ))
    ));
    assert_eq!(std::fs::read(&path).unwrap(), original);
    assert!(journals(root.path()).is_empty());
}

#[test]
fn new_document_save_is_atomic_and_never_overwrites_an_occupied_name() {
    let root = fixture();
    let cancel = Cancellation::default();
    let path = root.path().join("new.md");
    let snapshot = Transaction::save_new_document(&path, b"\xef\xbb\xbfnew\r\n", &cancel).unwrap();
    assert_eq!(snapshot.bytes(), b"\xef\xbb\xbfnew\r\n");
    assert!(Transaction::save_new_document(&path, b"other", &cancel).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"\xef\xbb\xbfnew\r\n");
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
}

#[test]
fn new_document_save_refuses_symlink_and_fifo_names_without_following_them() {
    let root = fixture();
    let cancel = Cancellation::default();
    let source = root.path().join("source");
    std::fs::write(&source, b"foreign").unwrap();
    symlink(&source, root.path().join("link")).unwrap();
    assert!(Transaction::save_new_document(&root.path().join("link"), b"other", &cancel).is_err());
    let fifo = root.path().join("fifo");
    let name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    syscall(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }).unwrap();
    assert!(Transaction::save_new_document(&fifo, b"other", &cancel).is_err());
    assert_eq!(std::fs::read(&source).unwrap(), b"foreign");
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 3);
}

#[test]
fn precancelled_new_document_save_creates_nothing() {
    let root = fixture();
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(Transaction::save_new_document(&root.path().join("new"), b"new", &cancel).is_err());
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
}

#[test]
fn search_transaction_cannot_discard_undo_as_a_document_save() {
    let root = fixture();
    initial(root.path());
    let cancel = Cancellation::default();
    let transaction = Transaction::apply(changes(root.path()), &cancel)
        .unwrap()
        .unwrap();
    let location = transaction.path().to_owned();
    assert!(matches!(
        transaction.finish_document_save(&cancel),
        Err(Error::RecoveryRequired(_))
    ));
    assert!(location.join("original-copy-0").exists());
}

#[test]
fn document_save_rejects_external_change_and_bounded_read_rejects_oversize_early() {
    let root = fixture();
    initial(root.path());
    let cancel = Cancellation::default();
    assert!(matches!(
        Snapshot::read_bounded(&root.path().join("a"), 2, &cancel),
        Err(Error::Limit)
    ));
    let snapshot = Snapshot::read(&root.path().join("a"), &cancel).unwrap();
    std::fs::write(root.path().join("a"), b"foreign").unwrap();
    assert!(matches!(
        Transaction::save_document(snapshot, b"edited", &cancel),
        Err(Error::Stale)
    ));
    assert_eq!(std::fs::read(root.path().join("a")).unwrap(), b"foreign");
    assert!(journals(root.path()).is_empty());
}

#[test]
fn crash_worker() {
    if std::env::var("FASTRA_IO_CHILD").as_deref() != Ok("crash") {
        return;
    }
    let root = PathBuf::from(std::env::var_os("FASTRA_IO_CHILD_ROOT").unwrap());
    let point = std::env::var("FASTRA_IO_CHILD_POINT").unwrap();
    let cancel = Cancellation::default();
    let mut observer = |event: &str, index: usize, _: &Transaction| {
        if point == format!("{event}-{index}") {
            unsafe {
                libc::kill(libc::getpid(), libc::SIGKILL);
            }
        }
    };
    let plan = if std::env::var("FASTRA_IO_CHILD_NESTED").as_deref() == Ok("yes") {
        vec![
            change(&root.join("left/a"), "old", "new"),
            change(&root.join("right/b"), "old", "new"),
        ]
    } else {
        changes(&root)
    };
    let mut transaction = Transaction::apply_observing(plan, &cancel, &mut observer)
        .unwrap()
        .unwrap();
    transaction.undo_observing(&cancel, &mut observer).unwrap();
    panic!("requested crash boundary was not reached");
}

#[test]
fn sigkill_recovers_partial_apply_and_partial_undo_in_a_fresh_process() {
    for point in [
        "prepared-0",
        "exchanged-0",
        "exchanged-1",
        "applied-0",
        "undo-exchanged-1",
        "intent-written-1",
        "intent-written-2",
        "intent-written-3",
        "intent-written-4",
    ] {
        let root = fixture();
        initial(root.path());
        let executable = std::env::var_os("FASTRA_IO_TEST_COMMAND")
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::current_exe().unwrap());
        let output = std::process::Command::new(executable)
            .args(["--exact", "linux::tests::crash_worker", "--nocapture"])
            .env("FASTRA_IO_CHILD", "crash")
            .env("FASTRA_IO_CHILD_ROOT", root.path())
            .env("FASTRA_IO_CHILD_POINT", point)
            .output()
            .unwrap();
        assert_eq!(
            output.status.signal(),
            Some(libc::SIGKILL),
            "{point}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let locations = journals(root.path());
        assert_eq!(locations.len(), 1);
        let mut transaction = Transaction::reopen(&locations[0]).unwrap();
        let before = [
            std::fs::read(root.path().join("a")).unwrap(),
            std::fs::read(root.path().join("b")).unwrap(),
        ];
        let states = transaction.inspect(&Cancellation::default()).unwrap();
        assert!(
            !states.contains(&FileState::Conflict),
            "{point}: {states:?}"
        );
        assert_eq!(
            before,
            [
                std::fs::read(root.path().join("a")).unwrap(),
                std::fs::read(root.path().join("b")).unwrap()
            ]
        );
        transaction.undo(&Cancellation::default()).unwrap();
        assert_original(root.path());
        transaction.discard(&Cancellation::default()).unwrap();
        assert!(journals(root.path()).is_empty());
    }
}

#[test]
fn different_directories_on_same_filesystem_apply_and_undo_as_one_transaction() {
    let root = fixture();
    for name in ["left", "right"] {
        std::fs::create_dir(root.path().join(name)).unwrap();
        initial(&root.path().join(name));
    }
    let cancel = Cancellation::default();
    let plan = vec![
        change(&root.path().join("left/a"), "old", "new"),
        change(&root.path().join("right/b"), "old", "new"),
    ];
    let transaction = Transaction::apply(plan, &cancel).unwrap().unwrap();
    assert_eq!(
        transaction.inspect(&cancel).unwrap(),
        [FileState::Replaced, FileState::Replaced]
    );
    let location = transaction.path().to_owned();
    drop(transaction);
    let mut transaction = Transaction::reopen(&location).unwrap();
    transaction.undo(&cancel).unwrap();
    assert_original(&root.path().join("left"));
    assert_original(&root.path().join("right"));
    transaction.discard(&cancel).unwrap();
    assert!(!location.exists());
}

#[test]
fn same_basename_in_different_directories_is_not_a_duplicate_input() {
    let root = fixture();
    for name in ["left", "right"] {
        std::fs::create_dir(root.path().join(name)).unwrap();
        initial(&root.path().join(name));
    }
    let cancel = Cancellation::default();
    let plan = vec![
        change(&root.path().join("left/a"), "old", "new"),
        change(&root.path().join("right/a"), "old", "new"),
    ];
    let mut transaction = Transaction::apply(plan, &cancel).unwrap().unwrap();
    transaction.undo(&cancel).unwrap();
    assert_original(&root.path().join("left"));
    assert_original(&root.path().join("right"));
    transaction.discard(&cancel).unwrap();
}

#[test]
fn sigkill_between_directories_has_a_single_recoverable_journal() {
    for point in ["exchanged-0", "exchanged-1", "undo-exchanged-1"] {
        let root = fixture();
        for name in ["left", "right"] {
            std::fs::create_dir(root.path().join(name)).unwrap();
            initial(&root.path().join(name));
        }
        let executable = std::env::var_os("FASTRA_IO_TEST_COMMAND")
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::current_exe().unwrap());
        let output = std::process::Command::new(executable)
            .args(["--exact", "linux::tests::crash_worker", "--nocapture"])
            .env("FASTRA_IO_CHILD", "crash")
            .env("FASTRA_IO_CHILD_ROOT", root.path())
            .env("FASTRA_IO_CHILD_POINT", point)
            .env("FASTRA_IO_CHILD_NESTED", "yes")
            .output()
            .unwrap();
        assert_eq!(
            output.status.signal(),
            Some(libc::SIGKILL),
            "{point}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let locations = journals(&root.path().join("left"));
        assert_eq!(locations.len(), 1);
        assert!(journals(&root.path().join("right")).is_empty());
        let mut transaction = Transaction::reopen(&locations[0]).unwrap();
        transaction.undo(&Cancellation::default()).unwrap();
        assert_original(&root.path().join("left"));
        assert_original(&root.path().join("right"));
        transaction.discard(&Cancellation::default()).unwrap();
    }
}

#[test]
fn undo_final_preflight_includes_noops_and_previously_restored_targets() {
    for interfered in ["noop", "b"] {
        let root = fixture();
        initial(root.path());
        std::fs::write(root.path().join("noop"), "untouched").unwrap();
        let cancel = Cancellation::default();
        let mut inputs = changes(root.path());
        inputs.push(change(&root.path().join("noop"), "missing", "unused"));
        let mut tx = Transaction::apply(inputs, &cancel).unwrap().unwrap();
        let result = tx.undo_observing(&cancel, &mut |point, index, _| {
            if point == "undo-exchanged" && index == 0 {
                std::fs::write(root.path().join(interfered), "EXTERNAL").unwrap();
            }
        });
        assert!(matches!(result, Err(Error::RecoveryRequired(_))));
        assert_eq!(tx.phase(), Phase::Undoing);
        assert_eq!(
            std::fs::read(root.path().join(interfered)).unwrap(),
            b"EXTERNAL"
        );
        let reopened = Transaction::reopen(tx.path()).unwrap();
        assert!(reopened
            .inspect(&cancel)
            .unwrap()
            .contains(&FileState::Conflict));
    }
}

#[test]
fn native_overlay_final_new_document_target_is_guarded_with_allowed_parent() {
    if std::env::var("FASTRA_POLICY_TEST_CASE").as_deref() != Ok("overlay") {
        return;
    }
    crate::initialize_runtime_policy().unwrap();
    let parent = Arc::new(Directory::open(Path::new("/usr/bin")).unwrap());
    let error = Transaction::save_new_document_bound(
        parent, OsString::from("bwrap"), b"never publish", &Cancellation::default(),
    ).unwrap_err();
    assert!(matches!(error, Error::Io(error) if error.kind() == std::io::ErrorKind::PermissionDenied));
}
