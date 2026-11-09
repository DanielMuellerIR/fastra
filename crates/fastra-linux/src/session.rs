//! Lokale Sitzungsrettung ergänzt Dateispeicherung; fremde Plattenstände werden nie ungesehen zur Basis.
mod close;
mod journals;
pub(super) use close::Permit as ClosePermit;
mod store;
use super::{buffer_text, git_view as support, Document, Ui};
use gtk::prelude::*;
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    path::PathBuf,
    rc::{Rc, Weak},
    sync::Arc,
};
use store::{Record, Session};
#[derive(Clone, Copy)]
enum CloseMode {
    Recovery,
    Discard,
}
struct Captured {
    record: Record,
    original: Option<(Arc<fastra_core::encoding::Decoded>, String)>,
    snapshot: Option<fastra_io::Snapshot>,
}
struct Capture {
    width: i32,
    height: i32,
    active: usize,
    documents: Vec<Captured>,
    read_only_sources: Vec<store::ReadOnlyRecord>,
    recovery_journals: Vec<Vec<u8>>,
}
impl Capture {
    fn session(mut self) -> Result<Session, String> {
        let mut total = 0usize;
        for c in &mut self.documents {
            let original_length = c
                .snapshot
                .as_ref()
                .map(|s| s.bytes().len())
                .or_else(|| c.original.as_ref().map(|(_, text)| text.len()))
                .unwrap_or(c.record.original_hex.len() / 2);
            total = total
                .checked_add(c.record.text.len() + original_length)
                .ok_or("Recovery size overflow")?;
            if total > store::MAX_TOTAL {
                return Err("Recovery total limit: 8 MiB".into());
            }
            if let Some(snapshot) = &c.snapshot {
                if snapshot.bytes().len() > store::MAX_DOC_BYTES {
                    return Err("Original exceeds 4 MiB recovery limit".into());
                }
                c.record.original_hex = store::hex(snapshot.bytes());
                c.record.binding = Some(store::hex(
                    &snapshot.binding_digest().map_err(|e| e.to_string())?,
                ));
            } else if let Some((original, text)) = &c.original {
                let bytes = original.encode(text).map_err(|e| e.to_string())?;
                if bytes.len() > store::MAX_DOC_BYTES {
                    return Err("Original exceeds 4 MiB recovery limit".into());
                }
                c.record.original_hex = store::hex(&bytes);
            }
        }
        let session = Session {
            recovery_journals: self.recovery_journals,
            version: if self.read_only_sources.is_empty() {
                1
            } else {
                2
            },
            active: self.active,
            width: self.width,
            height: self.height,
            documents: self.documents.into_iter().map(|c| c.record).collect(),
            read_only_sources: self.read_only_sources,
        };
        session.validate()?;
        Ok(session)
    }
}
struct Restored {
    record: Record,
    decoded: fastra_core::encoding::Decoded,
    snapshot: Option<fastra_io::Snapshot>,
}
fn restore_records(records: Vec<Record>) -> Result<Vec<Restored>, String> {
    records
        .into_iter()
        .map(|record| {
            record.validate_endings()?;
            let bytes = store::unhex(&record.original_hex)?;
            let decoded =
                fastra_core::encoding::decode(&bytes, Some(store::encoding(record.encoding)?))
                    .map_err(|e| e.to_string())?;
            let snapshot = record
                .path
                .as_deref()
                .and_then(|path| {
                    fastra_io::Snapshot::read_bounded(
                        &store::source_path(path),
                        store::MAX_DOC_BYTES,
                        &fastra_core::Cancellation::default(),
                    )
                    .ok()
                })
                .filter(|s| {
                    record.binding.as_ref().is_some_and(|expected| {
                        s.binding_digest()
                            .ok()
                            .is_some_and(|digest| store::hex(&digest) == *expected)
                    }) && Some(s.file_identity().device) == record.device
                        && Some(s.file_identity().inode) == record.inode
                        && s.bytes() == bytes
                });
            Ok(Restored {
                record,
                decoded,
                snapshot,
            })
        })
        .collect()
}
#[derive(Clone)]
enum RestoreEntry {
    Editor(Record),
    ReadOnly(store::ReadOnlyRecord),
}
enum RestoredTab {
    Editor(Box<Restored>),
    ReadOnly(
        store::ReadOnlyRecord,
        Result<Arc<fastra_document::ReadOnlyTextDocument>, fastra_document::Error>,
    ),
}
fn restore_tabs(
    entries: Vec<RestoreEntry>,
    cancel: &fastra_core::Cancellation,
) -> Result<Vec<RestoredTab>, String> {
    let mut tabs = Vec::with_capacity(entries.len());
    for entry in entries {
        if cancel.check().is_err() {
            return Err("Restoration cancelled".into());
        }
        tabs.push(match entry {
            RestoreEntry::Editor(record) => {
                RestoredTab::Editor(Box::new(restore_records(vec![record])?.remove(0)))
            }
            RestoreEntry::ReadOnly(record) => {
                let encoding = store::encoding(record.encoding)?;
                let source = fastra_document::ReadOnlyTextDocument::open(
                    &store::source_path(&record.path),
                    Some(encoding),
                    cancel,
                )
                .map(Arc::new);
                RestoredTab::ReadOnly(record, source)
            }
        });
    }
    if cancel.check().is_err() {
        return Err("Restoration cancelled".into());
    }
    Ok(tabs)
}
fn editor_membership(ui: &Ui) -> Vec<(usize, bool, bool)> {
    ui.documents
        .borrow()
        .iter()
        .map(|doc| {
            (
                Rc::as_ptr(doc) as usize,
                doc.is_read_only(),
                doc.is_rich_active(),
            )
        })
        .collect()
}
type Stamp = Vec<(usize, u64, Option<fastra_io::FileIdentity>, bool, bool)>;
#[derive(Clone, PartialEq, Eq)]
struct WindowStamp {
    epoch: u64,
    documents: Stamp,
    active: Option<u32>,
    width: i32,
    height: i32,
}
pub(super) struct State {
    ui: Weak<Ui>,
    status: gtk::Label,
    journals: RefCell<Vec<PathBuf>>,
    journals_epoch: Cell<u64>,
    journals_saved: Cell<u64>,
    index_closing: Cell<bool>,
    review_open: Cell<usize>,
    journal_button: gtk::Button,
    enabled: gtk::CheckButton,
    manage: gtk::Button,
    save_now: gtk::Button,
    lease: RefCell<Option<Arc<store::Lease>>>,
    archives: RefCell<Vec<store::Archive>>,
    busy: Cell<bool>,
    ready: Cell<bool>,
    epoch: Cell<u64>,
    allow_close: Cell<bool>,
    closing: Cell<bool>,
    close_dialog: Cell<bool>,
    pending_close: Cell<Option<CloseMode>>,
    stamp: RefCell<Option<WindowStamp>>,
    fallback: RefCell<HashMap<usize, (Weak<Document>, Record)>>,
    consume: RefCell<Vec<store::Archive>>,
}
impl State {
    fn initialize(self: &Rc<Self>) {
        if self.ui.upgrade().is_none_or(|ui| !ui.window.is_visible()) {
            return;
        }
        if self.busy.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                let dir = store::Directory::open(&state_base()?)?;
                let archives = dir.inactive()?;
                let mut count = 0;
                let mut bytes = 0;
                for archive in &archives {
                    count += archive.session.tab_count();
                    for record in &archive.session.documents {
                        bytes += record.text.len() + record.original_hex.len() / 2;
                    }
                }
                if count > store::MAX_DOCS || bytes > store::MAX_TOTAL {
                    return Err("Combined recovery limit: 32 documents / 8 MiB".into());
                }
                Ok((Arc::new(dir.create()?), archives))
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.busy.set(false);
                if state.ui.upgrade().is_none_or(|ui| !ui.window.is_visible()) {
                    return;
                }
                match result {
                    Ok((lease, archives)) => {
                        *state.lease.borrow_mut() = Some(lease);
                        *state.archives.borrow_mut() = archives;
                        state.ready.set(true);
                        if let Err(error) = state.merge_journals() {
                            state.ready.set(false);
                            state.failed(&error);
                            return;
                        }
                        state
                            .manage
                            .set_sensitive(!state.archives.borrow().is_empty());
                        state.save_now.set_sensitive(state.enabled.is_active());
                        state.save_now.set_label(
                            state
                                .ui
                                .upgrade()
                                .unwrap()
                                .lang
                                .text("Jetzt sichern", "Back up now"),
                        );
                        if !state.enabled.is_active() {
                            let ui = state.ui.upgrade().unwrap();
                            state.status.set_text(ui.lang.text("Textsicherung aus. Vorhandene Sicherungen können ausdrücklich geöffnet werden.","Text backup off. Existing backups can be opened explicitly."));
                            state.status.set_tooltip_text(None);
                        }
                        state.tick();
                        if state.enabled.is_active() && !state.archives.borrow().is_empty() {
                            state.review();
                        }
                    }
                    Err(error) => state.failed(&error),
                }
            },
        );
    }
    fn capture(&self, mode: Option<CloseMode>) -> Result<Capture, String> {
        let Some(ui) = self.ui.upgrade() else {
            return Err("Window closed".into());
        };
        let docs = ui.documents.borrow();
        if docs.iter().any(|d| d.saving.get()) {
            return Err("File save still running".into());
        }
        let mut documents = Vec::new();
        let mut read_only_sources = Vec::new();
        let mut active = 0;
        let mut total = 0usize;
        let active_doc = ui.active();
        for doc in docs.iter() {
            if let Some(source) = doc.read_source.borrow().as_ref() {
                use std::os::unix::ffi::OsStrExt;
                if documents.len() + read_only_sources.len() >= store::MAX_DOCS {
                    return Err("Recovery limit: 32 documents".into());
                }
                let position = documents.len() + read_only_sources.len();
                if active_doc
                    .as_ref()
                    .is_some_and(|active| Rc::ptr_eq(active, doc))
                {
                    active = position;
                }
                read_only_sources.push(store::ReadOnlyRecord {
                    name: doc.name.clone(),
                    path: source.path().as_os_str().as_bytes().to_vec(),
                    encoding: store::encoding_id(source.decoded().encoding()),
                    position,
                });
                continue;
            }
            if doc.is_read_only() {
                continue;
            }
            let snapshot = doc.snapshot.borrow().clone();
            let dirty = doc.buffer.is_modified();
            if snapshot.is_none() && !dirty {
                continue;
            }
            if matches!(mode, Some(CloseMode::Discard)) && snapshot.is_none() {
                continue;
            }
            if documents.len() + read_only_sources.len() >= store::MAX_DOCS
                || doc.buffer.char_count() as usize > store::MAX_DOC_BYTES
            {
                return Err("Recovery limit: 32 documents / 4 MiB per document".into());
            }
            let mut text = buffer_text(&doc.buffer);
            let format = doc.format.borrow().clone();
            if matches!(mode, Some(CloseMode::Discard)) {
                text = doc.original.borrow().clone();
            }
            total = total
                .checked_add(text.len())
                .ok_or("Recovery size overflow")?;
            if text.len() > store::MAX_DOC_BYTES || total > store::MAX_TOTAL {
                return Err("Recovery total limit: 8 MiB".into());
            }
            let key = Rc::as_ptr(doc) as usize;
            let fallback = self
                .fallback
                .borrow()
                .get(&key)
                .filter(|(weak, _)| weak.upgrade().is_some_and(|old| Rc::ptr_eq(&old, doc)))
                .map(|(_, r)| r.clone());
            let path = snapshot.as_ref().map(|s| {
                use std::os::unix::ffi::OsStrExt;
                s.path().as_os_str().as_bytes().to_vec()
            });
            let identity = snapshot.as_ref().map(|s| s.file_identity());
            let mut record = Record {
                name: snapshot
                    .as_ref()
                    .and_then(|s| {
                        s.path()
                            .file_name()
                            .map(|name| name.to_string_lossy().into_owned())
                    })
                    .unwrap_or_else(|| doc.name.clone()),
                path,
                device: identity.map(|i| i.device),
                inode: identity.map(|i| i.inode),
                binding: None,
                original_hex: String::new(),
                encoding: store::encoding_id(format.encoding()),
                text,
                saved_ending: Some(super::line_endings::encode(doc.line_endings.saved())),
                pending_ending: if matches!(mode, Some(CloseMode::Discard)) {
                    None
                } else {
                    doc.line_endings.pending().map(super::line_endings::encode)
                },
                dirty: dirty && !matches!(mode, Some(CloseMode::Discard)),
            };
            let original = if snapshot.is_some() {
                None
            } else if let Some(base) = fallback {
                record.name = base.name;
                record.path = base.path;
                record.device = base.device;
                record.inode = base.inode;
                record.binding = base.binding;
                record.original_hex = base.original_hex;
                record.encoding = base.encoding;
                None
            } else {
                let original = doc.original.borrow();
                if original.len() > store::MAX_DOC_BYTES {
                    return Err("Original recovery text exceeds 4 MiB".into());
                }
                Some((format, original.clone()))
            };
            if active_doc.as_ref().is_some_and(|a| Rc::ptr_eq(a, doc)) {
                active = documents.len() + read_only_sources.len();
            }
            documents.push(Captured {
                record,
                original,
                snapshot,
            });
        }
        Ok(Capture {
            recovery_journals: self
                .journals
                .borrow()
                .iter()
                .map(|p| {
                    use std::os::unix::ffi::OsStrExt;
                    p.as_os_str().as_bytes().to_vec()
                })
                .collect(),
            width: ui.window.width().clamp(760, 4000),
            height: ui.window.height().clamp(700, 2400),
            active,
            documents,
            read_only_sources,
        })
    }
    fn current_stamp(&self) -> Option<WindowStamp> {
        let ui = self.ui.upgrade()?;
        let result = ui
            .documents
            .borrow()
            .iter()
            .map(|d| {
                (
                    Rc::as_ptr(d) as usize,
                    d.revision.get(),
                    d.snapshot.borrow().as_ref().map(|s| s.file_identity()),
                    d.buffer.is_modified(),
                    d.saving.get(),
                )
            })
            .collect();
        Some(WindowStamp {
            epoch: self.epoch.get(),
            documents: result,
            active: ui.tabs.current_page(),
            width: ui.window.width(),
            height: ui.window.height(),
        })
    }
    fn tick(self: &Rc<Self>) {
        if self.ui.upgrade().is_none_or(|ui| !ui.window.is_visible()) {
            return;
        }
        if !self.ready.get() || self.busy.get() || self.closing.get() || self.allow_close.get() {
            return;
        }
        if self.journals_epoch.get() != self.journals_saved.get() {
            self.flush_journals();
            return;
        }
        if !self.enabled.is_active() {
            return;
        }
        if self
            .ui
            .upgrade()
            .is_some_and(|ui| ui.documents.borrow().iter().any(|doc| doc.saving.get()))
        {
            return;
        }
        let stamp = self.current_stamp();
        if *self.stamp.borrow() != stamp {
            self.flush(None);
        }
    }
    fn flush(self: &Rc<Self>, close: Option<CloseMode>) {
        let Some(ui) = self.ui.upgrade().filter(|ui| ui.window.is_visible()) else {
            self.pending_close.take();
            self.closing.set(false);
            return;
        };
        if close.is_some() {
            self.closing.set(true);
        }
        if self.busy.get() {
            if let Some(mode) = close {
                self.pending_close.set(Some(mode));
            }
            return;
        }
        let Some(lease) = self.lease.borrow().clone() else {
            return;
        };
        let members = editor_membership(&ui);
        self.busy.set(true);
        if close.is_some() {
            ui.window.set_sensitive(false);
        }
        self.status.set_text(ui.lang.text(
            "Editorstände werden vor der Sicherung abgeglichen …",
            "Synchronizing editor contents before backup …",
        ));
        let weak = Rc::downgrade(self);
        let owner = Rc::downgrade(&ui);
        super::rich_editor::flush_all_owned(
            &ui,
            true,
            Box::new(move |ok| {
                let Some(ui) = owner.upgrade() else {
                    return;
                };
                let Some(state) = weak.upgrade() else {
                    super::rich_editor::release_all(&ui);
                    return;
                };
                if !ok || !ui.window.is_visible() || editor_membership(&ui) != members {
                    super::rich_editor::release_all(&ui);
                    state.busy.set(false);
                    state.pending_close.take();
                    ui.window.set_sensitive(true);
                    if ui.window.is_visible() {
                        state.failed(if !ok{ui.lang.text("Rich-Inhalt nicht synchronisiert. Keine Sicherung und kein Schließen; sichtbarer Entwurf bleibt erhalten.","Rich contents not synchronized. No backup or close; visible draft retained.")}else{ui.lang.text("Fensterinhalt während des Abgleichs geändert. Erneut prüfen und sichern.","Window changed during synchronization. Review and back up again.")});
                        state.stamp.borrow_mut().take();
                    } else {
                        state.closing.set(false);
                    }
                    return;
                }
                let capture = state.capture(close);
                let stamp = state.current_stamp();
                // Beim Schließen sperrt Gtk bereits Eingaben; danach darf die JS-Fence wieder frei sein.
                super::rich_editor::release_all(&ui);
                match capture {
                    Ok(capture) => state.write_capture(close, capture, stamp, lease),
                    Err(error) => {
                        state.busy.set(false);
                        state.pending_close.take();
                        ui.window.set_sensitive(true);
                        state.failed(&error);
                    }
                }
            }),
        );
    }
    fn write_capture(
        self: &Rc<Self>,
        close: Option<CloseMode>,
        capture: Capture,
        stamp: Option<WindowStamp>,
        lease: Arc<store::Lease>,
    ) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        self.status.set_text(ui.lang.text(
            "Sitzung wird lokal gesichert …",
            "Saving local recovery copy …",
        ));
        let consume = std::mem::take(&mut *self.consume.borrow_mut());
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                let session = capture.session()?;
                lease.write(&session)?;
                for archive in consume {
                    archive.lease.remove()?;
                }
                Ok(())
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.busy.set(false);
                let Some(ui) = state.ui.upgrade() else { return };
                if !ui.window.is_visible() {
                    state.pending_close.take();
                    state.closing.set(false);
                    return;
                }
                ui.window.set_sensitive(true);
                match result {
                    Ok(()) => {
                        *state.stamp.borrow_mut() = stamp.clone();
                        state.status.set_tooltip_text(None);
                        state.status.set_text(ui.lang.text(
                            "Texttabs lokal gesichert; Abschnitt/Hex ausgenommen. Wiederherstellung nur nach Freigabe.",
                            "Text tabs backed up; section/hex excluded. Restoration requires consent.",
                        ));
                        if close.is_some() {
                            if state.current_stamp() == stamp {
                                state.allow_close.set(true);
                                ui.window.close();
                            } else {
                                state.failed(ui.lang.text("Fensterinhalt während der Sicherung geändert; Schließen erneut wählen.","Window changed during recovery save; choose Close again."));
                            }
                        }
                    }
                    Err(error) => state.failed(&error),
                }
                if let Some(mode) = state.pending_close.take() {
                    state.flush(Some(mode));
                }
            },
        );
    }
    fn failed(&self, error: &str) {
        self.closing.set(false);
        *self.stamp.borrow_mut() = self.current_stamp();
        let Some(ui) = self.ui.upgrade() else { return };
        self.save_now.set_sensitive(true);
        self.save_now.set_label(if self.ready.get() {
            ui.lang.text("Jetzt sichern", "Back up now")
        } else {
            ui.lang.text("Erneut prüfen", "Retry")
        });
        let detail = if error.contains("Rich") {
            error
        } else if error.contains("4 MiB")
            || error.contains("8 MiB")
            || error.contains("32 documents")
            || error.contains("limit")
        {
            ui.lang.text("Sitzungsgrenze erreicht: 32 Texttabs, je 4 MiB Text/Original und 8 MiB Nutzdaten insgesamt. Eine vorhandene vorige Kopie bleibt erhalten.","Recovery limit reached: 32 text tabs, 4 MiB per text/original and 8 MiB total data. An existing previous copy is retained.")
        } else if error.contains("mode 0700") || error.contains("mode 0600") {
            ui.lang.text("Besitz und Rechte des privaten Zustandsordners prüfen: Ordner 0700, Dateien 0600.","Check ownership and permissions of the private state folder: directories 0700, files 0600.")
        } else if error.contains("Window changed") || error.contains("Fensterinhalt während") {
            error
        } else if error.contains("save still running") {
            ui.lang.text(
                "Dateispeicherung läuft noch. Die Sitzung wird anschließend erneut geprüft.",
                "File save still running. Session recovery will be checked again afterwards.",
            )
        } else if error.contains("schema")
            || error.contains("encoding")
            || error.contains("Invalid")
            || error.contains("unknown")
            || error.contains("missing field")
        {
            ui.lang.text("Sitzungsdaten ungültig oder inkompatibel. Bestehende Sicherungen bleiben zur Prüfung erhalten.","Session data invalid or incompatible. Existing backups are retained for inspection.")
        } else {
            ui.lang.text("Lokalen Zustandspfad und freien Speicher prüfen. Jetzt sichern wiederholt den Versuch; Deaktivieren erlaubt Schließen ohne neue Sitzungskopie.","Check the local state path and free space. Back up now retries; disabling permits closing without a new recovery copy.")
        };
        self.status.set_text(&format!(
            "{} {detail}",
            ui.lang.text(
                "Sitzung nicht vollständig gesichert. Editor bleibt offen.",
                "Session recovery incomplete. Editor remains open."
            )
        ));
        self.status.set_tooltip_text(Some(error));
    }
    pub(super) fn has_pending_index(&self) -> bool {
        self.journals_epoch.get() != self.journals_saved.get()
    }
    pub(super) fn is_enabled(&self) -> bool {
        self.enabled.is_active()
    }
    fn review(self: &Rc<Self>) {
        if self.closing.get() {
            return;
        }
        if self.ui.upgrade().is_none_or(|ui| !ui.window.is_visible()) {
            return;
        }
        if self.archives.borrow().is_empty() {
            return;
        }
        let Some(ui) = self.ui.upgrade() else { return };
        let window = support::window(
            &ui,
            ui.lang.text("Sitzung wiederherstellen", "Restore session"),
            true,
        );
        window.set_default_size(1000, 760);
        let root = support::column();
        root.append(&support::label(ui.lang.text("Gespeicherte Editorinhalte vollständig prüfen. Geänderte oder fehlende Quelldateien werden als ungesicherte Wiederherstellung geöffnet; ihre Speicherbasis wird nicht neu gebunden.","Review the complete saved editor contents. Changed or missing source files open as unsaved recovered documents; their save base is not rebound.")));
        let notebook = gtk::Notebook::new();
        notebook.set_scrollable(true);
        notebook.set_vexpand(true);
        let mut records = Vec::new();
        for archive in self.archives.borrow().iter() {
            for tab in archive.session.ordered() {
                if let store::Tab::ReadOnly(record) = tab {
                    let page = support::column();
                    let path = super::project_view::display(&store::source_path(&record.path));
                    let encoding = super::document_view::encoding_name(
                        store::encoding(record.encoding).unwrap(),
                    );
                    let information =
                        support::label(&format!("{} · {path} · {encoding}", record.name));
                    information.set_wrap_mode(gtk::pango::WrapMode::WordChar);
                    information.set_selectable(true);
                    page.append(&information);
                    page.append(&support::label(ui.lang.text(
                        "Schreibgeschützter Quelltext. Gespeichert sind nur Dateipfad und Kodierung. Beim Wiederherstellen wird der aktuelle Dateiinhalt erneut schreibgeschützt gelesen. Fehlende oder nicht lesbare Dateien bleiben in dieser Sicherung erhalten.",
                        "Read-only source text. Only the file path and encoding are saved. Restoration reads the current file contents again as read-only text. Missing or unreadable files remain in this backup.",
                    )));
                    let tab = gtk::Label::new(Some(&record.name));
                    tab.set_width_chars(12);
                    tab.set_max_width_chars(24);
                    tab.set_ellipsize(gtk::pango::EllipsizeMode::End);
                    tab.set_tooltip_text(Some(&record.name));
                    notebook.append_page(&page, Some(&tab));
                    records.push(RestoreEntry::ReadOnly(record.clone()));
                    continue;
                }
                let store::Tab::Editor(record) = tab else {
                    unreachable!()
                };
                let page = support::column();
                let path = record
                    .path
                    .as_deref()
                    .map(|p| super::project_view::display(&store::source_path(p)))
                    .unwrap_or_else(|| ui.lang.text("Ohne Dateipfad", "No file path").into());
                let encoding =
                    super::document_view::encoding_name(store::encoding(record.encoding).unwrap());
                let prefix =
                    store::unhex(&record.original_hex[..record.original_hex.len().min(8)]).unwrap();
                let bom = if fastra_core::encoding::detect_bom(&prefix).0.is_empty() {
                    ui.lang.text("ohne BOM", "no BOM")
                } else {
                    "BOM"
                };
                let metadata = format!(
                    "{} · {} · {} · {encoding} · {bom}",
                    record.name,
                    path,
                    if record.dirty {
                        ui.lang.text("ungesichert", "unsaved")
                    } else {
                        ui.lang
                            .text("gesicherter Editorstand", "saved editor version")
                    }
                );
                let information = support::label(&metadata);
                information.set_lines(2);
                information.set_wrap_mode(gtk::pango::WrapMode::WordChar);
                information.set_max_width_chars(64);
                information.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
                information.set_tooltip_text(Some(&metadata));
                page.append(&information);
                let text = support::output();
                text.buffer().set_text(&record.text);
                page.append(&support::scroll(&text));
                let tab = gtk::Label::new(Some(&super::project_view::display(
                    std::path::Path::new(&record.name),
                )));
                tab.set_width_chars(12);
                tab.set_max_width_chars(24);
                tab.set_ellipsize(gtk::pango::EllipsizeMode::End);
                tab.set_tooltip_text(Some(&record.name));
                notebook.append_page(&page, Some(&tab));
                records.push(RestoreEntry::Editor(record.clone()));
            }
        }
        root.append(&notebook);
        let consent = gtk::CheckButton::with_label(ui.lang.text(
            "Die gezeigten Dokumente als neue Tabs wiederherstellen",
            "Restore the displayed documents as new tabs",
        ));
        root.append(&consent);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let restore = gtk::Button::with_label(ui.lang.text("Wiederherstellen", "Restore"));
        restore.set_sensitive(false);
        let later = gtk::Button::with_label(ui.lang.text("Später", "Later"));
        let discard = gtk::Button::with_label(
            ui.lang
                .text("Diese Sicherungen löschen …", "Delete these backups …"),
        );
        for b in [&restore, &later, &discard] {
            row.append(b);
        }
        root.append(&row);
        let status = support::label("");
        status.set_lines(4);
        status.set_ellipsize(gtk::pango::EllipsizeMode::End);
        root.append(&status);
        window.set_child(Some(&root));
        let r = restore.clone();
        let started = Rc::new(Cell::new(false));
        let running = started.clone();
        consent.connect_toggled(move |c| r.set_sensitive(c.is_active() && !running.get()));
        let close = window.clone();
        later.connect_clicked(move |_| close.close());
        let (restored_active, width, height) = self
            .archives
            .borrow()
            .first()
            .map(|a| (a.session.active, a.session.width, a.session.height))
            .unwrap_or((0, 900, 800));
        let owner = ui.generation.get();
        let live = Rc::new(Cell::new(true));
        self.review_open.set(self.review_open.get() + 1);
        let weak_review = Rc::downgrade(self);
        let l = live.clone();
        let cancellation = fastra_core::Cancellation::default();
        let cancel_on_close = cancellation.clone();
        window.connect_close_request(move |_| {
            if l.replace(false) {
                cancel_on_close.cancel();
                if let Some(state) = weak_review.upgrade() {
                    state
                        .review_open
                        .set(state.review_open.get().saturating_sub(1));
                }
            }
            gtk::glib::Propagation::Proceed
        });
        let weak = Rc::downgrade(self);
        let close = window.clone();
        let current = live.clone();
        restore.connect_clicked(move |button| {
            let Some(state) = weak.upgrade() else { return };
            let Some(ui) = state.ui.upgrade() else { return };
            if !ui.window.is_visible() || !current.get() || ui.generation.get() != owner {
                status.set_text(ui.lang.text(
                    "Fenster geändert. Erneut prüfen.",
                    "Window changed. Review again.",
                ));
                return;
            }
            if started.replace(true) { return; }
            button.set_sensitive(false);
            let records = records.clone();
            let cancellation = cancellation.clone();
            let weak = Rc::downgrade(&state);
            let current = current.clone();
            let close = close.clone();
            let status = status.clone();
            support::background(
                move || restore_tabs(records, &cancellation),
                move |result| {
                    let Some(state) = weak.upgrade() else { return };
                    let Some(ui) = state.ui.upgrade() else { return };
                    if !ui.window.is_visible() || !current.get() || ui.generation.get() != owner {
                        status.set_text(ui.lang.text(
                            "Wiederherstellung veraltet; keine Tabs hinzugefügt.",
                            "Restoration stale; no tabs added.",
                        ));
                        return;
                    }
                    match result {
                        Ok(restored) => {
                            let mut selected = None;
                            let mut first = None;
                            let mut failures = Vec::new();
                            for (position, restored) in restored.into_iter().enumerate() {
                                let restored = match restored {
                                    RestoredTab::Editor(restored) => *restored,
                                    RestoredTab::ReadOnly(record, source) => {
                                        match source {
                                            Ok(source) => {
                                                let doc = super::readonly_source::append(&ui, &record.name, source);
                                                first.get_or_insert_with(|| doc.clone());
                                                if position == restored_active { selected = Some(doc); }
                                            }
                                            Err(error) => {
                                                let message = if matches!(error, fastra_document::Error::NotText) {
                                                    ui.lang.text("Keine vollständige Textansicht möglich: Binärdaten oder überlange Zeile.", "Full text view unavailable: binary data or an overlong line.").to_owned()
                                                } else { super::loader::document_error(ui.lang, &error) };
                                                failures.push(format!("{}: {message}", record.name));
                                            }
                                        }
                                        continue;
                                    }
                                };
                                let stale =
                                    restored.record.path.is_some() && restored.snapshot.is_none();
                                let name=restored.record.name.clone();
                                ui.add_document(&name, &restored.record.text);
                                let doc = ui.active().unwrap();
                                first.get_or_insert_with(|| doc.clone());
                                if position == restored_active { selected = Some(doc.clone()); }
                                doc.line_endings.restore(
                                    restored.record.saved_ending, restored.record.pending_ending,
                                    restored.decoded.text(),
                                );
                                *doc.original.borrow_mut() = restored.decoded.text().to_owned();
                                *doc.format.borrow_mut() = Arc::new(restored.decoded);
                                *doc.snapshot.borrow_mut() = restored.snapshot;
                                super::editor_options::restore(&ui, &doc);
                                doc.buffer.set_modified(restored.record.dirty || stale);
                                doc.reopen.set_sensitive(doc.snapshot.borrow().is_some());
                                let format=super::document_view::format_text(&doc.format.borrow(),&restored.record.text,ui.lang);
                                doc.format_label.set_text(&if stale{format!("{format} · {}",ui.lang.text("Wiederhergestellt ohne Dateibindung. Speichern benötigt ein neues Ziel.","Recovered without file binding. Saving requires a new target."))}else{format});
                                doc.update_label();
                                if stale {
                                    state.fallback.borrow_mut().insert(
                                        Rc::as_ptr(&doc) as usize,
                                        (Rc::downgrade(&doc), restored.record),
                                    );
                                } else if doc.snapshot.borrow().is_some() {
                                    *doc.watch.borrow_mut() = Some(super::watch::attach(&ui, &doc));
                                }
                            }
                            if let Some(doc) = selected.or(first) {
                                if let Some(page) = ui.documents.borrow().iter().position(|open| Rc::ptr_eq(open, &doc)) {
                                    ui.tabs.set_current_page(Some(page as u32));
                                }
                            }
                            ui.refresh_save();
                            let geometry = ui
                                .window
                                .surface()
                                .and_then(|surface| {
                                    gtk::prelude::WidgetExt::display(&ui.window)
                                        .monitor_at_surface(&surface)
                                })
                                .map(|m| m.geometry());
                            ui.window.set_default_size(
                                width.min(geometry.as_ref().map_or(4000, |g| g.width().max(760))),
                                height.min(geometry.as_ref().map_or(2400, |g| g.height().max(700))),
                            );
                            if failures.is_empty() && state.enabled.is_active() {
                                *state.consume.borrow_mut() =
                                    std::mem::take(&mut *state.archives.borrow_mut());
                                state.manage.set_sensitive(false);
                                state.stamp.borrow_mut().take();
                                state.flush(None);
                            }
                            if failures.is_empty() {
                                close.close();
                            } else {
                                let message = format!("{}\n{}", ui.lang.text(
                                    "Verfügbare Tabs wiederhergestellt. Einige Quellen konnten nicht geöffnet werden. Die ursprünglichen Sicherungen bleiben zur erneuten Prüfung erhalten.",
                                    "Available tabs restored. Some sources could not be opened. The original backups are retained for another review.",
                                ), failures.join("\n"));
                                status.set_text(&message);
                                status.set_tooltip_text(Some(&message));
                                state.status.set_text(ui.lang.text("Einige Quellen fehlen. Sicherungen zur erneuten Prüfung erhalten.", "Some sources are unavailable. Backups retained for another review."));
                            }
                        }
                        Err(error) => status.set_text(&format!(
                            "{}: {error}",
                            ui.lang
                                .text("Sitzung nicht wiederhergestellt", "Session not restored")
                        )),
                    }
                },
            );
        });
        let weak = Rc::downgrade(self);
        let close = window.clone();
        discard.connect_clicked(move |_| {
            if let Some(state) = weak.upgrade() {
                state.delete_archives(&close);
            }
        });
        #[cfg(debug_assertions)]
        if std::env::var_os("FASTRA_SESSION_SELFTEST").is_some() {
            support::test_size(&window);
        }
        window.present();
    }
    fn delete_archives(self: &Rc<Self>, parent: &gtk::Window) {
        let Some(ui) = self.ui.upgrade() else { return };
        let dialog=gtk::AlertDialog::builder()
            .message(ui.lang.text("Gezeigte lokale Sicherungen endgültig löschen?","Permanently delete the displayed local backups?"))
            .detail(ui.lang.text("Quelldateien und aktuelle Tabs bleiben erhalten. Ungesicherte Texte dieser Sicherungen gehen verloren.","Source files and current tabs are retained. Unsaved text in these backups will be lost."))
            .buttons([ui.lang.text("Abbrechen","Cancel"),ui.lang.text("Sicherungen löschen","Delete backups")])
            .cancel_button(0).default_button(0).build();
        let weak = Rc::downgrade(self);
        let close = parent.clone();
        dialog.choose(
            Some(parent),
            None::<&gtk::gio::Cancellable>,
            move |result| {
                if result != Ok(1) {
                    return;
                }
                let Some(state) = weak.upgrade() else { return };
                let archives = std::mem::take(&mut *state.archives.borrow_mut());
                let weak = Rc::downgrade(&state);
                let close = close.clone();
                support::background(
                    move || {
                        for archive in archives {
                            archive.lease.remove()?;
                        }
                        Ok(())
                    },
                    move |result| {
                        if let Some(state) = weak.upgrade() {
                            if let Err(error) = result {
                                state.failed(&error);
                            }
                            state.manage.set_sensitive(false);
                        }
                        close.close();
                    },
                );
            },
        );
    }
}
pub(super) fn changed(ui: &Ui) {
    if let Some(state) = ui.session.borrow().as_ref() {
        state.epoch.set(state.epoch.get().wrapping_add(1));
        state.stamp.borrow_mut().take();
    }
}

fn state_base() -> Result<PathBuf, String> {
    if let Some(base) = std::env::var_os("XDG_STATE_HOME") {
        let path = PathBuf::from(base);
        if path.is_absolute() {
            return Ok(path);
        }
        return Err("XDG_STATE_HOME must be absolute".into());
    }
    std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(".local/state"))
        .ok_or_else(|| "HOME missing".into())
}
pub(super) fn attach(ui: &Rc<Ui>) -> Rc<State> {
    let row = gtk::Box::new(gtk::Orientation::Vertical, 4);
    let options = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        // GTK 4.14 nutzt die ungebundene Höhe auch als Fenstergrenze.
        .min_children_per_line(4)
        .max_children_per_line(4)
        .column_spacing(8)
        .row_spacing(4)
        .build();
    let enabled =
        gtk::CheckButton::with_label(ui.lang.text("Texttabs lokal sichern", "Back up text tabs"));
    enabled.set_active(false);
    let manage = gtk::Button::with_label(ui.lang.text("Wiederherstellung …", "Restore backups …"));
    manage.set_sensitive(false);
    options.insert(&enabled, -1);
    options.insert(&manage, -1);
    let journal_button =
        gtk::Button::with_label(ui.lang.text("Dateitransaktionen …", "File transactions …"));
    journal_button.set_sensitive(false);
    options.insert(&journal_button, -1);
    let save_now = gtk::Button::with_label(ui.lang.text("Jetzt sichern", "Back up now"));
    options.insert(&save_now, -1);
    row.append(&options);
    row.append(&support::label(ui.lang.text("Aktivierung speichert auch ungesicherte Textinhalte lokal und unverschlüsselt (nur dieses Fenster).","Enabling stores unsaved text contents locally without encryption (this window only).")));
    let status = support::label(ui.lang.text(
        "Lokale Sitzungssicherung wird vorbereitet …",
        "Preparing local session recovery …",
    ));
    row.append(&status);
    super::chrome::settings(ui, &row);
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        status,
        journals: RefCell::new(Vec::new()),
        journals_epoch: Cell::new(0),
        journals_saved: Cell::new(0),
        index_closing: Cell::new(false),
        review_open: Cell::new(0),
        journal_button: journal_button.clone(),
        enabled: enabled.clone(),
        manage: manage.clone(),
        save_now: save_now.clone(),
        lease: RefCell::new(None),
        archives: RefCell::new(Vec::new()),
        busy: Cell::new(false),
        ready: Cell::new(false),
        epoch: Cell::new(0),
        allow_close: Cell::new(false),
        closing: Cell::new(false),
        close_dialog: Cell::new(false),
        pending_close: Cell::new(None),
        stamp: RefCell::new(None),
        fallback: RefCell::new(HashMap::new()),
        consume: RefCell::new(Vec::new()),
    });
    let weak = Rc::downgrade(&state);
    save_now.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            if state.closing.get() {
                return;
            }
            if !state.ready.get() {
                state.initialize();
            } else if state.has_pending_index() {
                state.flush_journals();
            } else if state.is_enabled() {
                state.flush(None);
            }
        }
    });
    let weak = Rc::downgrade(&state);
    manage.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.review();
        }
    });
    let weak = Rc::downgrade(&state);
    enabled.connect_toggled(move|button|{if let Some(state)=weak.upgrade(){
        state.epoch.set(state.epoch.get().wrapping_add(1));
        state.stamp.borrow_mut().take();state.save_now.set_sensitive(button.is_active()||!state.ready.get()||state.has_pending_index());
        if button.is_active(){state.tick();}else if let Some(ui)=state.ui.upgrade(){state.status.set_text(ui.lang.text("Textsicherung aus. Vorhandene und bereits gestartete Kopien bleiben bis zur ausdrücklichen Löschung erhalten.","Text backup off. Existing and already started copies remain until explicitly deleted."));}
    }});
    let weak = Rc::downgrade(&state);
    journal_button.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.review_journals();
        }
    });
    state.initialize();
    let weak = Rc::downgrade(&state);
    gtk::glib::timeout_add_local(std::time::Duration::from_secs(1), move || {
        let Some(state) = weak.upgrade() else {
            return gtk::glib::ControlFlow::Break;
        };
        if state.ui.upgrade().is_none_or(|ui| !ui.window.is_visible()) {
            return gtk::glib::ControlFlow::Break;
        }
        state.tick();
        gtk::glib::ControlFlow::Continue
    });
    state
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
mod journal_test;
#[cfg(debug_assertions)]
mod readonly_test;
#[cfg(debug_assertions)]
mod rich_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>, mode: &str) {
    assert_eq!(
        std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(),
        Ok("1"),
        "Session tests require a private display"
    );
    if mode.starts_with("readonly") {
        readonly_test::run(ui, mode);
    } else if mode.starts_with("journal-") {
        journal_test::run(ui, mode);
    } else if mode == "rich" || mode == "rich-failure" {
        rich_test::run(ui, mode == "rich-failure");
    } else {
        gui_test::run(ui, mode);
    }
}

/// Metadatenindex, keine Erfassung aktueller Editorinhalte.
pub(super) fn remember_journal(ui: &Rc<Ui>, path: PathBuf) -> Result<(), String> {
    let state = ui
        .session
        .borrow()
        .clone()
        .ok_or("Session index unavailable")?;
    state.remember_journal(path)
}
pub(super) fn forget_journal(ui: &Rc<Ui>, path: &std::path::Path) {
    if let Some(state) = ui.session.borrow().clone() {
        state.forget_journal(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::{ffi::OsStrExt, fs::MetadataExt};
    #[test]
    fn readonly_restore_reads_current_disk_without_promoting_capability_or_losing_drafts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reader.md");
        let alias = dir.path().join("alias.md");
        std::fs::write(&path, "old reader").unwrap();
        std::fs::hard_link(&path, &alias).unwrap();
        let reader = store::ReadOnlyRecord {
            name: "reader".into(),
            path: path.as_os_str().as_bytes().to_vec(),
            encoding: 0,
            position: 0,
        };
        // Der ursprüngliche Lesegrund entfällt; die Sitzungsreferenz erwirbt trotzdem keine Schreibbasis.
        std::fs::remove_file(alias).unwrap();
        std::fs::write(&path, "current reader").unwrap();
        let draft = Record {
            name: "draft".into(),
            path: None,
            device: None,
            inode: None,
            binding: None,
            original_hex: String::new(),
            encoding: 0,
            text: "unsaved draft".into(),
            saved_ending: None,
            pending_ending: None,
            dirty: true,
        };
        let plan = vec![
            RestoreEntry::ReadOnly(reader.clone()),
            RestoreEntry::Editor(draft),
        ];
        let cancel = fastra_core::Cancellation::default();
        let tabs = restore_tabs(plan.clone(), &cancel).unwrap();
        let RestoredTab::ReadOnly(_, Ok(source)) = &tabs[0] else {
            panic!("expected readonly capability")
        };
        assert_eq!(source.text(), "current reader");
        assert!(
            fastra_io::Snapshot::read(&path, &cancel).is_ok(),
            "file is now writable independently"
        );
        std::fs::remove_file(&path).unwrap();
        let tabs = restore_tabs(plan.clone(), &cancel).unwrap();
        assert!(matches!(&tabs[0], RestoredTab::ReadOnly(_, Err(_))));
        let RestoredTab::Editor(editor) = &tabs[1] else {
            panic!("draft lost")
        };
        assert_eq!(editor.record.text, "unsaved draft");
        assert!(editor.snapshot.is_none());
        for bytes in [b"binary\0body".to_vec(), vec![b'a'; 65537]] {
            std::fs::write(&path, bytes).unwrap();
            assert!(matches!(
                &restore_tabs(plan.clone(), &cancel).unwrap()[0],
                RestoredTab::ReadOnly(_, Err(_))
            ));
        }
        cancel.cancel();
        assert!(restore_tabs(plan, &cancel).is_err());
    }
    #[test]
    fn original_binding_and_bom_survive_foreign_source_changes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(std::ffi::OsStr::from_bytes(b"source-\xff"));
        let original = [
            b"\xff\xfe".as_slice(),
            &"base 😀é\r\n"
                .encode_utf16()
                .flat_map(u16::to_le_bytes)
                .collect::<Vec<_>>(),
        ]
        .concat();
        std::fs::write(&path, &original).unwrap();
        let meta = std::fs::metadata(&path).unwrap();
        let record = Record {
            name: "source".into(),
            path: Some(path.as_os_str().as_bytes().to_vec()),
            device: Some(meta.dev()),
            inode: Some(meta.ino()),
            binding: Some(store::hex(
                &fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default())
                    .unwrap()
                    .binding_digest()
                    .unwrap(),
            )),
            original_hex: store::hex(&original),
            encoding: 1,
            text: "dirty 😀é\r\n!".into(),
            saved_ending: None,
            pending_ending: None,
            dirty: true,
        };
        let restored = restore_records(vec![record.clone()]).unwrap();
        assert!(restored[0].snapshot.is_some());
        let mut legacy = record.clone();
        legacy.binding = None;
        assert!(restore_records(vec![legacy]).unwrap()[0].snapshot.is_none());
        assert_eq!(restored[0].decoded.bom(), b"\xff\xfe");
        std::fs::write(&path, "foreign").unwrap();
        let restored = restore_records(vec![record.clone()]).unwrap();
        assert!(restored[0].snapshot.is_none());
        assert_eq!(
            restored[0]
                .decoded
                .encode(restored[0].decoded.text())
                .unwrap(),
            original
        );
        assert_eq!(restored[0].record.text, "dirty 😀é\r\n!");
        let next = dir.path().join("replacement");
        std::fs::write(&next, &original).unwrap();
        std::fs::rename(next, &path).unwrap();
        assert!(
            restore_records(vec![record.clone()]).unwrap()[0]
                .snapshot
                .is_none(),
            "same bytes on a foreign inode must not rebind"
        );
        std::fs::remove_file(&path).unwrap();
        assert!(restore_records(vec![record]).unwrap()[0].snapshot.is_none());
    }
    #[test]
    fn metadata_and_parent_binding_never_silently_refresh_the_base() {
        use std::os::unix::fs::PermissionsExt;
        fn record(path: &std::path::Path) -> Record {
            let snapshot =
                fastra_io::Snapshot::read(path, &fastra_core::Cancellation::default()).unwrap();
            Record {
                name: "source".into(),
                path: Some(path.as_os_str().as_bytes().to_vec()),
                device: Some(snapshot.file_identity().device),
                inode: Some(snapshot.file_identity().inode),
                binding: Some(store::hex(&snapshot.binding_digest().unwrap())),
                original_hex: store::hex(snapshot.bytes()),
                encoding: 0,
                text: "edited".into(),
                saved_ending: None,
                pending_ending: None,
                dirty: true,
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("project");
        std::fs::create_dir(&root).unwrap();
        let path = root.join("source");
        std::fs::write(&path, b"same").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let original = record(&path);
        assert!(restore_records(vec![original.clone()]).unwrap()[0]
            .snapshot
            .is_some());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(restore_records(vec![original]).unwrap()[0]
            .snapshot
            .is_none());
        let original = record(&path);
        let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
        let times = [
            libc::timespec {
                tv_sec: 0,
                tv_nsec: libc::UTIME_OMIT,
            },
            libc::timespec {
                tv_sec: 1577836800,
                tv_nsec: 123456789,
            },
        ];
        assert_eq!(
            unsafe { libc::utimensat(libc::AT_FDCWD, c.as_ptr(), times.as_ptr(), 0) },
            0
        );
        assert!(restore_records(vec![original]).unwrap()[0]
            .snapshot
            .is_none());
        let original = record(&path);
        let key = std::ffi::CString::new("user.fastra-session-test").unwrap();
        assert_eq!(
            unsafe { libc::setxattr(c.as_ptr(), key.as_ptr(), b"metadata".as_ptr().cast(), 8, 0) },
            0
        );
        assert!(restore_records(vec![original]).unwrap()[0]
            .snapshot
            .is_none());
        let original = record(&path);
        std::fs::rename(&root, dir.path().join("moved")).unwrap();
        std::fs::create_dir(&root).unwrap();
        std::fs::rename(dir.path().join("moved/source"), &path).unwrap();
        assert!(restore_records(vec![original]).unwrap()[0]
            .snapshot
            .is_none());
    }
}
