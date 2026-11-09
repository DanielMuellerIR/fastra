//! Manueller Push: Netzwerkprüfung und Freigabe sind getrennte sichtbare Schritte.
use super::{git_fetch, git_view as support, project_view, Language, Ui};
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::{Rc, Weak},
    sync::mpsc,
    time::Duration,
};
thread_local! { static DIALOGS: RefCell<Vec<Weak<State>>> = const { RefCell::new(Vec::new()) }; }
pub(super) fn invalidate_owner(ui: &Ui) {
    DIALOGS.with_borrow_mut(|all| {
        all.retain(|weak| {
            let Some(s) = weak.upgrade() else {
                return false;
            };
            if s.ui
                .upgrade()
                .is_some_and(|owner| std::ptr::eq(owner.as_ref(), ui))
            {
                s.invalidate();
            }
            true
        })
    });
}
struct Owner {
    document: Option<Weak<super::Document>>,
    generation: u64,
    revision: Option<u64>,
    document_path: Option<PathBuf>,
    project: Option<project_view::Binding>,
}
impl Owner {
    fn capture(ui: &Rc<Ui>) -> Self {
        Self {
            document: ui.active().map(|d| Rc::downgrade(&d)),
            generation: ui.generation.get(),
            revision: ui.active().map(|d| d.revision.get()),
            document_path: ui.active().and_then(|d| d.disk_path()),
            project: project_view::current_binding(ui),
        }
    }
    fn current(&self, ui: &Rc<Ui>) -> bool {
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
    targets: Vec<(Vec<u8>, Result<fastra_git::PushTarget, String>)>,
}
pub(super) struct State {
    ui: Weak<Ui>,
    window: gtk::Window,
    program: PathBuf,
    path: PathBuf,
    owner: Owner,
    basis: gtk::Label,
    choice: gtk::DropDown,
    force_mode: gtk::CheckButton,
    inspect: gtk::Button,
    apply: gtk::Button,
    cancel_button: gtk::Button,
    status: gtk::Label,
    output: gtk::TextView,
    loaded: RefCell<Option<Loaded>>,
    preview: RefCell<Option<fastra_git::PushPreview>>,
    cancel: RefCell<fastra_git::Cancellation>,
    busy: Cell<bool>,
    confirming: Cell<bool>,
    epoch: Cell<u64>,
    warning: RefCell<Option<gio::Cancellable>>,
    valid: Cell<bool>,
    handlers: RefCell<Vec<(glib::Object, glib::SignalHandlerId)>>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.cancel.borrow().cancel();
        if let Some(warning) = self.warning.get_mut().take() {
            warning.cancel();
        }
        for (object, id) in self.handlers.get_mut().drain(..) {
            object.disconnect(id);
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
    support::bytes(bytes).chars().flat_map(|c| if (c.is_control() && !matches!(c,'\n'|'\t')) || matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}') { c.escape_default().collect::<Vec<_>>() } else { vec![c] }).collect()
}
fn failure(error: fastra_git::Error, lang: Language) -> String {
    use fastra_git::Error;
    let message = match &error {
        Error::StaleRepository | Error::StalePreview => Some(lang.text("Repository, Branch, Commits oder Push-Ziel geändert. Vorschau neu laden.", "Repository, branch, commits or push target changed. Reload the preview.")),
        Error::InvalidInput("Push requires exactly one address per remote") => Some(lang.text("Ein Remote besitzt mehrere oder keine eindeutige Push-Adresse. Konfiguriere genau eine Adresse je Remote und öffne Push erneut.", "A remote has multiple or no unambiguous push addresses. Configure exactly one address per remote and reopen Push.")),
        Error::InvalidInput("Git URL rewrite rules prevent an unambiguous push target") => Some(lang.text("Git-URL-Umschreibregeln verhindern ein eindeutiges Push-Ziel. Entferne insteadOf/pushInsteadOf oder verwende bewusst das Terminal.", "Git URL rewrite rules prevent an unambiguous push target. Remove insteadOf/pushInsteadOf or deliberately use the terminal.")),
        Error::InvalidInput("push requires a local branch") => Some(lang.text("Push braucht einen lokalen Branch mit Commit. Wähle einen Branch und lade die Vorschau erneut.", "Push requires a local branch with a commit. Choose a branch and reload the preview.")),
        Error::InvalidInput("normal push requires new commits and a fast-forward") => Some(lang.text("Normaler Push nicht möglich: Es gibt keine neuen Commits oder die Historien divergieren.", "Normal push unavailable: there are no new commits or the histories diverge.")),
        Error::InvalidInput("force push requires complete non-shallow history") => Some(lang.text("Force Push braucht eine vollständige Historie. Vervollständige zuerst das flache Repository und lade die Vorschau erneut.", "Force Push requires complete history. Unshallow the repository first and reload the preview.")),
        Error::InvalidInput("force push requires an existing different target commit") => Some(lang.text("Force Push braucht einen vorhandenen Zielbranch mit anderem Commit. Verwende für einen neuen Branch den normalen Push.", "Force Push requires an existing target branch at a different commit. Use normal Push for a new branch.")),
        Error::InvalidInput("another repository operation is running") => Some(lang.text("Ein anderer Git-Auftrag für dieses Repository läuft noch. Warte auf seinen Abschluss.", "Another Git operation for this repository is still running. Wait for it to finish.")),
        _ => None,
    };
    message.map_or_else(
        || visible(support::error(error, lang).as_bytes()),
        str::to_owned,
    )
}
impl State {
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |u| u.lang)
    }
    fn current(&self) -> bool {
        self.valid.get()
            && self.window.is_visible()
            && self.ui.upgrade().is_some_and(|u| self.owner.current(&u))
    }
    fn controls(&self) {
        let ready = self.current()
            && !self.busy.get()
            && !self.confirming.get()
            && self.loaded.borrow().is_some();
        self.choice.set_sensitive(ready);
        self.force_mode.set_sensitive(ready);
        self.apply.set_label(if self.force_mode.is_active() {
            self.lang()
                .text("Mit Lease erzwingen …", "Force with lease …")
        } else {
            self.lang().text("Push ausführen", "Execute push")
        });
        self.inspect.set_sensitive(
            ready
                && self.loaded.borrow().as_ref().is_some_and(|l| {
                    l.targets
                        .get(self.choice.selected() as usize)
                        .is_some_and(|(_, t)| t.is_ok())
                }),
        );
        self.apply
            .set_sensitive(ready && self.preview.borrow().as_ref().is_some_and(|p| p.can_push()));
        self.cancel_button
            .set_sensitive(self.busy.get() || self.confirming.get());
    }
    fn revoke_warning(&self) {
        self.epoch.set(self.epoch.get().wrapping_add(1));
        self.confirming.set(false);
        let warning = self.warning.borrow_mut().take();
        if let Some(warning) = warning {
            warning.cancel();
        }
    }
    fn input_changed(&self) {
        self.revoke_warning();
        self.cancel.borrow().cancel();
        self.preview.borrow_mut().take();
        self.output.buffer().set_text("");
        self.status.set_text(self.lang().text(
            "Modus oder Ziel geändert. Vorschau neu laden.",
            "Mode or target changed. Reload the preview.",
        ));
        self.controls();
    }
    fn invalidate(&self) {
        self.valid.set(false);
        self.revoke_warning();
        self.cancel.borrow().cancel();
        self.preview.borrow_mut().take();
        self.loaded.borrow_mut().take();
        self.controls();
        self.status.set_text(self.lang().text(
            "Fenster, Dokument oder Projekt geändert. Push erneut öffnen.",
            "Window, document or project changed. Reopen Push.",
        ));
    }
    fn load(self: &Rc<Self>) {
        self.busy.set(true);
        self.controls();
        let program = self.program.clone();
        let path = self.path.clone();
        let cancel = self.cancel.borrow().clone();
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        let project = self.owner.project.as_ref().map(|p| p.root.clone());
        support::background(
            move || {
                if let Some(project) = project {
                    project.validate()?;
                }
                let repository = fastra_git::Git::new(program)
                    .and_then(|g| g.discover(&path, policy(), &cancel))
                    .map_err(|e| failure(e, lang))?;
                let identity = repository
                    .operation_identity()
                    .map_err(|e| failure(e, lang))?;
                let started = std::time::Instant::now();
                let mut targets = Vec::new();
                for remote in repository
                    .remotes(policy(), &cancel)
                    .map_err(|e| failure(e, lang))?
                    .value
                {
                    let remaining = policy().timeout.saturating_sub(started.elapsed());
                    if remaining.is_zero() {
                        return Err(failure(
                            fastra_git::Error::TimedOut(fastra_git::GitOutput::empty()),
                            lang,
                        ));
                    }
                    let result = repository
                        .push_target(
                            &remote,
                            fastra_git::Policy {
                                timeout: remaining,
                                ..policy()
                            },
                            &cancel,
                        )
                        .map_err(|e| failure(e, lang));
                    targets.push((remote, result));
                }
                Ok(Loaded {
                    repository,
                    identity,
                    targets,
                })
            },
            move |result| {
                let Some(s) = weak.upgrade() else { return };
                s.busy.set(false);
                if !s.current() {
                    s.invalidate();
                    return;
                }
                match result {
                    Ok(loaded) => {
                        s.basis.set_text(&format!(
                            "Repository\n{}",
                            project_view::display(loaded.repository.root())
                        ));
                        let names = loaded
                            .targets
                            .iter()
                            .map(|(name, _)| visible(name))
                            .collect::<Vec<_>>();
                        s.choice.set_model(Some(&gtk::StringList::new(
                            &names.iter().map(String::as_str).collect::<Vec<_>>(),
                        )));
                        s.choice.set_selected(0);
                        if loaded.targets.is_empty() {
                            s.status.set_text(
                                s.lang()
                                    .text("Kein Remote konfiguriert.", "No remote configured."),
                            );
                        } else {
                            s.status.set_text(s.lang().text(
                                "Ziel wählen. Erst „Vorschau laden“ kontaktiert den Remote.",
                                "Choose a target. Only “Load preview” contacts the remote.",
                            ));
                            if let Some((_, Err(diagnostic))) = loaded.targets.first() {
                                s.output.buffer().set_text(diagnostic);
                            }
                            *s.loaded.borrow_mut() = Some(loaded);
                        }
                    }
                    Err(e) => {
                        s.status.set_text(s.lang().text(
                            "Push-Ziele konnten nicht gelesen werden.",
                            "Could not read push targets.",
                        ));
                        s.output.buffer().set_text(&e);
                    }
                }
                s.controls();
            },
        );
    }
    fn progress(self: &Rc<Self>, rx: mpsc::Receiver<Vec<u8>>) {
        let weak = Rc::downgrade(self);
        let mut bytes = Vec::new();
        glib::timeout_add_local(Duration::from_millis(30), move || {
            let Some(s) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if !s.current() {
                s.invalidate();
                return glib::ControlFlow::Break;
            }
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
    }
    fn inspect(self: &Rc<Self>) {
        if !self.current() || self.busy.get() || self.confirming.get() {
            return;
        }
        let (repository, target, identity) = {
            let loaded = self.loaded.borrow();
            let Some(loaded) = loaded.as_ref() else {
                return;
            };
            let Some((_, Ok(target))) = loaded.targets.get(self.choice.selected() as usize) else {
                return;
            };
            (loaded.repository.clone(), target.clone(), loaded.identity)
        };
        self.preview.borrow_mut().take();
        let force = self.force_mode.is_active();
        let epoch = self.epoch.get();
        let cancel = fastra_git::Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy.set(true);
        self.controls();
        self.output.buffer().set_text("");
        self.status.set_text(self.lang().text(
            "Remote-Stand und Commits werden geprüft …",
            "Checking remote state and commits …",
        ));
        let (tx, rx) = mpsc::sync_channel(64);
        self.progress(rx);
        let weak = Rc::downgrade(self);
        let lang = self.lang();
        let project = self.owner.project.as_ref().map(|p| p.root.clone());
        support::background(
            move || {
                if let Some(project) = project {
                    project.validate()?;
                }
                if repository
                    .operation_identity()
                    .map_err(|e| failure(e, lang))?
                    != identity
                {
                    return Err(failure(fastra_git::Error::StaleRepository, lang));
                }
                let mut observer = |b: &[u8]| {
                    let _ = tx.try_send(b.to_vec());
                };
                (if force {
                    repository.prepare_force_push(&target, policy(), &cancel, &mut observer)
                } else {
                    repository.prepare_push(&target, policy(), &cancel, &mut observer)
                })
                .map_err(|e| failure(e, lang))
            },
            move |result| {
                let Some(s) = weak.upgrade() else { return };
                s.busy.set(false);
                if !s.current() {
                    s.invalidate();
                    return;
                }
                if s.epoch.get() != epoch {
                    s.controls();
                    return;
                }
                match result {
                    Ok(preview) => {
                        let old = preview.remote_oid().map(visible).unwrap_or_else(|| {
                            s.lang()
                                .text(
                                    "nicht vorhanden (wird angelegt)",
                                    "absent (will be created)",
                                )
                                .into()
                        });
                        let text = format!(
                            "{}: {}\n{}: {}\n{}: {}\n{}: {}\n{}: {}\n\n↑ {}  ↓ {}\n\n{}\n{}",
                            s.lang().text("Remote", "Remote"),
                            visible(preview.target().remote()),
                            s.lang().text("Adresse", "Address"),
                            visible(preview.target().address_display().as_bytes()),
                            s.lang().text("Zielref", "Target ref"),
                            visible(preview.remote_ref()),
                            s.lang().text("Quell-Commit", "Source commit"),
                            visible(preview.source_oid()),
                            s.lang()
                                .text("Erwarteter Remote-Commit", "Expected remote commit"),
                            old,
                            preview.ahead(),
                            preview.behind(),
                            s.lang().text(
                                "Zu übertragende Commits (vollständig):",
                                "Commits to transfer (complete):"
                            ),
                            visible(&preview.commits().stdout)
                        );
                        let text = if preview.force_with_lease() {
                            format!("{}\n\n{}\n\n{}\n{}", s.lang().text("FORCE PUSH MIT EXAKTER LEASE", "FORCE PUSH WITH EXACT LEASE"), text,
                                s.lang().text("Danach nicht mehr über diesen Zielbranch erreichbare Commits (vollständig; keine globale Objektlöschung):", "Commits no longer reachable through this target branch afterward (complete; no global object deletion):"),
                                visible(&preview.removed_commits().stdout))
                        } else {
                            text
                        };
                        s.output.buffer().set_text(&text);
                        s.status.set_text(if preview.force_with_lease() { s.lang().text("Beide Commitlisten prüfen. Erzwingen benötigt eine zusätzliche Bestätigung für genau diese Vorschau.", "Review both commit lists. Forcing requires an additional confirmation for exactly this preview.") } else if preview.can_push(){s.lang().text("Vorschau prüfen. „Push ausführen“ überträgt genau diesen Stand.","Review the preview. “Execute push” sends exactly this state.")}else if preview.behind()>0{s.lang().text("Normaler Push nicht möglich: Historien divergieren. Der getrennte Force-Modus benötigt eine neue Vorschau.","Normal push unavailable: histories diverge. Use the separate Force mode only after reviewing a fresh preview.")}else{s.lang().text("Keine neuen Commits für dieses Ziel.","No new commits for this target.")});
                        *s.preview.borrow_mut() = Some(preview);
                    }
                    Err(e) => {
                        s.output.buffer().set_text(&e);
                        s.status.set_text(s.lang().text(
                            "Vorschau fehlgeschlagen. Diagnose unten.",
                            "Preview failed. See diagnostic below.",
                        ));
                    }
                }
                s.controls();
            },
        );
    }
    fn apply(self: &Rc<Self>) {
        if !self.current() || self.busy.get() || self.confirming.get() {
            return;
        }
        let Some(preview) = self.preview.borrow_mut().take() else {
            return;
        };
        if !preview.can_push() || preview.force_with_lease() != self.force_mode.is_active() {
            return;
        }
        if !preview.force_with_lease() {
            self.execute(preview);
            return;
        }
        self.confirming.set(true);
        let epoch = self.epoch.get();
        let cancellable = gio::Cancellable::new();
        *self.warning.borrow_mut() = Some(cancellable.clone());
        self.controls();
        let lang = self.lang();
        let detail = format!("{}: {}\n{}: {}\n{}: {}\n{}: {}\n{}: {}\n\n{}", lang.text("Remote", "Remote"), visible(preview.target().remote()),
            lang.text("Adresse", "Address"), visible(preview.target().address_display().as_bytes()),
            lang.text("Zielref", "Target ref"), visible(preview.remote_ref()),
            lang.text("Alt", "Old"), visible(preview.remote_oid().unwrap_or_default()),
            lang.text("Neu", "New"), visible(preview.source_oid()),
            lang.text("Nur wenn das Ziel noch exakt Alt entspricht. Commits können über diesen Branch unerreichbar werden. Ein Abbruch macht ein bereits übernommenes Update nicht rückgängig.", "Only if the target still equals Old exactly. Commits may become unreachable through this branch. Cancelling does not undo an update already accepted."));
        let dialog = gtk::AlertDialog::builder()
            .message(lang.text(
                "Force Push mit Lease ausführen?",
                "Execute Force Push with Lease?",
            ))
            .detail(&detail)
            .modal(true)
            .buttons([
                lang.text("Abbrechen", "Cancel"),
                lang.text("Mit Lease erzwingen", "Force with lease"),
            ])
            .cancel_button(0)
            .default_button(0)
            .build();
        let weak = Rc::downgrade(self);
        dialog.choose(Some(&self.window), Some(&cancellable), move |result| {
            let Some(s) = weak.upgrade() else {
                return;
            };
            if s.epoch.get() != epoch {
                return;
            }
            s.warning.borrow_mut().take();
            s.confirming.set(false);
            if result == Ok(1) && s.current() && s.force_mode.is_active() {
                s.execute(preview);
            } else {
                s.status.set_text(lang.text(
                    "Freigabe verbraucht. Für einen neuen Versuch Vorschau neu laden.",
                    "Approval consumed. Reload the preview before another attempt.",
                ));
                s.controls();
            }
        });
    }
    fn execute(self: &Rc<Self>, preview: fastra_git::PushPreview) {
        if !self.current()
            || self.busy.get()
            || preview.force_with_lease() != self.force_mode.is_active()
        {
            return;
        }
        let Some(identity) = self.loaded.borrow().as_ref().map(|l| l.identity) else {
            return;
        };
        let cancel = fastra_git::Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy.set(true);
        self.controls();
        self.status
            .set_text(self.lang().text("Push läuft …", "Pushing …"));
        let (tx, rx) = mpsc::sync_channel(64);
        self.progress(rx);
        let weak = Rc::downgrade(self);
        let lang = self.lang();
        let project = self.owner.project.as_ref().map(|p| p.root.clone());
        support::background(
            move || {
                if let Some(project) = project {
                    project.validate()?;
                }
                let root = preview.root().to_owned();
                let result = preview.execute(policy(), &cancel, &mut |b| {
                    let _ = tx.try_send(b.to_vec());
                });
                Ok((root, identity, result))
            },
            move |result| {
                if let Ok((root, identity, _)) = &result {
                    git_fetch::refreshed(root, *identity);
                }
                let Some(s) = weak.upgrade() else { return };
                s.busy.set(false);
                if !s.current() {
                    s.invalidate();
                    return;
                }
                match result {
                    Ok((_, _, result)) => {
                        match result {
                            Ok(out) => {
                                s.output.buffer().set_text(&format!(
                                    "{} 0\n{}{}",
                                    lang.text("Exit", "Exit"),
                                    visible(&out.stdout),
                                    visible(&out.stderr)
                                ));
                                s.status.set_text(lang.text("Push abgeschlossen. Für einen weiteren Push Vorschau neu laden.","Push completed. Reload the preview before another push."));
                            }
                            Err(e) => {
                                s.output.buffer().set_text(&failure(e, lang));
                                s.status.set_text(lang.text("Push fehlgeschlagen oder abgebrochen. Remote kann bereits geändert sein; Vorschau neu laden.","Push failed or was cancelled. Remote may already have changed; reload the preview."));
                            }
                        }
                    }
                    Err(e) => {
                        s.output.buffer().set_text(&e);
                        s.status.set_text(lang.text(
                            "Push nicht gestartet. Diagnose unten.",
                            "Push not started. See diagnostic below.",
                        ));
                    }
                }
                s.controls();
            },
        );
    }
}
pub(super) fn open(ui: &Rc<Ui>, program: PathBuf, path: PathBuf) -> Rc<State> {
    let lang = ui.lang;
    let window = support::window(ui, lang.text("Git · Push", "Git · Push"), false);
    window.set_default_size(800, 700);
    let root = support::column();
    root.append(&support::label(lang.text("Push überträgt lokale Commits. Wähle ein konfiguriertes Ziel, lade die vollständige Vorschau und gib die Übertragung danach ausdrücklich frei.","Push sends local commits. Choose a configured target, load the complete preview, then explicitly approve the transfer.")));
    let basis = support::label(&project_view::display(&path));
    basis.set_selectable(true);
    root.append(&basis);
    root.append(&support::label(lang.text("Ziel-Remote", "Target remote")));
    let choice = support::file_dropdown();
    root.append(&choice);
    let force_mode = gtk::CheckButton::with_label(lang.text(
        "Force Push mit exakter Lease (Historie des Zielbranches ändern)",
        "Force Push with exact lease (change target branch history)",
    ));
    force_mode.set_active(false);
    root.append(&force_mode);
    let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let inspect = gtk::Button::with_label(lang.text("Vorschau laden", "Load preview"));
    let apply = gtk::Button::with_label(lang.text("Push ausführen", "Execute push"));
    apply.add_css_class("suggested-action");
    let cancel_button = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    line.append(&inspect);
    line.append(&apply);
    line.append(&cancel_button);
    root.append(&line);
    let status = support::label(lang.text("Push-Ziele werden gelesen …", "Reading push targets …"));
    root.append(&status);
    let output = support::output();
    output.set_wrap_mode(gtk::WrapMode::WordChar);
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
        force_mode,
        inspect,
        apply,
        cancel_button,
        status,
        output,
        loaded: RefCell::new(None),
        preview: RefCell::new(None),
        cancel: RefCell::new(Default::default()),
        busy: Cell::new(false),
        confirming: Cell::new(false),
        epoch: Cell::new(0),
        warning: RefCell::new(None),
        valid: Cell::new(true),
        handlers: RefCell::new(Vec::new()),
    });
    let weak = Rc::downgrade(&s);
    s.inspect.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.inspect();
        }
    });
    let weak = Rc::downgrade(&s);
    s.apply.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.apply();
        }
    });
    let weak = Rc::downgrade(&s);
    s.cancel_button.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.cancel.borrow().cancel();
            if s.confirming.get() {
                s.revoke_warning();
                s.controls();
            }
        }
    });
    let weak = Rc::downgrade(&s);
    s.force_mode.connect_toggled(move |_| {
        if let Some(s) = weak.upgrade() {
            s.input_changed();
        }
    });
    let weak = Rc::downgrade(&s);
    s.choice.connect_selected_notify(move |_| {
        if let Some(s) = weak.upgrade() {
            s.input_changed();
            let loaded = s.loaded.borrow();
            let diagnostic = loaded
                .as_ref()
                .and_then(|l| l.targets.get(s.choice.selected() as usize))
                .and_then(|(_, t)| t.as_ref().err())
                .cloned()
                .unwrap_or_default();
            s.output.buffer().set_text(&diagnostic);
            s.controls();
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
    support::hold(&window, s.clone(), |s| {
        s.cancel.borrow().cancel();
        s.revoke_warning();
    });
    window.present();
    s.load();
    s
}
#[cfg(debug_assertions)]
mod force_gui_test;
#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_GIT_FORCE_PUSH_SELFTEST").is_some() {
        force_gui_test::run(ui);
    } else {
        gui_test::run(ui);
    }
}
