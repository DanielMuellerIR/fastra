//! Rücknahme allein neuer Zielbilder, nur solange kein Dokument veröffentlicht wurde.
use super::*;
use fastra_io::markdown_assets::{Owner, Receipt};
pub(super) fn compensate(
    receipt: Receipt,
    owner: &Owner,
    target: &std::path::Path,
    texts: &[(std::path::PathBuf, String)],
    complete: bool,
    lang: Language,
) -> (Receipt, Result<(), String>) {
    compensate_with(receipt, owner, target, texts, complete, lang, || {})
}
fn compensate_with(
    mut receipt: Receipt,
    owner: &Owner,
    target: &std::path::Path,
    texts: &[(std::path::PathBuf, String)],
    complete: bool,
    lang: Language,
    after_undo: impl FnOnce(),
) -> (Receipt, Result<(), String>) {
    let cancel = Cancellation::default();
    let deadline = cancel.clone();
    let (finished, wait) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        if matches!(
            wait.recv_timeout(Duration::from_secs(5)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout)
        ) {
            deadline.cancel();
        }
    });
    let protection =
        rich_editor::asset_refs::Protection::scan_target(target, texts, complete, &cancel);
    let result = (|| {
        if protection.protects(
            receipt
                .preview()
                .iter()
                .map(|entry| target.parent().unwrap().join(&entry.relative)),
        ) || !protection.current(&cancel)
        {
            return Err(lang
                .text(
                    "Neue Bildnamen sind durch Verweise geschützt; Dateien bleiben erhalten.",
                    "Created image names are protected by references; files retained",
                )
                .into());
        }
        receipt
            .undo(owner, &cancel)
            .map_err(|e| crate::io_error_text(lang, &e))?;
        after_undo();
        if !protection.current(&cancel) {
            return match receipt.rollback_undo(owner) {
                Ok(()) => Err(lang
                    .text(
                        "Verweisquellen geändert; Bildnamen wiederhergestellt.",
                        "Reference sources changed; image names restored",
                    )
                    .into()),
                Err(error) => Err(format!(
                    "{} {error}",
                    lang.text(
                        "Verweisquellen geändert; Wiederherstellung fehlgeschlagen:",
                        "Reference sources changed; restore failed:"
                    )
                )),
            };
        }
        Ok(())
    })();
    let _ = finished.send(());
    (receipt, result)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, PathBuf, Owner, Receipt) {
        let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let dir = tempfile::tempdir_in(root).unwrap();
        let target = dir.path().join("missing.md");
        let owner = Owner {
            document: "save-as-rollback".into(),
            revision: 1,
            generation: 1,
        };
        let anchor =
            fastra_io::save_target::Target::capture(&target, &Cancellation::default()).unwrap();
        let receipt = fastra_io::markdown_assets::Plan::prepare_at(
            anchor,
            owner.clone(),
            vec![fastra_io::markdown_assets::Input {
                extension: "png".into(),
                bytes: Arc::new(b"approved image".to_vec()),
            }],
            &Cancellation::default(),
        )
        .unwrap()
        .apply(&owner, &Cancellation::default())
        .unwrap();
        (dir, target, owner, receipt)
    }
    #[test]
    fn absent_target_compensation_retains_claim_bytes_and_rechecks_reference_drift() {
        for drift in [false, true] {
            let (dir, target, owner, receipt) = fixture();
            let image = dir.path().join(&receipt.preview()[0].relative);
            let (receipt, result) =
                compensate_with(receipt, &owner, &target, &[], true, Language(false), || {
                    assert!(!image.exists());
                    if drift {
                        std::fs::write(dir.path().join(".notes.md"), "![new](images/1.png)")
                            .unwrap();
                    }
                });
            assert!(!target.exists());
            if drift {
                assert!(result.is_err());
                assert!(receipt.is_applied());
                assert_eq!(std::fs::read(image).unwrap(), b"approved image");
            } else {
                result.unwrap();
                assert!(!receipt.is_applied());
                assert_eq!(
                    std::fs::read(&receipt.recovery_paths()[0].1).unwrap(),
                    b"approved image"
                );
            }
        }
    }
}
