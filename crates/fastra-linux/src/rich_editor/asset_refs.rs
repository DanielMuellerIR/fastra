//! Konservative Verweisprüfung vor dem Verschieben eigener Bilddateien.
use super::*;
use std::{
    collections::BTreeSet,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};
thread_local! {static WINDOWS:RefCell<Vec<std::rc::Weak<Ui>>>=const{RefCell::new(Vec::new())};}
pub(super) fn register(ui: &Rc<Ui>) {
    WINDOWS.with(|list| {
        let mut list = list.borrow_mut();
        list.retain(|w| w.strong_count() > 0);
        if !list
            .iter()
            .filter_map(std::rc::Weak::upgrade)
            .any(|other| Rc::ptr_eq(&other, ui))
        {
            list.push(Rc::downgrade(ui));
        }
    });
}
struct WindowStamp {
    ui: std::rc::Weak<Ui>,
    generation: u64,
    documents: Vec<(std::rc::Weak<Document>, u64, Option<PathBuf>)>,
}
pub(crate) struct OpenSnapshot {
    windows: Vec<WindowStamp>,
    pub texts: Vec<(PathBuf, String)>,
    pub complete: bool,
}
fn uncertain_unsaved(source: &str) -> bool {
    let Ok(events) = crate::markdown::syntax::events(source, &Cancellation::default()) else { return true };
    events.into_iter().enumerate().any(|(count, (event, _, _))| {
            count > 100000
                || match event {
                    Event::Start(Tag::Image { .. }) | Event::Html(_) | Event::InlineHtml(_) => true,
                    Event::Start(Tag::Link { dest_url, .. }) => {
                        !dest_url.starts_with('#')
                            && !dest_url.starts_with("http:")
                            && !dest_url.starts_with("https:")
                            && !dest_url.starts_with("mailto:")
                    }
                    _ => false,
                }
        })
}
pub(crate) fn capture(excluded: &Rc<Document>) -> OpenSnapshot {
    let mut snapshot = OpenSnapshot {
        windows: Vec::new(),
        texts: Vec::new(),
        complete: true,
    };
    let mut total = 0usize;
    WINDOWS.with(|list| {
        for ui in list.borrow().iter().filter_map(std::rc::Weak::upgrade) {
            let mut stamp = WindowStamp {
                ui: Rc::downgrade(&ui),
                generation: ui.generation.get(),
                documents: Vec::new(),
            };
            for doc in ui.documents.borrow().iter() {
                stamp
                    .documents
                    .push((Rc::downgrade(doc), doc.revision.get(), doc.disk_path()));
                if Rc::ptr_eq(doc, excluded) {
                    continue;
                }
                if doc.buffer.char_count() > 262144 {
                    snapshot.complete = false;
                    continue;
                }
                let text = buffer_text(&doc.buffer);
                total += text.len();
                if total > 8 * 1024 * 1024 {
                    snapshot.complete = false;
                    continue;
                }
                if let Some(path) = doc.disk_path() {
                    snapshot.texts.push((path, text));
                } else if uncertain_unsaved(&text) {
                    snapshot.complete = false;
                }
            }
            snapshot.windows.push(stamp);
        }
    });
    snapshot
}
impl OpenSnapshot {
    pub fn current(&self) -> bool {
        WINDOWS.with(|windows| {
            let now = windows
                .borrow()
                .iter()
                .filter_map(std::rc::Weak::upgrade)
                .collect::<Vec<_>>();
            if now.len() != self.windows.len() {
                return false;
            }
            self.windows.iter().all(|old| {
                old.ui.upgrade().is_some_and(|ui| {
                    now.iter().any(|n| Rc::ptr_eq(n, &ui))
                        && ui.generation.get() == old.generation
                        && {
                            let docs = ui.documents.borrow();
                            docs.len() == old.documents.len()
                                && docs.iter().zip(&old.documents).all(
                                    |(doc, (weak, revision, path))| {
                                        doc.revision.get() == *revision
                                            && doc.disk_path() == *path
                                            && weak
                                                .upgrade()
                                                .is_some_and(|old| Rc::ptr_eq(doc, &old))
                                    },
                                )
                        }
                })
            })
        })
    }
}
#[derive(PartialEq, Eq)]
struct Entry {
    name: std::ffi::OsString,
    identity: (u64, u64),
    file: bool,
    bytes: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
fn folder(path: &Path) -> Result<Vec<Entry>, String> {
    let mut entries = Vec::new();
    for item in std::fs::read_dir(path).map_err(|e| e.to_string())? {
        if entries.len() >= 10000 {
            return Err("Reference directory entry limit".into());
        }
        let item = item.map_err(|e| e.to_string())?;
        let meta = std::fs::symlink_metadata(item.path()).map_err(|e| e.to_string())?;
        entries.push(Entry {
            name: item.file_name(),
            identity: (meta.dev(), meta.ino()),
            file: meta.is_file(),
            bytes: if meta.is_file() { meta.len() } else { 0 },
            modified: if meta.is_file() {
                (meta.mtime(), meta.mtime_nsec())
            } else {
                (0, 0)
            },
            changed: if meta.is_file() {
                (meta.ctime(), meta.ctime_nsec())
            } else {
                (0, 0)
            },
        });
    }
    entries.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(entries)
}
pub(crate) struct Protection {
    all: bool,
    paths: BTreeSet<PathBuf>,
    documents: Vec<fastra_io::Snapshot>,
    folder: PathBuf,
    entries: Vec<Entry>,
}
fn reference_path(raw: &str, document: &Path) -> Result<PathBuf, String> {
    let path = crate::markdown::decode_path(raw)?;
    let path = if path.is_absolute() {
        path
    } else {
        document
            .parent()
            .ok_or("reference directory missing")?
            .join(path)
    };
    if let Ok(path) = path.canonicalize() {
        return Ok(path);
    }
    Ok(path
        .parent()
        .ok_or("reference directory missing")?
        .canonicalize()
        .map_err(|e| e.to_string())?
        .join(path.file_name().ok_or("reference name missing")?))
}
fn collect(source: &str, document: &Path, protection: &mut Protection) {
    let Ok(events) = crate::markdown::syntax::events(source, &Cancellation::default()) else { protection.all = true; return };
    for (count, (event, _, _)) in events.into_iter().enumerate() {
        if count > 100000 {
            protection.all = true;
            return;
        }
        match event {
            Event::Start(Tag::Image { dest_url, .. } | Tag::Link { dest_url, .. }) => {
                if dest_url.starts_with('#')
                    || dest_url.starts_with("https:")
                    || dest_url.starts_with("http:")
                    || dest_url.starts_with("mailto:")
                {
                    continue;
                }
                match reference_path(&dest_url, document) {
                    Ok(path) => {
                        if path == protection.folder.join("images") {
                            protection.all = true;
                        }
                        protection.paths.insert(path);
                    }
                    Err(_) => protection.all = true,
                }
            }
            Event::Html(_) | Event::InlineHtml(_) => protection.all = true,
            _ => {}
        }
    }
}
impl Protection {
    pub fn scan(
        document: &Path,
        opened: &[(PathBuf, String)],
        complete: bool,
        cancel: &Cancellation,
    ) -> Self {
        Self::scan_bound(document, opened, complete, true, cancel)
    }
    pub fn scan_target(document: &Path, opened: &[(PathBuf,String)], complete: bool, cancel: &Cancellation) -> Self {
        let exists = std::fs::symlink_metadata(document);
        let readable = !matches!(&exists,Err(error) if error.kind()==std::io::ErrorKind::NotFound);
        Self::scan_bound(document, opened, complete, readable, cancel)
    }
    fn scan_bound(document: &Path, opened: &[(PathBuf,String)], complete: bool, read_document: bool, cancel: &Cancellation) -> Self {
        let folder_path = document
            .parent()
            .unwrap_or_else(|| Path::new("/"))
            .to_owned();
        let mut protection = Self {
            all: !complete,
            paths: BTreeSet::new(),
            documents: Vec::new(),
            folder: folder_path,
            entries: Vec::new(),
        };
        let result = (|| {
            protection.entries = folder(&protection.folder)?;
            let mut paths = if read_document { vec![document.to_owned()] } else { Vec::new() };
            for entry in &protection.entries {
                let path = protection.folder.join(&entry.name);
                if path == document {
                    continue;
                }
                if path.extension().and_then(|v| v.to_str()).is_some_and(|v| {
                    matches!(
                        v.to_ascii_lowercase().as_str(),
                        "md" | "markdown" | "mdown" | "mkd"
                    )
                }) {
                    if !entry.file {
                        return Err("Nonregular Markdown reference source".into());
                    }
                    paths.push(path);
                }
            }
            let mut bytes = 0usize;
            for path in paths {
                let snapshot = fastra_io::Snapshot::read_bounded(&path, 10 * 1024 * 1024, cancel)
                    .map_err(|e| e.to_string())?;
                bytes += snapshot.bytes().len();
                if bytes > 32 * 1024 * 1024 {
                    return Err("Reference text budget".into());
                }
                let decoded = fastra_core::encoding::decode(snapshot.bytes(), None)
                    .map_err(|e| format!("{e:?}"))?;
                collect(decoded.text(), &path, &mut protection);
                protection.documents.push(snapshot);
            }
            for (path, text) in opened {
                // Auch ein direkt geöffnetes Bilddokument besitzt seinen Dateinamen, ohne einen Markdown-Verweis zu enthalten.
                protection
                    .paths
                    .insert(path.canonicalize().unwrap_or_else(|_| path.clone()));
                collect(text, path, &mut protection);
            }
            Ok::<(), String>(())
        })();
        if result.is_err() {
            protection.all = true;
        }
        protection
    }
    pub fn protects(&self, paths: impl Iterator<Item = PathBuf>) -> bool {
        self.all || paths.into_iter().any(|path| self.paths.contains(&path))
    }
    pub fn current(&self, cancel: &Cancellation) -> bool {
        if folder(&self.folder).ok().as_ref() != Some(&self.entries) {
            return false;
        }
        self.documents.iter().all(|old| {
            fastra_io::Snapshot::read_bounded(&old.path(), 10 * 1024 * 1024, cancel)
                .is_ok_and(|now| now.binding_digest().ok() == old.binding_digest().ok())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let dir = tempfile::tempdir_in(root).unwrap();
        let document = dir.path().join("main.md");
        std::fs::write(&document, "Plain\n").unwrap();
        std::fs::create_dir(dir.path().join("images")).unwrap();
        let image = dir.path().join("images/a#b.png");
        std::fs::write(&image, b"synthetic").unwrap();
        (dir, document, image)
    }
    #[test]
    fn unsaved_documents_protect_unknown_local_image_bases_but_not_plain_welcome_text() {
        for source in [
            "![image](/project/images/a.png)",
            "![image](images/a.png)",
            "[local](images)",
            "<style>img{content:url(a.png)}</style>",
        ] {
            assert!(uncertain_unsaved(source));
        }
        for source in [
            "Welcome to the editor",
            "[remote](https://example.invalid)",
            "`![code](images/a.png)`",
        ] {
            assert!(!uncertain_unsaved(source));
        }
    }
    #[test]
    fn directly_opened_image_documents_protect_their_file_without_markdown_text() {
        let (_dir, document, image) = fixture();
        let protection = Protection::scan(
            &document,
            &[(image.clone(), String::new())],
            true,
            &Cancellation::default(),
        );
        assert!(protection.protects(std::iter::once(image)));
    }
    #[test]
    fn saved_sibling_open_and_encoded_references_protect_only_the_actual_image() {
        for origin in 0..5 {
            let (dir, document, image) = fixture();
            let mut opened = Vec::new();
            let text = "![image](images/a%23b.png)\n";
            match origin {
                0 => std::fs::write(&document, text).unwrap(),
                1 => std::fs::write(dir.path().join("sibling.markdown"), text).unwrap(),
                2 => opened.push((document.clone(), text.into())),
                4 => std::fs::write(dir.path().join(".notes.md"), text).unwrap(),
                _ => {
                    let bytes = [
                        b"\xff\xfe".to_vec(),
                        text.encode_utf16().flat_map(u16::to_le_bytes).collect(),
                    ]
                    .concat();
                    std::fs::write(dir.path().join("utf16.md"), bytes).unwrap();
                }
            }
            let protection = Protection::scan(&document, &opened, true, &Cancellation::default());
            assert!(protection.current(&Cancellation::default()));
            assert!(protection.protects(std::iter::once(image)));
            assert!(!protection.protects(std::iter::once(dir.path().join("images/unrelated.png"))));
        }
    }
    #[test]
    fn unknown_reference_authority_is_conservative_and_source_changes_invalidate() {
        for text in [
            "<style>img{content:url(images/a.png)}</style>",
            "[folder](images)",
            "![unknown](images/missing/sub.png)",
        ] {
            let (_dir, document, image) = fixture();
            std::fs::write(&document, text).unwrap();
            let protection = Protection::scan(&document, &[], true, &Cancellation::default());
            assert!(protection.protects(std::iter::once(image)));
        }
        let (dir, document, image) = fixture();
        let protection = Protection::scan(&document, &[], false, &Cancellation::default());
        assert!(protection.protects(std::iter::once(image)));
        let protection = Protection::scan(&document, &[], true, &Cancellation::default());
        std::fs::write(dir.path().join("new.md"), "new reference source").unwrap();
        assert!(!protection.current(&Cancellation::default()));
        let protection = Protection::scan(&document, &[], true, &Cancellation::default());
        std::fs::write(&document, "changed").unwrap();
        assert!(!protection.current(&Cancellation::default()));
    }
}
