//! Entscheidungen und Captures ändern noch keine bestehende Wiederherstellung.
use super::*;
use crate::close_protocol::{Abort, Ticket};

type Completion = Box<dyn FnOnce(Result<Permit, Abort>)>;
struct Prepared {
    session: Session,
    archives: Vec<Session>,
    replace_archives: bool,
}
struct Published {
    primary: Arc<store::Lease>,
    archives: Vec<store::Archive>,
}
struct Retired {
    primary: Option<Arc<store::Lease>>,
    archives: Vec<store::Archive>,
    consume: Vec<store::Archive>,
    journals_saved: u64,
    stamp: Option<WindowStamp>,
    replace_archives: bool,
}
pub(crate) struct Permit {
    state: Rc<State>,
    stamp: WindowStamp,
    enabled: bool,
    journals_epoch: u64,
    prepared: RefCell<Option<Prepared>>,
    published: Rc<RefCell<Option<Published>>>,
    retired: RefCell<Option<Retired>>,
}
impl Permit {
    pub(crate) fn valid(&self) -> bool {
        self.state.current_stamp().as_ref() == Some(&self.stamp)
            && self.state.enabled.is_active() == self.enabled
            && self.state.journals_epoch.get() == self.journals_epoch
            && self.state.closing.get()
            && self.state.review_open.get() == 0
            && !self.state.busy.get()
            && !self.state.close_dialog.get()
    }
    pub(crate) fn publish(&self, ticket: Rc<Ticket>, done: Box<dyn FnOnce(bool)>) {
        if !ticket.current() || !self.valid() {
            done(false);
            return;
        }
        let Some(prepared) = self.prepared.take() else {
            done(false);
            return;
        };
        self.state.busy.set(true);
        let result_slot = self.published.clone();
        let state = self.state.clone();
        // Neue Leases halten bisherige Kopien selbst dann fest, wenn ein späteres Fenster scheitert.
        support::background(
            move || {
                let dir = store::Directory::open(&state_base()?)?;
                let primary = Arc::new(dir.create()?);
                primary.write(&prepared.session)?;
                #[cfg(debug_assertions)]
                crate::close_protocol::test_pause("SESSION");
                let mut archives = Vec::new();
                if prepared.replace_archives {
                    for session in prepared.archives {
                        let lease = dir.create()?;
                        lease.write(&session)?;
                        archives.push(store::Archive { lease, session });
                    }
                }
                Ok(Published { primary, archives })
            },
            move |result| {
                state.busy.set(false);
                match result {
                    Ok(published) => {
                        *result_slot.borrow_mut() = Some(published);
                        done(ticket.current());
                    }
                    Err(error) => {
                        if ticket.current() {
                            state.failed(&error);
                        }
                        done(false);
                    }
                }
            },
        );
    }
    pub(crate) fn finalize(&self, ticket: Rc<Ticket>, done: Box<dyn FnOnce(bool)>) {
        if !ticket.current() || !self.valid() {
            done(false);
            return;
        }
        let Some(published) = self.published.borrow_mut().take() else {
            done(false);
            return;
        };
        // Noch kein unlink: auch ein späteres Fenster darf den gesamten Versuch abbrechen.
        let retired = Retired {
            primary: self.state.lease.replace(Some(published.primary)),
            archives: if self.enabled {
                Vec::new()
            } else {
                self.state.archives.replace(published.archives)
            },
            consume: self.state.consume.take(),
            journals_saved: self.state.journals_saved.get(),
            stamp: self.state.stamp.borrow().clone(),
            replace_archives: !self.enabled,
        };
        *self.retired.borrow_mut() = Some(retired);
        self.state.journals_saved.set(self.journals_epoch);
        *self.state.stamp.borrow_mut() = Some(self.stamp.clone());
        done(true);
    }
    pub(crate) fn rollback(&self) {
        if let Some(retired) = self.retired.take() {
            *self.state.lease.borrow_mut() = retired.primary;
            if retired.replace_archives {
                *self.state.archives.borrow_mut() = retired.archives;
            }
            *self.state.consume.borrow_mut() = retired.consume;
            self.state.journals_saved.set(retired.journals_saved);
            *self.state.stamp.borrow_mut() = retired.stamp;
        }
    }
    pub(crate) fn cleanup(&self, done: Box<dyn FnOnce(bool)>) {
        let Some(retired) = self.retired.take() else {
            done(true);
            return;
        };
        // Erst nach dem tatsächlichen Entfernen ALLER freigegebenen Fenster aufrufen.
        let lang = self
            .state
            .ui
            .upgrade()
            .map_or(crate::Language(false), |ui| ui.lang);
        support::background(
            move || {
                if let Some(old) = retired.primary {
                    if old.read_optional()?.is_some() {
                        old.remove()?;
                    }
                }
                for archive in retired.archives.iter().chain(&retired.consume) {
                    archive.lease.remove()?;
                }
                Ok(())
            },
            move |result| {
                if let Err(error) = &result {
                    eprintln!("{}: {error}",lang.text("Fastra: ältere Sitzungssicherungen nicht vollständig entfernt; verbliebene Dateien bleiben zur Prüfung erhalten","Fastra: older session backups not fully removed; remaining files retained for inspection"));
                }
                done(result.is_ok());
            },
        );
    }
}
impl State {
    #[cfg(debug_assertions)]
    pub(crate) fn close_observation(&self) -> serde_json::Value {
        serde_json::json!({"ready":self.ready.get(),"busy":self.busy.get(),"closing":self.closing.get(),"allowClose":self.allow_close.get(),"closeDialog":self.close_dialog.get(),"indexClosing":self.index_closing.get(),"pendingClose":self.pending_close.get().is_some(),"epoch":self.epoch.get(),"journalsEpoch":self.journals_epoch.get(),"journalsSaved":self.journals_saved.get(),"lease":self.lease.borrow().as_ref().map(|lease|lease.name.as_str()),"consume":self.consume.borrow().iter().map(|archive|archive.lease.name.as_str()).collect::<Vec<_>>()})
    }
    pub(crate) fn commit_prepared_close(&self) {
        if self.closing.get() {
            self.allow_close.set(true);
        }
    }
    #[cfg(debug_assertions)]
    pub(super) fn close(self: &Rc<Self>) -> Option<gtk::glib::Propagation> {
        if let Some(ui) = self.ui.upgrade() {
            ui.window.close();
        }
        Some(gtk::glib::Propagation::Stop)
    }
    pub(crate) fn abort_prepared_close(&self) {
        self.closing.set(false);
        self.close_dialog.set(false);
        self.allow_close.set(false);
        self.index_closing.set(false);
        self.pending_close.take();
    }
    pub(crate) fn prepare_close(self: &Rc<Self>, ticket: Rc<Ticket>, done: Completion) {
        if !self.ready.get()
            || self.busy.get()
            || self.closing.get()
            || self.close_dialog.get()
            || self.review_open.get() > 0
        {
            if let Some(ui) = self.ui.upgrade() {
                self.status.set_text(ui.lang.text("Sitzung noch beschäftigt oder Wiederherstellungsprüfung offen. Vorgang zuerst abschließen.","Session still busy or restore review open. Finish that operation first."));
            }
            done(Err(Abort::Blocked));
            return;
        }
        ticket.own_session();
        self.closing.set(true);
        let Some(ui) = self.ui.upgrade() else {
            done(Err(Abort::Stale));
            return;
        };
        if !self.is_enabled() {
            self.prepare_capture(ticket, None, done);
            return;
        }
        if !ui
            .documents
            .borrow()
            .iter()
            .any(|doc| doc.buffer.is_modified())
        {
            self.prepare_capture(ticket, Some(CloseMode::Recovery), done);
            return;
        }
        let stamp = self.current_stamp();
        self.close_dialog.set(true);
        let dialog=gtk::AlertDialog::builder().message(ui.lang.text("Ungesicherte Editorinhalte beim Schließen?","Unsaved editor contents on close?"))
            .detail(ui.lang.text("Eine lokale Sitzungskopie ersetzt keine Dateispeicherung. Mit Wiederherstellung schließen erhält die Editorinhalte für den nächsten Start; Verwerfen entfernt sie aus dieser Kopie.","A local recovery copy does not save source files. Close with recovery retains editor contents for the next start; Discard removes them from this copy."))
            .buttons([ui.lang.text("Abbrechen","Cancel"),ui.lang.text("Mit Wiederherstellung schließen","Close with recovery"),ui.lang.text("Verwerfen und schließen","Discard and close")])
            .cancel_button(0).default_button(0).build();
        let state = self.clone();
        let cancellable = ticket.begin_dialog();
        let completed = cancellable.clone();
        dialog.choose(Some(&ui.window), Some(&cancellable), move |result| {
            ticket.end_dialog(&completed);
            state.close_dialog.set(false);
            if !ticket.current() || state.current_stamp() != stamp {
                done(Err(Abort::Stale));
                return;
            }
            match result {
                Ok(1) => state.prepare_capture(ticket, Some(CloseMode::Recovery), done),
                Ok(2) => state.prepare_capture(ticket, Some(CloseMode::Discard), done),
                _ => done(Err(Abort::Cancelled)),
            }
        });
    }
    fn prepare_capture(
        self: &Rc<Self>,
        ticket: Rc<Ticket>,
        mode: Option<CloseMode>,
        done: Completion,
    ) {
        let Some(stamp) = self.current_stamp() else {
            done(Err(Abort::Stale));
            return;
        };
        let enabled = self.enabled.is_active();
        let journals_epoch = self.journals_epoch.get();
        let capture = if enabled {
            match self.capture(mode) {
                Ok(capture) => Some(capture),
                Err(error) => {
                    self.failed(&error);
                    done(Err(Abort::Failed));
                    return;
                }
            }
        } else {
            None
        };
        let lease = self.lease.borrow().clone();
        let mut archives: Vec<_> = if enabled {
            Vec::new()
        } else {
            self.archives
                .borrow()
                .iter()
                .map(|archive| archive.session.clone())
                .collect()
        };
        let journals: Vec<_> = self
            .journals
            .borrow()
            .iter()
            .map(|path| {
                use std::os::unix::ffi::OsStrExt;
                path.as_os_str().as_bytes().to_vec()
            })
            .collect();
        let width = stamp.width.clamp(760, 4000);
        let height = stamp.height.clamp(700, 2400);
        let state = self.clone();
        let current = self.clone();
        support::background(
            move || {
                let session = if let Some(capture) = capture {
                    capture.session()?
                } else {
                    let mut session = lease
                        .ok_or("Session lease missing")?
                        .read_optional()?
                        .unwrap_or(Session {
                            version: 1,
                            active: 0,
                            width,
                            height,
                            documents: Vec::new(),
                            read_only_sources: Vec::new(),
                            recovery_journals: Vec::new(),
                        });
                    session.recovery_journals = journals.clone();
                    for archive in &mut archives {
                        archive.recovery_journals = journals.clone();
                    }
                    session.validate()?;
                    session
                };
                Ok(Prepared {
                    session,
                    archives,
                    replace_archives: !enabled,
                })
            },
            move |result| {
                if !ticket.current()
                    || current.current_stamp().as_ref() != Some(&stamp)
                    || current.enabled.is_active() != enabled
                    || current.journals_epoch.get() != journals_epoch
                {
                    done(Err(Abort::Stale));
                    return;
                }
                match result {
                    Ok(prepared) => done(Ok(Permit {
                        state,
                        stamp,
                        enabled,
                        journals_epoch,
                        prepared: RefCell::new(Some(prepared)),
                        published: Rc::default(),
                        retired: RefCell::new(None),
                    })),
                    Err(error) => {
                        current.failed(&error);
                        done(Err(Abort::Failed));
                    }
                }
            },
        );
    }
}
