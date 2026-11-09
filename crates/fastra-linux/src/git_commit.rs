//! Bestätigter vollständiger Indexcommit; Arbeitsindex und Editorpuffer bleiben erhalten.
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
    message: gtk::TextView,
    changing: Cell<bool>,
    reload: gtk::Button,
    prepare: gtk::Button,
    approved: gtk::CheckButton,
    start: gtk::Button,
    cancel: gtk::Button,
    status: gtk::Label,
    output: gtk::TextView,
    preview: RefCell<Option<fastra_git::CommitPreview>>,
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
        timeout: Duration::from_secs(120),
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
        self.message.set_editable(ready);
        let message = self.message.buffer();
        self.prepare.set_sensitive(
            ready
                && !message
                    .text(&message.start_iter(), &message.end_iter(), true)
                    .trim()
                    .is_empty(),
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
        let (id, c) = self.begin(
            self.lang()
                .text("Commitbasis wird gelesen …", "Reading commit basis …"),
        );
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
                Ok(Loaded {
                    repository: r,
                    identity,
                })
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if !s.finished(id) {
                    return;
                }
                match result {
                    Ok(loaded) => {
                        s.basis.set_text(&format!(
                            "Repository\n{}",
                            project_view::display(loaded.repository.root())
                        ));
                        *s.loaded.borrow_mut() = Some(loaded);
                        s.status.set_text(s.lang().text(
                            "Vollständige Nachricht eingeben und Vorschau des bereitgestellten Index erstellen.",
                            "Enter the complete message and prepare a preview of the staged index.",
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
        let buffer = self.message.buffer();
        let message = buffer
            .text(&buffer.start_iter(), &buffer.end_iter(), true)
            .as_bytes()
            .to_vec();
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
            "Commitvorschau wird vorbereitet …",
            "Preparing commit preview …",
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
                let helper = commit_helper().map_err(|e| e.to_string())?;
                r.prepare_commit(message, helper, policy(), &c)
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
                        let parents = p
                            .parents()
                            .iter()
                            .map(|o| visible(o))
                            .collect::<Vec<_>>()
                            .join("\n");
                        let entries = p
                            .entries()
                            .stdout
                            .split(|b| *b == 0)
                            .map(visible)
                            .collect::<Vec<_>>()
                            .join("\n");
                        s.output.buffer().set_text(&format!("Repository\n{}\n\n{}\n{}\n\nTree\n{}\n\nParents\n{}\n\n{}\n{}\n\n{}\n{}\n\n{}\n{}\n\n{} ({} Bytes)\n{}\n{}\n\n{}\n{}\n\n{}\n{}",project_view::display(p.root()),s.lang().text("Aktueller Ref","Current ref"),if p.branch()==b"HEAD"{s.lang().text("Losgelöster HEAD; kein Branch wird aktualisiert","Detached HEAD; no branch is updated").into()}else{visible(p.branch())},visible(p.tree()),if parents.is_empty(){s.lang().text("Erster Commit; keine Parents","Initial commit; no parents").into()}else{parents},s.lang().text("Autor (vollständige Git-Identität)","Author (complete Git identity)"),visible(p.author()),s.lang().text("Committer (vollständige Git-Identität)","Committer (complete Git identity)"),visible(p.committer()),s.lang().text("Native Signierung laut Gitkonfiguration","Native signing from Git configuration"),visible(p.signing()),s.lang().text("Vollständige Nachricht","Complete message"),p.message().len(),visible(p.message()),s.lang().text("[Nachrichtenende; abschließender LF ist enthalten]","[End of message; includes final LF]"),s.lang().text("Vollständiger bereitgestellter Diff","Complete staged diff"),output(p.diff()),s.lang().text("Vollständiger Tree (Modus, Typ, Objekt-ID, Pfad)","Complete tree (mode, type, object ID, path)"),entries));
                        *s.preview.borrow_mut() = Some(p);
                        s.status.set_text(s.lang().text(
                            "Tree, Parents, Identitäten, Signierung und vollständige Nachricht prüfen und bestätigen.",
                            "Review and approve tree, parents, identities, signing and the complete message.",
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
        let (id, c) = self.begin(self.lang().text(
            "Git erstellt den bestätigten Commit …",
            "Git is creating the approved commit …",
        ));
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
                        let published = report.published.as_ref().map(|o| visible(o));
                        let reached = report.state.as_ref().is_ok_and(|state| {
                            state.status.value.head_oid.as_ref() == report.published.as_ref()
                        }) && report.published.is_some();
                        let success = report.result.is_ok();
                        let mut text = match report.result {
                            Ok(out) => format!("Exit 0\n{}", output(&out)),
                            Err(e) => error(e, s.lang()),
                        };
                        text.push_str(&format!(
                            "\n\n{}: {}\n",
                            s.lang().text("Validierter Commit", "Validated commit"),
                            published.unwrap_or_else(|| "—".into())
                        ));
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
                        if success && reached {
                            s.changing.set(true);
                            s.message.buffer().set_text("");
                            s.changing.set(false);
                        }
                        s.status.set_text(if success&&reached{s.lang().text("Commit bestätigt. Arbeitsindex und offene Puffer bleiben erhalten. Für weiteren Commit neu laden.","Commit confirmed. Working index and open buffers retained. Reload before another commit.")}else{s.lang().text("Auftrag beendet. Hooks oder Abbruch können Änderungen hinterlassen. Tatsächlichen Zustand und Ausgabe prüfen; neu laden.","Operation ended. Hooks or cancellation may leave changes. Review actual state and output; reload.")});
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
        lang.text("Git · Commit erstellen", "Git · Create commit"),
        false,
    );
    window.set_default_size(900, 900);
    window.set_size_request(640, 760);
    let root = support::column();
    let basis = support::label(&project_view::display(&path));
    basis.set_selectable(true);
    root.append(&basis);
    root.append(&support::label(
        lang.text("Vollständige Commit-Nachricht", "Complete commit message"),
    ));
    let message = gtk::TextView::builder()
        .wrap_mode(gtk::WrapMode::WordChar)
        .monospace(true)
        .hexpand(true)
        .build();
    let message_scroll = support::scroll(&message);
    message_scroll.set_min_content_height(100);
    message_scroll.set_max_content_height(140);
    message_scroll.set_vexpand(false);
    root.append(&message_scroll);
    root.append(&support::label(lang.text("Nur der vollständig gezeigte Index-Snapshot wird committet. Kein automatisches Stagen. Späteres Staging und ungespeicherte Editorpuffer bleiben erhalten.","Only the complete displayed index snapshot is committed. No automatic staging. Later staging and unsaved editor buffers are retained.")));
    root.append(&support::label(lang.text("Native Git-Hooks und Signierung bleiben aktiv. Ändert ein Hook Tree, Parents, Identität oder Nachricht, verweigert der Validator die Veröffentlichung. Hook-Nebeneffekte und bereits veröffentlichte Commits werden bei Fehler oder Abbruch nicht zurückgerollt; der tatsächliche Zustand wird neu gelesen.","Native Git hooks and signing remain active. If a hook changes tree, parents, identity or message, validation rejects publication. Hook side effects and commits already published are not rolled back on error or cancellation; actual state is read again.")));
    let actions = gtk::FlowBox::new();
    actions.set_selection_mode(gtk::SelectionMode::None);
    actions.set_max_children_per_line(3);
    actions.set_min_children_per_line(1);
    actions.set_column_spacing(8);
    let reload = gtk::Button::with_label(lang.text("Commitbasis neu laden", "Reload commit basis"));
    let prepare = gtk::Button::with_label(lang.text("Vorschau erstellen", "Prepare preview"));
    let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    for b in [&reload, &prepare, &cancel] {
        actions.insert(b, -1);
    }
    root.append(&actions);
    let approved = gtk::CheckButton::with_label(lang.text(
        "Vollständigen Tree, Parents, Identitäten, Signierung und Nachricht geprüft",
        "Complete tree, parents, identities, signing and message reviewed",
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
    let start = gtk::Button::with_label(
        lang.text("Bestätigten Commit erstellen", "Create approved commit"),
    );
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
        message,
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
    s.message.buffer().connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            if !s.changing.get() {
                s.invalidate(s.lang().text(
                    "Nachricht geändert. Neue Vorschau und Bestätigung erforderlich.",
                    "Message changed. Prepare and approve a new preview.",
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

fn commit_helper() -> std::io::Result<std::path::PathBuf> {
    let application = std::env::current_exe()?;
    if !fastra_process::host::is_active().map_err(std::io::Error::other)? {
        return Ok(application);
    }
    let helper = application.with_file_name("fastra-git-commit-hook");
    fastra_process::host::resolve_program(helper.as_os_str())
        .map_err(std::io::Error::other)?
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "Packaged GTK-free Git commit helper missing",
            )
        })
}
