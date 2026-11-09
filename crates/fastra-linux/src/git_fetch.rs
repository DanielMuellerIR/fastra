//! Manuelles Abrufen konfigurierter Remotes. Alle Git-Prozesse laufen auf Workern.
use super::{git_view as support, project_view, Language, Ui};
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::{Path, PathBuf},
    rc::{Rc, Weak},
    sync::mpsc,
    time::Duration,
};

type Refresh = Box<dyn Fn(&Path, (u64, u64))>;
thread_local! {
    static REFRESH: RefCell<Vec<(glib::WeakRef<gtk::Window>, Refresh)>> = RefCell::new(Vec::new());
    static DIALOGS: RefCell<Vec<Weak<State>>> = const { RefCell::new(Vec::new()) };
}
pub(super) fn invalidate_owner(ui: &Ui) {
    DIALOGS.with_borrow_mut(|all| {
        all.retain(|weak| {
            let Some(state) = weak.upgrade() else {
                return false;
            };
            if state
                .ui
                .upgrade()
                .is_some_and(|owner| std::ptr::eq(owner.as_ref(), ui))
            {
                state.invalidate();
            }
            true
        });
    });
}
pub(super) fn observe(window: &gtk::Window, refresh: impl Fn(&Path, (u64, u64)) + 'static) {
    REFRESH.with_borrow_mut(|all| {
        all.retain(|(w, _)| w.upgrade().is_some());
        all.push((window.downgrade(), Box::new(refresh)));
    });
}
pub(super) fn refreshed(root: &Path, identity: (u64, u64)) {
    REFRESH.with_borrow(|all| {
        for (window, refresh) in all {
            if window.upgrade().is_some_and(|w| w.is_visible()) {
                refresh(root, identity);
            }
        }
    });
}
pub(super) struct Owner {
    document: Option<Weak<super::Document>>,
    generation: u64,
    revision: Option<u64>,
    document_path: Option<PathBuf>,
    project: Option<project_view::Binding>,
}
impl Owner {
    pub(super) fn capture(ui: &Rc<Ui>) -> Self {
        Self {
            document: ui.active().map(|d| Rc::downgrade(&d)),
            generation: ui.generation.get(),
            revision: ui.active().map(|d| d.revision.get()),
            document_path: ui.active().and_then(|d| d.disk_path()),
            project: project_view::current_binding(ui),
        }
    }
    pub(super) fn project_root(&self) -> Option<project_view::RootBinding> {
        self.project.as_ref().map(|binding| binding.root.clone())
    }
    pub(super) fn current(&self, ui: &Rc<Ui>) -> bool {
        ui.window.is_visible()
            && ui.generation.get() == self.generation
            && match (&self.document, ui.active()) {
                (None, None) => true,
                (Some(old), Some(now)) => {
                    old.upgrade().is_some_and(|old| Rc::ptr_eq(&old, &now))
                        && !now.saving.get()
                        && self.revision == Some(now.revision.get())
                        && self.document_path == now.disk_path()
                }
                _ => false,
            }
            && match (&self.project, project_view::current_binding(ui)) {
                (None, None) => true,
                (Some(old), Some(now)) => old.is_current() && old.owner_id() == now.owner_id(),
                _ => false,
            }
    }
}
struct Loaded {
    repository: fastra_git::Repository,
    identity: (u64, u64),
    remotes: Vec<Vec<u8>>,
}
pub(super) struct State {
    ui: Weak<Ui>,
    window: gtk::Window,
    program: PathBuf,
    path: PathBuf,
    owner: Owner,
    basis: gtk::Label,
    choice: gtk::DropDown,
    prune: gtk::CheckButton,
    start: gtk::Button,
    cancel_button: gtk::Button,
    status: gtk::Label,
    output: gtk::TextView,
    loaded: RefCell<Option<Loaded>>,
    cancel: RefCell<fastra_git::Cancellation>,
    busy: Cell<bool>,
    handlers: RefCell<Vec<(glib::Object, glib::SignalHandlerId)>>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
        for (o, id) in self.handlers.get_mut().drain(..) {
            o.disconnect(id);
        }
    }
}
fn policy() -> fastra_git::Policy {
    fastra_git::Policy {
        stdout_bytes: 512 * 1024,
        stderr_bytes: 512 * 1024,
        timeout: Duration::from_secs(120),
        ..Default::default()
    }
}
fn visible(bytes: &[u8]) -> String {
    support::bytes(bytes).chars().flat_map(|c|if (c.is_control()&&!matches!(c,'\n'|'\t'))||matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}') {c.escape_default().collect::<Vec<_>>()}else{vec![c]}).collect()
}
fn failure(error: fastra_git::Error, lang: Language) -> String {
    visible(support::error(error, lang).as_bytes())
}
impl State {
    fn current(&self) -> bool {
        self.window.is_visible() && self.ui.upgrade().is_some_and(|ui| self.owner.current(&ui))
    }
    fn controls(&self) {
        let ready = self.current() && !self.busy.get() && self.loaded.borrow().is_some();
        self.start.set_sensitive(ready);
        self.choice.set_sensitive(ready);
        self.prune.set_sensitive(ready);
        self.cancel_button.set_sensitive(self.busy.get());
    }
    fn invalidate(&self) {
        self.cancel.borrow().cancel();
        self.loaded.borrow_mut().take();
        self.start.set_sensitive(false);
        self.choice.set_sensitive(false);
        self.prune.set_sensitive(false);
        self.status.set_text(self.lang().text(
            "Fenster, Dokument oder Projekt geändert. Fetch erneut öffnen.",
            "Window, document or project changed. Reopen Fetch.",
        ));
    }
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |u| u.lang)
    }
    fn load(self: &Rc<Self>) {
        self.busy.set(true);
        self.controls();
        let program = self.program.clone();
        let path = self.path.clone();
        let cancel = self.cancel.borrow().clone();
        let weak = Rc::downgrade(self);
        let lang = self.lang();
        // Die Projektidentität wird unmittelbar vor der Repository-Ermittlung geprüft.
        let project = self.owner.project.as_ref().map(|p| p.root.clone());
        support::background(
            move || {
                if let Some(project) = project {
                    project.validate()?;
                }
                let repository = fastra_git::Git::new(program)
                    .and_then(|git| git.discover(&path, policy(), &cancel))
                    .map_err(|e| failure(e, lang))?;
                let remotes = repository
                    .remotes(policy(), &cancel)
                    .map_err(|e| failure(e, lang))?;
                Ok((
                    Loaded {
                        identity: repository
                            .operation_identity()
                            .map_err(|e| failure(e, lang))?,
                        repository,
                        remotes: remotes.value,
                    },
                    remotes.output.stderr,
                ))
            },
            move |result| {
                let Some(s) = weak.upgrade() else { return };
                s.busy.set(false);
                if !s.current() {
                    s.invalidate();
                    return;
                }
                match result {
                    Ok((loaded, warning)) => {
                        s.basis.set_text(&format!(
                            "{}\n{}",
                            s.lang().text("Repository", "Repository"),
                            project_view::display(loaded.repository.root())
                        ));
                        let mut names =
                            vec![s.lang().text("Alle Remotes", "All remotes").to_owned()];
                        names.extend(loaded.remotes.iter().map(|r| visible(r)));
                        s.choice.set_model(Some(&gtk::StringList::new(
                            &names.iter().map(String::as_str).collect::<Vec<_>>(),
                        )));
                        s.choice.set_selected(0);
                        s.output.buffer().set_text(&visible(&warning));
                        if loaded.remotes.is_empty() {
                            s.status.set_text(
                                s.lang()
                                    .text("Kein Remote konfiguriert.", "No remote configured."),
                            );
                        } else {
                            s.status.set_text(s.lang().text(
                                "Quelle und Prune prüfen, dann abrufen.",
                                "Review source and prune, then fetch.",
                            ));
                            *s.loaded.borrow_mut() = Some(loaded);
                        }
                    }
                    Err(error) => {
                        s.status.set_text(s.lang().text(
                            "Remotes konnten nicht gelesen werden.",
                            "Could not read remotes.",
                        ));
                        s.output.buffer().set_text(&error);
                    }
                }
                s.controls();
            },
        );
    }
    fn start(self: &Rc<Self>) {
        if !self.current() || self.busy.get() {
            return;
        }
        let (repository, selection, expected_remotes, expected_identity) = {
            let loaded = self.loaded.borrow();
            let Some(loaded) = loaded.as_ref() else {
                return;
            };
            let selection = match self.choice.selected() {
                0 => fastra_git::FetchSelection::All,
                n => {
                    let Some(remote) = loaded.remotes.get(n as usize - 1) else {
                        return;
                    };
                    fastra_git::FetchSelection::Remote(remote.clone())
                }
            };
            (
                loaded.repository.clone(),
                selection,
                loaded.remotes.clone(),
                loaded.identity,
            )
        };
        let prune = self.prune.is_active();
        let cancel = fastra_git::Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy.set(true);
        self.controls();
        self.output.buffer().set_text("");
        self.status.set_text(self.lang().text(
            "Fetch läuft … Arbeitsdateien und Index bleiben unverändert.",
            "Fetching … Working files and index remain unchanged.",
        ));
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        let project = self.owner.project.as_ref().map(|p| p.root.clone());
        let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(64);
        let progress = Rc::new(RefCell::new(Vec::new()));
        let current = progress.clone();
        let progress_weak = weak.clone();
        glib::timeout_add_local(Duration::from_millis(30), move || {
            let Some(s) = progress_weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if !s.current() {
                s.invalidate();
                return glib::ControlFlow::Break;
            }
            let mut bytes = current.borrow_mut();
            let mut changed = false;
            for chunk in rx.try_iter() {
                bytes.extend_from_slice(&chunk);
                changed = true;
            }
            if changed && s.busy.get() {
                s.output.buffer().set_text(&visible(&bytes));
            }
            if s.busy.get() {
                glib::ControlFlow::Continue
            } else {
                glib::ControlFlow::Break
            }
        });
        support::background(
            move || {
                if let Some(project) = project {
                    project.validate()?;
                }
                let identity = repository
                    .operation_identity()
                    .map_err(|e| failure(e, lang))?;
                if identity != expected_identity {
                    return Err(failure(fastra_git::Error::StaleRepository, lang));
                }
                let all = matches!(selection, fastra_git::FetchSelection::All);
                let plan = repository
                    .prepare_fetch(selection, prune, policy(), &cancel)
                    .map_err(|e| failure(e, lang))?;
                if all && plan.remotes() != expected_remotes {
                    return Err(lang
                        .text(
                            "Konfigurierte Remotes geändert. Fetch erneut öffnen.",
                            "Configured remotes changed. Reopen Fetch.",
                        )
                        .into());
                }
                if repository
                    .operation_identity()
                    .map_err(|e| failure(e, lang))?
                    != expected_identity
                {
                    return Err(failure(fastra_git::Error::StaleRepository, lang));
                }
                let report = plan
                    .execute(policy(), &cancel, &mut |_, bytes| {
                        let _ = tx.try_send(bytes.to_vec());
                    })
                    .map_err(|e| failure(e, lang))?;
                let root = plan.root().to_owned();
                // Auch nach einem Teilfehler werden die aktuellen Tracking-Refs neu gelesen.
                let refresh_cancel = fastra_git::Cancellation::default();
                let status = repository
                    .status(policy(), &refresh_cancel)
                    .map_err(|e| failure(e, lang));
                let branches = repository
                    .branches(policy(), &refresh_cancel)
                    .map_err(|e| failure(e, lang));
                Ok((root, identity, report, status, branches))
            },
            move |result| {
                if let Ok((root, identity, _, _, _)) = &result {
                    refreshed(root, *identity);
                }
                let Some(s) = weak.upgrade() else { return };
                s.busy.set(false);
                s.controls();
                if !s.current() {
                    s.invalidate();
                    return;
                }
                match result {
                    Err(error) => {
                        s.output.buffer().set_text(&error);
                        s.status.set_text(s.lang().text(
                            "Fetch nicht gestartet oder beendet; Diagnose unten.",
                            "Fetch not started or ended; diagnostic below.",
                        ));
                    }
                    Ok((root, _, report, status, branches)) => {
                        let success = report.success();
                        let refresh_ok = status.is_ok() && branches.is_ok();
                        let mut text = String::new();
                        for remote in report.attempts {
                            text.push_str(&format!(
                                "{} {}\n",
                                s.lang().text("Remote:", "Remote:"),
                                visible(&remote.remote)
                            ));
                            match remote.result {
                                Ok(out) => {
                                    text.push_str(&format!(
                                        "{} 0\n{}{}",
                                        s.lang().text("Exit", "Exit"),
                                        visible(&out.stdout),
                                        visible(&out.stderr)
                                    ));
                                }
                                Err(e) => {
                                    text.push_str(&failure(e, s.lang()));
                                    text.push('\n');
                                }
                            }
                            text.push('\n');
                        }
                        if !report.remaining.is_empty() {
                            text.push_str(s.lang().text("Nicht mehr gestartet: ", "Not started: "));
                            text.push_str(
                                &report
                                    .remaining
                                    .iter()
                                    .map(|r| visible(r))
                                    .collect::<Vec<_>>()
                                    .join(", "),
                            );
                            text.push_str("\n\n");
                        }
                        match status {
                            Ok(status) => {
                                text.push_str(&format!(
                                    "{}\nBranch: {}\n↑{} ↓{}\n",
                                    s.lang().text("Aktueller Status", "Current status"),
                                    status.value.branch.as_deref().map(visible).unwrap_or_else(
                                        || s.lang().text("abgelöst", "detached").into()
                                    ),
                                    status.value.ahead,
                                    status.value.behind
                                ));
                                text.push_str(&visible(&status.output.stderr));
                            }
                            Err(e) => {
                                text.push_str(&e);
                                text.push('\n');
                            }
                        }
                        match branches {
                            Ok(branches) => {
                                text.push_str("\nBranches\n");
                                for branch in branches.value {
                                    text.push_str(&format!(
                                        "{} {}\n",
                                        visible(&branch.full_name),
                                        visible(&branch.oid)
                                    ));
                                }
                                text.push_str(&visible(&branches.output.stderr));
                            }
                            Err(e) => {
                                text.push_str(&e);
                                text.push('\n');
                            }
                        }
                        s.output.buffer().set_text(&text);
                        s.status.set_text(if success && refresh_ok {
                            s.lang().text("Fetch abgeschlossen. Status und Branches aktualisiert.", "Fetch completed. Status and branches refreshed.")
                        } else if success {
                            s.lang().text("Fetch abgeschlossen; Status oder Branches konnten nicht aktualisiert werden. Diagnose unten.", "Fetch completed; status or branches could not be refreshed. See the diagnostic below.")
                        } else {
                            s.lang().text("Fetch unvollständig. Ergebnisse jedes Remotes und verbleibende Quellen prüfen.", "Fetch incomplete. Review each remote result and remaining sources.")
                        });
                        let _ = root;
                    }
                }
            },
        );
    }
}
pub(super) fn open(ui: &Rc<Ui>, program: PathBuf, path: PathBuf) -> Rc<State> {
    let lang = ui.lang;
    let window = support::window(ui, lang.text("Git · Abrufen", "Git · Fetch"), false);
    window.set_default_size(760, 640);
    let root = support::column();
    root.append(&support::label(lang.text("Fetch aktualisiert Remote-Tracking-Refs. Arbeitsdateien, Index und aktueller Branch bleiben unverändert.","Fetch updates remote-tracking refs. Working files, index and current branch remain unchanged.")));
    let basis = support::label(&project_view::display(&path));
    basis.set_selectable(true);
    root.append(&basis);
    let choice = support::file_dropdown();
    choice.set_tooltip_text(Some(lang.text(
        "Konfigurierten Remote oder alle Remotes wählen",
        "Choose a configured remote or all remotes",
    )));
    root.append(&support::label(lang.text("Quelle", "Source")));
    root.append(&choice);
    let prune = gtk::CheckButton::with_label(lang.text(
        "Veraltete Remote-Tracking-Refs entfernen (Prune)",
        "Remove stale remote-tracking refs (prune)",
    ));
    prune.set_active(true);
    root.append(&prune);
    let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let start = gtk::Button::with_label(lang.text("Abrufen", "Fetch"));
    start.add_css_class("suggested-action");
    let cancel_button = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    line.append(&start);
    line.append(&cancel_button);
    root.append(&line);
    let status = support::label(lang.text(
        "Konfigurierte Remotes werden gelesen …",
        "Reading configured remotes …",
    ));
    root.append(&status);
    let output = support::output();
    root.append(&support::scroll(&output));
    window.set_child(Some(&root));
    let s = Rc::new(State {
        ui: Rc::downgrade(ui),
        window: window.clone(),
        program,
        path,
        owner: Owner::capture(ui),
        basis,
        choice,
        prune,
        start,
        cancel_button,
        status,
        output,
        loaded: RefCell::new(None),
        cancel: RefCell::new(Default::default()),
        busy: Cell::new(false),
        handlers: RefCell::new(Vec::new()),
    });
    let weak = Rc::downgrade(&s);
    s.start.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.start();
        }
    });
    let weak = Rc::downgrade(&s);
    s.cancel_button.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.cancel.borrow().cancel();
        }
    });
    let weak = Rc::downgrade(&s);
    let id = ui.tabs.connect_switch_page(move |_, _, _| {
        if let Some(s) = weak.upgrade() {
            s.invalidate();
        }
    });
    s.handlers.borrow_mut().push((ui.tabs.clone().upcast(), id));
    let weak = Rc::downgrade(&s);
    let id = ui.window.connect_visible_notify(move |_| {
        if let Some(s) = weak.upgrade() {
            if !s.current() {
                s.invalidate();
            }
        }
    });
    s.handlers
        .borrow_mut()
        .push((ui.window.clone().upcast(), id));
    if let Some(doc) = ui.active() {
        let weak = Rc::downgrade(&s);
        let id = doc.buffer.connect_changed(move |_| {
            if let Some(s) = weak.upgrade() {
                s.invalidate();
            }
        });
        s.handlers
            .borrow_mut()
            .push((doc.buffer.clone().upcast(), id));
    }
    let weak = Rc::downgrade(&s);
    glib::timeout_add_local(Duration::from_millis(30), move || {
        let Some(s) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if !s.current() {
            s.invalidate();
            return glib::ControlFlow::Break;
        }
        glib::ControlFlow::Continue
    });
    DIALOGS.with_borrow_mut(|all| {
        all.retain(|s| s.strong_count() > 0);
        all.push(Rc::downgrade(&s));
    });
    support::hold(&window, s.clone(), |s| s.cancel.borrow().cancel());
    window.present();
    s.load();
    s
}
#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
