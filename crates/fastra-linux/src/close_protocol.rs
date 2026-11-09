//! Fensterfreigaben bleiben bis zur gemeinsamen Abschlussprüfung unverbraucht.
use super::{
    application_lifecycle, folder, hex_editor, pattern_view, rich_editor, session, workflow_view,
    Document, Ui,
};
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    rc::{Rc, Weak},
    sync::Arc,
};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum SaveOutcome {
    Saved { before: u64, after: u64 },
    Cancelled,
    Failed,
    Stale,
}
pub(super) type SaveCompletion = Box<dyn FnOnce(SaveOutcome)>;
#[derive(Clone, Copy, Debug)]
pub(super) enum Abort {
    Cancelled,
    Blocked,
    Failed,
    Stale,
}
type Completion = Box<dyn FnOnce(Result<Permit, Abort>)>;

type ActivateTab = Rc<dyn Fn(&Rc<Document>)>;

#[derive(Clone)]
pub(super) struct TabSelection {
    pub(super) keep: Option<Rc<Document>>,
    pub(super) valid: Rc<dyn Fn() -> bool>,
    pub(super) activate: ActivateTab,
}
fn prevent_hex(ui: &Rc<Ui>, tabs: Option<&TabSelection>) -> bool {
    if let Some(tabs) = tabs {
        ui.documents
            .borrow()
            .iter()
            .filter(|doc| tabs.keep.as_ref().is_none_or(|keep| !Rc::ptr_eq(doc, keep)))
            .any(|doc| hex_editor::prevent_document_close(ui, doc))
    } else {
        hex_editor::prevent_close(ui)
    }
}

pub(super) struct Ticket {
    ui: Weak<Ui>,
    active: Cell<bool>,
    dialog: RefCell<Option<gio::Cancellable>>,
    session_owned: Cell<bool>,
    sensitive: Cell<Option<bool>>,
    fences: Rc<rich_editor::CloseFences>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
}
impl Ticket {
    pub(super) fn current(&self) -> bool {
        self.active.get() && self.ui.upgrade().is_some_and(|ui| ui.window.is_visible())
    }
    pub(super) fn hold_saved_editor(
        &self,
        editor: Rc<rich_editor::RichEditor>,
        done: Box<dyn FnOnce(bool)>,
    ) {
        rich_editor::hold_for_close(self.fences.clone(), editor, done);
    }
    pub(crate) fn begin_dialog(&self) -> gio::Cancellable {
        let dialog = gio::Cancellable::new();
        assert!(
            self.dialog.borrow().is_none(),
            "one owned close dialog at a time"
        );
        *self.dialog.borrow_mut() = Some(dialog.clone());
        dialog
    }
    pub(crate) fn end_dialog(&self, dialog: &gio::Cancellable) {
        let matches = self.dialog.borrow().as_ref() == Some(dialog);
        if matches {
            self.dialog.borrow_mut().take();
        }
    }
    pub(crate) fn own_session(&self) {
        self.session_owned.set(true);
    }
    pub(super) fn cancel(&self) {
        if !self.active.replace(false) {
            self.fences.cancel();
            return;
        }
        let pending = self.dialog.borrow().as_ref().cloned();
        if let Some(dialog) = pending {
            dialog.cancel();
        }
        self.hold.borrow_mut().take();
        if let Some(ui) = self.ui.upgrade() {
            ui.window_close_dialog.set(false);
            ui.close_committed.set(false);
            ui.discard_confirmed.set(false);
            if self.session_owned.get() {
                if let Some(state) = ui.session.borrow().as_ref() {
                    state.abort_prepared_close();
                }
            }
            if let Some(sensitive) = self.sensitive.take() {
                ui.window.set_sensitive(sensitive);
            }
            self.fences.cancel();
        }
    }
    fn freeze(&self) {
        if let Some(ui) = self.ui.upgrade() {
            if self.sensitive.get().is_none() {
                self.sensitive.set(Some(ui.window.is_sensitive()));
            }
            ui.window.set_sensitive(false);
        }
    }
}
struct DocumentStamp {
    doc: Weak<Document>,
    revision: u64,
    dirty: bool,
    read_only: bool,
    base: Option<[u8; 32]>,
    format: Arc<fastra_core::encoding::Decoded>,
    rich: Option<(Rc<rich_editor::RichEditor>, rich_editor::CloseStamp)>,
}
impl DocumentStamp {
    fn capture(doc: &Rc<Document>) -> Option<Self> {
        if doc.saving.get() {
            return None;
        }
        let base = doc
            .snapshot
            .borrow()
            .as_ref()
            .map(|s| s.binding_digest())
            .transpose()
            .ok()?;
        let rich = doc.rich.borrow().clone().map(|editor| {
            let stamp = editor.close_stamp();
            (editor, stamp)
        });
        Some(Self {
            doc: Rc::downgrade(doc),
            revision: doc.revision.get(),
            dirty: doc.buffer.is_modified(),
            read_only: doc.is_read_only(),
            base,
            format: doc.format.borrow().clone(),
            rich,
        })
    }
    fn same_membership(&self, doc: &Rc<Document>) -> bool {
        self.doc
            .upgrade()
            .is_some_and(|prior| Rc::ptr_eq(&prior, doc))
            && !doc.saving.get()
            && self.read_only == doc.is_read_only()
            && Arc::ptr_eq(&self.format, &doc.format.borrow())
            && doc
                .snapshot
                .borrow()
                .as_ref()
                .map(|snapshot| snapshot.binding_digest())
                .transpose()
                .ok()
                == Some(self.base)
            && match (&self.rich, doc.rich.borrow().as_ref()) {
                (None, None) => true,
                (Some((prior, stamp)), Some(editor)) => {
                    Rc::ptr_eq(prior, editor) && stamp.1 == editor.active.get()
                }
                _ => false,
            }
    }
    fn valid(&self, doc: &Rc<Document>) -> bool {
        self.same_membership(doc)
            && self.revision == doc.revision.get()
            && self.dirty == doc.buffer.is_modified()
            && self
                .rich
                .as_ref()
                .is_none_or(|(editor, stamp)| *stamp == editor.close_stamp())
    }
}
struct Preparation {
    ui: Rc<Ui>,
    ticket: Rc<Ticket>,
    basis: RefCell<Vec<DocumentStamp>>,
    done: RefCell<Option<Completion>>,
    tabs: Option<TabSelection>,
}
impl Preparation {
    fn end(&self, error: Abort) {
        if self.ticket.current() && matches!(error, Abort::Stale) {
            self.ui.status.set_text(self.ui.lang.text(
                "Fenster oder Speicherbasis inzwischen geändert; Schließen angehalten.",
                "Window or save base changed meanwhile; Close held.",
            ));
        }
        self.ticket.cancel();
        if let Some(done) = self.done.borrow_mut().take() {
            done(Err(error));
        }
    }
    fn valid(&self) -> bool {
        valid_basis(&self.ui, &self.basis.borrow())
            && self.ticket.current()
            && self.tabs.as_ref().is_none_or(|tabs| (tabs.valid)())
    }
    fn next(self: &Rc<Self>, index: usize) {
        if !self.valid() {
            self.end(Abort::Stale);
            return;
        }
        let doc = self.ui.documents.borrow().get(index).cloned();
        let Some(doc) = doc else {
            self.ready(None);
            return;
        };
        if self
            .tabs
            .as_ref()
            .is_some_and(|tabs| tabs.keep.as_ref().is_some_and(|keep| Rc::ptr_eq(keep, &doc)))
            || !doc.buffer.is_modified()
        {
            self.next(index + 1);
            return;
        }
        if let Some(tabs) = &self.tabs {
            (tabs.activate)(&doc);
        }
        if !self.valid() {
            self.end(Abort::Stale);
            return;
        }
        let dialog = gtk::AlertDialog::builder()
            .message(self.ui.lang.text(
                "Änderungen in diesem Tab sichern?",
                "Save changes in this tab?",
            ))
            .detail(doc.label.text())
            .buttons([
                self.ui.lang.text("Abbrechen", "Cancel"),
                self.ui
                    .lang
                    .text("Ohne Speichern schließen", "Close without saving"),
                self.ui
                    .lang
                    .text("Speichern und schließen", "Save and close"),
            ])
            .cancel_button(0)
            .default_button(2)
            .build();
        let this = self.clone();
        let cancellable = self.ticket.begin_dialog();
        let completed = cancellable.clone();
        dialog.choose(Some(&self.ui.window), Some(&cancellable), move |result| {
            this.ticket.end_dialog(&completed);
            if !this.valid() {
                this.end(Abort::Stale);
                return;
            }
            match result {
                Ok(1) => this.next(index + 1),
                Ok(2) => {
                    let pending = this.clone();
                    this.ui.save_document_ready_owned(
                        doc.clone(),
                        Some(this.ticket.clone()),
                        Box::new(move |outcome| {
                            if !pending.ticket.current() {
                                pending.end(Abort::Stale);
                                return;
                            }
                            match outcome {
                                SaveOutcome::Saved { before, after } => {
                                    let docs = pending.ui.documents.borrow();
                                    let basis = pending.basis.borrow();
                                    let unchanged = docs.len() == basis.len()
                                        && docs.iter().zip(basis.iter()).enumerate().all(
                                            |(at, (current, prior))| {
                                                if at == index {
                                                    Rc::ptr_eq(current, &doc)
                                                        && before == prior.revision
                                                        && current.revision.get() == after
                                                        && !current.saving.get()
                                                        && !current.buffer.is_modified()
                                                } else {
                                                    prior.valid(current)
                                                }
                                            },
                                        );
                                    drop(basis);
                                    drop(docs);
                                    if !unchanged {
                                        pending.end(Abort::Stale);
                                        return;
                                    }
                                    let Some(stamp) = DocumentStamp::capture(&doc) else {
                                        pending.end(Abort::Stale);
                                        return;
                                    };
                                    pending.basis.borrow_mut()[index] = stamp;
                                    pending.next(index + 1);
                                }
                                SaveOutcome::Cancelled => pending.end(Abort::Cancelled),
                                SaveOutcome::Failed => pending.end(Abort::Failed),
                                SaveOutcome::Stale => pending.end(Abort::Stale),
                            }
                        }),
                    );
                }
                _ => this.end(Abort::Cancelled),
            }
        });
    }
    fn ready(&self, session: Option<session::ClosePermit>) {
        if !self.valid() {
            self.end(Abort::Stale);
            return;
        }
        if let Some(done) = self.done.borrow_mut().take() {
            done(Ok(Permit {
                ui: Rc::downgrade(&self.ui),
                ticket: self.ticket.clone(),
                basis: self.basis.take(),
                session,
                tabs: self.tabs.clone(),
            }));
        }
    }
}
fn valid_basis(ui: &Ui, basis: &[DocumentStamp]) -> bool {
    let docs = ui.documents.borrow();
    ui.window.is_visible()
        && docs.len() == basis.len()
        && docs.iter().zip(basis).all(|(doc, stamp)| stamp.valid(doc))
}
pub(super) struct Permit {
    pub(super) ui: Weak<Ui>,
    pub(super) ticket: Rc<Ticket>,
    basis: Vec<DocumentStamp>,
    session: Option<session::ClosePermit>,
    tabs: Option<TabSelection>,
}
impl Permit {
    pub(super) fn documents_valid(&self) -> bool {
        self.ui
            .upgrade()
            .is_some_and(|ui| valid_basis(&ui, &self.basis))
    }
    pub(super) fn valid(&self) -> bool {
        !crate::asset_io::pending() && !crate::git_pull::pending()
            && self
                .ui
                .upgrade()
                .is_some_and(|ui| crate::editor_options::profiles_can_close(&ui))
            && self.ticket.current()
            && self.ui.upgrade().is_some_and(|ui| {
                valid_basis(&ui, &self.basis)
                    && !folder::prevent_close(&ui)
                    && !prevent_hex(&ui, self.tabs.as_ref())
                    && self.tabs.as_ref().is_none_or(|tabs| (tabs.valid)())
                    && !pattern_view::prevent_close(&ui)
                    && !workflow_view::prevent_close(&ui)
            })
            && self.session.as_ref().is_none_or(|session| session.valid())
    }
    pub(super) fn freeze(&self) {
        self.ticket.freeze();
    }
    pub(super) fn publish(&self, done: Box<dyn FnOnce(bool)>) {
        if let Some(session) = &self.session {
            session.publish(self.ticket.clone(), done);
        } else {
            done(true);
        }
    }
    pub(super) fn finalize(&self, done: Box<dyn FnOnce(bool)>) {
        if let Some(session) = &self.session {
            session.finalize(self.ticket.clone(), done);
        } else {
            done(true);
        }
    }
    pub(super) fn removed(&self) -> bool {
        self.ui.upgrade().is_none_or(|ui| {
            ui.window.application().is_none_or(|app| {
                !app.windows()
                    .iter()
                    .any(|window| window == ui.window.upcast_ref::<gtk::Window>())
            })
        })
    }
    pub(super) fn close(&self) {
        if let Some(ui) = self.ui.upgrade() {
            if let Some(state) = ui.session.borrow().as_ref() {
                state.commit_prepared_close();
            }
            ui.close_committed.set(true);
            ui.window.close();
        }
    }
    pub(super) fn cleanup(&self, done: Box<dyn FnOnce(bool)>) {
        let ticket = self.ticket.clone();
        let finished: Box<dyn FnOnce(bool)> = Box::new(move |ok| {
            ticket.active.set(false);
            ticket.hold.borrow_mut().take();
            done(ok);
        });
        if let Some(session) = &self.session {
            session.cleanup(finished);
        } else {
            finished(true);
        }
    }
    pub(super) fn cancel(&self) {
        if let Some(session) = &self.session {
            session.rollback();
        }
        self.ticket.cancel();
    }
}
pub(super) fn active(ui: &Ui) -> bool {
    ui.close_ticket
        .borrow()
        .as_ref()
        .and_then(Weak::upgrade)
        .is_some_and(|ticket| ticket.current())
}
pub(super) fn prepare(ui: &Rc<Ui>, done: Completion) -> Option<Rc<Ticket>> {
    prepare_inner(ui, None, done)
}
pub(super) fn prepare_tabs(
    ui: &Rc<Ui>,
    tabs: TabSelection,
    done: Completion,
) -> Option<Rc<Ticket>> {
    if !(tabs.valid)() {
        done(Err(Abort::Stale));
        return None;
    }
    prepare_inner(ui, Some(tabs), done)
}
fn prepare_inner(ui: &Rc<Ui>, tabs: Option<TabSelection>, done: Completion) -> Option<Rc<Ticket>> {
    if !crate::editor_options::profiles_can_close(ui) || !crate::asset_io::can_close(ui) || !crate::git_pull::can_close(ui) {
        done(Err(Abort::Blocked));
        return None;
    }
    if folder::prevent_close(ui) {
        done(Err(Abort::Blocked));
        return None;
    }
    if active(ui)
        || ui.window_close_dialog.get()
        || ui
            .documents
            .borrow()
            .iter()
            .any(|doc| doc.close_pending.get() || doc.saving.get())
        || prevent_hex(ui, tabs.as_ref())
        || pattern_view::prevent_close(ui)
        || workflow_view::prevent_close(ui)
    {
        ui.status.set_text(ui.lang.text(
            "Laufende Schließentscheidung, Entwurf oder Speicherung zuerst abschließen.",
            "Finish the pending close decision, draft or save first.",
        ));
        done(Err(Abort::Blocked));
        return None;
    }
    let Some(members) = ui
        .documents
        .borrow()
        .iter()
        .map(DocumentStamp::capture)
        .collect::<Option<Vec<_>>>()
    else {
        done(Err(Abort::Stale));
        return None;
    };
    let ticket = Rc::new(Ticket {
        ui: Rc::downgrade(ui),
        active: Cell::new(true),
        dialog: RefCell::new(None),
        session_owned: Cell::new(false),
        sensitive: Cell::new(None),
        fences: rich_editor::CloseFences::new(),
        hold: RefCell::new(ui.window.application().map(|app| app.hold())),
    });
    *ui.close_ticket.borrow_mut() = Some(Rc::downgrade(&ticket));
    crate::editor_options::startup::interrupt(ui);
    if crate::application_lifecycle::ordinary_windows().is_none_or(|windows| windows.len() <= 1) {
        crate::editor_options::startup::cancel_restoration();
    }
    ui.window_close_dialog.set(true);
    let state = Rc::new(Preparation {
        ui: ui.clone(),
        ticket: ticket.clone(),
        basis: RefCell::new(Vec::new()),
        done: RefCell::new(Some(done)),
        tabs,
    });
    let started = state.clone();
    rich_editor::flush_close(
        ui,
        ticket.fences.clone(),
        Box::new(move |ok| {
            // Der mutierende Rich-Rückruf muss seinen globalen IO-Besitz erst vollständig freigeben.
            glib::idle_add_local_once(move || {
                if !started.ticket.current()
                    || started.tabs.as_ref().is_some_and(|tabs| !(tabs.valid)())
                {
                    started.end(Abort::Stale);
                    return;
                }
                if !ok {
                    started.ui.status.set_text(started.ui.lang.text(
                        "Schließen angehalten: Rich-Änderungen sind nicht synchronisiert.",
                        "Close held: rich changes are not synchronized.",
                    ));
                    started.end(Abort::Failed);
                    return;
                }
                if !crate::asset_io::can_close(&started.ui) || !crate::git_pull::can_close(&started.ui) {
                    started.end(Abort::Blocked);
                    return;
                }
                let membership_unchanged = {
                    let docs = started.ui.documents.borrow();
                    docs.len() == members.len()
                        && docs
                            .iter()
                            .zip(&members)
                            .all(|(doc, prior)| prior.same_membership(doc))
                };
                if !membership_unchanged {
                    started.end(Abort::Stale);
                    return;
                }
                let Some(stamps) = started
                    .ui
                    .documents
                    .borrow()
                    .iter()
                    .map(DocumentStamp::capture)
                    .collect::<Option<Vec<_>>>()
                else {
                    started.end(Abort::Stale);
                    return;
                };
                *started.basis.borrow_mut() = stamps;
                let session = started.ui.session.borrow().clone();
                if let Some(session) = session.filter(|state| {
                    started.tabs.is_none() && (state.is_enabled() || state.has_pending_index())
                }) {
                    let this = started.clone();
                    session.prepare_close(
                        started.ticket.clone(),
                        Box::new(move |result| match result {
                            Ok(permit) => this.ready(Some(permit)),
                            Err(error) => this.end(error),
                        }),
                    );
                } else {
                    started.next(0);
                }
            });
        }),
    );
    Some(ticket)
}
pub(super) fn window_close(ui: &Rc<Ui>) -> glib::Propagation {
    if !crate::editor_options::profiles_can_close(ui) || !crate::git_pull::can_close(ui) {
        return glib::Propagation::Stop;
    }
    if ui.close_committed.replace(false) || ui.discard_confirmed.replace(false) {
        ui.cancellation.borrow().cancel();
        return glib::Propagation::Proceed;
    }
    application_lifecycle::abort_quit();
    if active(ui) || ui.window_close_dialog.get() {
        return glib::Propagation::Stop;
    }
    ui.window_close_dialog.set(true);
    let owner = Rc::downgrade(ui);
    // GTK ignoriert ein synchron erneut ausgelöstes close im ursprünglichen close-request.
    glib::idle_add_local_once(move || {
        if let Some(ui) = owner.upgrade() {
            ui.window_close_dialog.set(false);
            if ui.window.is_visible() {
                prepare_window(&ui);
            }
        }
    });
    glib::Propagation::Stop
}
fn prepare_window(ui: &Rc<Ui>) {
    let owner = Rc::downgrade(ui);
    prepare(
        ui,
        Box::new(move |result| {
            let Ok(permit) = result else {
                return;
            };
            let permit = Rc::new(permit);
            if !permit.valid() {
                permit.cancel();
                return;
            }
            permit.freeze();
            let next = permit.clone();
            permit.publish(Box::new(move |ok| {
                if !ok || !next.valid() {
                    next.cancel();
                    return;
                }
                let last = next.clone();
                next.finalize(Box::new(move |ok| {
                    glib::idle_add_local_once(move || {
                        if ok && last.valid() && owner.upgrade().is_some() {
                            let close = move |ok| {
                                if ok && last.valid() {
                                    last.close();
                                    if last.removed() { last.cleanup(Box::new(|_| {})); }
                                    else { last.cancel(); }
                                } else { last.cancel(); }
                            };
                            if crate::application_lifecycle::ordinary_windows().is_none_or(|windows| windows.len() <= 1) {
                                crate::editor_options::startup::capture(vec![owner.upgrade().unwrap()], Box::new(close));
                            } else { close(true); }
                        } else {
                            last.cancel();
                        }
                    });
                }));
            }));
        }),
    );
}

#[cfg(debug_assertions)]
pub(super) fn test_pause(phase: &str) {
    let Ok(value) = std::env::var(format!("FASTRA_QUIT_TEST_DELAY_{phase}_MS")) else {
        return;
    };
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let delay: u64 = value.parse().unwrap();
    assert!(delay <= 1500);
    std::thread::sleep(std::time::Duration::from_millis(delay));
}
