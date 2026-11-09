use super::{document_view::DocumentView, git_view as support, Document, Language, Ui};
use fastra_core::Cancellation;
use fastra_document::SectionDocument;
use fastra_io::Snapshot;
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::{Rc, Weak},
    sync::Arc,
};
mod model;
const MAX_SOURCE: usize = 32 * 1024 * 1024;

fn verify_basis(
    section: &SectionDocument,
    snapshot: &Snapshot,
) -> Result<(), fastra_document::Error> {
    let identity = snapshot.file_identity();
    if snapshot.bytes().len() as u64 != section.identity().size()
        || identity.device != section.identity().device()
        || identity.inode != section.identity().inode()
        || snapshot.path() != section.path()
    {
        return Err(fastra_document::Error::Stale);
    }
    Ok(())
}

struct Plan {
    epoch: u64,
    revision: u64,
    snapshot: Snapshot,
    bytes: Vec<u8>,
}
struct Loaded {
    snapshot: Snapshot,
    section: SectionDocument,
    session: model::Session,
    recovery_missing: bool,
}
pub(super) struct Editor {
    ui: Weak<Ui>,
    doc: Weak<Document>,
    window: gtk::Window,
    path: PathBuf,
    initial: SectionDocument,
    snapshot: RefCell<Option<Snapshot>>,
    session: RefCell<Option<model::Session>>,
    pending: RefCell<Option<Arc<Plan>>>,
    epoch: Cell<u64>,
    busy: Cell<bool>,
    saving: Cell<bool>,
    setting: Cell<bool>,
    recovery: RefCell<Option<PathBuf>>,
    cancel: RefCell<Cancellation>,
    row_offset: Cell<usize>,
    page_start: Cell<usize>,
    content: gtk::Box,
    navigation: gtk::Box,
    row_commands: [gtk::Button; 2],
    row: gtk::Entry,
    offset: gtk::Entry,
    row_label: gtk::Label,
    page: gtk::TextView,
    preview: gtk::TextView,
    path_label: gtk::Label,
    status: gtk::Label,
    consent: gtk::CheckButton,
    prepare: gtk::Button,
    save: gtk::Button,
    undo: gtk::Button,
    redo: gtk::Button,
    previous: gtk::Button,
    next: gtk::Button,
    cancel_button: gtk::Button,
    recover: gtk::Button,
}
impl Editor {
    fn language(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |ui| ui.lang)
    }
    fn alive(&self) -> bool {
        let (Some(ui), Some(doc)) = (self.ui.upgrade(), self.doc.upgrade()) else {
            return false;
        };
        let alive = ui
            .documents
            .borrow()
            .iter()
            .any(|item| Rc::ptr_eq(item, &doc));
        alive
    }
    fn unsubmitted(&self) -> bool {
        match self
            .session
            .borrow()
            .as_ref()
            .and_then(|s| s.row(self.row_offset.get()).ok())
        {
            Some(expected) => self.row.text().as_str() != expected,
            None => !self.row.text().is_empty(),
        }
    }
    pub(super) fn dirty(&self) -> bool {
        self.unsubmitted()
            || self
                .session
                .borrow()
                .as_ref()
                .is_some_and(model::Session::dirty)
    }
    pub(super) fn path(&self) -> PathBuf {
        self.snapshot
            .borrow()
            .as_ref()
            .map_or_else(|| self.path.clone(), Snapshot::path)
    }
    pub(super) fn pending(&self) -> bool {self.busy.get() || self.saving.get()}
    pub(super) fn can_print(&self) -> bool {
        !self.saving.get() && !self.unsubmitted()
    }
    pub(super) fn can_request_save(&self) -> bool {
        self.dirty() && !self.busy.get() && self.recovery.borrow().is_none()
    }
    pub(super) fn command_save(self: &Rc<Self>) {
        self.window.present();
        if self.pending.borrow().is_some() && self.consent.is_active() {
            self.save();
        } else {
            self.prepare();
        }
    }
    fn controls(&self) {
        let ready = self.session.borrow().is_some();
        let busy = self.busy.get();
        self.content.set_sensitive(!busy);
        self.navigation.set_sensitive(!busy && ready);
        let editable = !busy
            && self
                .session
                .borrow()
                .as_ref()
                .is_some_and(|s| !s.source().is_empty());
        self.row.set_sensitive(editable);
        for button in &self.row_commands {
            button.set_sensitive(editable);
        }
        self.undo.set_sensitive(
            !busy
                && self
                    .session
                    .borrow()
                    .as_ref()
                    .is_some_and(model::Session::can_undo),
        );
        self.redo.set_sensitive(
            !busy
                && self
                    .session
                    .borrow()
                    .as_ref()
                    .is_some_and(model::Session::can_redo),
        );
        self.prepare.set_sensitive(
            !busy
                && ready
                && self
                    .session
                    .borrow()
                    .as_ref()
                    .is_some_and(model::Session::dirty)
                && self.recovery.borrow().is_none(),
        );
        self.consent
            .set_sensitive(!busy && self.pending.borrow().is_some());
        self.save.set_sensitive(
            !busy
                && self.pending.borrow().is_some()
                && self.consent.is_active()
                && self.recovery.borrow().is_none(),
        );
        self.cancel_button.set_sensitive(busy && !self.saving.get());
        self.recover.set_visible(self.recovery.borrow().is_some());
        self.previous
            .set_sensitive(!busy && self.page_start.get() > 0);
        self.next.set_sensitive(
            !busy
                && self
                    .session
                    .borrow()
                    .as_ref()
                    .is_some_and(|s| self.page_start.get() + 4096 < s.source().len()),
        );
    }
    fn invalidate(&self) {
        if self.saving.get() {
            return;
        }
        self.cancel.borrow().cancel();
        self.epoch.set(self.epoch.get().wrapping_add(1));
        self.pending.borrow_mut().take();
        self.consent.set_active(false);
        self.preview.buffer().set_text("");
        self.controls();
    }
    fn update_document(&self, committed: bool) {
        if let Some(doc) = self.doc.upgrade() {
            if committed {
                doc.revision.set(doc.revision.get().wrapping_add(1));
                let changes = self
                    .session
                    .borrow()
                    .as_ref()
                    .map(model::Session::changes)
                    .unwrap_or_default();
                if let Some(view) = doc.section_view.borrow().as_ref() {
                    view.set_hex_overlay(
                        changes.iter().map(|c| (c.offset, c.old, c.new)).collect(),
                    );
                }
            }
            doc.update_label();
        }
        if let Some(ui) = self.ui.upgrade() {
            ui.refresh_save();
        }
    }
    fn show_row(&self) {
        let session = self.session.borrow();
        let Some(session) = session.as_ref() else {
            return;
        };
        self.setting.set(true);
        self.row
            .set_text(&session.row(self.row_offset.get()).unwrap_or_default());
        self.offset.set_text(&self.row_offset.get().to_string());
        self.setting.set(false);
        self.row_label.set_text(&format!(
            "0x{:012X} · {} {}",
            self.row_offset.get(),
            (session.source().len().saturating_sub(self.row_offset.get())).min(16),
            self.language().text("Bytes", "bytes")
        ));
        self.row.set_sensitive(!session.source().is_empty());
        self.update_page();
    }
    fn update_page(&self) {
        let Some(page) = self
            .session
            .borrow()
            .as_ref()
            .and_then(|s| s.page(self.page_start.get(), 4096).ok())
        else {
            return;
        };
        let mut text = String::new();
        for (row, bytes) in page.chunks(16).enumerate() {
            text.push_str(&format!("{:012X}  ", self.page_start.get() + row * 16));
            for byte in bytes {
                text.push_str(&format!("{byte:02X} "));
            }
            text.push('\n');
        }
        self.page.buffer().set_text(&text);
        self.controls();
    }
    fn edit_row(&self) {
        if self.busy.get() {
            return;
        }
        let result = self
            .session
            .borrow_mut()
            .as_mut()
            .map(|s| s.edit_row(self.row_offset.get(), self.row.text().as_str()));
        match result {
            Some(Ok(changed)) => {
                self.invalidate();
                self.show_row();
                self.update_document(changed);
                self.status.set_text(self.language().text("Hexzeile im Entwurf vorgemerkt. Datei unverändert; vor dem Speichern alle Änderungen prüfen.", "Hex row staged in the draft. File unchanged; review every change before saving."));
            }
            Some(Err(error)) => self.status.set_text(&format!("{} ({error:?})",self.language().text("Zeile nicht vorgemerkt. Je Byte genau einen zweistelligen Hexwert eingeben; höchstens 4096 geänderte Bytes und 4096 Undo-Schritte.", "Row not staged. Enter one two-character hexadecimal value per byte; at most 4096 changed bytes and 4096 undo actions."))),
            None => (),
        }
        self.controls();
    }
    fn history(&self, redo: bool) {
        if self.busy.get() {
            return;
        }
        if self.unsubmitted() {
            self.status.set_text(self.language().text(
                "Die Feldeingabe zuerst vormerken oder zurücksetzen.",
                "Stage or reset the field input first.",
            ));
            return;
        }
        let changed =
            self.session
                .borrow_mut()
                .as_mut()
                .is_some_and(|s| if redo { s.redo() } else { s.undo() });
        if changed {
            self.invalidate();
            self.show_row();
            self.update_document(true);
        }
    }
    fn navigate(&self, offset: usize) {
        if self.busy.get() {
            return;
        }
        if self.unsubmitted() {
            self.status.set_text(self.language().text(
                "Die Feldeingabe zuerst vormerken oder zurücksetzen.",
                "Stage or reset the field input first.",
            ));
            return;
        }
        let size = self
            .session
            .borrow()
            .as_ref()
            .map_or(0, |s| s.source().len());
        if offset >= size && size != 0 {
            self.status.set_text(self.language().text(
                "Byteoffset liegt außerhalb der Datei.",
                "Byte offset lies outside the file.",
            ));
            return;
        }
        self.row_offset.set(offset / 16 * 16);
        self.page_start.set(offset / 4096 * 4096);
        self.show_row();
    }
    fn replace_view(self: &Rc<Self>, section: SectionDocument) {
        let (Some(ui), Some(doc)) = (self.ui.upgrade(), self.doc.upgrade()) else {
            return;
        };
        while let Some(child) = doc.container.first_child() {
            doc.container.remove(&child);
        }
        let path = section.path().to_path_buf();
        let weak = Rc::downgrade(&ui);
        let reopen: Rc<dyn Fn()> = Rc::new(move || {
            if let Some(ui) = weak.upgrade() {
                ui.load_path(path.clone());
            }
        });
        let view = DocumentView::new(section, true, ui.lang, reopen);
        doc.container.append(&view.root);
        *doc.section_view.borrow_mut() = Some(view.clone());
        install(&ui, &doc, &view);
    }
    fn load(self: &Rc<Self>, initial: bool) {
        if self.saving.get() {
            return;
        }
        self.invalidate();
        self.busy.set(true);
        self.controls();
        self.status.set_text(self.language().text(
            "Dateibasis wird vollständig und begrenzt gelesen …",
            "Reading the complete bounded file basis …",
        ));
        let epoch = self.epoch.get();
        let path = self.path();
        let expected = initial.then(|| self.initial.clone());
        let recovery = self.recovery.borrow().clone();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                let result = (|| {
                    if let Some(expected) = expected.as_ref() {
                        expected.verify_current(&cancel)?;
                    }
                    let section = fastra_document::Document::open_hex(&path, &cancel)?;
                    if section.identity().size() > MAX_SOURCE as u64 {
                        return Err(fastra_document::Error::Limit);
                    }
                    let snapshot = Snapshot::read_bounded(section.path(), MAX_SOURCE, &cancel)
                        .map_err(fastra_document::Error::Snapshot)?;
                    // Die beiden getrennten Leser müssen dieselbe Datei halten, auch nach Eltern-ABA.
                    verify_basis(&section, &snapshot)?;
                    section.verify_current(&cancel)?;
                    if let Some(expected) = expected.as_ref() {
                        verify_basis(expected, &snapshot)?;
                        expected.verify_current(&cancel)?;
                    }
                    let session = model::Session::new(Arc::from(snapshot.bytes()))
                        .map_err(|_| fastra_document::Error::Limit)?;
                    let recovery_missing = recovery.as_ref().is_none_or(|path| matches!(std::fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound));
                    Ok(Loaded {
                        snapshot,
                        section,
                        session,
                        recovery_missing,
                    })
                })();
                result.map_err(|e: fastra_document::Error| e.to_string())
            },
            move |result| {
                let Some(state) = weak
                    .upgrade()
                    .filter(|s| s.alive() && s.epoch.get() == epoch)
                else {
                    return;
                };
                state.busy.set(false);
                match result {
                    Ok(loaded) => {
                        state.epoch.set(state.epoch.get().wrapping_add(1));
                        state
                            .path_label
                            .set_text(&super::project_view::display(&loaded.snapshot.path()));
                        if loaded.recovery_missing {
                            state.recovery.borrow_mut().take();
                        }
                        *state.snapshot.borrow_mut() = Some(loaded.snapshot);
                        *state.session.borrow_mut() = Some(loaded.session);
                        state.row_offset.set(0);
                        state.page_start.set(0);
                        if !initial {
                            state.replace_view(loaded.section);
                        }
                        state.show_row();
                        state.update_document(false);
                        state.status.set_text(state.language().text("Dateibasis geladen. Zeilenänderungen bleiben bis zur vollständigen Freigabe nur im Entwurf.","File basis loaded. Row edits remain draft-only until complete approval."));
                    }
                    Err(error) => state.status.set_text(&format!(
                        "{}: {error}",
                        state.language().text(
                            "Dateibasis nicht geladen; Entwurf und Datei erhalten",
                            "File basis not loaded; draft and file retained"
                        )
                    )),
                }
                state.controls();
            },
        );
    }
    fn prepare(self: &Rc<Self>) {
        if self.busy.get() || !self.alive() || self.recovery.borrow().is_some() {
            return;
        }
        if self.unsubmitted() {
            self.status.set_text(self.language().text(
                "Die Feldeingabe zuerst vormerken oder zurücksetzen.",
                "Stage or reset the field input first.",
            ));
            return;
        }
        self.invalidate();
        let Some(snapshot) = self.snapshot.borrow().clone() else {
            return;
        };
        let frozen = {
            let session = self.session.borrow();
            let Some(session) = session.as_ref().filter(|s| s.dirty()) else {
                return;
            };
            match session.frozen(session.revision()) {
                Ok(frozen) => frozen,
                Err(_) => return,
            }
        };
        let epoch = self.epoch.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy.set(true);
        self.controls();
        let weak = Rc::downgrade(self);
        let lang = self.language();
        support::background(
            move || {
                cancel.check().map_err(|e| e.to_string())?;
                let current = Snapshot::read_bounded(&snapshot.path(), MAX_SOURCE, &cancel)
                    .map_err(|e| e.to_string())?;
                if current.binding_digest().map_err(|e| e.to_string())?
                    != snapshot.binding_digest().map_err(|e| e.to_string())?
                {
                    return Err("Stale file basis".into());
                }
                drop(current);
                let bytes = frozen.output().map_err(|e| format!("{e:?}"))?;
                cancel.check().map_err(|e| e.to_string())?;
                let mut text = format!(
                    "{}\n{}\n{}\n\n{}     {} → {}\n",
                    lang.text("Vollständige Hexänderungen", "Complete hex changes"),
                    super::project_view::display(&snapshot.path()),
                    lang.text(
                        "Dateilänge bleibt erhalten. Nur die aufgeführten Bytes werden geändert.",
                        "File length is preserved. Only listed bytes change."
                    ),
                    lang.text("Byteoffset", "Byte offset"),
                    lang.text("Alt", "Old"),
                    lang.text("Neu", "New")
                );
                for change in frozen.changes() {
                    cancel.check().map_err(|e| e.to_string())?;
                    text.push_str(&format!(
                        "{:012X}     {:02X} → {:02X}\n",
                        change.offset, change.old, change.new
                    ));
                }
                Ok((
                    Arc::new(Plan {
                        epoch,
                        revision: frozen.revision(),
                        snapshot,
                        bytes,
                    }),
                    text,
                ))
            },
            move |result| {
                let Some(state) = weak
                    .upgrade()
                    .filter(|s| s.alive() && s.epoch.get() == epoch)
                else {
                    return;
                };
                state.busy.set(false);
                match result {
                    Ok((plan, text)) => {
                        state.preview.buffer().set_text(&text);
                        *state.pending.borrow_mut() = Some(plan);
                        state.status.set_text(lang.text("Alle geänderten Bytes prüfen und ausdrücklich freigeben. Datei noch unverändert.","Review every changed byte and approve explicitly. File is still unchanged."));
                    }
                    Err(error) => state.status.set_text(&format!(
                        "{}: {error}",
                        lang.text(
                            "Keine freigabefähige Hexvorschau",
                            "No approvable hex preview"
                        )
                    )),
                }
                state.controls();
            },
        );
    }
    fn conflicts(&self, ui: &Ui) -> bool {
        let path = self.path();
        let own = self.doc.upgrade();
        ui.documents.borrow().iter().any(|doc| {
            if own.as_ref().is_some_and(|own| Rc::ptr_eq(own, doc)) {
                return false;
            }
            let text = doc
                .snapshot
                .borrow()
                .as_ref()
                .is_some_and(|s| s.path() == path)
                && (doc.buffer.is_modified() || doc.saving.get() || doc.is_rich_active());
            let hex = doc.hex_editor.borrow().as_ref().is_some_and(|editor| {
                editor.path() == path && (editor.dirty() || editor.saving.get())
            });
            text || hex
        })
    }
    fn save(self: &Rc<Self>) {
        if self.busy.get() || !self.alive() || !self.consent.is_active() || self.unsubmitted() {
            return;
        }
        let Some(ui) = self.ui.upgrade() else { return };
        if !super::git_pull::write_allowed(&ui) {self.status.set_text(&ui.status.text());return;}
        let Some(doc) = self.doc.upgrade() else {
            return;
        };
        if self.conflicts(&ui) {
            self.status.set_text(self.language().text(
                "Betroffene andere Tabs zuerst speichern oder deren Hexentwurf verwerfen.",
                "Save other affected tabs or discard their hex drafts first.",
            ));
            return;
        }
        let Some(plan) = self.pending.borrow_mut().take() else {
            return;
        };
        if plan.epoch != self.epoch.get()
            || self
                .session
                .borrow()
                .as_ref()
                .is_none_or(|s| s.revision() != plan.revision)
        {
            self.invalidate();
            return;
        }
        self.saving.set(true);
        self.busy.set(true);
        doc.saving.set(true);
        ui.refresh_save();
        self.controls();
        self.status.set_text(self.language().text(
            "Freigegebene Bytes werden atomar gespeichert …",
            "Saving approved bytes atomically …",
        ));
        let epoch = self.epoch.get();
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                let cancel = Cancellation::default();
                let saved = (|| {
                    let session = model::Session::new(Arc::from(plan.bytes.as_slice()))
                        .map_err(|_| fastra_io::Error::Limit)?;
                    let (snapshot, section) = if let Some(transaction) =
                        fastra_io::Transaction::save_document(
                            plan.snapshot.clone(),
                            &plan.bytes,
                            &cancel,
                        )? {
                        super::loader::finish_saved_document(transaction, &cancel, |snapshot| {
                            if snapshot.bytes() != plan.bytes {
                                return Err(fastra_io::Error::Stale);
                            }
                            let section =
                                fastra_document::Document::open_hex(&snapshot.path(), &cancel)
                                    .map_err(|error| {
                                        fastra_io::Error::Io(std::io::Error::other(
                                            error.to_string(),
                                        ))
                                    })?;
                            if section.identity().device() != snapshot.file_identity().device
                                || section.identity().inode() != snapshot.file_identity().inode
                            {
                                return Err(fastra_io::Error::Stale);
                            }
                            Ok(section)
                        })?
                    } else {
                        let section =
                            fastra_document::Document::open_hex(&plan.snapshot.path(), &cancel)
                                .map_err(|e| {
                                    fastra_io::Error::Io(std::io::Error::other(e.to_string()))
                                })?;
                        (plan.snapshot.clone(), section)
                    };
                    Ok(Loaded {
                        snapshot,
                        section,
                        session,
                        recovery_missing: true,
                    })
                })();
                // Typisierte Dateifehler bleiben bis zur UI erhalten, damit RecoveryRequired indiziert wird.
                Ok(saved)
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.saving.set(false);
                state.busy.set(false);
                if let Some(doc) = state.doc.upgrade() {
                    doc.saving.set(false);
                }
                if let Some(ui) = state.ui.upgrade() {
                    ui.refresh_save();
                }
                if !state.alive() || state.epoch.get() != epoch {
                    return;
                }
                let result = result.unwrap_or_else(|message| {
                    Err(fastra_io::Error::Io(std::io::Error::other(message)))
                });
                match result {
                    Ok(loaded) => {
                        if let Some(ui) = state.ui.upgrade() {
                            ui.refresh_clean_documents(vec![loaded.snapshot.clone()]);
                        }
                        state.epoch.set(state.epoch.get().wrapping_add(1));
                        *state.snapshot.borrow_mut() = Some(loaded.snapshot);
                        *state.session.borrow_mut() = Some(loaded.session);
                        state.consent.set_active(false);
                        state.preview.buffer().set_text("");
                        state.replace_view(loaded.section);
                        state.show_row();
                        state.update_document(true);
                        state.status.set_text(state.language().text("Hexänderungen sicher gespeichert. Entwurfs-Undo beginnt mit der neuen Dateibasis neu.","Hex changes saved safely. Draft undo restarts with the new file basis."));
                    }
                    Err(error) => {
                        if let fastra_io::Error::RecoveryRequired(path) = &error {
                            *state.recovery.borrow_mut() = Some(path.clone());
                            if let Some(ui) = state.ui.upgrade() {
                                if let Err(index_error) =
                                    super::session::remember_journal(&ui, path.clone())
                                {
                                    ui.status.set_text(&index_error);
                                }
                            }
                        }
                        state.consent.set_active(false);
                        state
                            .status
                            .set_text(&super::io_error_text(state.language(), &error));
                    }
                }
                state.controls();
                state.update_document(false);
            },
        );
    }
    fn discard_reload(self: &Rc<Self>) {
        if self.saving.get() {
            return;
        }
        let weak = Rc::downgrade(self);
        if !self.dirty() {
            self.load(false);
            return;
        }
        let epoch = self.epoch.get();
        let dialog = gtk::AlertDialog::builder()
            .message(self.language().text("Hexentwurf verwerfen und Datei neu laden?", "Discard the hex draft and reload the file?"))
            .detail(self.language().text("Alle vorgemerkten Byteänderungen und die aktuelle Feldeingabe gehen verloren. Die Datei wird nicht geändert.", "All staged byte changes and current field input will be lost. The file will not be changed."))
            .buttons([self.language().text("Behalten", "Keep"), self.language().text("Verwerfen und neu laden", "Discard and reload")])
            .cancel_button(0).default_button(0).build();
        dialog.choose(
            Some(&self.window),
            None::<&gtk::gio::Cancellable>,
            move |response| {
                if matches!(response, Ok(1)) {
                    if let Some(state) = weak
                        .upgrade()
                        .filter(|s| s.alive() && !s.busy.get() && s.epoch.get() == epoch)
                    {
                        state.session.borrow_mut().take();
                        state.snapshot.borrow_mut().take();
                        state.row.set_text("");
                        state.update_document(true);
                        state.load(false);
                    }
                }
            },
        );
    }
}
pub(super) fn install(ui: &Rc<Ui>, doc: &Rc<Document>, view: &Rc<DocumentView>) {
    let source = view.source();
    let button = gtk::Button::with_label(ui.lang.text("Hex bearbeiten …", "Edit hex …"));
    button.set_sensitive(source.identity().size() <= MAX_SOURCE as u64);
    button.set_tooltip_text(Some(ui.lang.text("Optionaler Hexentwurf bis 32 MiB. Bytes werden erst nach vollständiger Vorschau und Freigabe gespeichert.","Optional hex draft up to 32 MiB. Bytes are saved only after complete preview and approval.")));
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    button.connect_clicked(move |_| {
        if let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) {
            open(&ui, &doc, source.clone());
        }
    });
    view.add_action(&button);
}
pub(super) fn open(ui: &Rc<Ui>, doc: &Rc<Document>, source: SectionDocument) -> Rc<Editor> {
    if let Some(editor) = doc.hex_editor.borrow().as_ref() {
        editor.window.present();
        return editor.clone();
    }
    let lang = ui.lang;
    let window = support::window(
        ui,
        lang.text("Hex bearbeiten · Entwurf", "Edit hex · draft"),
        false,
    );
    window.set_default_size(1000, 850);
    let root = support::column();
    let path_label = support::label(&super::project_view::display(source.path()));
    path_label.set_selectable(true);
    path_label.set_wrap(false);
    path_label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    path_label.set_max_width_chars(100);
    path_label.set_tooltip_text(Some(&super::project_view::display(source.path())));
    root.append(&path_label);
    root.append(&support::label(lang.text("16 Bytes je Zeile, feste Dateilänge. Vormerken ändert nur den Entwurf. Vor dem Speichern zeigt die Vorschau alle geänderten Byteoffsets und Alt-/Neuwerte. Grenzen: 32 MiB, 4096 geänderte Bytes, 4096 Undo-Schritte.","16 bytes per row, fixed file length. Staging only changes the draft. Before saving, the preview shows every changed byte offset and old/new value. Limits: 32 MiB, 4096 changed bytes, 4096 undo actions.")));
    let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let navigation = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let offset = gtk::Entry::builder()
        .placeholder_text(lang.text(
            "Byteoffset: dezimal oder 0x…",
            "Byte offset: decimal or 0x…",
        ))
        .hexpand(true)
        .build();
    let go = gtk::Button::with_label(lang.text("Zeile anzeigen", "Show row"));
    let previous = gtk::Button::with_label(lang.text("Vorige Seite", "Previous page"));
    let next = gtk::Button::with_label(lang.text("Nächste Seite", "Next page"));
    for widget in [
        offset.upcast_ref::<gtk::Widget>(),
        go.upcast_ref(),
        previous.upcast_ref(),
        next.upcast_ref(),
    ] {
        navigation.append(widget)
    }
    content.append(&navigation);
    let row_label = support::label("");
    content.append(&row_label);
    let row = gtk::Entry::builder().hexpand(true).max_length(4096).build();
    row.add_css_class("monospace");
    content.append(&row);
    let actions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(2)
        .max_children_per_line(5)
        .column_spacing(8)
        .row_spacing(6)
        .build();
    let stage = gtk::Button::with_label(lang.text("Zeile vormerken", "Stage row"));
    let reset = gtk::Button::with_label(lang.text("Feldeingabe zurücksetzen", "Reset field input"));
    let undo = gtk::Button::with_label(lang.text("Entwurf rückgängig", "Undo draft"));
    let redo = gtk::Button::with_label(lang.text("Entwurf wiederholen", "Redo draft"));
    let reload =
        gtk::Button::with_label(lang.text("Verwerfen / neu laden …", "Discard / reload …"));
    for button in [&stage, &reset, &undo, &redo, &reload] {
        actions.insert(button, -1);
    }
    content.append(&actions);
    let page = support::output();
    let preview = support::output();
    let panes = gtk::Paned::new(gtk::Orientation::Vertical);
    panes.set_start_child(Some(&support::scroll(&page)));
    panes.set_end_child(Some(&support::scroll(&preview)));
    panes.set_position(240);
    panes.set_vexpand(true);
    content.append(&panes);
    root.append(&content);
    let bottom = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(2)
        .max_children_per_line(4)
        .column_spacing(8)
        .row_spacing(6)
        .build();
    let prepare =
        gtk::Button::with_label(lang.text("Alle Hexänderungen prüfen", "Review all hex changes"));
    let save =
        gtk::Button::with_label(lang.text("Freigegebene Bytes speichern", "Save approved bytes"));
    let cancel_button =
        gtk::Button::with_label(lang.text("Berechnung abbrechen", "Cancel calculation"));
    let recover =
        gtk::Button::with_label(lang.text("Dateisicherung prüfen …", "Review file recovery …"));
    for button in [&prepare, &save, &cancel_button, &recover] {
        bottom.insert(button, -1);
    }
    let consent = gtk::CheckButton::with_label(lang.text(
        "Ich habe alle geänderten Bytes und den Zieldateipfad geprüft.",
        "I reviewed every changed byte and the target file path.",
    ));
    root.append(&consent);
    root.append(&bottom);
    let status = support::label("");
    let status_scroll = gtk::ScrolledWindow::builder()
        .child(&status)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .min_content_height(24)
        .max_content_height(100)
        .propagate_natural_height(true)
        .build();
    root.append(&status_scroll);
    window.set_child(Some(&root));
    let state = Rc::new(Editor {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(doc),
        window: window.clone(),
        path: source.path().to_path_buf(),
        initial: source,
        snapshot: RefCell::new(None),
        session: RefCell::new(None),
        pending: RefCell::new(None),
        epoch: Cell::new(0),
        busy: Cell::new(false),
        saving: Cell::new(false),
        setting: Cell::new(false),
        recovery: RefCell::new(None),
        cancel: RefCell::new(Cancellation::default()),
        row_offset: Cell::new(0),
        page_start: Cell::new(0),
        content,
        navigation,
        row_commands: [stage.clone(), reset.clone()],
        row,
        offset,
        row_label,
        page,
        preview,
        path_label,
        status,
        consent,
        prepare,
        save,
        undo,
        redo,
        previous,
        next,
        cancel_button,
        recover,
    });
    let weak = Rc::downgrade(&state);
    state.row.connect_changed(move |_| {
        if let Some(state) = weak.upgrade() {
            if !state.setting.get() && !state.busy.get() {
                state.invalidate();
                state.update_document(false);
            }
        }
    });
    let weak = Rc::downgrade(&state);
    stage.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.edit_row();
        }
    });
    let weak = Rc::downgrade(&state);
    reset.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            if !state.busy.get() {
                state.invalidate();
                state.show_row();
                state.update_document(false);
            }
        }
    });
    for (redo, button) in [(false, &state.undo), (true, &state.redo)] {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(state) = weak.upgrade() {
                state.history(redo);
            }
        });
    }
    let weak = Rc::downgrade(&state);
    reload.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.discard_reload();
        }
    });
    let weak = Rc::downgrade(&state);
    state.prepare.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.prepare();
        }
    });
    let weak = Rc::downgrade(&state);
    state.save.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.save();
        }
    });
    let weak = Rc::downgrade(&state);
    state.consent.connect_toggled(move |_| {
        if let Some(state) = weak.upgrade() {
            state.controls();
        }
    });
    let weak = Rc::downgrade(&state);
    go.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            let text = state.offset.text();
            let text = text.trim();
            let parsed = if let Some(hex) = text.strip_prefix("0x") {
                usize::from_str_radix(hex, 16)
            } else {
                text.parse()
            };
            match parsed {
                Ok(offset) => state.navigate(offset),
                Err(_) => state.status.set_text(state.language().text(
                    "Bitte einen gültigen Byteoffset eingeben.",
                    "Enter a valid byte offset.",
                )),
            }
        }
    });
    for (next, button) in [(false, &state.previous), (true, &state.next)] {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(state) = weak.upgrade() {
                state.navigate(if next {
                    state.page_start.get() + 4096
                } else {
                    state.page_start.get().saturating_sub(4096)
                });
            }
        });
    }
    let weak = Rc::downgrade(&state);
    state.cancel_button.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            if !state.saving.get() {
                state.invalidate();
                state.busy.set(false);
                state.controls();
                state.status.set_text(state.language().text(
                    "Berechnung abgebrochen. Entwurf und Datei erhalten.",
                    "Calculation cancelled. Draft and file retained.",
                ));
            }
        }
    });
    let weak = Rc::downgrade(&state);
    state.recover.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            if let (Some(ui), Some(path)) = (state.ui.upgrade(), state.recovery.borrow().clone()) {
                super::recovery::open_path(&ui, path);
            }
        }
    });
    let weak = Rc::downgrade(&state);
    window.connect_close_request(move |window| {
        if let Some(state) = weak.upgrade() {
            if state.saving.get() {
                state.status.set_text(state.language().text(
                    "Speichern zuerst abschließen lassen.",
                    "Wait for saving to finish.",
                ));
                return glib::Propagation::Stop;
            }
            state.invalidate();
            state.busy.set(false);
            state.controls();
        }
        window.set_visible(false);
        glib::Propagation::Stop
    });
    *doc.hex_editor.borrow_mut() = Some(state.clone());
    window.present();
    state.load(true);
    state
}
pub(super) fn prevent_document_close(ui: &Rc<Ui>, doc: &Document) -> bool {
    let editor = doc.hex_editor.borrow().clone();
    let Some(editor) = editor else { return false };
    if editor.saving.get() {
        ui.status.set_text(ui.lang.text(
            "Hex-Speichern zuerst abschließen lassen.",
            "Wait for hex saving to finish.",
        ));
        return true;
    }
    if editor.dirty() {
        editor.window.present();
        editor.status.set_text(ui.lang.text(
            "Ungespeicherter Hexentwurf: vor dem Schließen speichern oder ausdrücklich verwerfen.",
            "Unsaved hex draft: save or explicitly discard before closing.",
        ));
        return true;
    }
    false
}
pub(super) fn close_document(doc: &Document) {
    if let Some(editor) = doc.hex_editor.borrow().as_ref() {
        editor.invalidate();
        editor.window.close();
    }
}
pub(super) fn prevent_close(ui: &Rc<Ui>) -> bool {
    ui.documents
        .borrow()
        .iter()
        .any(|doc| prevent_document_close(ui, doc))
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}

#[cfg(test)]
mod host_tests {
    use super::*;
    #[test]
    fn parent_aba_cannot_mix_section_and_snapshot_file_bases() {
        let root = tempfile::tempdir().unwrap();
        let current = root.path().join("current");
        let replacement = root.path().join("replacement");
        let held = root.path().join("held");
        std::fs::create_dir(&current).unwrap();
        std::fs::create_dir(&replacement).unwrap();
        let path = current.join("source.bin");
        std::fs::write(&path, b"same\0bytes").unwrap();
        std::fs::write(replacement.join("source.bin"), b"same\0bytes").unwrap();
        let cancel = Cancellation::default();
        let section = fastra_document::Document::open_hex(&path, &cancel).unwrap();
        let original = Snapshot::read_bounded(&path, MAX_SOURCE, &cancel).unwrap();
        assert!(verify_basis(&section, &original).is_ok());
        std::fs::rename(&current, &held).unwrap();
        std::fs::rename(&replacement, &current).unwrap();
        let other_section = fastra_document::Document::open_hex(&path, &cancel).unwrap();
        let other = Snapshot::read_bounded(&path, MAX_SOURCE, &cancel).unwrap();
        assert!(verify_basis(&other_section, &other).is_ok());
        std::fs::rename(&current, &replacement).unwrap();
        std::fs::rename(&held, &current).unwrap();
        section.verify_current(&cancel).unwrap();
        assert_eq!(original.bytes(), other.bytes());
        assert!(matches!(
            verify_basis(&section, &other),
            Err(fastra_document::Error::Stale)
        ));
    }
}

#[cfg(debug_assertions)]
mod routes_test;
#[cfg(debug_assertions)]
pub(super) fn routes_selftest(ui: Rc<Ui>) {
    routes_test::run(ui);
}
