use fastra_core::{preview, Cancellation, Limits, SearchMode, SearchRequest};
use fastra_io::{Change, Snapshot, Transaction};
fn dir() -> tempfile::TempDir {
    tempfile::tempdir_in(std::env::var_os("FASTRA_IO_TEST_ROOT").unwrap_or_else(|| "/tmp".into()))
        .unwrap()
}
fn change(path: &std::path::Path, selected: &[usize]) -> Change {
    let cancel = Cancellation::default();
    let snapshot = Snapshot::read(path, &cancel).unwrap();
    let request = SearchRequest {
        pattern: "old".into(),
        replacement: "new".into(),
        mode: SearchMode::Literal,
        case_sensitive: true,
        range: None,
    };
    let p = preview(
        std::str::from_utf8(snapshot.bytes()).unwrap(),
        3,
        4,
        &request,
        Limits::default(),
        &cancel,
    )
    .unwrap();
    Change::from_preview(snapshot, &p, 3, 4, selected, &cancel).unwrap()
}
#[test]
fn receipts_cover_changed_and_unchanged_inputs_before_and_after_undo() {
    let d = dir();
    let a = d.path().join("a");
    let b = d.path().join("b");
    std::fs::write(&a, "old").unwrap();
    std::fs::write(&b, "old").unwrap();
    let c = Cancellation::default();
    let mut tx = Transaction::apply(vec![change(&a, &[0]), change(&b, &[])], &c)
        .unwrap()
        .unwrap();
    let receipts = tx.applied_snapshots(&c).unwrap();
    assert_eq!(receipts.len(), 2);
    assert_eq!(receipts[0].bytes(), b"new");
    assert_eq!(receipts[1].bytes(), b"old");
    assert!(tx.restored_snapshots(&c).is_err());
    tx.undo(&c).unwrap();
    assert!(tx.applied_snapshots(&c).is_err());
    assert!(tx
        .restored_snapshots(&c)
        .unwrap()
        .iter()
        .all(|s| s.bytes() == b"old"));
    tx.discard(&c).unwrap();
}
#[test]
fn identical_bytes_from_an_unseen_inode_are_not_adopted() {
    let d = dir();
    let a = d.path().join("a");
    let other = d.path().join("other");
    std::fs::write(&a, "old").unwrap();
    let c = Cancellation::default();
    let tx = Transaction::apply(vec![change(&a, &[0])], &c)
        .unwrap()
        .unwrap();
    std::fs::write(&other, "new").unwrap();
    std::fs::rename(&other, &a).unwrap();
    assert!(tx.applied_snapshots(&c).is_err());
}

#[test]
fn recovery_approval_binds_the_shown_bytes_and_journal_identity() {
    let d = dir();
    let a = d.path().join("a");
    std::fs::write(&a, "old").unwrap();
    let c = Cancellation::default();
    let tx = Transaction::apply(vec![change(&a, &[0])], &c)
        .unwrap()
        .unwrap();
    let journal = tx.path().to_owned();
    drop(tx);
    let mut tx = Transaction::reopen(&journal).unwrap();
    let preview = tx.recovery_preview(&c).unwrap();
    assert_eq!(preview.files()[0].current_bytes(), b"new");
    assert_eq!(preview.files()[0].original_bytes(), b"old");
    assert_eq!(preview.files()[0].path(), a);
    tx.undo_approved(&preview, &c).unwrap();
    assert_eq!(std::fs::read(&a).unwrap(), b"old");
    assert!(tx.undo_approved(&preview, &c).is_err());
    tx.discard(&c).unwrap();
}
#[test]
fn changed_input_after_recovery_preview_blocks_all_restoration() {
    let d = dir();
    let a = d.path().join("a");
    let b = d.path().join("b");
    std::fs::write(&a, "old").unwrap();
    std::fs::write(&b, "old").unwrap();
    let c = Cancellation::default();
    let mut tx = Transaction::apply(vec![change(&a, &[0]), change(&b, &[])], &c)
        .unwrap()
        .unwrap();
    let preview = tx.recovery_preview(&c).unwrap();
    std::fs::write(&b, "other").unwrap();
    assert!(tx.undo_approved(&preview, &c).is_err());
    assert_eq!(std::fs::read(&a).unwrap(), b"new");
}
#[test]
fn forged_journal_sizes_are_rejected_before_source_reads() {
    let d = dir();
    let a = d.path().join("a");
    std::fs::write(&a, "old").unwrap();
    let c = Cancellation::default();
    let tx = Transaction::apply(vec![change(&a, &[0])], &c)
        .unwrap()
        .unwrap();
    let journal = tx.path().to_owned();
    drop(tx);
    let intent = journal.join("intent.json");
    let mut json: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&intent).unwrap()).unwrap();
    json["entries"][0]["original"]["size"] = u64::MAX.into();
    std::fs::write(intent, serde_json::to_vec(&json).unwrap()).unwrap();
    assert!(Transaction::reopen(&journal).is_err());
    assert_eq!(std::fs::read(&a).unwrap(), b"new");
}

#[test]
fn binding_digest_is_stored_and_covers_metadata_and_raw_name() {
    use std::os::unix::fs::PermissionsExt;
    let d = dir();
    let a = d.path().join("a");
    std::fs::write(&a, "old").unwrap();
    std::fs::set_permissions(&a, std::fs::Permissions::from_mode(0o600)).unwrap();
    let c = Cancellation::default();
    let captured = Snapshot::read(&a, &c).unwrap();
    let token = captured.binding_digest().unwrap();
    assert_eq!(
        Snapshot::read(&a, &c).unwrap().binding_digest().unwrap(),
        token
    );
    std::fs::set_permissions(&a, std::fs::Permissions::from_mode(0o640)).unwrap();
    assert_eq!(captured.binding_digest().unwrap(), token);
    assert_ne!(
        Snapshot::read(&a, &c).unwrap().binding_digest().unwrap(),
        token
    );
    let before_move = Snapshot::read(&a, &c).unwrap().binding_digest().unwrap();
    let b = d.path().join("b");
    std::fs::rename(&a, &b).unwrap();
    assert_ne!(
        Snapshot::read(&b, &c).unwrap().binding_digest().unwrap(),
        before_move
    );
}
