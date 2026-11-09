//! Der Journalindex enthält nur rohe lokale Pfade, niemals ungefragt aktuelle Editortexte.
use super::*;
use std::os::unix::ffi::OsStrExt;
impl State {
    pub(super) fn merge_journals(&self) -> Result<(), String> {
        let mut paths = self.journals.borrow().clone();
        for archive in self.archives.borrow().iter() {
            for raw in &archive.session.recovery_journals {
                let path = store::source_path(raw);
                if !paths.contains(&path) {
                    paths.push(path);
                }
            }
        }
        if paths.len() > store::MAX_JOURNALS {
            return Err("Combined journal index limit: 64".into());
        }
        self.journal_button.set_sensitive(!paths.is_empty());
        *self.journals.borrow_mut() = paths;
        Ok(())
    }
    pub(super) fn remember_journal(self: &Rc<Self>, path: PathBuf) -> Result<(), String> {
        let raw = path.as_os_str().as_bytes();
        if !path.is_absolute() || raw.len() > 4096 || raw.contains(&0) {
            return Err("Invalid recovery journal path".into());
        }
        let mut paths = self.journals.borrow_mut();
        if paths.contains(&path) {
            return Ok(());
        }
        if paths.len() >= store::MAX_JOURNALS {
            return Err("Recovery journal index limit: 64".into());
        }
        paths.push(path);
        drop(paths);
        self.journal_changed();
        Ok(())
    }
    pub(super) fn forget_journal(self: &Rc<Self>, path: &std::path::Path) {
        let mut paths = self.journals.borrow_mut();
        let previous = paths.len();
        paths.retain(|p| p != path);
        if paths.len() != previous {
            drop(paths);
            self.journal_changed();
        }
    }
    fn journal_changed(self: &Rc<Self>) {
        self.journals_epoch.set(self.journals_epoch.get() + 1);
        self.epoch.set(self.epoch.get() + 1);
        self.stamp.borrow_mut().take();
        self.journal_button
            .set_sensitive(!self.journals.borrow().is_empty());
        self.save_now.set_sensitive(true);
        self.tick();
    }
    pub(super) fn flush_journals(self: &Rc<Self>) {
        let Some(ui) = self.ui.upgrade().filter(|ui| ui.window.is_visible()) else {
            return;
        };
        let Some(lease) = self.lease.borrow().clone() else {
            return;
        };
        if self.review_open.get() > 0 {
            return;
        }
        if self.busy.replace(true) {
            return;
        }
        let paths: Vec<Vec<u8>> = self
            .journals
            .borrow()
            .iter()
            .map(|p| p.as_os_str().as_bytes().to_vec())
            .collect();
        let epoch = self.journals_epoch.get();
        let mut archives = std::mem::take(&mut *self.archives.borrow_mut());
        let width = ui.window.width().clamp(760, 4000);
        let height = ui.window.height().clamp(700, 2400);
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                let result = (|| {
                    // Bei Opt-out ausschließlich die bereits bestätigte Kopie lesen; keine Gtk-Puffer erfassen.
                    let mut record = lease.read_optional()?.unwrap_or(Session {
                        version: 1,
                        active: 0,
                        width,
                        height,
                        documents: Vec::new(),
                        read_only_sources: Vec::new(),
                        recovery_journals: Vec::new(),
                    });
                    record.recovery_journals = paths.clone();
                    lease.write(&record)?;
                    // Ein entferntes Journal darf beim nächsten Start nicht aus einem Altarchiv wiederkehren.
                    for archive in &mut archives {
                        archive.session.recovery_journals = paths.clone();
                        archive.lease.write(&archive.session)?;
                    }
                    Ok::<_, String>(())
                })();
                Ok((archives, result))
            },
            move |outcome| {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                let (archives, result) = match outcome {
                    Ok(value) => value,
                    Err(error) => {
                        state.busy.set(false);
                        state.index_closing.set(false);
                        if let Some(ui) = state.ui.upgrade() {
                            ui.window.set_sensitive(true);
                        }
                        state.failed(&error);
                        return;
                    }
                };
                *state.archives.borrow_mut() = archives;
                state.busy.set(false);
                if state.ui.upgrade().is_none_or(|ui| !ui.window.is_visible()) {
                    return;
                }
                match result {
                    Ok(()) => {
                        state.journals_saved.set(epoch);
                        state
                            .save_now
                            .set_sensitive(state.enabled.is_active() || state.has_pending_index());
                        if let Some(ui) = state.ui.upgrade() {
                            state.status.set_text(ui.lang.text("Dateitransaktionsindex lokal gesichert; keine aktuellen Editorinhalte erfasst.","File transaction index saved locally; no current editor contents captured."));
                        }
                    }
                    Err(error) => state.failed(&error),
                }
                if state.index_closing.replace(false) {
                    if let Some(ui) = state.ui.upgrade() {
                        ui.window.set_sensitive(true);
                        if state.has_pending_index() {
                            // Fehler hält das Fenster offen; neuere Metadaten dürfen später erneut geprüft werden.
                        } else {
                            gtk::glib::idle_add_local_once(move || {
                                if ui.window.is_visible() {
                                    ui.window.close();
                                }
                            });
                        }
                    }
                }
                if let Some(mode) = state.pending_close.take() {
                    state.flush(Some(mode));
                }
            },
        );
    }
    pub(super) fn review_journals(self: &Rc<Self>) {
        if self.closing.get() {
            return;
        }
        let Some(ui) = self.ui.upgrade().filter(|ui| ui.window.is_visible()) else {
            return;
        };
        let window = support::window(
            &ui,
            ui.lang
                .text("Bekannte Dateitransaktionen", "Known file transactions"),
            false,
        );
        window.set_default_size(760, 440);
        let root = support::column();
        root.append(&support::label(ui.lang.text("Eintrag öffnet nur die vollständige Prüfung. Keine automatische Rücknahme oder Dateiveränderung. Pfade können fehlen oder inzwischen ungültig sein.","An entry only opens full inspection. No automatic rollback or file changes. Paths may be missing or invalid now.")));
        let list = support::column();
        for path in self.journals.borrow().iter() {
            let button = gtk::Button::new();
            let label = support::label(&super::super::project_view::display(path));
            label.set_wrap(true);
            label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
            label.set_max_width_chars(72);
            button.set_child(Some(&label));
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            button.set_hexpand(true);
            row.append(&button);
            let forget =
                gtk::Button::with_label(ui.lang.text("Eintrag vergessen …", "Forget entry …"));
            row.append(&forget);
            let forget_path = path.clone();
            let weak = Rc::downgrade(self);
            let parent = window.downgrade();
            let row_weak = row.downgrade();
            forget.connect_clicked(move |_|{
                let (Some(state),Some(parent))=(weak.upgrade(),parent.upgrade())else{return;};
                let Some(ui)=state.ui.upgrade().filter(|ui|ui.window.is_visible()&&parent.is_visible())else{return;};
                let dialog=gtk::AlertDialog::builder().message(ui.lang.text("Nur diesen Indexeintrag vergessen?","Forget only this index entry?"))
                    .detail(format!("{}\n{}",super::super::project_view::display(&forget_path),ui.lang.text("Originaldateien und Sicherungsordner bleiben vollständig erhalten. Dieser Schritt stellt keine Dateien wieder her und löscht keine Sicherung.","Original files and recovery folder are fully retained. This step neither restores files nor deletes recovery data.")))
                    .buttons([ui.lang.text("Abbrechen","Cancel"),ui.lang.text("Nur Indexeintrag vergessen","Forget index entry only")]).cancel_button(0).default_button(0).build();
                let path=forget_path.clone();let weak=Rc::downgrade(&state);let row=row_weak.clone();let owner=parent.downgrade();
                dialog.choose(Some(&parent),None::<&gtk::gio::Cancellable>,move|result|{
                    if result!=Ok(1){return;}let (Some(state),Some(parent))=(weak.upgrade(),owner.upgrade())else{return;};
                    if !parent.is_visible()||state.ui.upgrade().is_none_or(|ui|!ui.window.is_visible()){return;}
                    state.forget_journal(&path);if let Some(row)=row.upgrade(){row.set_sensitive(false);}
                });
            });
            let path = path.clone();
            let owner = Rc::downgrade(&ui);
            let tool = window.downgrade();
            button.connect_clicked(move |_| {
                if let (Some(ui), Some(tool)) = (owner.upgrade(), tool.upgrade()) {
                    if ui.window.is_visible() && tool.is_visible() {
                        super::super::recovery::open_path(&ui, path.clone());
                    }
                }
            });
            list.append(&row);
        }
        let scroll = gtk::ScrolledWindow::builder()
            .vexpand(true)
            .hexpand(true)
            .child(&list)
            .build();
        root.append(&scroll);
        let status = support::label(&self.status.text());
        root.append(&status);
        let weak = Rc::downgrade(self);
        let owner = window.downgrade();
        gtk::glib::timeout_add_local(std::time::Duration::from_millis(200), move || {
            let (Some(state), Some(window)) = (weak.upgrade(), owner.upgrade()) else {
                return gtk::glib::ControlFlow::Break;
            };
            if !window.is_visible() || state.ui.upgrade().is_none_or(|ui| !ui.window.is_visible()) {
                return gtk::glib::ControlFlow::Break;
            }
            status.set_text(&state.status.text());
            gtk::glib::ControlFlow::Continue
        });
        let close = gtk::Button::with_label(ui.lang.text("Schließen", "Close"));
        let w = window.clone();
        close.connect_clicked(move |_| w.close());
        root.append(&close);
        window.set_child(Some(&root));
        window.present();
    }
}
