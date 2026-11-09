//! Begrenzter Projektbaum; Pfade bleiben rohe Unix-Pfade und werden nicht aus Labels rekonstruiert.
use super::{git_view as support, Ui};
use gtk::prelude::*;
use std::{
    cell::{Cell, RefCell},
    collections::HashSet,
    ffi::CString,
    fs::{self, File},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
    path::{Path, PathBuf},
    rc::Rc,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
#[path = "recent_projects.rs"]
mod recent_projects;
const MAX_ENTRIES: usize = 4000;
const MAX_DEPTH: usize = 32;
const MAX_NAMES: usize = 1024 * 1024;
#[derive(Clone, Debug, PartialEq, Eq)]
struct Entry {
    relative: PathBuf,
    depth: usize,
    directory: bool,
    openable: bool,
    identity: (u64, u64, u64, i64, i64),
}
#[derive(Debug, PartialEq, Eq)]
struct Tree {
    root: PathBuf,
    identity: (u64, u64),
    entries: Vec<Entry>,
    issues: Vec<String>,
}
pub(super) fn display(path: &Path) -> String {
    match path.to_str() {
        Some(text) => text
            .chars()
            .flat_map(|c| {
                if c.is_control() || c == '\\' {
                    c.escape_default().collect::<Vec<_>>()
                } else {
                    vec![c]
                }
            })
            .collect(),
        None => support::bytes(path.as_os_str().as_bytes()),
    }
}
fn scan(path: &Path, hidden: bool, cancel: &AtomicBool) -> Result<Tree, String> {
    fastra_io::check_runtime_path(path).map_err(|e| e.to_string())?;
    let root = fs::canonicalize(path).map_err(|e| e.to_string())?;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&root)
        .map_err(|e| e.to_string())?;
    fastra_io::check_runtime_file(&file).map_err(|e| e.to_string())?;
    let meta = file.metadata().map_err(|e| e.to_string())?;
    let mut tree = Tree {
        root,
        identity: (meta.dev(), meta.ino()),
        entries: Vec::new(),
        issues: Vec::new(),
    };
    let started = Instant::now();
    let mut names = 0;
    fn walk(
        file: File,
        relative: &Path,
        depth: usize,
        tree: &mut Tree,
        hidden: bool,
        budget: (&AtomicBool, Instant, &mut usize),
    ) -> Result<(), String> {
        let (cancel, started, names) = budget;
        fastra_io::check_runtime_file(&file).map_err(|e| e.to_string())?;
        if depth > MAX_DEPTH {
            return Err("Depth limit: 32".into());
        }
        let fdpath = PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd()));
        let mut children = Vec::new();
        for item in fs::read_dir(&fdpath).map_err(|e| e.to_string())? {
            if cancel.load(Ordering::Relaxed) {
                return Err("Cancelled".into());
            }
            if started.elapsed() > Duration::from_secs(2) {
                return Err("Scan time limit: 2 seconds".into());
            }
            let item = item.map_err(|e| e.to_string())?;
            let name = item.file_name();
            fastra_io::check_runtime_path(&tree.root.join(relative).join(&name)).map_err(|e| e.to_string())?;
            if !hidden && name.as_bytes().first() == Some(&b'.') {
                continue;
            }
            *names += name.as_bytes().len();
            if tree.entries.len() + children.len() >= MAX_ENTRIES || *names > MAX_NAMES {
                return Err("Tree limit: 4000 entries / 1 MiB names".into());
            }
            let meta = fs::symlink_metadata(fdpath.join(&name)).map_err(|e| e.to_string())?;
            children.push((name, meta));
        }
        children.sort_by(|(a, am), (b, bm)| {
            bm.is_dir()
                .cmp(&am.is_dir())
                .then(a.as_bytes().cmp(b.as_bytes()))
        });
        for (name, meta) in children {
            if cancel.load(Ordering::Relaxed) {
                return Err("Cancelled".into());
            }
            if tree.entries.len() >= MAX_ENTRIES {
                return Err("Tree limit: 4000 entries".into());
            }
            let child = relative.join(&name);
            let directory = meta.is_dir();
            tree.entries.push(Entry {
                relative: child.clone(),
                depth,
                directory,
                openable: meta.is_file(),
                identity: (
                    meta.dev(),
                    meta.ino(),
                    meta.len(),
                    meta.mtime(),
                    meta.mtime_nsec(),
                ),
            });
            if directory {
                let name = CString::new(name.as_bytes()).map_err(|e| e.to_string())?;
                // Gehaltene Verzeichnisdeskriptoren verhindern das Folgen ausgetauschter Symlinks.
                let fd = unsafe {
                    libc::openat(
                        file.as_raw_fd(),
                        name.as_ptr(),
                        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                    )
                };
                if fd < 0 {
                    if tree.issues.len() >= 32 {
                        return Err("Too many unreadable directories (32)".into());
                    }
                    if tree.issues.len() < 32 {
                        tree.issues.push(format!(
                            "{}: {}",
                            display(&child),
                            std::io::Error::last_os_error()
                        ));
                    }
                    continue;
                }
                let childfile = unsafe { File::from_raw_fd(fd) };
                fastra_io::check_runtime_file(&childfile).map_err(|e| e.to_string())?;
                let m = childfile.metadata().map_err(|e| e.to_string())?;
                if m.dev() != meta.dev() || m.ino() != meta.ino() {
                    return Err("Directory changed during scan".into());
                }
                walk(
                    childfile,
                    &child,
                    depth + 1,
                    tree,
                    hidden,
                    (cancel, started, names),
                )?;
            }
        }
        Ok(())
    }
    walk(
        file,
        Path::new(""),
        0,
        &mut tree,
        hidden,
        (cancel, started, &mut names),
    )?;
    let after = fs::metadata(&tree.root).map_err(|e| e.to_string())?;
    if (after.dev(), after.ino()) != tree.identity {
        return Err("Project root changed during scan".into());
    }
    Ok(tree)
}
fn validate_loaded(
    root: &Path,
    root_identity: (u64, u64),
    checked_path: &Path,
    expected: (u64, u64, u64, i64, i64),
    loaded: &super::viewer::Loaded,
) -> bool {
    let Ok(root_meta) = fs::metadata(root) else {
        return false;
    };
    let Ok(meta) = fs::symlink_metadata(checked_path) else {
        return false;
    };
    let loaded_identity = match loaded {
        super::viewer::Loaded::Editor(loaded) => match loaded {
            super::loader::Loaded::Text { snapshot, .. } => (
                snapshot.file_identity().device,
                snapshot.file_identity().inode,
            ),
            super::loader::Loaded::ReadOnlyText(source) => (
                source.identity().device(), source.identity().inode(),
            ),
            super::loader::Loaded::Sections(source) | super::loader::Loaded::Hex(source) => {
                (source.identity().device(), source.identity().inode())
            }
        },
        super::viewer::Loaded::Visual(source) => (
            source.snapshot().file_identity().device,
            source.snapshot().file_identity().inode,
        ),
    };
    (root_meta.dev(), root_meta.ino()) == root_identity
        && meta.is_file()
        && (
            meta.dev(),
            meta.ino(),
            meta.len(),
            meta.mtime(),
            meta.mtime_nsec(),
        ) == expected
        && loaded_identity == (expected.0, expected.1)
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct RootBinding {
    pub(super) path: PathBuf,
    identity: (u64, u64),
}
impl RootBinding {
    pub(super) fn identity(&self) -> (u64, u64) {
        self.identity
    }
    pub(super) fn validate(&self) -> Result<(), String> {
        fastra_io::check_runtime_path(&self.path).map_err(|e| e.to_string())?;
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&self.path)
            .map_err(|e| e.to_string())?;
        fastra_io::check_runtime_file(&file).map_err(|e| e.to_string())?;
        let metadata = file.metadata().map_err(|e| e.to_string())?;
        if (metadata.dev(), metadata.ino()) != self.identity {
            return Err("Project root identity changed".into());
        }
        Ok(())
    }
}
#[derive(Clone)]
pub(super) struct WorkBinding {
    root: RootBinding,
    cancel: Arc<fastra_core::Cancellation>,
}
impl WorkBinding {
    /// Dateisystemprüfung ausschließlich auf dem Worker ausführen.
    pub(super) fn validate(&self) -> Result<(), String> {
        self.cancel.check().map_err(|e| e.to_string())?;
        self.root.validate()?;
        self.cancel.check().map_err(|e| e.to_string())
    }
}
#[derive(Clone)]
pub(super) struct Binding {
    pub(super) root: RootBinding,
    generation: u64,
    owner: std::rc::Weak<State>,
}
impl Binding {
    pub(super) fn owner_id(&self) -> String {
        format!(
            "project-{:x}-{}-{}-{}",
            self.owner.as_ptr() as usize,
            self.generation,
            self.root.identity.0,
            self.root.identity.1
        )
    }
    pub(super) fn work(&self, cancel: &fastra_core::Cancellation) -> Result<WorkBinding, String> {
        if !self.is_current() {
            return Err("Project selection changed".into());
        }
        let owner = self.owner.upgrade().ok_or("Project closed")?;
        let mut work = owner.work.borrow_mut();
        work.retain(|w| w.strong_count() > 0);
        if work.len() >= 64 {
            return Err("Project operation limit: 64".into());
        }
        // Nur aktive Worker halten den Abbruch stark; erledigte Aufträge sammeln sich nicht im Projekt.
        let cancel = Arc::new(cancel.clone());
        work.push(Arc::downgrade(&cancel));
        Ok(WorkBinding {
            root: self.root.clone(),
            cancel,
        })
    }
    pub(super) fn is_current(&self) -> bool {
        self.owner.upgrade().is_some_and(|state| {
            state.root_generation.get() == self.generation
                && state.selected.borrow().as_ref() == Some(&self.root)
                && state.ui.upgrade().is_some_and(|ui| ui.window.is_visible())
        })
    }
}
pub(super) fn search(ui: &Rc<Ui>) {
    let current = ui.project.borrow().clone();
    if let Some(binding) = current.and_then(|state| state.binding()) {
        super::folder::open_project(ui, binding);
    } else {
        open(ui);
        ui.status.set_text(ui.lang.text(
            "Projektordner wählen und vollständigen Baum abwarten. Danach Projekt durchsuchen.",
            "Choose a project folder and wait for its complete tree. Then search the project.",
        ));
    }
}
pub(super) struct State {
    ui: std::rc::Weak<Ui>,
    window: gtk::Window,
    path: gtk::Entry,
    hidden: gtk::CheckButton,
    filter: gtk::Entry,
    list: gtk::ListBox,
    rows: RefCell<Vec<(PathBuf, gtk::glib::WeakRef<gtk::Button>)>>,
    status: gtk::Label,
    tree: RefCell<Option<Tree>>,
    collapsed: RefCell<HashSet<PathBuf>>,
    generation: Cell<u64>,
    request: Cell<u64>,
    busy: Cell<bool>,
    polling: Cell<bool>,
    // Filter und Baumansicht ändern die gewählte Projektidentität nicht.
    root_generation: Cell<u64>,
    work: RefCell<Vec<std::sync::Weak<fastra_core::Cancellation>>>,
    selected: RefCell<Option<RootBinding>>,
    search_project: gtk::Button,
    reveal: gtk::Button,
    reveal_request: Rc<super::file_manager::Request>,
    paused: Cell<bool>,
    root_path: RefCell<PathBuf>,
    setting_path: Cell<bool>,
    cancel: RefCell<Arc<AtomicBool>>,
    recent: RefCell<Option<Rc<recent_projects::Menu>>>,
    remember_choice: Cell<bool>,
}
impl State {
    pub(super) fn close_for_transition(&self) {
        self.invalidate_root();
        self.selected.borrow_mut().take();
        self.remember_choice.set(false);
        self.reveal_request.cancel();
        self.cancel.borrow().store(true, Ordering::Relaxed);
        self.request.set(self.request.get().wrapping_add(1));
        self.generation.set(self.generation.get().wrapping_add(1));
        self.paused.set(true);
        self.invalidate();
    }

    fn invalidate_root(&self) {
        self.reveal_request.cancel();
        self.reveal.set_sensitive(false);
        if let Some(ui) = self.ui.upgrade() {
            super::git_fetch::invalidate_owner(&ui);
            super::git_push::invalidate_owner(&ui);
            super::git_branches::invalidate_owner(&ui);
            super::git_switch::invalidate_owner(&ui);
            super::git_commit::invalidate_owner(&ui);
        }
        self.root_generation.set(self.root_generation.get() + 1);
        for cancel in self.work.borrow_mut().drain(..).filter_map(|w| w.upgrade()) {
            cancel.cancel();
        }
    }
    #[cfg(debug_assertions)]
    pub(super) fn test_binding(self: &Rc<Self>) -> Option<Binding> {
        self.binding()
    }
    fn binding(self: &Rc<Self>) -> Option<Binding> {
        Some(Binding {
            root: self.selected.borrow().clone()?,
            generation: self.root_generation.get(),
            owner: Rc::downgrade(self),
        })
    }
    fn reveal_root(self: &Rc<Self>) {
        if self.reveal_request.pending() || !self.window.is_visible() {
            return;
        }
        let Some(ui) = self.ui.upgrade().filter(|ui| ui.window.is_visible()) else {
            return;
        };
        let Some(binding) = self.binding() else {
            return;
        };
        let path = binding.root.path.clone();
        self.reveal.set_sensitive(false);
        let weak = Rc::downgrade(self);
        self.reveal_request.show(&ui.window, &path, move |result| {
            let Some(state) = weak.upgrade() else { return };
            if !state.window.is_visible() || !binding.is_current() {
                return;
            }
            state.reveal.set_sensitive(true);
            if let Err(error) = result {
                if let Some(ui) = state.ui.upgrade() {
                    state.status.set_text(&format!(
                        "{}: {}",
                        ui.lang.text(
                            "Dateimanager konnte den Projektordner nicht zeigen",
                            "The file manager could not show the project folder"
                        ),
                        error.message(ui.lang)
                    ));
                }
            }
        });
    }
    fn choose_root(self: &Rc<Self>, path: PathBuf) {
        self.set_root(path);
        self.remember_choice.set(true);
    }
    fn set_root(self: &Rc<Self>, path: PathBuf) {
        if let Some(ui) = self.ui.upgrade() { super::editor_options::startup::interrupt(&ui); }
        self.remember_choice.set(false);
        self.invalidate_root();
        self.selected.borrow_mut().take();
        self.search_project.set_sensitive(false);
        *self.root_path.borrow_mut() = path.clone();
        self.setting_path.set(true);
        self.path.set_text(&display(&path));
        self.setting_path.set(false);
        self.collapsed.borrow_mut().clear();
        self.paused.set(false);
        self.invalidate();
        self.refresh();
    }
    fn start_polling(self: &Rc<Self>) {
        if self.polling.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        gtk::glib::timeout_add_local(Duration::from_secs(3), move || {
            let Some(state) = weak.upgrade() else {
                return gtk::glib::ControlFlow::Break;
            };
            if !state.window.is_visible()
                || state.ui.upgrade().is_none_or(|ui| !ui.window.is_visible())
            {
                state.polling.set(false);
                return gtk::glib::ControlFlow::Break;
            }
            if !state.paused.get() {
                state.refresh();
            }
            gtk::glib::ControlFlow::Continue
        });
    }
    fn invalidate(&self) {
        self.cancel.borrow().store(true, Ordering::Relaxed);
        self.generation.set(self.generation.get() + 1);
        self.request.set(self.request.get() + 1);
        self.tree.borrow_mut().take();
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
    }
    fn refresh(self: &Rc<Self>) {
        if self.busy.get()
            || !self.window.is_visible()
            || self.ui.upgrade().is_none_or(|ui| !ui.window.is_visible())
        {
            return;
        }
        let path = self.root_path.borrow().clone();
        if path.as_os_str().is_empty() {
            return;
        }
        let hidden = self.hidden.is_active();
        let request = self.request.get() + 1;
        self.request.set(request);
        self.busy.set(true);
        let cancel = Arc::new(AtomicBool::new(false));
        *self.cancel.borrow_mut() = cancel.clone();
        let weak = Rc::downgrade(self);
        let Some(ui) = self.ui.upgrade() else { return };
        self.status
            .set_text(ui.lang.text("Projekt wird gelesen …", "Reading project …"));
        support::background(
            move || scan(&path, hidden, &cancel),
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.busy.set(false);
                if !state.window.is_visible()
                    || state.ui.upgrade().is_none_or(|ui| !ui.window.is_visible())
                    || state.request.get() != request
                {
                    return;
                }
                let Some(ui) = state.ui.upgrade() else { return };
                match result {
                    Ok(tree) => {
                        if state.tree.borrow().is_none() {
                            state.collapsed.borrow_mut().extend(tree.entries.iter().filter(|entry| entry.directory).map(|entry| entry.relative.clone()));
                        }
                        let selected = RootBinding {
                            path: tree.root.clone(),
                            identity: tree.identity,
                        };
                        if state.selected.borrow().as_ref() != Some(&selected) {
                            state.invalidate_root();
                            *state.selected.borrow_mut() = Some(selected);
                        }
                        state.search_project.set_sensitive(true);
                        state.reveal.set_sensitive(!state.reveal_request.pending());
                        if state.remember_choice.replace(false) {
                            if let Some(recent) = state.recent.borrow().as_ref() {
                                recent.remember(tree.root.clone());
                            }
                        }
                        let changed = state.tree.borrow().as_ref() != Some(&tree);
                        let message = format!(
                            "{} · {} {}\n{}",
                            display(&tree.root),
                            tree.entries.len(),
                            ui.lang.text(
                                "Einträge · Symlinks/Spezialdateien nicht geöffnet",
                                "entries · symlinks/special files are not opened"
                            ),
                            tree.issues.join("\n")
                        );
                        state.status.set_text(&message);
                        if changed {
                            state.generation.set(state.generation.get() + 1);
                            *state.tree.borrow_mut() = Some(tree);
                            state.render();
                        }
                    }
                    Err(error) => {
                        state.invalidate_root();
                        state.selected.borrow_mut().take();
                        state.search_project.set_sensitive(false);
                        state.invalidate();
                        state.status.set_text(&format!(
                            "{}: {error}",
                            ui.lang.text(
                                "Projekt nicht vollständig gelesen",
                                "Project not completely read"
                            )
                        ));
                    }
                }
            },
        );
    }
    fn render(self: &Rc<Self>) {
        self.rows.borrow_mut().clear();
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let tree = self.tree.borrow();
        let Some(tree) = tree.as_ref() else { return };
        let needle = self.filter.text().to_lowercase();
        let mut entries: Vec<_> = tree.entries.iter().collect();
        // Nur die Darstellung wird sprachfreundlich sortiert. Der geprüfte
        // Scan und sämtliche Dateibindungen behalten ihre unveränderten Pfade.
        entries.sort_by_cached_key(|entry| {
            let parts: Vec<_> = entry.relative.components().collect();
            parts.iter().enumerate().map(|(index, part)| {
                let directory = index + 1 < parts.len() || entry.directory;
                (!directory, display(Path::new(part.as_os_str())).to_lowercase(), part.as_os_str().as_bytes().to_vec())
            }).collect::<Vec<_>>()
        });
        for entry in entries {
            if !needle.is_empty() && !display(&entry.relative).to_lowercase().contains(&needle) {
                continue;
            }
            if needle.is_empty()
                && entry
                    .relative
                    .ancestors()
                    .skip(1)
                    .any(|parent| self.collapsed.borrow().contains(parent))
            {
                continue;
            }
            let text = format!(
                "{} {}",
                if entry.directory {
                    if self.collapsed.borrow().contains(&entry.relative) {
                        "▸"
                    } else {
                        "▾"
                    }
                } else if entry.openable {
                    "·"
                } else {
                    "⊘"
                },
                display(Path::new(entry.relative.file_name().unwrap()))
            );
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            row.set_margin_start((entry.depth * 16) as i32);
            let disclosure = gtk::Image::from_icon_name(if entry.directory { if self.collapsed.borrow().contains(&entry.relative) { "pan-end-symbolic" } else { "pan-down-symbolic" } } else { "" });
            disclosure.set_pixel_size(10); disclosure.set_size_request(10, -1); row.append(&disclosure);
            let image = gtk::Image::from_icon_name(if entry.directory { "fastra-folder-symbolic" } else { "fastra-file-symbolic" }); image.set_pixel_size(14); row.append(&image);
            let label = gtk::Label::new(Some(&display(Path::new(entry.relative.file_name().unwrap()))));
            label.set_xalign(0.);
            label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            row.append(&label);
            let button = gtk::Button::new();
            if let Some(ui) = self.ui.upgrade() { if ui.active().and_then(|doc| doc.disk_path()).is_some_and(|path| path == tree.root.join(&entry.relative)) { button.add_css_class("project-selected"); } }
            button.set_child(Some(&row));
            button.update_property(&[gtk::accessible::Property::Label(&text)]);
            button.set_tooltip_text(Some(&display(&entry.relative)));
            button.set_sensitive(entry.directory || entry.openable);
            self.rows.borrow_mut().push((tree.root.join(&entry.relative), button.downgrade()));
            let entry = entry.clone();
            let weak = Rc::downgrade(self);
            button.connect_clicked(move |_| {
                let Some(state) = weak.upgrade() else { return };
                if entry.directory {
                    if !state.collapsed.borrow_mut().remove(&entry.relative) {
                        state.collapsed.borrow_mut().insert(entry.relative.clone());
                    }
                    state.render();
                } else {
                    state.open_entry(&entry);
                }
            });
            self.list.append(&button);
        }
    }
    fn open_entry(self: &Rc<Self>, entry: &Entry) {
        let Some(ui) = self.ui.upgrade() else { return };
        let tree = self.tree.borrow();
        let Some(tree) = tree.as_ref() else { return };
        let path = tree.root.join(&entry.relative);
        let generation = self.generation.get();
        let weak = Rc::downgrade(self);
        // Der Guard bleibt bis zur tatsächlichen asynchronen Tab-Erzeugung wirksam.
        let root = tree.root.clone();
        let root_identity = tree.identity;
        let expected = entry.identity;
        let checked_path = path.clone();
        ui.load_path_validated(
            path,
            None,
            Rc::new(move || {
                weak.upgrade().is_some_and(|s| {
                    s.window.is_visible()
                        && s.ui.upgrade().is_some_and(|ui| ui.window.is_visible())
                        && s.generation.get() == generation
                })
            }),
            Some(Box::new(move |loaded| {
                validate_loaded(&root, root_identity, &checked_path, expected, loaded)
            })),
        );
    }
}
pub(super) fn open_path(ui: &Rc<Ui>, path: PathBuf) {
    open(ui).choose_root(path);
}

pub(super) fn welcome_recent(ui: &Rc<Ui>) -> gtk::Box { recent_projects::welcome(ui) }

pub(super) fn refresh_selection(ui: &Ui) {
    if let Some(state) = ui.project.borrow().as_ref() {
        let selected = ui.active().and_then(|doc| doc.disk_path());
        for (path, row) in state.rows.borrow().iter() {
            if let Some(row) = row.upgrade() {
                if selected.as_ref() == Some(path) { row.add_css_class("project-selected"); }
                else { row.remove_css_class("project-selected"); }
            }
        }
    }
}

#[allow(deprecated)]
pub(super) fn open(ui: &Rc<Ui>) -> Rc<State> {
    let existing = ui.project.borrow().clone();
    if let Some(state) = existing {
        if ui.window.is_visible() {
            state.window.present();
            state.start_polling();
            if !state.paused.get() {
                state.refresh();
            }
        }
        return state;
    }
    let window = ui.window.clone().upcast::<gtk::Window>();
    let root = support::column();
    root.append(&support::label(ui.lang.text(
        "Lokaler Projektbaum · Nur reguläre Dateien öffnen · Höchstens 4000 Einträge",
        "Local project tree · Open regular files only · At most 4000 entries",
    )));
    let path = gtk::Entry::builder()
        .hexpand(true)
        .width_chars(12)
        .max_width_chars(24)
        .max_length(4096)
        .build();
    let choose = gtk::Button::with_label(ui.lang.text("Projekt wählen …", "Choose project …"));
    let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    line.append(&path);
    line.append(&choose);
    root.append(&line);
    let hidden = gtk::CheckButton::with_label(
        ui.lang
            .text("Versteckte Einträge anzeigen", "Show hidden entries"),
    );
    root.append(&hidden);
    let filter = gtk::Entry::builder()
        .max_length(256)
        .placeholder_text(ui.lang.text(
            "Angezeigte relative Pfade filtern",
            "Filter displayed relative paths",
        ))
        .build();
    root.append(&filter);
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let refresh = gtk::Button::with_label(ui.lang.text("Aktualisieren", "Refresh"));
    let cancel = gtk::Button::with_label(ui.lang.text("Abbrechen", "Cancel"));
    actions.append(&refresh);
    actions.append(&cancel);
    let search_project =
        gtk::Button::with_label(ui.lang.text("Projekt durchsuchen …", "Search project …"));
    search_project.set_sensitive(false);
    actions.append(&search_project);
    root.append(&actions);
    let reveal = gtk::Button::with_label(ui.lang.text("Im Dateimanager zeigen", "Show in file manager"));
    reveal.set_tooltip_text(Some(ui.lang.text(
        "Den gewählten Projektordner im übergeordneten Ordner des Dateimanagers markieren.",
        "Select the chosen project folder in its parent folder in the file manager.")));
    reveal.set_halign(gtk::Align::Start);
    reveal.set_sensitive(false);
    root.append(&reveal);
    let status = support::label(ui.lang.text(
        "Projektordner wählen. Automatische Aktualisierung alle 3 Sekunden.",
        "Choose a project folder. Automatic refresh every 3 seconds.",
    ));
    root.append(&status);
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    let list_scroll = support::scroll(&list);
    root.append(&list_scroll);
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        window: window.clone(),
        path: path.clone(),
        hidden: hidden.clone(),
        filter: filter.clone(),
        list: list.clone(),
        rows: RefCell::new(Vec::new()),
        status,
        tree: RefCell::new(None),
        collapsed: RefCell::new(HashSet::new()),
        generation: Cell::new(0),
        request: Cell::new(0),
        busy: Cell::new(false),
        polling: Cell::new(false),
        root_generation: Cell::new(0),
        work: RefCell::new(Vec::new()),
        selected: RefCell::new(None),
        search_project: search_project.clone(),
        reveal: reveal.clone(),
        reveal_request: Rc::default(),
        paused: Cell::new(false),
        root_path: RefCell::new(PathBuf::new()),
        setting_path: Cell::new(false),
        cancel: RefCell::new(Arc::new(AtomicBool::new(false))),
        recent: RefCell::new(None),
        remember_choice: Cell::new(false),
    });
    let weak = Rc::downgrade(&state);
    let recent = recent_projects::Menu::new(
        ui,
        &window,
        Rc::new(move |path| {
            if let Some(state) = weak.upgrade() {
                if let Some(ui) = state.ui.upgrade() { super::chrome::open_project(&ui, path); }
            }
        }),
    );
    root.insert_child_after(&recent.button, Some(&line));
    *state.recent.borrow_mut() = Some(recent);
    let weak = Rc::downgrade(&state);
    path.connect_activate(move |entry| {
        if let Some(state) = weak.upgrade() {
            // Ein angezeigter RawPath wird beim Bestätigen unverändert weitergereicht.
            let path = if display(&state.root_path.borrow()) == entry.text().as_str() {
                state.root_path.borrow().clone()
            } else {
                PathBuf::from(entry.text().as_str())
            };
            state.choose_root(path);
        }
    });
    let weak = Rc::downgrade(&state);
    path.connect_changed(move |entry| {
        if let Some(s) = weak.upgrade() {
            if !s.setting_path.get() {
                s.set_root(PathBuf::from(entry.text().as_str()));
            }
        }
    });
    let weak = Rc::downgrade(&state);
    hidden.connect_toggled(move |_| {
        if let Some(s) = weak.upgrade() {
            s.paused.set(false);
            s.invalidate();
            s.refresh();
        }
    });
    let weak = Rc::downgrade(&state);
    filter.connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            s.generation.set(s.generation.get() + 1);
            s.render();
        }
    });
    let weak = Rc::downgrade(&state);
    refresh.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.paused.set(false);
            s.refresh();
        }
    });
    let weak = Rc::downgrade(&state);
    cancel.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.remember_choice.set(false);
            s.paused.set(true);
            s.invalidate();
            if let Some(ui) = s.ui.upgrade() {
                s.status.set_text(ui.lang.text(
                    "Scan abgebrochen. Mit Aktualisieren fortsetzen.",
                    "Scan cancelled. Use Refresh to resume.",
                ));
            }
        }
    });
    let weak = Rc::downgrade(&state);
    choose.connect_clicked(move |_| {
        let Some(s) = weak.upgrade() else { return };
        let Some(ui) = s.ui.upgrade() else { return };
        let chooser = gtk::FileChooserNative::new(
            Some(ui.lang.text("Projekt wählen", "Choose project")),
            Some(&s.window),
            gtk::FileChooserAction::SelectFolder,
            Some(ui.lang.text("Öffnen", "Open")),
            Some(ui.lang.text("Abbrechen", "Cancel")),
        );
        let weak = Rc::downgrade(&s);
        chooser.connect_response(move |chooser, response| {
            if response == gtk::ResponseType::Accept {
                if let (Some(s), Some(path)) =
                    (weak.upgrade(), chooser.file().and_then(|f| f.path()))
                {
                    if s.window.is_visible()
                        && s.ui.upgrade().is_some_and(|ui| ui.window.is_visible())
                    {
                        if let Some(ui) = s.ui.upgrade() { super::chrome::open_project(&ui, path); }
                    }
                }
            }
            chooser.destroy();
        });
        chooser.show();
    });
    let weak = Rc::downgrade(&state);
    reveal.connect_clicked(move |_| { if let Some(state) = weak.upgrade() { state.reveal_root(); } });
    let weak = Rc::downgrade(&state);
    search_project.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            if let Some(ui) = state.ui.upgrade() {
                ui.scope.set_selected(3);
                search(&ui);
            }
        }
    });
    let weak = Rc::downgrade(&state);
    window.connect_hide(move |_| {
        if let Some(state) = weak.upgrade() {
            state.remember_choice.set(false);
            state.reveal_request.cancel();
            state.reveal.set_sensitive(state.selected.borrow().is_some());
            state.cancel.borrow().store(true, Ordering::Relaxed);
            state.request.set(state.request.get() + 1);
            state.generation.set(state.generation.get() + 1);
        }
    });
    *ui.project.borrow_mut() = Some(state.clone());
    super::chrome::sidebar(ui, &root, &path, &filter, &list_scroll);
    state.start_polling();
    window.present();
    state
}

#[cfg(debug_assertions)]
fn click_button(widget: &gtk::Widget, label: &str) -> bool {
    if let Some(button) = widget.downcast_ref::<gtk::Button>() {
        if button.label().as_deref() == Some(label) {
            button.emit_clicked();
            return true;
        }
    }
    let mut child = widget.first_child();
    while let Some(item) = child {
        if click_button(&item, label) {
            return true;
        }
        child = item.next_sibling();
    }
    false
}
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    let fixture = PathBuf::from(std::env::var_os("FASTRA_PROJECT_FIXTURE").unwrap());
    let state = open(&ui);
    support::test_size(&state.window);
    state
        .path
        .set_text(fixture.join("project").to_str().unwrap());
    let phase = Cell::new(0);
    let deadline = Instant::now();
    let original_count = ui.documents.borrow().len();
    gtk::glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            deadline.elapsed() < Duration::from_secs(30),
            "project timeout phase{} {}",
            phase.get(),
            state.status.text()
        );
        if state.busy.get() || state.tree.borrow().is_none() {
            return gtk::glib::ControlFlow::Continue;
        }
        let target = state
            .tree
            .borrow()
            .as_ref()
            .unwrap()
            .entries
            .iter()
            .find(|e| e.relative == Path::new("folder/target.txt"))
            .unwrap()
            .clone();
        match phase.get() {
            0 => {
                assert_eq!(state.tree.borrow().as_ref().unwrap().entries.len(), 5);
                state.filter.set_text("target.txt");
                let row = state
                    .list
                    .first_child()
                    .unwrap()
                    .downcast::<gtk::ListBoxRow>()
                    .unwrap();
                row.child()
                    .unwrap()
                    .downcast::<gtk::Button>()
                    .unwrap()
                    .emit_clicked();
                state.generation.set(state.generation.get() + 1);
                phase.set(1);
            }
            1 => {
                if deadline.elapsed() < Duration::from_millis(600) {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert_eq!(
                    ui.documents.borrow().len(),
                    original_count,
                    "stale project load must not open tab"
                );
                state.open_entry(&target);
                phase.set(2);
            }
            2 => {
                if ui.active().and_then(|doc| doc.disk_path()).as_ref() != Some(&fixture.join("project/folder/target.txt")) {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), original_count, "pristine scratch reused");
                assert_eq!(super::buffer_text(&ui.active().unwrap().buffer), "target café\r\n");
                state.filter.set_text("");
                state.hidden.set_active(true);
                phase.set(3);
            }
            3 => {
                assert_eq!(state.tree.borrow().as_ref().unwrap().entries.len(), 6);
                let directory = state
                    .list
                    .first_child()
                    .unwrap()
                    .downcast::<gtk::ListBoxRow>()
                    .unwrap()
                    .child()
                    .unwrap()
                    .downcast::<gtk::Button>()
                    .unwrap();
                assert!(state.collapsed.borrow().contains(Path::new("folder")));
                directory.emit_clicked();
                assert!(!state.collapsed.borrow().contains(Path::new("folder")));
                directory.emit_clicked();
                assert!(state.collapsed.borrow().contains(Path::new("folder")));
                click_button(
                    state.window.upcast_ref(),
                    ui.lang.text("Abbrechen", "Cancel"),
                );
                assert!(state.paused.get());
                assert!(state.tree.borrow().is_none());
                click_button(
                    state.window.upcast_ref(),
                    ui.lang.text("Aktualisieren", "Refresh"),
                );
                assert!(!state.paused.get());
                phase.set(4);
            }
            4 => {
                support::finish(state.window.clone(), ui.clone(), "project");
                return gtk::glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        gtk::glib::ControlFlow::Continue
    });
}

#[cfg(debug_assertions)]
mod scope_test;
#[cfg(debug_assertions)]
pub(super) fn scope_selftest(ui: Rc<Ui>) {
    scope_test::run(ui);
}

pub(super) fn current_binding(ui: &Rc<Ui>) -> Option<Binding> {
    ui.project
        .borrow()
        .as_ref()
        .and_then(|state| state.binding())
}

#[cfg(debug_assertions)]
pub(super) fn recent_selftest(ui: Rc<Ui>) {
    recent_projects::selftest(ui);
}

pub(super) fn context_id(ui:&Rc<Ui>)->Option<String> {
    ui.project.borrow().as_ref().map(|state|format!("project-{:x}-{}",Rc::as_ptr(state) as usize,state.root_generation.get()))
}


#[cfg(test)]
mod tests {
    #[test]
    fn displayed_raw_paths_keep_literal_escape_names_distinct() {
        use std::os::unix::ffi::OsStrExt;
        let invalid = std::path::Path::new(std::ffi::OsStr::from_bytes(b"pair-\xff"));
        let literal = std::path::Path::new(r"pair-\xff");
        assert_ne!(super::display(invalid), super::display(literal));
        assert_eq!(super::display(std::path::Path::new("café/雪")), "café/雪");
        assert_eq!(
            super::display(std::path::Path::new("line\nname")),
            r"line\nname"
        );
    }

    use super::*;
    use std::os::unix::ffi::OsStringExt;
    #[test]
    fn raw_paths_hidden_special_and_cancel() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir(dir.path().join("folder")).unwrap();
        fs::write(dir.path().join("folder/a"), "x").unwrap();
        fs::write(dir.path().join(".hidden"), "h").unwrap();
        let raw = std::ffi::OsString::from_vec(vec![b'x', 0xff]);
        fs::write(dir.path().join(&raw), "raw").unwrap();
        std::os::unix::fs::symlink("/", dir.path().join("escape")).unwrap();
        let cancel = AtomicBool::new(false);
        let tree = scan(dir.path(), false, &cancel).unwrap();
        assert_eq!(tree.entries.len(), 4);
        assert!(tree
            .entries
            .iter()
            .any(|e| e.relative.as_os_str() == raw.as_os_str()));
        assert!(
            !tree
                .entries
                .iter()
                .find(|e| e.relative == Path::new("escape"))
                .unwrap()
                .openable
        );
        assert_eq!(scan(dir.path(), true, &cancel).unwrap().entries.len(), 5);
        cancel.store(true, Ordering::Relaxed);
        assert!(scan(dir.path(), true, &cancel).is_err());
    }
    #[test]
    fn bounds_stop_before_partial_tree_is_exposed() {
        let dir = tempfile::tempdir().unwrap();
        for i in 0..=MAX_ENTRIES {
            fs::write(dir.path().join(i.to_string()), []).unwrap();
        }
        assert!(scan(dir.path(), true, &AtomicBool::new(false)).is_err());
    }
    #[test]
    fn stale_file_and_root_cannot_validate_a_loaded_tab() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("project");
        fs::create_dir(&root).unwrap();
        let path = root.join("a");
        fs::write(&path, "first").unwrap();
        let tree = scan(&root, true, &AtomicBool::new(false)).unwrap();
        let expected = tree.entries[0].identity;
        let loaded =
            super::super::viewer::Loaded::Editor(super::super::loader::read(&path).unwrap());
        assert!(validate_loaded(
            &root,
            tree.identity,
            &path,
            expected,
            &loaded
        ));
        fs::write(root.join("replacement"), "other").unwrap();
        fs::rename(root.join("replacement"), &path).unwrap();
        assert!(!validate_loaded(
            &root,
            tree.identity,
            &path,
            expected,
            &loaded
        ));
        fs::rename(&root, parent.path().join("renamed")).unwrap();
        fs::create_dir(&root).unwrap();
        fs::write(&path, "first").unwrap();
        assert!(!validate_loaded(
            &root,
            tree.identity,
            &path,
            expected,
            &loaded
        ));
    }
}

#[cfg(test)]
mod runtime_policy_tests {
    #[test]
    fn native_overlay_project_tree_is_not_partial() {
        if std::env::var("FASTRA_POLICY_TEST_CASE").as_deref() != Ok("overlay") { return; }
        let error = super::scan(std::path::Path::new("/usr/bin"), false, &std::sync::atomic::AtomicBool::new(false)).unwrap_err();
        assert!(error.contains("runtime shadows"), "{error}");
        assert!(super::scan(std::path::Path::new("/usr/share/zoneinfo/Etc"), false, &std::sync::atomic::AtomicBool::new(false)).is_ok());
    }
}


pub(crate) fn requested_path(ui: &Ui) -> Option<PathBuf> {
    ui.project.borrow().as_ref().and_then(|state| {
        if let Some(selected) = state.selected.borrow().as_ref() { return Some(selected.path.clone()); }
        let path = state.root_path.borrow().clone();
        if path.as_os_str().is_empty() { None }
        else if path.is_absolute() { Some(path) }
        else { std::env::current_dir().ok().map(|root| root.join(path)) }
    })
}
