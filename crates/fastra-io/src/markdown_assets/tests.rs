use super::*;
fn fixture() -> tempfile::TempDir {
    let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    tempfile::Builder::new()
        .prefix("asset-test-")
        .tempdir_in(root)
        .unwrap()
}
fn owner() -> Owner {
    Owner {
        document: "document-A".into(),
        revision: 1,
        generation: 7,
    }
}
fn inputs() -> Vec<Input> {
    vec![
        Input {
            extension: "png".into(),
            bytes: b"synthetic PNG bytes".to_vec().into(),
        },
        Input {
            extension: "gif".into(),
            bytes: b"synthetic GIF bytes".to_vec().into(),
        },
    ]
}
fn plan(root: &Path) -> Plan {
    let doc = root.join("document.md");
    std::fs::write(&doc, b"unmodified source\r\n").unwrap();
    Plan::prepare(&doc, owner(), inputs(), &Cancellation::default()).unwrap()
}
#[test]
fn preview_has_no_writes_and_owner_aba_refuses() {
    let root = fixture();
    let prepared = plan(root.path());
    assert!(!root.path().join("images").exists());
    assert_eq!(
        prepared.preview()[0].relative,
        PathBuf::from("images/1.png")
    );
    let mut changed = owner();
    changed.generation += 2;
    assert!(matches!(
        prepared.apply(&changed, &Cancellation::default()),
        Err(Error::Stale)
    ));
    assert!(!root.path().join("images").exists());
}
#[test]
fn assets_roundtrip_without_source_writes_and_with_unrelated_files() {
    let root = fixture();
    let prepared = plan(root.path());
    let mut receipt = prepared.apply(&owner(), &Cancellation::default()).unwrap();
    assert_eq!(
        std::fs::read(root.path().join("images/1.png")).unwrap(),
        *inputs()[0].bytes
    );
    std::fs::write(root.path().join("images/foreign.txt"), b"foreign").unwrap();
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
    assert!(!root.path().join("images/1.png").exists());
    assert!(root.path().join("images/foreign.txt").exists());
    receipt.redo(&owner(), &Cancellation::default()).unwrap();
    assert_eq!(
        std::fs::read(root.path().join("images/2.gif")).unwrap(),
        *inputs()[1].bytes
    );
    assert_eq!(
        std::fs::read(root.path().join("document.md")).unwrap(),
        b"unmodified source\r\n"
    );
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
}
#[test]
fn undo_retains_owned_inodes_and_redo_reuses_them() {
    let root = fixture();
    let mut receipt = plan(root.path())
        .apply(&owner(), &Cancellation::default())
        .unwrap();
    let original = Snapshot::read(&root.path().join("images/1.png"), &Cancellation::default())
        .unwrap()
        .file_identity();
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
    assert!(!root.path().join("images/1.png").exists());
    let recovery = receipt.recovery_paths();
    assert_eq!(recovery.len(), 2);
    assert!(recovery.iter().all(|(_, claim)| claim.exists()));
    assert_eq!(
        Snapshot::read(&recovery[0].1, &Cancellation::default())
            .unwrap()
            .file_identity(),
        original
    );
    receipt.redo(&owner(), &Cancellation::default()).unwrap();
    assert_eq!(
        Snapshot::read(&root.path().join("images/1.png"), &Cancellation::default())
            .unwrap()
            .file_identity(),
        original
    );
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
}
#[test]
fn collisions_after_preview_and_changed_source_are_not_overwritten() {
    let root = fixture();
    std::fs::create_dir(root.path().join("images")).unwrap();
    let prepared = plan(root.path());
    std::fs::write(root.path().join("images/1.png"), b"foreign collision").unwrap();
    assert!(prepared.apply(&owner(), &Cancellation::default()).is_err());
    assert_eq!(
        std::fs::read(root.path().join("images/1.png")).unwrap(),
        b"foreign collision"
    );
    let prepared = plan(root.path());
    std::fs::write(root.path().join("document.md"), b"external edit").unwrap();
    assert!(matches!(
        prepared.apply(&owner(), &Cancellation::default()),
        Err(Error::Stale)
    ));
}
#[test]
fn undo_preserves_modified_replaced_and_foreign_owner_assets() {
    let root = fixture();
    let mut receipt = plan(root.path())
        .apply(&owner(), &Cancellation::default())
        .unwrap();
    let mut foreign = owner();
    foreign.document = "document-B".into();
    assert!(matches!(
        receipt.undo(&foreign, &Cancellation::default()),
        Err(Error::Stale)
    ));
    std::fs::write(root.path().join("images/1.png"), b"edited by user").unwrap();
    assert!(matches!(
        receipt.undo(&owner(), &Cancellation::default()),
        Err(Error::Stale)
    ));
    assert_eq!(
        std::fs::read(root.path().join("images/1.png")).unwrap(),
        b"edited by user"
    );
    assert!(root.path().join("images/2.gif").exists());
}
#[test]
fn symlink_directory_rejected_and_redo_collision_preserved() {
    use std::os::unix::fs::symlink;
    let root = fixture();
    let outside = fixture();
    std::fs::write(root.path().join("document.md"), b"source").unwrap();
    symlink(outside.path(), root.path().join("images")).unwrap();
    assert!(
        Plan::prepare(
            &root.path().join("document.md"),
            owner(),
            inputs(),
            &Cancellation::default()
        )
        .is_err()
    );
    std::fs::remove_file(root.path().join("images")).unwrap();
    let mut receipt = plan(root.path())
        .apply(&owner(), &Cancellation::default())
        .unwrap();
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
    assert!(root.path().join("images").exists());
    std::fs::write(root.path().join("images/1.png"), b"new foreign").unwrap();
    assert!(receipt.redo(&owner(), &Cancellation::default()).is_err());
    assert_eq!(
        std::fs::read(root.path().join("images/1.png")).unwrap(),
        b"new foreign"
    );
}
#[test]
fn collision_during_second_publication_rolls_back_first_without_touching_foreign() {
    let root = fixture();
    let prepared = plan(root.path());
    RACE.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(|phase, path| {
            if phase == "before-publish" && path.file_name() == Some(OsStr::new("2.gif")) {
                std::fs::write(path, b"foreign racing file").unwrap();
            }
        }))
    });
    let result = prepared.apply(&owner(), &Cancellation::default());
    RACE.with(|hook| hook.borrow_mut().take());
    assert!(result.is_err());
    assert!(!root.path().join("images/1.png").exists());
    assert_eq!(
        std::fs::read(root.path().join("images/2.gif")).unwrap(),
        b"foreign racing file"
    );
    assert_eq!(
        std::fs::read_dir(root.path().join("images"))
            .unwrap()
            .count(),
        2
    );
}
#[test]
fn mutation_after_claim_is_restored_and_never_deleted() {
    let root = fixture();
    let mut receipt = plan(root.path())
        .apply(&owner(), &Cancellation::default())
        .unwrap();
    RACE.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(|phase, path| {
            if phase == "after-claim" {
                std::fs::write(path, b"user edit during undo").unwrap();
            }
        }))
    });
    let result = receipt.undo(&owner(), &Cancellation::default());
    RACE.with(|hook| hook.borrow_mut().take());
    assert!(result.is_err());
    assert_eq!(
        std::fs::read(root.path().join("images/1.png")).unwrap(),
        b"user edit during undo"
    );
    assert_eq!(
        std::fs::read(root.path().join("images/2.gif")).unwrap(),
        *inputs()[1].bytes
    );
    assert_eq!(
        std::fs::read_dir(root.path().join("images"))
            .unwrap()
            .count(),
        2
    );
}
#[test]
fn cancellation_after_first_publication_retains_recovery_but_no_live_output() {
    let root = fixture();
    let prepared = plan(root.path());
    let cancel = Cancellation::default();
    let worker = cancel.clone();
    RACE.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move |phase, path| {
            if phase == "before-publish" && path.file_name() == Some(OsStr::new("2.gif")) {
                worker.cancel();
            }
        }))
    });
    let result = prepared.apply(&owner(), &cancel);
    RACE.with(|hook| hook.borrow_mut().take());
    assert!(matches!(result, Err(Error::RecoveryRequired(_))));
    assert!(!root.path().join("images/1.png").exists());
    assert!(!root.path().join("images/2.gif").exists());
    let retained = std::fs::read_dir(root.path().join("images"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect::<Vec<_>>();
    assert_eq!(retained.len(), 1);
    assert_eq!(std::fs::read(&retained[0]).unwrap(), *inputs()[0].bytes);
}
#[test]
fn open_fd_write_to_first_claim_during_second_claim_is_restored() {
    use std::io::{Seek, SeekFrom, Write};
    let root = fixture();
    let mut receipt = plan(root.path())
        .apply(&owner(), &Cancellation::default())
        .unwrap();
    let mut fd = std::fs::OpenOptions::new()
        .write(true)
        .open(root.path().join("images/1.png"))
        .unwrap();
    let mut count = 0;
    RACE.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move |phase, _| {
            if phase == "after-claim" {
                count += 1;
                if count == 2 {
                    fd.seek(SeekFrom::Start(0)).unwrap();
                    fd.write_all(b"FD EDIT").unwrap();
                    fd.sync_all().unwrap();
                }
            }
        }))
    });
    let result = receipt.undo(&owner(), &Cancellation::default());
    RACE.with(|hook| hook.borrow_mut().take());
    assert!(result.is_err());
    assert!(
        std::fs::read(root.path().join("images/1.png"))
            .unwrap()
            .starts_with(b"FD EDIT")
    );
    assert!(root.path().join("images/2.gif").exists());
    assert_eq!(
        std::fs::read_dir(root.path().join("images"))
            .unwrap()
            .count(),
        2
    );
}
#[test]
fn open_fd_writes_after_successful_undo_survive_redo_refusal_and_receipt_drop() {
    use std::io::Write;
    let root = fixture();
    let mut receipt = plan(root.path())
        .apply(&owner(), &Cancellation::default())
        .unwrap();
    let mut fd = std::fs::OpenOptions::new()
        .write(true)
        .open(root.path().join("images/1.png"))
        .unwrap();
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
    let recovery = receipt.recovery_paths();
    fd.write_all(b"LATE FD EDIT").unwrap();
    fd.sync_all().unwrap();
    assert!(matches!(
        receipt.redo(&owner(), &Cancellation::default()),
        Err(Error::RecoveryRequired(_))
    ));
    drop(receipt);
    assert!(
        std::fs::read(&recovery[0].1)
            .unwrap()
            .starts_with(b"LATE FD EDIT")
    );
    assert!(recovery[1].1.exists());
}
#[test]
fn changed_or_replaced_temporary_never_matches_approved_publication() {
    for replace in [false, true] {
        let root = fixture();
        let prepared = plan(root.path());
        RACE.with(|hook| {
            *hook.borrow_mut() = Some(Box::new(move |phase, path| {
                if phase == "before-temp-hash" {
                    if replace {
                        std::fs::remove_file(path).unwrap();
                    }
                    std::fs::write(path, b"unapproved replacement").unwrap();
                }
            }))
        });
        let result = prepared.apply(&owner(), &Cancellation::default());
        RACE.with(|hook| hook.borrow_mut().take());
        assert!(matches!(result, Err(Error::RecoveryRequired(_))));
        assert!(!root.path().join("images/1.png").exists());
        assert!(!root.path().join("images/2.gif").exists());
        let retained = std::fs::read_dir(root.path().join("images"))
            .unwrap()
            .map(|e| e.unwrap().path())
            .collect::<Vec<_>>();
        assert_eq!(retained.len(), 1);
        assert_eq!(
            std::fs::read(&retained[0]).unwrap(),
            b"unapproved replacement"
        );
    }
}

#[test]
fn undo_directory_sync_failure_restores_live_names_and_receipt_state() {
    let root = fixture();
    let mut receipt = plan(root.path())
        .apply(&owner(), &Cancellation::default())
        .unwrap();
    FAIL_UNDO_SYNC.with(|flag| flag.set(true));
    assert!(receipt.undo(&owner(), &Cancellation::default()).is_err());
    assert!(receipt.is_applied());
    assert!(receipt.recovery_paths().is_empty());
    assert_eq!(
        std::fs::read(root.path().join("images/1.png")).unwrap(),
        *inputs()[0].bytes
    );
    assert_eq!(
        std::fs::read(root.path().join("images/2.gif")).unwrap(),
        *inputs()[1].bytes
    );
    assert_eq!(
        std::fs::read_dir(root.path().join("images"))
            .unwrap()
            .count(),
        2
    );
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
    assert!(!receipt.is_applied());
    assert_eq!(receipt.recovery_paths().len(), 2);
}

#[test]
fn owner_stale_rollback_restores_retained_inode_with_late_fd_edits() {
    use std::io::Write;
    let root = fixture();
    let mut receipt = plan(root.path())
        .apply(&owner(), &Cancellation::default())
        .unwrap();
    let mut fd = std::fs::OpenOptions::new()
        .write(true)
        .open(root.path().join("images/1.png"))
        .unwrap();
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
    fd.write_all(b"LATE EDIT").unwrap();
    fd.sync_all().unwrap();
    receipt.rollback_undo(&owner()).unwrap();
    assert!(receipt.is_applied());
    assert!(
        std::fs::read(root.path().join("images/1.png"))
            .unwrap()
            .starts_with(b"LATE EDIT")
    );
    assert!(root.path().join("images/2.gif").exists());
    assert!(receipt.undo(&owner(), &Cancellation::default()).is_err());
    assert!(
        std::fs::read(root.path().join("images/1.png"))
            .unwrap()
            .starts_with(b"LATE EDIT")
    );
}

#[test]
fn rollback_undo_identity_failure_after_first_rename_rolls_back_all_names() {
    let root = fixture();
    let mut receipt = plan(root.path())
        .apply(&owner(), &Cancellation::default())
        .unwrap();
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
    let before = receipt.recovery_paths();
    let second = before[1].1.clone();
    RACE.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move |phase, path| {
            if phase == "before-relocate" && path == second {
                FAIL_IDENTITY.with(|flag| flag.set(true));
            }
        }))
    });
    let result = receipt.rollback_undo(&owner());
    RACE.with(|hook| hook.borrow_mut().take());
    assert!(result.is_err());
    assert!(!receipt.is_applied());
    assert!(!root.path().join("images/1.png").exists());
    assert!(!root.path().join("images/2.gif").exists());
    assert_eq!(receipt.recovery_paths(), before);
    assert!(before.iter().all(|(_, path)| path.exists()));
    receipt.redo(&owner(), &Cancellation::default()).unwrap();
}

#[test]
fn failed_rollback_keeps_mixed_placements_in_recovery_ledger() {
    let root = fixture();
    let mut receipt = plan(root.path())
        .apply(&owner(), &Cancellation::default())
        .unwrap();
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
    let before = receipt.recovery_paths();
    let claim_one = before[0].1.clone();
    let second = before[1].1.clone();
    RACE.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move |phase, path| {
            if phase == "before-relocate" && path == second {
                FAIL_IDENTITY.with(|flag| flag.set(true));
                std::fs::write(&claim_one, b"foreign collision").unwrap();
            }
        }))
    });
    assert!(matches!(
        receipt.rollback_undo(&owner()),
        Err(Error::RecoveryRequired(_))
    ));
    RACE.with(|hook| hook.borrow_mut().take());
    let recovery = receipt.recovery_paths();
    assert_eq!(recovery[0].1, root.path().join("images/1.png"));
    assert_eq!(recovery[1].1, before[1].1);
    assert_eq!(std::fs::read(&recovery[0].1).unwrap(), *inputs()[0].bytes);
    assert_eq!(std::fs::read(&recovery[1].1).unwrap(), *inputs()[1].bytes);
    assert_eq!(std::fs::read(&before[0].1).unwrap(), b"foreign collision");
    assert!(receipt.redo(&owner(), &Cancellation::default()).is_err());
    drop(receipt);
    assert!(recovery.iter().all(|(_, path)| path.exists()));
}
