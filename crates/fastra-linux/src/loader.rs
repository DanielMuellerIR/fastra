use fastra_core::{
    encoding::{Decoded, Encoding},
    Cancellation,
};
use fastra_document::{Document, SectionDocument};
use fastra_io::Snapshot;
use std::{path::Path, sync::Arc};

#[derive(Debug)]
pub enum Loaded {
    Text {
        decoded: Arc<Decoded>,
        snapshot: Snapshot,
    },
    ReadOnlyText(Arc<fastra_document::ReadOnlyTextDocument>),
    Sections(SectionDocument),
    Hex(SectionDocument),
}
#[derive(Debug)]
pub struct Error(pub fastra_document::Error);
#[derive(Debug)]
pub enum SaveError {
    Io(fastra_io::Error),
    Encoding(fastra_core::encoding::EncodingError),
}
impl From<fastra_io::Error> for SaveError {
    fn from(error: fastra_io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<std::io::Error> for SaveError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.into())
    }
}
impl From<fastra_core::encoding::EncodingError> for SaveError {
    fn from(error: fastra_core::encoding::EncodingError) -> Self {
        Self::Encoding(error)
    }
}
impl SaveError {
    pub fn message(&self, lang: super::Language) -> String {
        match self {Self::Io(error)=>super::io_error_text(lang,error),Self::Encoding(error)=>format!("{}{}",lang.text("Der Text enthält Zeichen, die in der Dateikodierung nicht darstellbar sind. Datei unverändert; Editoränderungen bleiben erhalten.","The text contains characters that cannot be represented in the file encoding. File unchanged; editor changes retained."), match error { fastra_core::encoding::EncodingError::Unrepresentable(c) => format!(" ({c})"), _ => String::new() })}
    }
}
impl Error {
    pub fn message(&self, de: bool) -> String {
        document_error(super::Language(de), &self.0)
    }
}
pub fn document_error(lang: super::Language, error: &fastra_document::Error) -> String {
    use fastra_document::Error;
    match error {
        Error::Snapshot(error) => super::io_error_text(lang, error),
        Error::Io(error) => format!("{} ({error})", lang.text("Die Datei konnte nicht gelesen werden.", "The file could not be read.")),
        Error::Stale => lang.text("Die Quelldatei hat sich geändert. Neu öffnen, bevor weitere Abschnitte angezeigt werden.","The source file changed. Reopen it before viewing more sections.").into(),
        Error::Encoding(_) => lang.text("Die Daten lassen sich mit der gewählten Kodierung nicht verlustfrei dekodieren. Datei unverändert.","The data cannot be decoded losslessly with the selected encoding. File unchanged.").into(),
        Error::Cancelled => lang.text("Lesen abgebrochen.","Reading cancelled.").into(),
        Error::NotRegular => lang.text("Nur reguläre Dateien können geöffnet werden. Ordner, Pipes und Geräte werden nicht gelesen.","Only regular files can be opened. Folders, pipes and devices are not read.").into(),
        Error::Limit|Error::InvalidOffset => lang.text("Der angeforderte Abschnitt liegt außerhalb der sicheren Lesegrenze.","The requested section exceeds the safe read bounds.").into(),
        _ => lang.text("Die Datei konnte nicht gelesen werden.","The file could not be read.").into(),
    }
}
pub fn read(path: &Path) -> Result<Loaded, Error> {
    read_with_encoding(path, None)
}
pub fn read_with_encoding(path: &Path, explicit: Option<Encoding>) -> Result<Loaded, Error> {
    let cancel = Cancellation::default();
    match Document::open(path, explicit, &cancel).map_err(Error)? {
        Document::Text(document) if document.text().contains('\0') => {
            // GLib akzeptiert U+0000 nicht in GtkTextBuffer. Niemals gekürzten Text als Save-Basis zeigen.
            Ok(Loaded::Hex(
                Document::open_hex(path, &cancel).map_err(Error)?,
            ))
        }
        Document::Text(document) => Ok(Loaded::Text {
            decoded: Arc::new(document.decoded().clone()),
            snapshot: document.snapshot().clone(),
        }),
        Document::ReadOnlyText(document) if document.text().contains('\0') => Ok(Loaded::Hex(
            Document::open_hex(path, &cancel).map_err(Error)?,
        )),
        Document::ReadOnlyText(document) => Ok(Loaded::ReadOnlyText(Arc::new(document))),
        Document::Sections(document) => Ok(Loaded::Sections(document)),
        Document::Hex(document) => Ok(Loaded::Hex(document)),
    }
}

// Nach erfolgreichem Schreiben gehört jeder Fehler zur gehaltenen Recovery-Transaktion.
pub(super) fn finish_saved_document<T>(
    transaction: fastra_io::Transaction,
    cancel: &Cancellation,
    verify: impl FnOnce(&Snapshot) -> Result<T, fastra_io::Error>,
) -> Result<(Snapshot, T), fastra_io::Error> {
    let path = transaction.path().to_path_buf();
    let recovery = || fastra_io::Error::RecoveryRequired(path.clone());
    let snapshot = transaction
        .saved_document_snapshot(cancel)
        .map_err(|_| recovery())?;
    let value = verify(&snapshot).map_err(|_| recovery())?;
    transaction
        .finish_document_save(cancel)
        .map_err(|_| recovery())?;
    Ok((snapshot, value))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn readable_hardlinks_open_as_full_readonly_source_with_exact_original_encoding() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("source");
        let bytes = [0xff, 0xfe, 0xe9, 0, 13, 0, 10, 0];
        std::fs::write(&path, bytes).unwrap();
        std::fs::hard_link(&path, dir.path().join("alias")).unwrap();
        let Loaded::ReadOnlyText(source) = read(&path).unwrap() else { panic!("no writable basis may be created"); };
        assert_eq!(source.text(), "é\r\n");
        assert_eq!(source.snapshot().bytes(), bytes);
        assert!(Snapshot::read(&path, &Cancellation::default()).is_err());
    }
    #[test]
    fn preserves_bom_and_charset_separately_from_editor_text() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("unicode");
        std::fs::write(&path, [0xff, 0xfe, 0xe9, 0, 13, 0, 10, 0]).unwrap();
        let Loaded::Text { decoded, snapshot } = read(&path).unwrap() else {
            panic!()
        };
        assert_eq!(decoded.text(), "é\r\n");
        assert_eq!(decoded.bom(), [0xff, 0xfe]);
        assert_eq!(decoded.encode(decoded.text()).unwrap(), snapshot.bytes());
    }
    #[test]
    fn decoded_nul_and_large_lines_never_reach_editable_gtk_buffers() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nul");
        std::fs::write(&path, [0xff, 0xfe, b'A', 0, 0, 0, b'B', 0]).unwrap();
        assert!(matches!(read(&path).unwrap(), Loaded::Hex(_)));
        std::fs::write(&path, vec![b'a'; 65537]).unwrap();
        assert!(matches!(read(&path).unwrap(), Loaded::Sections(_)));
    }
    fn saved_transaction() -> (
        tempfile::TempDir,
        std::path::PathBuf,
        fastra_io::Transaction,
    ) {
        let dir = tempfile::tempdir_in(
            std::env::var_os("FASTRA_IO_TEST_ROOT")
                .map(std::path::PathBuf::from)
                .unwrap_or_else(std::env::temp_dir),
        )
        .unwrap();
        let path = dir.path().join("receipt.bin");
        std::fs::write(&path, b"original\0bytes").unwrap();
        let cancel = Cancellation::default();
        let snapshot = Snapshot::read_bounded(&path, 1024, &cancel).unwrap();
        let transaction =
            fastra_io::Transaction::save_document(snapshot, b"changed\0bytes", &cancel)
                .unwrap()
                .unwrap();
        (dir, path, transaction)
    }
    fn assert_recovery<T>(result: Result<T, fastra_io::Error>, journal: &std::path::Path) {
        assert!(
            matches!(result, Err(fastra_io::Error::RecoveryRequired(ref path)) if path == journal)
        );
        assert!(journal.is_dir());
        assert!(fastra_io::Transaction::reopen(journal).is_ok());
        assert!(std::fs::read_dir(journal).unwrap().any(|entry| {
            std::fs::read(entry.unwrap().path()).is_ok_and(|bytes| bytes == b"original\0bytes")
        }));
    }
    #[test]
    fn save_receipt_verifies_bytes_and_view_before_journal_cleanup() {
        let (_dir, path, transaction) = saved_transaction();
        let journal = transaction.path().to_path_buf();
        let cancel = Cancellation::default();
        let (snapshot, section) = finish_saved_document(transaction, &cancel, |snapshot| {
            assert!(journal.is_dir());
            assert_eq!(snapshot.bytes(), b"changed\0bytes");
            let section = fastra_document::Document::open_hex(&snapshot.path(), &cancel)
                .map_err(|error| fastra_io::Error::Io(std::io::Error::other(error.to_string())))?;
            assert_eq!(section.identity().device(), snapshot.file_identity().device);
            assert_eq!(section.identity().inode(), snapshot.file_identity().inode);
            Ok(section)
        })
        .unwrap();
        assert_eq!(snapshot.path(), path);
        assert_eq!(snapshot.bytes(), b"changed\0bytes");
        section.verify_current(&cancel).unwrap();
        assert!(!journal.exists());
    }
    #[test]
    fn save_receipt_missing_target_retains_recovery_path_and_original_bytes() {
        let (_dir, path, transaction) = saved_transaction();
        let journal = transaction.path().to_path_buf();
        std::fs::remove_file(path).unwrap();
        let result = finish_saved_document::<()>(transaction, &Cancellation::default(), |_| {
            panic!("Host verification must not run without a valid receipt")
        });
        assert_recovery(result, &journal);
    }
    #[test]
    fn save_receipt_host_verification_failure_retains_recovery_path() {
        let (_dir, path, transaction) = saved_transaction();
        let journal = transaction.path().to_path_buf();
        let result = finish_saved_document(transaction, &Cancellation::default(), |_| {
            Err::<(), _>(fastra_io::Error::Stale)
        });
        assert_recovery(result, &journal);
        assert_eq!(std::fs::read(path).unwrap(), b"changed\0bytes");
    }
    #[test]
    fn save_receipt_finalization_failure_retains_recovery_path() {
        let (_dir, path, transaction) = saved_transaction();
        let journal = transaction.path().to_path_buf();
        let result = finish_saved_document(transaction, &Cancellation::default(), |_| {
            std::fs::remove_file(&path).unwrap();
            Ok(())
        });
        assert_recovery(result, &journal);
    }
}
