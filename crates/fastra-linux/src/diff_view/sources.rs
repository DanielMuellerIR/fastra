use super::*;
use crate::Document;
use std::{fs::OpenOptions, io::Read, os::unix::fs::OpenOptionsExt, path::Path};
#[derive(Clone)]
pub(super) enum Choice {
    File(PathBuf),
    Document(Weak<Document>),
}
pub(super) fn eligible(doc: &Document) -> bool {
    !doc.is_read_only()
        && !doc.close_pending.get()
        && !doc.saving.get()
        && doc.hex_editor.borrow().is_none()
}
pub(super) fn destination_ready(doc: &Document) -> bool {
    eligible(doc)
        && doc
            .rich
            .borrow()
            .as_ref()
            .is_none_or(|editor| !editor.active.get() || editor.can_replace_source())
}
fn member(ui: &Ui, doc: &Rc<Document>) -> bool {
    ui.documents
        .borrow()
        .iter()
        .any(|candidate| Rc::ptr_eq(candidate, doc))
}
#[derive(Clone)]
pub(super) struct Origin {
    document: Weak<Document>,
    revision: u64,
    path: Option<PathBuf>,
    identity: Option<fastra_io::FileIdentity>,
}
impl Origin {
    pub fn protected_identities(&self) -> Vec<fastra_io::FileIdentity> {
        let mut identities = self.identity.into_iter().collect::<Vec<_>>();
        if let Some(doc) = self.document.upgrade() {
            identities.extend(
                doc.source_identity(),
            );
        }
        identities
    }
    pub fn current(&self, ui: &Ui) -> Option<Rc<Document>> {
        self.document.upgrade().filter(|doc| {
            member(ui, doc)
                && eligible(doc)
                && doc.revision.get() == self.revision
                && doc.disk_path() == self.path
        })
    }
}
#[derive(Clone)]
pub(super) enum ReadRequest {
    File(PathBuf),
    Memory(fastra_diff::TextSnapshot),
}
#[derive(Clone)]
pub(super) struct Loaded {
    pub snapshot: fastra_diff::TextSnapshot,
    pub file: Option<Arc<fastra_document::ReadOnlyTextDocument>>,
    lang: Language,
}
impl Loaded {
    pub fn verify_file(&self, cancel: &fastra_core::Cancellation) -> Result<(), String> {
        debug_assert!(!glib::MainContext::default().is_owner(), "Full comparison reads belong on a worker");
        self.file.as_ref().map_or(Ok(()), |file| {
            file.verify_current(cancel)
                .map_err(|error| document_error(self.lang, error))
        })
    }
    pub fn verify_identity(&self, cancel: &fastra_core::Cancellation) -> Result<(), String> {
        self.file.as_ref().map_or(Ok(()), |file| {
            file.verify_identity(cancel)
                .map_err(|error| document_error(self.lang, error))
        })
    }
}
impl ReadRequest {
    pub fn load(
        self,
        cancel: &fastra_core::Cancellation,
        lang: Language,
    ) -> Result<Loaded, String> {
        match self {
            Self::Memory(snapshot) => {
                cancel.check().map_err(|e| e.to_string())?;
                Ok(Loaded {
                    snapshot,
                    file: None,
                    lang,
                })
            }
            Self::File(path) => {
                let file = Arc::new(fastra_document::ReadOnlyTextDocument::open(&path, None, cancel)
                    .map_err(|error| match error {
                        fastra_document::Error::NotText => lang.text("Abschnitts- und Binärdateien können nicht als vollständiger Zeilenvergleich geöffnet werden.", "Section and binary files cannot be opened as a complete line comparison.").into(),
                        error => document_error(lang, error),
                    })?);
                let snapshot = fastra_diff::TextSnapshot {
                    document_id: format!(
                        "file:{}:{}",
                        file.identity().device(),
                        file.identity().inode()
                    ),
                    revision: 0,
                    text: file.text().into(),
                };
                Ok(Loaded {
                    snapshot,
                    file: Some(file),
                    lang,
                })
            }
        }
    }
}
impl Choice {
    pub fn from_doc(doc: &Rc<Document>) -> Self {
        Self::Document(Rc::downgrade(doc))
    }
    pub fn name(&self, lang: Language) -> String {
        match self {
            Self::File(path) => path
                .file_name()
                .map(|name| crate::project_view::display(Path::new(name)))
                .unwrap_or_else(|| crate::project_view::display(path)),
            Self::Document(doc) => doc
                .upgrade()
                .map(|doc| {
                    doc.disk_path()
                        .as_ref()
                        .and_then(|path| path.file_name())
                        .map(|name| crate::project_view::display(Path::new(name)))
                        .unwrap_or_else(|| doc.name.clone())
                })
                .unwrap_or_else(|| lang.text("Geschlossener Tab", "Closed tab").into()),
        }
    }
    pub fn result_name(&self, lang: Language) -> String {
        let name = self.name(lang);
        match self {
            Self::Document(doc)
                if doc
                    .upgrade()
                    .is_some_and(|doc| doc.buffer.is_modified() && doc.disk_path().is_some()) =>
            {
                format!("{name} ({})", lang.text("ungespeichert", "unsaved"))
            }
            _ => name,
        }
    }
    pub fn description(&self, lang: Language) -> String {
        match self {
            Self::File(path) => path
                .parent()
                .map(crate::project_view::display)
                .unwrap_or_default(),
            Self::Document(doc) => doc
                .upgrade()
                .map(|doc| {
                    if doc.buffer.is_modified() {
                        lang.text(
                            "Offener Tab (ungespeicherte Änderungen)",
                            "Open tab (unsaved changes)",
                        )
                    } else {
                        lang.text("Offener Tab", "Open tab")
                    }
                    .into()
                })
                .unwrap_or_default(),
        }
    }
    pub fn path(&self) -> Option<PathBuf> {
        match self {
            Self::File(path) => Some(path.clone()),
            Self::Document(doc) => doc.upgrade().and_then(|doc| doc.disk_path()),
        }
    }
    pub fn document(&self, ui: &Ui) -> Option<Rc<Document>> {
        match self {
            Self::Document(doc) => doc.upgrade().filter(|doc| member(ui, doc) && eligible(doc)),
            _ => None,
        }
    }
    pub fn capture(&self, ui: &Ui) -> Result<(ReadRequest, Option<Origin>), String> {
        match self {
            Self::File(path) => Ok((ReadRequest::File(path.clone()), None)),
            Self::Document(_) => {
                let doc = self.document(ui).ok_or_else(|| {
                    ui.lang
                        .text(
                            "Tab ist nicht mehr geöffnet oder nicht mehr vergleichbar.",
                            "The tab is no longer open or comparable.",
                        )
                        .to_owned()
                })?;
                if doc.buffer.char_count() as usize > fastra_document::EDITABLE_BYTES {
                    return Err(ui
                        .lang
                        .text(
                            "Die Vergleichsquelle überschreitet 32 MiB.",
                            "The comparison source exceeds 32 MiB.",
                        )
                        .into());
                }
                let revision = doc.revision.get();
                let text = buffer_text(&doc.buffer);
                let origin = Origin {
                    document: Rc::downgrade(&doc),
                    revision,
                    path: doc.disk_path(),
                    identity: doc.source_identity(),
                };
                let snapshot = fastra_diff::TextSnapshot {
                    document_id: format!("document-{:x}", Rc::as_ptr(&doc) as usize),
                    revision,
                    text,
                };
                Ok((ReadRequest::Memory(snapshot), Some(origin)))
            }
        }
    }
}
pub(super) fn problem(path: &Path, lang: Language) -> Option<String> {
    let result = (|| {
        let metadata = std::fs::metadata(path).map_err(|_| {
            lang.text("Datei nicht gefunden.", "File not found.")
                .to_owned()
        })?;
        if metadata.is_dir() {
            return Err(lang
                .text(
                    "Wähle hier eine Datei. Für zwei Ordner nutze „Ordner vergleichen…“.",
                    "Choose a file here. For two folders, use “Compare folders…”.",
                )
                .into());
        }
        if !metadata.is_file() {
            return Err(lang
                .text(
                    "Die Quelle ist keine reguläre Datei.",
                    "The source is not a regular file.",
                )
                .into());
        }
        if metadata.len() > fastra_document::EDITABLE_BYTES as u64 {
            return Err(lang
                .text(
                    "Die Datei überschreitet die Textgrenze von 32 MiB.",
                    "The file exceeds the 32 MiB text limit.",
                )
                .into());
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)
            .map_err(|e| {
                format!(
                    "{} {e}",
                    lang.text("Datei nicht lesbar:", "Cannot read file:")
                )
            })?;
        if !file.metadata().map_err(|e| e.to_string())?.is_file() {
            return Err(lang
                .text(
                    "Die Quelle ist keine reguläre Datei.",
                    "The source is not a regular file.",
                )
                .into());
        }
        let mut bytes = Vec::new();
        file.take(8192)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        let bom = bytes.starts_with(&[0xff, 0xfe])
            || bytes.starts_with(&[0xfe, 0xff])
            || bytes.starts_with(&[0, 0, 0xfe, 0xff]);
        if !bom && bytes.contains(&0) {
            return Err(lang
                .text(
                    "Binärdatei — ein Zeilenvergleich ist nicht möglich.",
                    "Binary file — a line comparison is unavailable.",
                )
                .into());
        }
        Ok::<_, String>(())
    })();
    result.err()
}
