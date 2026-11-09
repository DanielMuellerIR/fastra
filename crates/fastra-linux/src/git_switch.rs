//! Expliziter normaler Branchwechsel; Editorpuffer bleiben bis zum geschützten Reload erhalten.
use super::{git_fetch, git_view as support, project_view, watch, Language, Ui};
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::{Rc, Weak},
    sync::mpsc,
    time::Duration,
};
thread_local! {static DIALOGS:RefCell<Vec<Weak<State>>>=const{RefCell::new(Vec::new())};}
pub(super) fn invalidate_owner(ui: &Ui) {
    DIALOGS.with_borrow_mut(|all| {
        all.retain(|w| {
            let Some(s) = w.upgrade() else {
                return false;
            };
            if s.ui.upgrade().is_some_and(|u| std::ptr::eq(u.as_ref(), ui)) {
                s.owner_changed();
            }
            true
        })
    });
}
struct Loaded {
    repository: fastra_git::Repository,
    identity: (u64, u64),
}
pub(super) struct State {
    ui: Weak<Ui>,
    window: gtk::Window,
    program: PathBuf,
    path: PathBuf,
    owner: RefCell<Option<git_fetch::Owner>>,
    loaded: RefCell<Option<Loaded>>,
    basis: gtk::Label,
    target: gtk::DropDown,
    targets: RefCell<Vec<Vec<u8>>>,
    changing: Cell<bool>,
    reload: gtk::Button,
    prepare: gtk::Button,
    approved: gtk::CheckButton,
    start: gtk::Button,
    cancel: gtk::Button,
    status: gtk::Label,
    output: gtk::TextView,
    preview: RefCell<Option<fastra_git::SwitchPreview>>,
    cancellation: RefCell<fastra_git::Cancellation>,
    generation: Cell<u64>,
    job: Cell<Option<u64>>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.cancellation.get_mut().cancel();
    }
}
fn policy() -> fastra_git::Policy {
    fastra_git::Policy {
        stdout_bytes: 4 * 1024 * 1024,
        stderr_bytes: 128 * 1024,
        timeout: Duration::from_secs(30),
        ..Default::default()
    }
}
fn visible(bytes: &[u8]) -> String {
    support::bytes(bytes).chars().flat_map(|c|if(c.is_control()&&!matches!(c,'\n'|'\t'))||matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}'){c.escape_default().collect::<Vec<_>>()}else{vec![c]}).collect()
}
fn error(e: fastra_git::Error, lang: Language) -> String {
    visible(support::error(e, lang).as_bytes())
}
fn output(out: &fastra_git::GitOutput) -> String {
    format!("{}{}", visible(&out.stdout), visible(&out.stderr))
}
fn state_text(state: &fastra_git::SwitchState, lang: Language) -> String {
    format!(
        "HEAD · {}\n{}\n\n{}\n{}\n\n{}\n{}\n\n{}\n{}",
        state
            .status
            .value
            .branch
            .as_deref()
            .map(visible)
            .unwrap_or_else(|| lang.text("Losgelöst", "Detached").into()),
        state
            .status
            .value
            .head_oid
            .as_deref()
            .map(visible)
            .unwrap_or_else(|| "—".into()),
        lang.text("Status (Git Porcelain)", "Status (Git porcelain)"),
        state
            .status
            .output
            .stdout
            .split(|b| *b == 0)
            .map(visible)
            .collect::<Vec<_>>()
            .join("\n"),
        lang.text("Index gegen HEAD", "Index against HEAD"),
        output(&state.staged),
        lang.text("Arbeitsdateien gegen Index", "Working files against index"),
        output(&state.working)
    )
}
impl State {
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |u| u.lang)
    }
    fn owned(&self) -> bool {
        self.window.is_visible()
            && self
                .ui
                .upgrade()
                .is_some_and(|u| self.owner.borrow().as_ref().is_some_and(|o| o.current(&u)))
    }
    fn controls(&self) {
        let busy = self.job.get().is_some();
        let ready = !busy && self.owned() && self.loaded.borrow().is_some();
        self.reload.set_sensitive(!busy);
        self.target.set_sensitive(ready);
        self.prepare.set_sensitive(
            ready
                && self
                    .targets
                    .borrow()
                    .get(self.target.selected() as usize)
                    .is_some(),
        );
        self.approved
            .set_sensitive(ready && self.preview.borrow().is_some());
        self.start
            .set_sensitive(ready && self.preview.borrow().is_some() && self.approved.is_active());
        self.cancel.set_sensitive(busy);
    }
    fn invalidate(&self, message: &str) {
        self.cancellation.borrow().cancel();
        self.generation.set(self.generation.get().wrapping_add(1));
        self.preview.borrow_mut().take();
        self.approved.set_active(false);
        self.output.buffer().set_text("");
        self.status.set_text(message);
        self.controls();
    }
    fn owner_changed(&self) {
        if self.owner.borrow_mut().take().is_some() {
            self.loaded.borrow_mut().take();
            self.invalidate(self.lang().text(
                "Fenster, Dokument oder Projekt geändert. Neu laden.",
                "Window, document or project changed. Reload.",
            ));
        }
    }
    fn begin(&self, message: &str) -> (u64, fastra_git::Cancellation) {
        self.invalidate(message);
        let c = fastra_git::Cancellation::default();
        *self.cancellation.borrow_mut() = c.clone();
        let id = self.generation.get();
        self.job.set(Some(id));
        self.controls();
        (id, c)
    }
    fn finished(&self, id: u64) -> bool {
        if self.job.get() == Some(id) {
            self.job.set(None);
        }
        self.controls();
        self.generation.get() == id && self.owned()
    }
    fn project(&self) -> Option<project_view::RootBinding> {
        self.owner
            .borrow()
            .as_ref()
            .and_then(git_fetch::Owner::project_root)
    }
    fn catalogue(&self, catalogue: fastra_git::LocalBranches) {
        self.changing.set(true);
        let mut labels = Vec::new();
        let mut targets = Vec::new();
        for b in catalogue.branches {
            if b.current {
                continue;
            }
            labels.push(format!(
                "{} · {}{}",
                visible(b.full_name.strip_prefix(b"refs/heads/").unwrap()),
                visible(&b.oid),
                if b.worktree_path.is_empty() {
                    String::new()
                } else {
                    format!(
                        " · {}",
                        self.lang().text("anderer Worktree", "other worktree")
                    )
                }
            ));
            targets.push(b.full_name);
        }
        self.target.set_model(Some(&gtk::StringList::new(
            &labels.iter().map(String::as_str).collect::<Vec<_>>(),
        )));
        *self.targets.borrow_mut() = targets;
        self.target.set_selected(if labels.is_empty() {
            gtk::INVALID_LIST_POSITION
        } else {
            0
        });
        self.changing.set(false);
    }
    fn load(self: &Rc<Self>) {
        if self.job.get().is_some() {
            return;
        }
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let owner = git_fetch::Owner::capture(&ui);
        if !owner.current(&ui) {
            return;
        }
        *self.owner.borrow_mut() = Some(owner);
        self.loaded.borrow_mut().take();
        let project = self.project();
        let (id, c) = self.begin(self.lang().text(
            "Lokale Branches werden gelesen …",
            "Reading local branches …",
        ));
        let path = self.path.clone();
        let program = self.program.clone();
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                if let Some(p) = project {
                    p.validate()?;
                }
                let r = fastra_git::Git::new(program)
                    .and_then(|g| g.discover(&path, policy(), &c))
                    .map_err(|e| error(e, lang))?;
                let identity = r.operation_identity().map_err(|e| error(e, lang))?;
                let cat = r.local_branches(policy(), &c).map_err(|e| error(e, lang))?;
                Ok((
                    Loaded {
                        repository: r,
                        identity,
                    },
                    cat,
                ))
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if !s.finished(id) {
                    return;
                }
                match result {
                    Ok((loaded, cat)) => {
                        s.basis.set_text(&format!(
                            "Repository\n{}",
                            project_view::display(loaded.repository.root())
                        ));
                        s.catalogue(cat.value);
                        *s.loaded.borrow_mut() = Some(loaded);
                        s.status.set_text(s.lang().text(
                            "Lokalen Zielbranch wählen und Vorschau erstellen.",
                            "Choose a local target branch and prepare a preview.",
                        ));
                    }
                    Err(e) => s.output.buffer().set_text(&e),
                }
                s.controls();
            },
        );
    }
    fn prepare(self: &Rc<Self>) {
        if !self.owned() || self.job.get().is_some() {
            return;
        }
        let Some(target) = self
            .targets
            .borrow()
            .get(self.target.selected() as usize)
            .cloned()
        else {
            return;
        };
        let Some((r, identity)) = self
            .loaded
            .borrow()
            .as_ref()
            .map(|l| (l.repository.clone(), l.identity))
        else {
            return;
        };
        let project = self.project();
        let (id, c) = self.begin(self.lang().text(
            "Wechselvorschau wird vorbereitet …",
            "Preparing switch preview …",
        ));
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                if let Some(p) = project {
                    p.validate()?;
                }
                if r.operation_identity().map_err(|e| error(e, lang))? != identity {
                    return Err(error(fastra_git::Error::StaleRepository, lang));
                }
                r.prepare_switch(target, policy(), &c)
                    .map_err(|e| error(e, lang))
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if !s.finished(id) {
                    return;
                }
                match result {
                    Ok(p) => {
                        s.output.buffer().set_text(&format!(
                            "Repository\n{}\n\n{}\n{}\n{}\n\n{}\n{}\n\n{}\n{}",
                            project_view::display(p.root()),
                            s.lang().text(
                                "Zielbranch und vollständige Ziel-ID",
                                "Target branch and complete target ID"
                            ),
                            visible(p.target()),
                            visible(p.target_oid()),
                            s.lang().text(
                                "Ausgangszustand (vollständige Quell-ID)",
                                "Source state (complete source ID)"
                            ),
                            state_text(p.source(), s.lang()),
                            s.lang().text(
                                "Vollständiger Commit-Unterschied Quelle → Ziel",
                                "Complete commit difference source → target"
                            ),
                            output(p.delta())
                        ));
                        *s.preview.borrow_mut() = Some(p);
                        s.status.set_text(s.lang().text(
                            "Quelle, Ziel und Unterschiede prüfen und ausdrücklich bestätigen.",
                            "Review source, target and differences, then explicitly approve.",
                        ));
                    }
                    Err(e) => {
                        s.output.buffer().set_text(&e);
                        s.status.set_text(s.lang().text(
                            "Keine freigegebene Vorschau. Diagnose prüfen.",
                            "No approved preview. Review the diagnostic.",
                        ));
                    }
                }
                s.controls();
            },
        );
    }
    fn execute(self: &Rc<Self>) {
        if !self.owned() || self.job.get().is_some() || !self.approved.is_active() {
            return;
        }
        let Some(preview) = self.preview.borrow_mut().take() else {
            return;
        };
        let Some(identity) = self.loaded.borrow().as_ref().map(|l| l.identity) else {
            return;
        };
        let root = preview.root().to_owned();
        let project = self.project();
        let (id, c) = self.begin(
            self.lang()
                .text("Git wechselt den Branch …", "Git is switching the branch …"),
        );
        let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(16);
        let weak = Rc::downgrade(self);
        let mut live = Vec::new();
        glib::timeout_add_local(Duration::from_millis(30), move || {
            let Some(s) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if s.job.get() != Some(id) || s.generation.get() != id {
                return glib::ControlFlow::Break;
            }
            while let Ok(bytes) = rx.try_recv() {
                let left = (128 * 1024usize).saturating_sub(live.len());
                live.extend_from_slice(&bytes[..bytes.len().min(left)]);
            }
            s.output.buffer().set_text(&visible(&live));
            glib::ControlFlow::Continue
        });
        let weak = Rc::downgrade(self);
        let ui = self.ui.clone();
        support::background(
            move || {
                if let Some(p) = project {
                    if p.validate().is_err() {
                        c.cancel();
                    }
                }
                let report = preview.execute(policy(), &c, &mut |b| {
                    let _ = tx.try_send(b.to_vec());
                });
                Ok(report)
            },
            move |result| {
                if let Some(ui) = ui.upgrade() {
                    watch::recheck_after_git(&ui, &root);
                }
                git_fetch::refreshed(&root, identity);
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if !s.finished(id) {
                    return;
                }
                match result {
                    Ok(report) => {
                        let reached = report.target_reached();
                        let success = report.result.is_ok();
                        let mut text = match report.result {
                            Ok(out) => format!("Exit 0\n{}", output(&out)),
                            Err(e) => error(e, s.lang()),
                        };
                        text.push_str("\n\n");
                        text.push_str(s.lang().text(
                            "Tatsächlich nach dem Versuch gelesen\n",
                            "Actual state read after the attempt\n",
                        ));
                        match report.state {
                            Ok(state) => text.push_str(&state_text(&state, s.lang())),
                            Err(e) => text.push_str(&error(e, s.lang())),
                        }
                        s.output.buffer().set_text(&text);
                        s.loaded.borrow_mut().take();
                        s.status.set_text(if success&&reached{s.lang().text("Zielbranch bestätigt. Offene Puffer bleiben erhalten; externe Änderungen separat prüfen. Für weiteren Wechsel neu laden.","Target branch confirmed. Open buffers retained; review external changes separately. Reload before another switch.")}else{s.lang().text("Versuch beendet; Änderungen sind auch bei Fehler oder Abbruch möglich. Tatsächlichen Zustand und offene Dateien prüfen. Neu laden.","Attempt ended; changes are possible even after errors or cancellation. Review actual state and open files. Reload.")});
                    }
                    Err(e) => s.output.buffer().set_text(&e),
                }
                s.controls();
            },
        );
    }
}
pub(super) fn open(ui: &Rc<Ui>, program: PathBuf, path: PathBuf) -> Rc<State> {
    let lang = ui.lang;
    let window = support::window(
        ui,
        lang.text("Git · Branch wechseln", "Git · Switch branch"),
        false,
    );
    window.set_default_size(900, 820);
    window.set_size_request(640, 700);
    let root = support::column();
    let basis = support::label(&project_view::display(&path));
    basis.set_selectable(true);
    root.append(&basis);
    root.append(&support::label(
        lang.text("Lokaler Zielbranch", "Local target branch"),
    ));
    let target = support::file_dropdown();
    root.append(&target);
    root.append(&support::label(lang.text("Normaler Git-Wechsel mit Git-Schutz für lokale Änderungen. Kein Force, Reset oder Stash. Ignorierte Dateien werden geschützt. Ungespeicherte Editorpuffer bleiben erhalten.","Normal Git switch with Git protection for local changes. No force, reset or stash. Ignored files are protected. Unsaved editor buffers are retained.")));
    root.append(&support::label(lang.text("Die Vorschau zeigt Commit-Unterschiede und lokale Änderungen, keine atomare Zusage des späteren Dateizustands. Externes Git kann nach der letzten Prüfung eingreifen; Git-Hooks und Filter können weitere Änderungen bewirken. Auch nach Fehler oder Abbruch wird der tatsächliche Zustand neu gelesen.","The preview shows commit differences and local changes, without an atomic guarantee of later file state. External Git can intervene after the last check; Git hooks and filters can cause additional changes. Actual state is read again even after errors or cancellation.")));
    let actions = gtk::FlowBox::new();
    actions.set_selection_mode(gtk::SelectionMode::None);
    actions.set_max_children_per_line(3);
    actions.set_min_children_per_line(1);
    actions.set_column_spacing(8);
    let reload = gtk::Button::with_label(lang.text("Branchliste neu laden", "Reload branches"));
    let prepare = gtk::Button::with_label(lang.text("Vorschau erstellen", "Prepare preview"));
    let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    for b in [&reload, &prepare, &cancel] {
        actions.insert(b, -1);
    }
    root.append(&actions);
    let approved = gtk::CheckButton::with_label(lang.text(
        "Quelle, Ziel und vollständige Unterschiede geprüft; normalen Wechsel ausführen",
        "Source, target and complete differences reviewed; perform normal switch",
    ));
    if let Some(label) = approved
        .child()
        .and_then(|w| w.downcast::<gtk::Label>().ok())
    {
        label.set_wrap(true);
        label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
        label.set_xalign(0.0);
    }
    root.append(&approved);
    let start = gtk::Button::with_label(lang.text(
        "Bestätigten Branchwechsel ausführen",
        "Execute approved branch switch",
    ));
    start.add_css_class("suggested-action");
    root.append(&start);
    let status = support::label("");
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
        owner: RefCell::new(None),
        loaded: RefCell::new(None),
        basis,
        target,
        targets: RefCell::new(Vec::new()),
        changing: Cell::new(false),
        reload,
        prepare,
        approved,
        start,
        cancel,
        status,
        output,
        preview: RefCell::new(None),
        cancellation: RefCell::new(Default::default()),
        generation: Cell::new(0),
        job: Cell::new(None),
    });
    let weak = Rc::downgrade(&s);
    s.target.connect_selected_notify(move |_| {
        if let Some(s) = weak.upgrade() {
            if !s.changing.get() {
                s.invalidate(s.lang().text(
                    "Ziel geändert. Neue Vorschau und Bestätigung erforderlich.",
                    "Target changed. Prepare and approve a new preview.",
                ));
            }
        }
    });
    let weak = Rc::downgrade(&s);
    s.reload.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.load();
        }
    });
    let weak = Rc::downgrade(&s);
    s.prepare.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.prepare();
        }
    });
    let weak = Rc::downgrade(&s);
    s.start.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.execute();
        }
    });
    let weak = Rc::downgrade(&s);
    s.approved.connect_toggled(move |_| {
        if let Some(s) = weak.upgrade() {
            s.controls();
        }
    });
    let weak = Rc::downgrade(&s);
    s.cancel.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.cancellation.borrow().cancel();
        }
    });
    let weak = Rc::downgrade(&s);
    git_fetch::observe(&window, move |_, identity| {
        if let Some(s) = weak.upgrade() {
            if s.job.get().is_none()
                && s.loaded
                    .borrow()
                    .as_ref()
                    .is_some_and(|l| l.identity == identity)
            {
                s.invalidate(s.lang().text(
                    "Repository geändert. Neu laden.",
                    "Repository changed. Reload.",
                ));
                s.loaded.borrow_mut().take();
                s.controls();
            }
        }
    });
    let weak = Rc::downgrade(&s);
    glib::timeout_add_local(Duration::from_millis(30), move || {
        let Some(s) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if s.owner.borrow().is_some() && !s.owned() {
            s.owner_changed();
        }
        glib::ControlFlow::Continue
    });
    DIALOGS.with_borrow_mut(|all| {
        all.retain(|w| w.strong_count() > 0);
        all.push(Rc::downgrade(&s));
    });
    support::hold(&window, s.clone(), |s| s.cancellation.borrow().cancel());
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
