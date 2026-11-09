//! Git-Werkzeugfenster mit expliziter Indexfreigabe; Kindprozesse bleiben auf Workern.
use super::{Language, Ui};
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::Rc,
    sync::mpsc,
    time::Duration,
};

pub(super) fn window(ui: &Ui, title: &str, modal: bool) -> gtk::Window {
    let window = gtk::Window::builder()
        .title(title)
        .transient_for(&ui.window)
        .modal(modal)
        .destroy_with_parent(true)
        .default_width(900)
        .default_height(660)
        .build();
    if let Some(application) = ui.window.application() {
        window.set_application(Some(&application));
    }
    super::chrome::dialog::decorate(&window, title, ui.lang);
    window.set_size_request(640, 500);
    window
}
pub(super) fn column() -> gtk::Box {
    let root = gtk::Box::new(gtk::Orientation::Vertical, 10);
    root.set_margin_top(16);
    root.set_margin_bottom(16);
    root.set_margin_start(16);
    root.set_margin_end(16);
    root
}
pub(super) fn label(text: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.set_wrap(true);
    label.set_xalign(0.);
    label
}
pub(super) fn file_dropdown() -> gtk::DropDown {
    let dropdown = gtk::DropDown::from_strings(&[]);
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        let item = item.downcast_ref::<gtk::ListItem>().unwrap();
        let label = gtk::Label::builder()
            .xalign(0.)
            .ellipsize(gtk::pango::EllipsizeMode::Middle)
            .max_width_chars(80)
            .build();
        item.set_child(Some(&label));
    });
    factory.connect_bind(|_, item| {
        let item = item.downcast_ref::<gtk::ListItem>().unwrap();
        let value = item
            .item()
            .unwrap()
            .downcast::<gtk::StringObject>()
            .unwrap();
        let label = item.child().unwrap().downcast::<gtk::Label>().unwrap();
        label.set_text(&value.string());
        label.set_tooltip_text(Some(&value.string()));
    });
    dropdown.set_factory(Some(&factory));
    dropdown.set_list_factory(Some(&factory));
    dropdown
}
pub(super) fn output() -> gtk::TextView {
    gtk::TextView::builder()
        .editable(false)
        .cursor_visible(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::None)
        .vexpand(true)
        .build()
}
pub(super) fn scroll(widget: &impl IsA<gtk::Widget>) -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder()
        .child(widget)
        .hexpand(true)
        .vexpand(true)
        .build()
}
pub(super) fn hold<T: 'static>(window: &gtk::Window, state: Rc<T>, cancel: impl Fn(&T) + 'static) {
    let holder = RefCell::new(Some(state));
    window.connect_close_request(move |_| {
        if let Some(state) = holder.borrow_mut().take() {
            cancel(&state);
        }
        glib::Propagation::Proceed
    });
}
pub(super) fn background<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
    done: impl FnOnce(Result<T, String>) + 'static,
) {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(work))
            .unwrap_or_else(|_| Err("Background operation failed".into()));
        let _ = tx.send(result);
    });
    let mut done = Some(done);
    glib::timeout_add_local(Duration::from_millis(20), move || match rx.try_recv() {
        Ok(value) => {
            done.take().unwrap()(value);
            glib::ControlFlow::Break
        }
        Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
        Err(_) => {
            done.take().unwrap()(Err("Background operation ended".into()));
            glib::ControlFlow::Break
        }
    });
}
pub(super) fn bytes(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(text) => text.replace('\0', "\\0"),
        Err(_) => bytes
            .iter()
            .flat_map(|b| std::ascii::escape_default(*b))
            .map(char::from)
            .collect(),
    }
}
pub(super) fn find_program(name: &str) -> Option<PathBuf> {
    if fastra_process::host::is_active().unwrap_or(true) {
        return fastra_process::host::resolve_program(std::ffi::OsStr::new(name))
            .ok()
            .flatten();
    }
    use std::os::unix::fs::PermissionsExt;
    let mut directories = vec![PathBuf::from("/usr/local/bin"), PathBuf::from("/usr/bin")];
    if let Some(path) = std::env::var_os("PATH") {
        directories.extend(std::env::split_paths(&path));
    }
    directories.into_iter().map(|p| p.join(name)).find(|p| {
        p.is_absolute()
            && std::fs::metadata(p)
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    })
}
pub(super) fn error(error: fastra_git::Error, lang: Language) -> String {
    use fastra_git::Error::*;
    let (title, output) = match error {
        GitFailed(out) => (
            lang.text("Git meldet einen Fehler", "Git reported an error"),
            Some(out),
        ),
        Cancelled(out) => (
            lang.text("Git-Aufruf abgebrochen", "Git command cancelled"),
            Some(out),
        ),
        TimedOut(out) => (
            lang.text("Git-Zeitlimit erreicht", "Git time limit reached"),
            Some(out),
        ),
        OutputLimit(out) => (
            lang.text(
                "Git-Ausgabegrenze erreicht; keine vollständige Ansicht",
                "Git output limit reached; view is incomplete",
            ),
            Some(out),
        ),
        Capture { message, output } => return format!("{}: {message}\n{}\n{}",lang.text("Git-Ausgabe konnte nicht vollständig erfasst werden","Git output could not be captured completely"),bytes(&output.stderr),bytes(&output.stdout)),
        IndexLocked => return lang.text("Git-Index gesperrt. Andere Git-Aufträge abschließen und Status neu laden. Fremde Sperrdateien werden nicht entfernt.","Git index is locked. Finish other Git operations and reload status. Foreign lock files are not removed.").into(),
        StalePreview | StaleRepository => return lang.text("Repository, Branch, Index oder Datei geändert. Git-Status neu laden und neu vorbereiten.","Repository, branch, index or file changed. Reload Git status and prepare again.").into(),
        IndexPublished(message) => return format!("{}\n{message}",lang.text("Index wurde übernommen, aber seine Dauerhaftigkeit konnte nicht bestätigt werden. Aktuellen Git-Status prüfen.","Index was published, but durability could not be confirmed. Inspect current Git status.")),
        InvalidInput(message) => return format!("{}\n{message}",lang.text("Git-Auftrag nicht möglich: Auswahl, Konflikte, Filter/Hooks oder Umfangsgrenzen prüfen. Gegebenenfalls das Git-CLI verwenden.","Git operation unavailable: inspect selection, conflicts, filters/hooks or size limits. Use the Git CLI when needed.")),
        Unavailable => {
            return lang
                .text("Git wurde nicht gefunden.", "Git was not found.")
                .into()
        }
        other => {
            return format!(
                "{}: {other}",
                lang.text("Git nicht verfügbar", "Git unavailable")
            )
        }
    };
    let out = output.unwrap();
    format!(
        "{title} ({} {})\n{}\n{}",
        lang.text("Exit", "exit"),
        out.exit_code
            .map(|c| c.to_string())
            .unwrap_or_else(|| "—".into()),
        bytes(&out.stderr),
        bytes(&out.stdout)
    )
}
pub(super) struct State {
    window: gtk::Window,
    path: gtk::Entry,
    raw_path: RefCell<Option<PathBuf>>,
    view: gtk::TextView,
    status: gtk::Label,
    buttons: Vec<gtk::Button>,
    #[cfg(debug_assertions)]
    manage: gtk::Button,
    index: RefCell<Option<Rc<IndexState>>>,
    cancel: RefCell<fastra_git::Cancellation>,
    generation: Cell<u64>,
    action: Cell<usize>,
    repository_root: RefCell<Option<PathBuf>>,
    repository_identity: Cell<Option<(u64, u64)>>,
    lang: Language,
    program: PathBuf,
}
impl State {
    fn run(self: &Rc<Self>, action: usize) {
        self.action.set(action);
        self.cancel.borrow().cancel();
        let cancel = fastra_git::Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        let path = self
            .raw_path
            .borrow()
            .clone()
            .unwrap_or_else(|| PathBuf::from(self.path.text().as_str()));
        let program = self.program.clone();
        let lang = self.lang;
        for b in &self.buttons {
            b.set_sensitive(false);
        }
        self.status
            .set_text(self.lang.text("Git wird gelesen …", "Reading Git …"));
        let weak = Rc::downgrade(self);
        background(
            move || {
                let git = fastra_git::Git::new(program).map_err(|e| error(e, lang))?;
                let policy = fastra_git::Policy {
                    stdout_bytes: 2 * 1024 * 1024,
                    stderr_bytes: 512 * 1024,
                    ..Default::default()
                };
                let repo = git
                    .discover(&path, policy, &cancel)
                    .map_err(|e| error(e, lang))?;
                let result = match action {
                    0 => {
                        let result = repo.status(policy, &cancel).map_err(|e| error(e, lang))?;
                        let mut text = format!(
                            "{}\nBranch: {}\nHEAD: {}\n↑{} ↓{}\n\n",
                            repo.root().display(),
                            result
                                .value
                                .branch
                                .as_deref()
                                .map(bytes)
                                .unwrap_or_else(|| lang.text("abgelöst", "detached").into()),
                            result
                                .value
                                .head_oid
                                .as_deref()
                                .map(bytes)
                                .unwrap_or_default(),
                            result.value.ahead,
                            result.value.behind
                        );
                        for change in result.value.changes {
                            text.push_str(&format!(
                                "{}{}  {:?}\n",
                                char::from(change.xy[0]),
                                char::from(change.xy[1]),
                                bytes(change.path.bytes())
                            ));
                            if let fastra_git::ChangeKind::RenameOrCopy { original, .. } =
                                change.kind
                            {
                                text.push_str(&format!("    ← {}\n", bytes(original.bytes())));
                            }
                        }
                        text.push_str(&bytes(&result.output.stderr));
                        text
                    }
                    1 => {
                        let result = repo.branches(policy, &cancel).map_err(|e| error(e, lang))?;
                        let mut text = String::new();
                        for branch in result.value {
                            text.push_str(&format!(
                                "{} {}  {}\n",
                                if branch.current { "●" } else { " " },
                                bytes(&branch.full_name),
                                bytes(&branch.oid)
                            ));
                            if !branch.worktree_path.is_empty() {
                                text.push_str(&format!("    {}\n", bytes(&branch.worktree_path)));
                            }
                        }
                        text.push_str(&bytes(&result.output.stderr));
                        text
                    }
                    2 => {
                        let out = repo.log(200, policy, &cancel).map_err(|e| error(e, lang))?;
                        bytes(&out.stdout) + &bytes(&out.stderr)
                    }
                    _ => {
                        let out = repo
                            .diff(
                                if action == 3 {
                                    fastra_git::DiffTarget::Index
                                } else {
                                    fastra_git::DiffTarget::WorkingTree
                                },
                                None,
                                policy,
                                &cancel,
                            )
                            .map_err(|e| error(e, lang))?;
                        bytes(&out.stdout) + &bytes(&out.stderr)
                    }
                };
                let identity = repo.operation_identity().map_err(|e| error(e, lang))?;
                Ok((repo.root().to_path_buf(), identity, result))
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                if state.generation.get() != generation {
                    return;
                }
                for b in &state.buttons {
                    b.set_sensitive(true);
                }
                match result {
                    Ok((root, identity, text)) => {
                        state.repository_identity.set(Some(identity));
                        *state.repository_root.borrow_mut() = Some(root);
                        state.view.buffer().set_text(&text);
                        state.status.set_text(state.lang.text(
                            "Aktueller Lesestand. Dateien und Index bleiben unverändert.",
                            "Current read snapshot. Files and index remain unchanged.",
                        ));
                    }
                    Err(error) => {
                        state.view.buffer().set_text(&error);
                        state.status.set_text(state.lang.text(
                            "Git-Aufruf beendet; Diagnose unten.",
                            "Git command ended; diagnostic below.",
                        ));
                    }
                }
            },
        );
    }
}
pub(super) fn open(ui: &Rc<Ui>, program: PathBuf) -> Rc<State> {
    let lang = ui.lang;
    let window = window(ui, lang.text("Git · Lesen", "Git · Read"), false);
    let root = column();
    root.append(&label(lang.text("Repository prüfen", "Inspect repository")));
    let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let path = gtk::Entry::builder()
        .hexpand(true)
        .width_chars(12)
        .max_width_chars(24)
        .placeholder_text(lang.text("Repository-Ordner", "Repository folder"))
        .build();
    let initial_path = ui.active().and_then(|doc| {
        doc.snapshot
            .borrow()
            .as_ref()
            .and_then(|snapshot| snapshot.path().parent().map(PathBuf::from))
    });
    if let Some(initial) = initial_path.as_ref() {
        path.set_text(&display_path(initial.as_os_str().as_encoded_bytes()));
    }
    let choose = gtk::Button::with_label(lang.text("Ordner wählen …", "Choose folder …"));
    line.append(&path);
    line.append(&choose);
    root.append(&line);
    let actions = gtk::FlowBox::new();
    actions.set_selection_mode(gtk::SelectionMode::None);
    actions.set_min_children_per_line(1);
    actions.set_max_children_per_line(5);
    actions.set_column_spacing(6);
    actions.set_row_spacing(6);
    let mut buttons = Vec::new();
    for title in [
        lang.text("Status", "Status"),
        lang.text("Branches", "Branches"),
        lang.text("Verlauf", "History"),
        lang.text("Bereitgestellter Diff", "Staged diff"),
        lang.text("Arbeits-Diff", "Working diff"),
    ] {
        let b = gtk::Button::with_label(title);
        actions.insert(&b, -1);
        buttons.push(b);
    }
    root.append(&actions);
    let manage = gtk::Button::with_label(lang.text("Stage / Unstage …", "Stage / Unstage …"));
    root.append(&manage);
    let explore = gtk::Button::with_label(lang.text("Historie erkunden …", "Explore history …"));
    root.append(&explore);
    let fetch = gtk::Button::with_label(lang.text("Abrufen …", "Fetch …"));
    root.append(&fetch);
    let pull = gtk::Button::with_label(lang.text("Pull …", "Pull …"));
    root.append(&pull);
    let push = gtk::Button::with_label(lang.text("Push …", "Push …"));
    root.append(&push);
    let branches = gtk::Button::with_label(lang.text("Lokale Branches …", "Local branches …"));
    root.append(&branches);
    let switch = gtk::Button::with_label(lang.text("Branch wechseln …", "Switch branch …"));
    root.append(&switch);
    let commit=gtk::Button::with_label(lang.text("Commit erstellen …","Create commit …"));
    root.append(&commit);
    let status = label(lang.text(
        "Ordner wählen und eine Ansicht laden.",
        "Choose a folder, then load a view.",
    ));
    root.append(&status);
    let view = output();
    root.append(&scroll(&view));
    let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    root.append(&cancel);
    window.set_child(Some(&root));
    let state = Rc::new(State {
        window: window.clone(),
        path: path.clone(),
        raw_path: RefCell::new(initial_path),
        view,
        status,
        buttons,
        #[cfg(debug_assertions)]
        manage: manage.clone(),
        index: RefCell::new(None),
        cancel: RefCell::new(Default::default()),
        generation: Cell::new(0),
        action: Cell::new(0),
        repository_root: RefCell::new(None),
        repository_identity: Cell::new(None),
        lang,
        program,
    });
    let weak = Rc::downgrade(&state);
    let owner = Rc::downgrade(ui);
    explore.connect_clicked(move |_| {
        if let (Some(state), Some(ui)) = (weak.upgrade(), owner.upgrade()) {
            let path = state
                .raw_path
                .borrow()
                .clone()
                .unwrap_or_else(|| PathBuf::from(state.path.text().as_str()));
            super::git_history_view::open(&ui, state.program.clone(), path);
        }
    });
    let weak = Rc::downgrade(&state);
    let owner = Rc::downgrade(ui);
    fetch.connect_clicked(move |_| {
        if let (Some(state), Some(ui)) = (weak.upgrade(), owner.upgrade()) {
            let path = state
                .raw_path
                .borrow()
                .clone()
                .unwrap_or_else(|| PathBuf::from(state.path.text().as_str()));
            super::git_fetch::open(&ui, state.program.clone(), path);
        }
    });
    let weak=Rc::downgrade(&state);let owner=Rc::downgrade(ui);pull.connect_clicked(move |_|{if let (Some(state),Some(ui))=(weak.upgrade(),owner.upgrade()){let path=state.raw_path.borrow().clone().unwrap_or_else(||PathBuf::from(state.path.text().as_str()));super::git_pull::open(&ui,state.program.clone(),path);}});
    let weak = Rc::downgrade(&state);
    let owner = Rc::downgrade(ui);
    push.connect_clicked(move |_| {
        if let (Some(state), Some(ui)) = (weak.upgrade(), owner.upgrade()) {
            let path = state
                .raw_path
                .borrow()
                .clone()
                .unwrap_or_else(|| PathBuf::from(state.path.text().as_str()));
            super::git_push::open(&ui, state.program.clone(), path);
        }
    });
    let weak = Rc::downgrade(&state);
    let owner = Rc::downgrade(ui);
    branches.connect_clicked(move |_| {
        if let (Some(state), Some(ui)) = (weak.upgrade(), owner.upgrade()) {
            let path = state
                .raw_path
                .borrow()
                .clone()
                .unwrap_or_else(|| PathBuf::from(state.path.text().as_str()));
            super::git_branches::open(&ui, state.program.clone(), path);
        }
    });
    let weak = Rc::downgrade(&state);
    let owner = Rc::downgrade(ui);
    switch.connect_clicked(move |_| {
        if let (Some(state),Some(ui))=(weak.upgrade(),owner.upgrade()) {
            let path=state.raw_path.borrow().clone().unwrap_or_else(||PathBuf::from(state.path.text().as_str()));
            super::git_switch::open(&ui,state.program.clone(),path);
        }
    });
    let weak=Rc::downgrade(&state);let owner=Rc::downgrade(ui);
    commit.connect_clicked(move |_|{if let (Some(state),Some(ui))=(weak.upgrade(),owner.upgrade()) {let path=state.raw_path.borrow().clone().unwrap_or_else(||PathBuf::from(state.path.text().as_str()));super::git_commit::open(&ui,state.program.clone(),path);}});
    let weak = Rc::downgrade(&state);
    super::git_fetch::observe(&window, move |root, identity| {
        if let Some(state) = weak.upgrade() {
            let path = state
                .raw_path
                .borrow()
                .clone()
                .unwrap_or_else(|| PathBuf::from(state.path.text().as_str()));
            if state.repository_identity.get() == Some(identity)
                || state.repository_root.borrow().as_deref() == Some(root)
                || path.starts_with(root)
            {
                state.run(state.action.get());
            }
        }
    });
    for (index, button) in state.buttons.iter().enumerate() {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(state) = weak.upgrade() {
                state.run(index);
            }
        });
    }
    let weak = Rc::downgrade(&state);
    cancel.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.cancel.borrow().cancel();
        }
    });
    let weak = Rc::downgrade(&state);
    state.path.connect_changed(move |_| {
        if let Some(state) = weak.upgrade() {
            state.raw_path.borrow_mut().take();
            state.repository_root.borrow_mut().take();
            state.repository_identity.set(None);
            state.cancel.borrow().cancel();
            state.generation.set(state.generation.get() + 1);
            for button in &state.buttons {
                button.set_sensitive(true);
            }
            state.view.buffer().set_text("");
            state.status.set_text(state.lang.text(
                "Ordner geändert. Ansicht neu laden.",
                "Folder changed. Reload the view.",
            ));
        }
    });
    let weak = Rc::downgrade(&state);
    choose.connect_clicked(move |_| {
        let Some(state) = weak.upgrade() else {
            return;
        };
        let generation = state.generation.get();
        let weak = Rc::downgrade(&state);
        gtk::FileDialog::new().select_folder(
            Some(&state.window),
            None::<&gio::Cancellable>,
            move |result| {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                if !state.window.is_visible() || state.generation.get() != generation {
                    return;
                }
                if let Ok(file) = result {
                    if let Some(folder) = file.path() {
                        state
                            .path
                            .set_text(&display_path(folder.as_os_str().as_encoded_bytes()));
                        *state.raw_path.borrow_mut() = Some(folder);
                    }
                }
            },
        );
    });
    let weak_ui = Rc::downgrade(ui);
    let weak = Rc::downgrade(&state);
    manage.connect_clicked(move |_| {
        if let (Some(ui), Some(s)) = (weak_ui.upgrade(), weak.upgrade()) {
            if let Some(existing) = s
                .index
                .borrow()
                .as_ref()
                .filter(|index| index.window.is_visible())
            {
                existing.window.present();
                return;
            }
            let path = s.raw_path.borrow().clone().or_else(|| {
                let text = s.path.text();
                if text.is_empty() {
                    None
                } else {
                    Some(PathBuf::from(text.as_str()))
                }
            });
            let index = open_index(&ui, s.program.clone(), path);
            *s.index.borrow_mut() = Some(index);
        }
    });
    hold(&window, state.clone(), |s| s.cancel.borrow().cancel());
    window.present();
    state
}

#[derive(Clone)]
struct IndexOwner {
    document: std::rc::Weak<super::Document>,
    revision: u64,
    generation: u64,
    path: Option<PathBuf>,
}
impl IndexOwner {
    fn capture(ui: &Ui) -> Option<Self> {
        let document = ui.active()?;
        if !ui.window.is_visible() || document.saving.get() {
            return None;
        }
        let path = document
            .snapshot
            .borrow()
            .as_ref()
            .map(|s| s.path().to_path_buf());
        Some(Self {
            document: Rc::downgrade(&document),
            revision: document.revision.get(),
            generation: ui.generation.get(),
            path,
        })
    }
    fn current(&self, ui: &Ui) -> bool {
        let Some(document) = self.document.upgrade() else {
            return false;
        };
        ui.window.is_visible()
            && !document.saving.get()
            && document.revision.get() == self.revision
            && ui.generation.get() == self.generation
            && ui
                .active()
                .is_some_and(|active| Rc::ptr_eq(&active, &document))
            && document
                .snapshot
                .borrow()
                .as_ref()
                .map(|s| s.path().to_path_buf())
                == self.path
    }
}
struct IndexLoaded {
    repository: fastra_git::Repository,
    identity: (u64, u64),
    status: fastra_git::Status,
    warning: Vec<u8>,
}
struct IndexState {
    window: gtk::Window,
    ui: std::rc::Weak<Ui>,
    lang: Language,
    program: PathBuf,
    path: RefCell<Option<PathBuf>>,
    path_label: gtk::Label,
    branch: gtk::Label,
    files: gtk::ListBox,
    selections: RefCell<Vec<(gtk::CheckButton, fastra_git::RepoPath)>>,
    view: gtk::TextView,
    status: gtk::Label,
    choose: gtk::Button,
    refresh: gtk::Button,
    stage: gtk::Button,
    unstage: gtk::Button,
    apply: gtk::Button,
    approved: gtk::CheckButton,
    loaded: RefCell<Option<IndexLoaded>>,
    preview: RefCell<Option<fastra_git::IndexPreview>>,
    owner: RefCell<Option<IndexOwner>>,
    cancellation: RefCell<fastra_git::Cancellation>,
    generation: Cell<u64>,
    busy: Cell<bool>,
    handlers: RefCell<Vec<(glib::Object, glib::SignalHandlerId)>>,
}
impl Drop for IndexState {
    fn drop(&mut self) {
        self.cancellation.borrow().cancel();
        for (object, handler) in self.handlers.get_mut().drain(..) {
            object.disconnect(handler);
        }
    }
}
fn display_path(path: &[u8]) -> String {
    match std::str::from_utf8(path) {
        Ok(text) => text.chars().flat_map(char::escape_debug).collect(),
        Err(_) => path
            .iter()
            .flat_map(|b| std::ascii::escape_default(*b))
            .map(char::from)
            .collect(),
    }
}
impl IndexState {
    fn policy() -> fastra_git::Policy {
        fastra_git::Policy {
            stdout_bytes: 2 * 1024 * 1024,
            stderr_bytes: 512 * 1024,
            ..Default::default()
        }
    }
    fn owned(&self) -> bool {
        self.window.is_visible()
            && self.ui.upgrade().is_some_and(|ui| {
                self.owner
                    .borrow()
                    .as_ref()
                    .is_some_and(|owner| owner.current(&ui))
            })
    }
    fn controls(&self) {
        let busy = self.busy.get();
        let selected = self.selections.borrow().iter().any(|(b, _)| b.is_active());
        self.choose.set_sensitive(!busy);
        self.refresh
            .set_sensitive(!busy && self.path.borrow().is_some());
        self.files.set_sensitive(!busy);
        self.stage
            .set_sensitive(!busy && selected && self.loaded.borrow().is_some());
        self.unstage
            .set_sensitive(!busy && selected && self.loaded.borrow().is_some());
        self.approved
            .set_sensitive(!busy && self.preview.borrow().is_some());
        self.apply.set_sensitive(
            !busy && self.preview.borrow().is_some() && self.approved.is_active() && self.owned(),
        );
    }
    fn invalidate(&self, message: &str) {
        self.cancellation.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
        self.preview.borrow_mut().take();
        self.approved.set_active(false);
        self.busy.set(false);
        self.view.buffer().set_text("");
        self.status.set_text(message);
        self.controls();
    }
    fn begin(&self, message: &str) -> (u64, fastra_git::Cancellation) {
        self.cancellation.borrow().cancel();
        let cancellation = fastra_git::Cancellation::default();
        *self.cancellation.borrow_mut() = cancellation.clone();
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        self.preview.borrow_mut().take();
        self.approved.set_active(false);
        self.busy.set(true);
        self.status.set_text(message);
        self.view.buffer().set_text("");
        self.controls();
        (generation, cancellation)
    }
    fn attach_owner(self: &Rc<Self>, owner: IndexOwner) {
        for (object, handler) in self.handlers.borrow_mut().drain(..) {
            object.disconnect(handler);
        }
        if let Some(document) = owner.document.upgrade() {
            let weak = Rc::downgrade(self);
            let handler = document.buffer.connect_changed(move |_| {
                if let Some(s) = weak.upgrade() {
                    s.invalidate(s.lang.text(
                        "Dokument geändert. Git-Status neu laden.",
                        "Document changed. Reload Git status.",
                    ));
                }
            });
            self.handlers
                .borrow_mut()
                .push((document.buffer.clone().upcast(), handler));
        }
        if let Some(ui) = self.ui.upgrade() {
            let weak = Rc::downgrade(self);
            let handler = ui.tabs.connect_switch_page(move |_, _, _| {
                if let Some(s) = weak.upgrade() {
                    s.invalidate(s.lang.text(
                        "Aktiver Tab geändert. Git-Status neu laden.",
                        "Active tab changed. Reload Git status.",
                    ));
                }
            });
            self.handlers
                .borrow_mut()
                .push((ui.tabs.clone().upcast(), handler));
            let weak = Rc::downgrade(self);
            let handler = ui.window.connect_visible_notify(move |_| {
                if let Some(s) = weak.upgrade() {
                    s.cancellation.borrow().cancel();
                }
            });
            self.handlers
                .borrow_mut()
                .push((ui.window.clone().upcast(), handler));
        }
        *self.owner.borrow_mut() = Some(owner);
    }
    fn refresh(self: &Rc<Self>) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let Some(owner) = IndexOwner::capture(&ui) else {
            return;
        };
        self.attach_owner(owner);
        let Some(path) = self.path.borrow().clone() else {
            return;
        };
        let program = self.program.clone();
        let lang = self.lang;
        let (generation, cancel) =
            self.begin(lang.text("Git-Status wird geladen …", "Loading Git status …"));
        let weak = Rc::downgrade(self);
        background(
            move || {
                let repository = fastra_git::Git::new(program)
                    .and_then(|git| git.discover(&path, Self::policy(), &cancel))
                    .map_err(|e| error(e, lang))?;
                let status = repository
                    .index_status(Self::policy(), &cancel)
                    .map_err(|e| error(e, lang))?;
                if status.value.changes.len() > 500 {
                    return Err(lang
                        .text(
                            "Mehr als 500 Änderungen. Bitte das Git-CLI verwenden.",
                            "More than 500 changes. Use the Git CLI.",
                        )
                        .into());
                }
                let identity = repository
                    .operation_identity()
                    .map_err(|e| error(e, lang))?;
                Ok(IndexLoaded {
                    repository,
                    identity,
                    warning: status.output.stderr,
                    status: status.value,
                })
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if s.generation.get() != generation || !s.owned() {
                    return;
                }
                s.busy.set(false);
                s.loaded.borrow_mut().take();
                s.selections.borrow_mut().clear();
                while let Some(child) = s.files.first_child() {
                    s.files.remove(&child);
                }
                match result {
                    Err(message) => {
                        s.view.buffer().set_text(&message);
                        s.status.set_text(s.lang.text(
                            "Git-Status nicht verfügbar. Diagnose unten.",
                            "Git status unavailable. Diagnostic below.",
                        ));
                    }
                    Ok(loaded) => {
                        s.path_label.set_text(&display_path(
                            loaded.repository.root().as_os_str().as_encoded_bytes(),
                        ));
                        s.branch.set_text(&format!(
                            "Branch: {} · HEAD: {}",
                            loaded
                                .status
                                .branch
                                .as_deref()
                                .map(display_path)
                                .unwrap_or_else(|| s.lang.text("abgelöst", "detached").into()),
                            loaded
                                .status
                                .head_oid
                                .as_deref()
                                .map(display_path)
                                .unwrap_or_else(|| s
                                    .lang
                                    .text("noch kein Commit", "no commit yet")
                                    .into())
                        ));
                        for change in &loaded.status.changes {
                            let title = format!(
                                "{}{}  {}{}",
                                char::from(change.xy[0]),
                                char::from(change.xy[1]),
                                display_path(change.path.bytes()),
                                match &change.kind {
                                    fastra_git::ChangeKind::RenameOrCopy { original, .. } =>
                                        format!(" ← {}", display_path(original.bytes())),
                                    _ => String::new(),
                                }
                            );
                            let check = gtk::CheckButton::with_label(&title);
                            check.set_tooltip_text(Some(&title));
                            if let Some(label) =
                                check.child().and_then(|c| c.downcast::<gtk::Label>().ok())
                            {
                                label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
                                label.set_xalign(0.);
                            }
                            let weak = Rc::downgrade(&s);
                            check.connect_toggled(move |_| {
                                if let Some(s) = weak.upgrade() {
                                    s.preview.borrow_mut().take();
                                    s.approved.set_active(false);
                                    s.view.buffer().set_text("");
                                    s.status.set_text(s.lang.text(
                                        "Dateiauswahl geändert. Neue Vorschau vorbereiten.",
                                        "File selection changed. Prepare a new preview.",
                                    ));
                                    s.controls();
                                }
                            });
                            s.files.append(&check);
                            s.selections.borrow_mut().push((check, change.path.clone()));
                        }
                        s.view.buffer().set_text(&bytes(&loaded.warning));
                        *s.loaded.borrow_mut() = Some(loaded);
                        s.status.set_text(s.lang.text("Dateien auswählen. Stage und Unstage benötigen eine neue vollständige Vorschau. Ungespeicherte Editoränderungen werden nicht bereitgestellt.","Select files. Stage and Unstage require a fresh complete preview. Unsaved editor changes are not staged."));
                    }
                }
                s.controls();
            },
        );
    }
    fn prepare(self: &Rc<Self>, action: fastra_git::IndexAction) {
        if self.busy.get() || !self.owned() {
            self.invalidate(self.lang.text(
                "Kontext geändert. Git-Status neu laden.",
                "Context changed. Reload Git status.",
            ));
            return;
        }
        let Some(repository) = self.loaded.borrow().as_ref().map(|s| s.repository.clone()) else {
            return;
        };
        let paths = self
            .selections
            .borrow()
            .iter()
            .filter(|(b, _)| b.is_active())
            .map(|(_, p)| p.clone())
            .collect::<Vec<_>>();
        let lang = self.lang;
        let (generation, cancel) = self.begin(lang.text(
            "Vollständige Indexvorschau wird vorbereitet …",
            "Preparing complete index preview …",
        ));
        let weak = Rc::downgrade(self);
        background(
            move || {
                repository
                    .prepare_index(action, &paths, Self::policy(), &cancel)
                    .map_err(|e| error(e, lang))
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if s.generation.get() != generation || !s.owned() {
                    return;
                }
                s.busy.set(false);
                match result {
                    Err(message) => {
                        s.view.buffer().set_text(&message);
                        s.status.set_text(s.lang.text(
                            "Keine freigabefähige Vorschau. Diagnose unten.",
                            "No approvable preview. Diagnostic below.",
                        ));
                    }
                    Ok(preview) => {
                        let mut text = format!(
                            "{}\nBranch: {}\nHEAD: {}\n{}\n",
                            match action {
                                fastra_git::IndexAction::Stage => s.lang.text(
                                    "STAGE – geprüfter neuer Index",
                                    "STAGE – reviewed new index"
                                ),
                                fastra_git::IndexAction::Unstage => s.lang.text(
                                    "UNSTAGE – geprüfter neuer Index",
                                    "UNSTAGE – reviewed new index"
                                ),
                            },
                            preview.branch().map(display_path).unwrap_or_default(),
                            preview.head_oid().map(display_path).unwrap_or_default(),
                            s.lang
                                .text("Vollständige Dateiauswahl:", "Complete file selection:")
                        );
                        for path in preview.paths() {
                            text.push_str(&format!("  {}\n", display_path(path.bytes())));
                        }
                        text.push_str(s.lang.text("\nVollständiger Diff dieser Indexänderung (Binärdateien als Git-Binärpatch):\n","\nComplete diff of this index change (binary files use Git binary patches):\n"));
                        text.push_str(&bytes(&preview.diff().stdout));
                        text.push_str(&bytes(&preview.operation_output().stdout));
                        text.push_str(&bytes(&preview.operation_output().stderr));
                        text.push_str(&bytes(&preview.diff().stderr));
                        if let Err(message) = super::text_limits::validate(&text, s.lang) {
                            s.view.buffer().set_text(&message);
                            s.status.set_text(s.lang.text("Keine vollständig darstellbare Indexvorschau. Git-CLI verwenden; kein Index übernommen.", "No completely displayable index preview. Use the Git CLI; no index was published."));
                            s.controls();
                            return;
                        }
                        s.view.buffer().set_text(&text);
                        *s.preview.borrow_mut() = Some(preview);
                        s.status.set_text(s.lang.text("Nur der Index wird geändert. Dateien und Branch bleiben erhalten. Die Vorbereitung kann lose Git-Objekte erzeugen; der echte Index ist noch unverändert.","Only the index changes. Files and branch are retained. Preparation may create loose Git objects; the real index is still unchanged."));
                    }
                }
                s.controls();
            },
        );
    }
    fn apply(self: &Rc<Self>) {
        if self.busy.get() || !self.approved.is_active() || !self.owned() {
            self.invalidate(self.lang.text(
                "Freigabe veraltet. Neu vorbereiten.",
                "Approval stale. Prepare again.",
            ));
            return;
        }
        let Some(repository) = self.loaded.borrow().as_ref().map(|s| s.repository.clone()) else {
            return;
        };
        let Some(preview) = self.preview.borrow_mut().take() else {
            return;
        };
        let lang = self.lang;
        let (generation, cancel) = self.begin(lang.text(
            "Freigegebener Index wird übernommen …",
            "Publishing approved index …",
        ));
        let weak = Rc::downgrade(self);
        background(
            move || {
                repository
                    .apply_index(preview, Self::policy(), &cancel)
                    .map_err(|e| error(e, lang))
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if s.generation.get() != generation || !s.window.is_visible() {
                    return;
                }
                s.busy.set(false);
                s.loaded.borrow_mut().take();
                s.files.set_sensitive(false);
                match result {
                    Ok(()) => {
                        s.view.buffer().set_text(s.lang.text("Index übernommen. Arbeitsdateien unverändert. Git-Status vor der nächsten Aktion neu laden.","Index published. Working files unchanged. Reload Git status before the next action."));
                        s.status.set_text(s.lang.text(
                            "Freigegebene Indexänderung abgeschlossen.",
                            "Approved index change complete.",
                        ));
                    }
                    Err(message) => {
                        s.view.buffer().set_text(&message);
                        s.status.set_text(s.lang.text("Auftrag beendet. Aktuellen Git-Status prüfen; Freigabe ist verbraucht.","Operation ended. Inspect current Git status; approval has been consumed."));
                    }
                }
                s.controls();
            },
        );
    }
}
fn open_index(ui: &Rc<Ui>, program: PathBuf, path: Option<PathBuf>) -> Rc<IndexState> {
    let lang = ui.lang;
    let window = window(
        ui,
        lang.text("Git · Index ändern", "Git · Change index"),
        true,
    );
    window.set_default_size(1000, 820);
    window.set_size_request(760, 620);
    let root = column();
    root.append(&label(lang.text("Stage / Unstage: ausgewählte Dateien auf dem aktuellen Branch. Erst vollständige Vorschau, dann ausdrückliche Freigabe. Keine Änderungen an Arbeitsdateien.","Stage / Unstage: selected files on the current branch. Review the complete preview, then approve explicitly. Working files are not changed.")));
    let location = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let path_label = label(
        &path
            .as_ref()
            .map(|p| display_path(p.as_os_str().as_encoded_bytes()))
            .unwrap_or_else(|| {
                lang.text("Kein Repository gewählt", "No repository selected")
                    .into()
            }),
    );
    path_label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    path_label.set_hexpand(true);
    let choose = gtk::Button::with_label(lang.text("Ordner wählen …", "Choose folder …"));
    let refresh = gtk::Button::with_label(lang.text("Status neu laden", "Reload status"));
    location.append(&path_label);
    location.append(&choose);
    location.append(&refresh);
    root.append(&location);
    let branch = label("");
    branch.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    root.append(&branch);
    let files = gtk::ListBox::new();
    files.set_selection_mode(gtk::SelectionMode::None);
    let file_scroll = scroll(&files);
    file_scroll.set_min_content_height(120);
    file_scroll.set_max_content_height(180);
    file_scroll.set_propagate_natural_height(true);
    file_scroll.set_vexpand(false);
    root.append(&file_scroll);
    let actions = gtk::FlowBox::new();
    actions.set_selection_mode(gtk::SelectionMode::None);
    actions.set_min_children_per_line(1);
    actions.set_max_children_per_line(2);
    actions.set_row_spacing(6);
    actions.set_column_spacing(6);
    let stage = gtk::Button::with_label(lang.text("Stage-Vorschau …", "Stage preview …"));
    let unstage = gtk::Button::with_label(lang.text("Unstage-Vorschau …", "Unstage preview …"));
    actions.insert(&stage, -1);
    actions.insert(&unstage, -1);
    root.append(&actions);
    root.append(&label(lang.text("Für einen Commit dieses Fenster schließen. In „Git · Lesen“ dasselbe Repository wählen und „Commit erstellen …“ öffnen. Die Commitansicht prüft den vollständigen Index separat. Stage / Unstage weist externe Clean-/Process-Filter und Index-Hooks weiterhin ab.","To create a commit, close this window. In “Git · Read”, select the same repository and open “Create commit …”. The commit view reviews the complete index separately. Stage / Unstage still rejects external clean/process filters and index hooks.")));
    let status = label(lang.text(
        "Repository wählen und Status laden.",
        "Choose a repository and load status.",
    ));
    root.append(&status);
    let view = output();
    root.append(&scroll(&view));
    let approved = gtk::CheckButton::with_label(lang.text(
        "Ich habe die Dateiauswahl und den vollständigen Diff geprüft.",
        "I have reviewed the file selection and the complete diff.",
    ));
    root.append(&approved);
    let bottom = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let apply = gtk::Button::with_label(
        lang.text("Freigegebenen Index übernehmen", "Publish approved index"),
    );
    let cancel = gtk::Button::with_label(
        lang.text("Abbrechen / Vorschau verwerfen", "Cancel / discard preview"),
    );
    bottom.append(&apply);
    bottom.append(&cancel);
    root.append(&bottom);
    window.set_child(Some(&root));
    let state = Rc::new(IndexState {
        window: window.clone(),
        ui: Rc::downgrade(ui),
        lang,
        program,
        path: RefCell::new(path),
        path_label,
        branch,
        files,
        selections: RefCell::new(Vec::new()),
        view,
        status,
        choose,
        refresh,
        stage,
        unstage,
        apply,
        approved,
        loaded: RefCell::new(None),
        preview: RefCell::new(None),
        owner: RefCell::new(None),
        cancellation: RefCell::new(Default::default()),
        generation: Cell::new(0),
        busy: Cell::new(false),
        handlers: RefCell::new(Vec::new()),
    });
    for (button, action) in [
        (&state.stage, fastra_git::IndexAction::Stage),
        (&state.unstage, fastra_git::IndexAction::Unstage),
    ] {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                s.prepare(action);
            }
        });
    }
    let weak = Rc::downgrade(&state);
    state.refresh.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.refresh();
        }
    });
    let weak = Rc::downgrade(&state);
    state.apply.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.apply();
        }
    });
    let weak = Rc::downgrade(&state);
    state.approved.connect_toggled(move |_| {
        if let Some(s) = weak.upgrade() {
            s.controls();
        }
    });
    let weak = Rc::downgrade(&state);
    cancel.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.invalidate(s.lang.text(
                "Abbruch angefordert. Freigabe verworfen; aktuellen Git-Status prüfen.",
                "Cancellation requested. Approval discarded; inspect current Git status.",
            ));
            s.loaded.borrow_mut().take();
            s.controls();
        }
    });
    let weak = Rc::downgrade(&state);
    state.choose.connect_clicked(move |_| {
        let Some(s) = weak.upgrade() else {
            return;
        };
        if s.busy.get() {
            return;
        }
        let generation = s.generation.get();
        let owner=s.ui.upgrade().and_then(|ui|IndexOwner::capture(&ui));
        let weak = Rc::downgrade(&s);
        gtk::FileDialog::new().select_folder(
            Some(&s.window),
            None::<&gio::Cancellable>,
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if s.generation.get() != generation || !s.window.is_visible() {
                    return;
                }
                if !s.ui.upgrade().is_some_and(|ui|owner.as_ref().is_some_and(|owner|owner.current(&ui))) {
                    s.invalidate(s.lang.text("Dokumentkontext während der Ordnerwahl geändert. Ordner erneut wählen.","Document context changed during folder selection. Choose the folder again."));
                    return;
                }
                if let Ok(file) = result {
                    if let Some(path) = file.path() {
                        s.invalidate(s.lang.text(
                            "Repository geändert. Status neu laden.",
                            "Repository changed. Reload status.",
                        ));
                        s.path_label
                            .set_text(&display_path(path.as_os_str().as_encoded_bytes()));
                        *s.path.borrow_mut() = Some(path);
                        s.loaded.borrow_mut().take();
                        s.refresh();
                    }
                }
            },
        );
    });
    let weak = Rc::downgrade(&state);
    super::git_fetch::observe(&window, move |root, identity| {
        if let Some(s) = weak.upgrade() {
            let same = s
                .loaded
                .borrow()
                .as_ref()
                .is_some_and(|loaded| loaded.identity == identity);
            if same
                || s.path
                    .borrow()
                    .as_ref()
                    .is_some_and(|path| path.starts_with(root))
            {
                s.invalidate(s.lang.text(
                    "Remote-Stand aktualisiert. Status wird neu geladen.",
                    "Remote state refreshed. Reloading status.",
                ));
                s.refresh();
            }
        }
    });
    hold(&window, state.clone(), |s| {
        s.cancellation.borrow().cancel();
        s.generation.set(s.generation.get() + 1);
        s.preview.borrow_mut().take();
        s.loaded.borrow_mut().take();
        s.owner.borrow_mut().take();
        s.selections.borrow_mut().clear();
        for (object, handler) in s.handlers.borrow_mut().drain(..) {
            object.disconnect(handler);
        }
    });
    let weak = Rc::downgrade(&state);
    glib::timeout_add_local(Duration::from_millis(100), move || {
        let Some(s) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if !s.window.is_visible() {
            return glib::ControlFlow::Break;
        }
        if (s.busy.get() || s.preview.borrow().is_some()) && !s.owned() {
            s.invalidate(s.lang.text(
                "Dokument- oder Fensterkontext geändert. Git-Status neu laden.",
                "Document or window context changed. Reload Git status.",
            ));
            s.loaded.borrow_mut().take();
            s.controls();
        }
        glib::ControlFlow::Continue
    });
    window.present();
    state.controls();
    if state.path.borrow().is_some() {
        state.refresh();
    }
    state
}

pub(super) fn balance_panes(panes: &gtk::Paned) {
    panes.set_resize_start_child(true);
    panes.set_resize_end_child(true);
    panes.set_shrink_start_child(false);
    panes.set_shrink_end_child(false);
    if panes.orientation() == gtk::Orientation::Horizontal {
        for child in [panes.start_child(), panes.end_child()]
            .into_iter()
            .flatten()
        {
            child.set_size_request(child.width_request().max(120), child.height_request());
        }
    }
    let positioned = Rc::new(Cell::new(false));
    let ticking = Rc::new(Cell::new(false));
    panes.connect_map(move |panes| {
        if positioned.get() || ticking.replace(true) {
            return;
        }
        let positioned = positioned.clone();
        let ticking = ticking.clone();
        let frames = Cell::new(0);
        // Ein verborgenes Notebook hat beim Map-Signal noch keine belastbare Breite.
        panes.add_tick_callback(move |panes, _| {
            let size = if panes.orientation() == gtk::Orientation::Horizontal {
                panes.width()
            } else {
                panes.height()
            };
            let orientation = panes.orientation();
            let minimum = panes.measure(orientation, -1).0;
            let children_ready =
                [panes.start_child(), panes.end_child()]
                    .into_iter()
                    .all(|child| {
                        child.is_some_and(|child| {
                            child.is_mapped()
                                && if orientation == gtk::Orientation::Horizontal {
                                    child.width() > 0
                                } else {
                                    child.height() > 0
                                }
                        })
                    });
            if size > 0 && size >= minimum && children_ready {
                panes.set_position(size / 2);
                positioned.set(true);
                ticking.set(false);
                return glib::ControlFlow::Break;
            }
            frames.set(frames.get() + 1);
            if frames.get() >= 120 {
                ticking.set(false);
                glib::ControlFlow::Break
            } else {
                glib::ControlFlow::Continue
            }
        });
    });
}

#[cfg(debug_assertions)]
pub(super) fn try_capture_x11(
    window: &impl IsA<gtk::Widget>,
    name: &str,
    pending: &RefCell<Option<mpsc::Receiver<bool>>>,
) -> bool {
    let Some(directory) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS") else {
        return true;
    };
    if pending.borrow().is_none() {
        let surface = window.as_ref().native().unwrap().surface().unwrap();
        let symbol =
            unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
        assert!(!symbol.is_null());
        let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
            unsafe { std::mem::transmute(symbol) };
        let id = unsafe { xid(surface.as_ptr().cast()) }.to_string();
        let path = std::path::PathBuf::from(directory).join(format!("{name}.png"));
        let (tx, rx) = mpsc::channel();
        *pending.borrow_mut() = Some(rx);
        std::thread::spawn(move || {
            let ok = std::process::Command::new("timeout")
                .args(["5s", "import", "-silent", "-window", &id])
                .arg(path)
                .status()
                .is_ok_and(|s| s.success());
            let _ = tx.send(ok);
        });
        return false;
    }
    let result = pending.borrow().as_ref().unwrap().try_recv();
    match result {
        Ok(ok) => {
            assert!(ok);
            pending.borrow_mut().take();
            true
        }
        Err(mpsc::TryRecvError::Empty) => false,
        Err(_) => panic!("X11 capture stopped"),
    }
}

#[cfg(debug_assertions)]
pub(super) fn capture(window: &gtk::Window, name: &str) {
    let Some(directory) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS").map(PathBuf::from) else {
        return;
    };
    capture_to(window, &directory.join(format!("{name}.png")));
}
#[cfg(debug_assertions)]
pub(super) fn capture_to(window: &gtk::Window, path: &std::path::Path) {
    assert!(try_capture_to(window, path), "painted tool window");
}
#[cfg(debug_assertions)]
pub(super) fn try_capture(window: &gtk::Window, name: &str) -> bool {
    std::env::var_os("FASTRA_TOOL_SCREENSHOTS")
        .map(PathBuf::from)
        .is_none_or(|directory| try_capture_to(window, &directory.join(format!("{name}.png"))))
}
#[cfg(debug_assertions)]
fn try_capture_to(window: &gtk::Window, path: &std::path::Path) -> bool {
    if !window.is_mapped() {
        window.queue_draw();
        return false;
    }
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let paintable = gtk::WidgetPaintable::new(Some(window));
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(
        &snapshot,
        f64::from(window.width()),
        f64::from(window.height()),
    );
    let Some(node) = snapshot.to_node() else {
        window.queue_draw();
        return false;
    };
    let texture = window
        .renderer()
        .expect("tool renderer")
        .render_texture(&node, None);
    texture.save_to_png(path).unwrap();
    true
}
#[cfg(debug_assertions)]
pub(super) fn finish(window: gtk::Window, ui: Rc<Ui>, name: &'static str) {
    let mut done = false;
    glib::timeout_add_local(Duration::from_millis(250), move || {
        if !done {
            capture(&window, name);
            done = true;
            println!("FASTRA_TOOL_SELFTEST_OK {name}");
            let application = ui.window.application().unwrap();
            window.close();
            application.quit();
        }
        glib::ControlFlow::Break
    });
}
#[cfg(debug_assertions)]
pub(super) fn test_size(window: &gtk::Window) {
    if let Ok(width) = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or_default()
        .parse::<i32>()
    {
        window.set_default_size(width, 760);
    }
}
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>, mode: &str) {
    assert_eq!(
        std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(),
        Ok("1"),
        "Tool tests require a private display"
    );
    match mode {
        "git" => git_test(ui),
        "git-index" => index_test(ui),
        "import" => super::import_view::selftest(ui),
        "diff" => super::diff_view::selftest(ui),
        _ => panic!("unknown tool selftest"),
    }
}
#[cfg(debug_assertions)]
fn git_test(ui: Rc<Ui>) {
    let fixture = PathBuf::from(std::env::var_os("FASTRA_TOOL_FIXTURE").unwrap());
    let state = open(&ui, PathBuf::from("/usr/bin/git"));
    test_size(&state.window);
    state
        .path
        .set_text(&fixture.join("repository").to_string_lossy());
    state.buttons[0].emit_clicked();
    let stage = Cell::new(0);
    let deadline = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            deadline.elapsed() < Duration::from_secs(30),
            "Git tool timed out: {}",
            state.status.text()
        );
        if state.buttons.iter().any(|b| !b.is_sensitive()) {
            return glib::ControlFlow::Continue;
        }
        let buffer = state.view.buffer();
        let text = buffer.text(&buffer.start_iter(), &buffer.end_iter(), true);
        match stage.get() {
            0 => {
                assert!(text.contains("tracked.txt"), "{text}");
                state.buttons[1].emit_clicked();
                stage.set(1);
            }
            1 => {
                assert!(text.contains("refs/heads/main"), "{text}");
                state.buttons[2].emit_clicked();
                stage.set(2);
            }
            2 => {
                assert!(text.contains("initial"), "{text}");
                state.buttons[4].emit_clicked();
                stage.set(3);
            }
            3 => {
                assert!(text.contains("+changed"), "{text}");
                state.buttons[0].emit_clicked();
                stage.set(4);
            }
            _ => {
                assert!(text.contains("tracked.txt"));
                finish(state.window.clone(), ui.clone(), "git");
                return glib::ControlFlow::Break;
            }
        }
        glib::ControlFlow::Continue
    });
}

#[cfg(debug_assertions)]
pub(super) fn menu_test(ui: Rc<Ui>, menu: gtk::MenuButton, buttons: Vec<gtk::Button>) {
    assert_eq!(
        std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(),
        Ok("1"),
        "Tool tests require a private display"
    );
    test_size(ui.window.upcast_ref());
    super::chrome::show_commands(&ui);
    let started = std::time::Instant::now();
    let phase = Cell::new(0);
    glib::timeout_add_local(Duration::from_millis(100), move || {
        if started.elapsed() < Duration::from_millis(400) {
            return glib::ControlFlow::Continue;
        }
        let expect_git = std::env::var_os("FASTRA_TOOL_EXPECT_GIT").is_some();
        menu.popup();
        assert_eq!(buttons[0].is_visible(), expect_git);
        let index = phase.get();
        if index < 3 {
            phase.set(index + 1);
            if index == 0 && !expect_git {
                return glib::ControlFlow::Continue;
            }
            menu.popup();
            buttons[index].emit_clicked();
            let application = ui.window.application().unwrap();
            let opened = application
                .windows()
                .into_iter()
                .find(|window| window.transient_for().as_ref() == Some(ui.window.upcast_ref()))
                .expect("tool window opened by real menu button");
            assert!(opened.is_visible());
            opened.close();
            return glib::ControlFlow::Continue;
        }
        finish(ui.window.clone().upcast(), ui.clone(), "menu");
        glib::ControlFlow::Break
    });
}

#[cfg(debug_assertions)]
fn index_test(ui: Rc<Ui>) {
    use std::os::unix::ffi::OsStringExt;
    let fixture = PathBuf::from(std::env::var_os("FASTRA_TOOL_FIXTURE").unwrap())
        .join(std::ffi::OsString::from_vec(b"repository\xff\n".to_vec()));
    let index = fixture.join(".git/index");
    let original = std::fs::read(&index).unwrap();
    let working = std::fs::read(fixture.join("tracked.txt")).unwrap();
    let reading = open(&ui, PathBuf::from("/usr/bin/git"));
    reading
        .path
        .set_text(&display_path(fixture.as_os_str().as_encoded_bytes()));
    *reading.raw_path.borrow_mut() = Some(fixture.clone());
    reading.manage.emit_clicked();
    let state = reading.index.borrow().as_ref().unwrap().clone();
    test_size(&state.window);
    let stage = Cell::new(0);
    let before_stale = RefCell::new(Vec::new());
    let began = std::time::Instant::now();
    let select = |s: &IndexState, path: &[u8]| {
        let check = s
            .selections
            .borrow()
            .iter()
            .find(|(_, p)| p.bytes() == path)
            .unwrap()
            .0
            .clone();
        check.set_active(true);
    };
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            began.elapsed() < Duration::from_secs(50),
            "Git index stage {}: {}",
            stage.get(),
            state.status.text()
        );
        if state.busy.get() {
            return glib::ControlFlow::Continue;
        }
        let text = || {
            let b = state.view.buffer();
            b.text(&b.start_iter(), &b.end_iter(), true).to_string()
        };
        match stage.get() {
            0 => {
                assert!(state.loaded.borrow().is_some(), "{}", text());
                assert!(state.path_label.text().contains("\\xff\\n"));
                select(&state, b"tracked.txt");
                select(&state, b"raw\xff\n.txt");
                state.stage.emit_clicked();
                stage.set(1);
            }
            1 => {
                assert!(state.preview.borrow().is_some(), "{}", text());
                assert_eq!(std::fs::read(&index).unwrap(), original);
                assert!(text().contains("+changed"));
                assert!(!state.apply.is_sensitive());
                state.approved.set_active(true);
                assert!(state.apply.is_sensitive());
                stage.set(2);
            }
            2 => {
                capture(&state.window, "git-index-stage");
                state.apply.emit_clicked();
                stage.set(3);
            }
            3 => {
                assert!(state.preview.borrow().is_none());
                assert_ne!(std::fs::read(&index).unwrap(), original);
                assert_eq!(std::fs::read(fixture.join("tracked.txt")).unwrap(), working);
                state.refresh.emit_clicked();
                stage.set(4);
            }
            4 => {
                let loaded = state.loaded.borrow();
                let status = &loaded.as_ref().unwrap().status;
                assert_eq!(
                    status
                        .changes
                        .iter()
                        .find(|c| c.path.bytes() == b"tracked.txt")
                        .unwrap()
                        .xy,
                    [b'M', b'.']
                );
                drop(loaded);
                select(&state, b"tracked.txt");
                state.unstage.emit_clicked();
                stage.set(5);
            }
            5 => {
                assert!(state.preview.borrow().is_some(), "{}", text());
                assert!(text().contains("-changed"));
                state.approved.set_active(true);
                stage.set(6);
            }
            6 => {
                capture(&state.window, "git-index-unstage");
                state.apply.emit_clicked();
                stage.set(7);
            }
            7 => {
                assert_eq!(std::fs::read(fixture.join("tracked.txt")).unwrap(), working);
                state.refresh.emit_clicked();
                stage.set(8);
            }
            8 => {
                let loaded = state.loaded.borrow();
                let status = &loaded.as_ref().unwrap().status;
                assert_eq!(
                    status
                        .changes
                        .iter()
                        .find(|c| c.path.bytes() == b"tracked.txt")
                        .unwrap()
                        .xy,
                    [b'.', b'M']
                );
                assert_eq!(
                    status
                        .changes
                        .iter()
                        .find(|c| c.path.bytes() == b"raw\xff\n.txt")
                        .unwrap()
                        .xy,
                    [b'A', b'.']
                );
                drop(loaded);
                select(&state, b"tracked.txt");
                state.stage.emit_clicked();
                stage.set(9);
            }
            9 => {
                assert!(state.preview.borrow().is_some(), "{}", text());
                *before_stale.borrow_mut() = std::fs::read(&index).unwrap();
                state.approved.set_active(true);
                std::fs::write(fixture.join("replacement"), &working).unwrap();
                std::fs::rename(fixture.join("replacement"), fixture.join("tracked.txt")).unwrap();
                state.apply.emit_clicked();
                stage.set(10);
            }
            10 => {
                assert!(state.preview.borrow().is_none());
                assert_eq!(std::fs::read(&index).unwrap(), *before_stale.borrow());
                assert!(
                    text().contains(state.lang.text(
                        "Repository, Branch, Index oder Datei geändert",
                        "Repository, branch, index or file changed"
                    )),
                    "{}",
                    text()
                );
                stage.set(11);
            }
            11 => {
                capture(&state.window, "git-index-stale-file");
                state.refresh.emit_clicked();
                stage.set(12);
            }
            12 => {
                assert!(state.loaded.borrow().is_some());
                select(&state, b"tracked.txt");
                state.stage.emit_clicked();
                stage.set(13);
            }
            13 => {
                assert!(state.preview.borrow().is_some(), "{}", text());
                state.approved.set_active(true);
                ui.add_document("switched-owner.txt", "owner switched");
                assert!(state.preview.borrow().is_none());
                assert!(!state.apply.is_sensitive());
                assert_eq!(std::fs::read(&index).unwrap(), *before_stale.borrow());
                state.refresh.emit_clicked();
                stage.set(14);
            }
            14 => {
                assert!(state.loaded.borrow().is_some());
                select(&state, b"tracked.txt");
                state.stage.emit_clicked();
                ui.add_document("late-owner.txt", "late owner");
                assert!(state.preview.borrow().is_none());
                stage.set(15);
            }
            15 => {
                assert!(state.preview.borrow().is_none());
                assert!(!state.apply.is_sensitive());
                assert_eq!(std::fs::read(&index).unwrap(), *before_stale.borrow());
                stage.set(16);
            }
            16 => {
                capture(&state.window, "git-index-stale-owner");
                state.refresh.emit_clicked();
                stage.set(17);
            }
            17 => {
                assert!(state.loaded.borrow().is_some());
                select(&state, b"tracked.txt");
                state.stage.emit_clicked();
                stage.set(18);
            }
            18 => {
                assert!(state.preview.borrow().is_some(), "{}", text());
                state.approved.set_active(true);
                let check = state
                    .selections
                    .borrow()
                    .iter()
                    .find(|(_, p)| p.bytes() == b"tracked.txt")
                    .unwrap()
                    .0
                    .clone();
                check.set_active(false);
                assert!(state.preview.borrow().is_none());
                assert!(!state.apply.is_sensitive());
                assert_eq!(std::fs::read(&index).unwrap(), *before_stale.borrow());
                assert_eq!(std::fs::read(fixture.join("tracked.txt")).unwrap(), working);
                assert!(!fixture.join(".git/index.lock").exists());
                std::fs::write(fixture.join("tracked.txt"), "A".repeat(66000)).unwrap();
                state.refresh.emit_clicked();
                stage.set(19);
            }
            19 => {
                assert!(state.loaded.borrow().is_some());
                select(&state, b"tracked.txt");
                state.stage.emit_clicked();
                stage.set(20);
            }
            20 => {
                assert!(state.preview.borrow().is_none());
                assert!(!state.apply.is_sensitive());
                assert!(text().contains("64 KiB"), "{}", text());
                assert_eq!(std::fs::read(&index).unwrap(), *before_stale.borrow());
                assert_eq!(
                    std::fs::read(fixture.join("tracked.txt")).unwrap(),
                    vec![b'A'; 66000]
                );
                assert!(!fixture.join(".git/index.lock").exists());
                println!("PASS Git index GUI: full bound approvals; raw paths; stage/unstage; retained working bytes; stale sources/owner/selection; complete display limit; no commit");
                finish(state.window.clone(), ui.clone(), "git-index");
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

#[cfg(debug_assertions)]
pub(super) fn test_click(widget: &impl IsA<gtk::Widget>, keys: &[&str]) {
    test_input(widget, keys, true);
}
#[cfg(debug_assertions)]
pub(super) fn test_keys(widget: &impl IsA<gtk::Widget>, keys: &[&str]) {
    test_input(widget, keys, false);
}
#[cfg(debug_assertions)]
pub(super) fn test_input_completed(
    widget: &impl IsA<gtk::Widget>, keys: &[&str], click: bool,
) -> mpsc::Receiver<()> {
    native_input(widget, keys, u32::from(click), None, None, None)
}
#[cfg(debug_assertions)]
fn test_input(widget: &impl IsA<gtk::Widget>, keys: &[&str], click: bool) {
    test_input_at(widget, keys, click, None);
}
#[cfg(debug_assertions)]
pub(super) fn test_click_at(widget: &impl IsA<gtk::Widget>, x: f32, y: f32, keys: &[&str]) {
    test_input_at(widget, keys, true, Some((x, y)));
}
#[cfg(debug_assertions)]
fn test_input_at(
    widget: &impl IsA<gtk::Widget>,
    keys: &[&str],
    click: bool,
    position: Option<(f32, f32)>,
) {
    native_input(widget, keys, u32::from(click), position, None, None);
}
#[cfg(debug_assertions)]
pub(super) fn test_type(widget: &impl IsA<gtk::Widget>, text: &str) -> mpsc::Receiver<()> {
    native_input(widget, &[], 0, None, Some(text.to_owned()), None)
}
#[cfg(debug_assertions)]
pub(super) fn test_drag_at(widget: &impl IsA<gtk::Widget>, x: f32, y: f32, dx: i32, dy: i32) {
    native_input(widget, &[], 0, Some((x, y)), None, Some((dx, dy)));
}
#[cfg(debug_assertions)]
pub(super) fn test_double_click_at(widget: &impl IsA<gtk::Widget>, x: f32, y: f32) {
    native_input(widget, &[], 2, Some((x, y)), None, None);
}
#[cfg(debug_assertions)]
struct NativePointer {
    clicks: u32,
    button: u32,
    shift: bool,
}
#[cfg(debug_assertions)]
pub(super) fn test_shift_click(widget: &impl IsA<gtk::Widget>) {
    native_input_with_pointer(
        widget,
        &[],
        NativePointer {
            clicks: 1,
            button: 1,
            shift: true,
        },
        None,
        None,
        None,
    );
}
#[cfg(debug_assertions)]
pub(super) fn test_context_click(widget: &impl IsA<gtk::Widget>) {
    native_input_with_pointer(
        widget,
        &[],
        NativePointer {
            clicks: 1,
            button: 3,
            shift: false,
        },
        None,
        None,
        None,
    );
}
#[cfg(debug_assertions)]
fn native_input(
    widget: &impl IsA<gtk::Widget>,
    keys: &[&str],
    clicks: u32,
    position: Option<(f32, f32)>,
    text: Option<String>,
    drag: Option<(i32, i32)>,
) -> mpsc::Receiver<()> {
    native_input_with_pointer(
        widget,
        keys,
        NativePointer {
            clicks,
            button: 1,
            shift: false,
        },
        position,
        text,
        drag,
    )
}
#[cfg(debug_assertions)]
fn native_input_with_pointer(
    widget: &impl IsA<gtk::Widget>,
    keys: &[&str],
    pointer: NativePointer,
    position: Option<(f32, f32)>,
    text: Option<String>,
    drag: Option<(i32, i32)>,
) -> mpsc::Receiver<()> {
    let NativePointer {
        clicks,
        button,
        shift,
    } = pointer;
    let (sent, received) = mpsc::channel();
    let widget = widget.as_ref();
    if clicks > 0 || drag.is_some() {
        assert!(
            widget.is_mapped() && widget.width() > 0 && widget.height() > 0,
            "Native pointer target must be mapped and allocated"
        );
    }
    let native = widget.native().unwrap();
    let point = widget
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(
                position.map_or(widget.width() as f32 / 2., |p| p.0),
                position.map_or(widget.height() as f32 / 2., |p| p.1),
            ),
        )
        .unwrap();
    let (x, y) = native.surface_transform();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(native.surface().unwrap().as_ptr().cast()) }.to_string();
    let top_level = native.is::<gtk::Window>();
    let managed = top_level && std::env::var_os("FASTRA_TEST_WM").is_some();
    let keys: Vec<String> = keys.iter().map(|s| s.to_string()).collect();
    std::thread::spawn(move || {
        let mut c = std::process::Command::new("xdotool");
        // Popover haben bereits einen nativen Grab. Ein künstlicher Fokuswechsel
        // währenddessen verfälscht die Aktivierung ihres Besitzerfensters.
        if managed {
            c.args(["windowactivate", "--sync", &id]);
        } else if top_level {
            c.args(["windowraise", &id, "windowfocus", "--sync", &id]);
        }
        if shift {
            c.args(["keydown", "Shift_L"]);
        }
        if clicks > 0 || drag.is_some() {
            c.args([
                "mousemove",
                "--window",
                &id,
                // GTK zieht den Surface-Versatz beim Zustellen wieder ab.
                // Die inverse Abbildung addiert ihn; doppelte Subtraktion
                // verfehlte kleine CSD-Controls bei 4 px Versatz um 8 px.
                &(point.x() as f64 + x).round().to_string(),
                &(point.y() as f64 + y).round().to_string(),
            ]);
            c.args(["sleep", "0.1"]);
            if let Some((dx, dy)) = drag {
                c.args([
                    "mousedown",
                    "1",
                    "mousemove_relative",
                    "--",
                    &dx.to_string(),
                    &dy.to_string(),
                    "sleep",
                    "0.1",
                    "mouseup",
                    "1",
                ]);
            } else {
                c.args([
                    "click",
                    "--repeat",
                    &clicks.to_string(),
                    "--delay",
                    "70",
                    &button.to_string(),
                ]);
            }
        }
        if shift {
            c.args(["keyup", "Shift_L"]);
        }
        if !keys.is_empty() {
            c.arg("key").args(keys);
        }
        if let Some(text) = text {
            c.args(["type", "--clearmodifiers", "--delay", "0", "--", &text]);
        }
        assert!(c.status().unwrap().success());
        let _ = sent.send(());
    });
    received
}
