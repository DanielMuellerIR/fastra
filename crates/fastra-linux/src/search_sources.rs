//! Suchquellen verwenden echte Pfade und eine frisch zusammengeführte private Ablage.
use super::*;
use fastra_workflow::search_locations::{Change, FileSet, ProjectChange, Settings, Store};
use std::{collections::VecDeque, path::PathBuf, rc::Weak};
pub(super) struct Request {
    pub roots: Vec<PathBuf>,
    pub paths: Option<Vec<PathBuf>>,
    pub exclusions: Vec<String>,
}
pub(super) struct Controls {
    pub root: gtk::Box,
    header: RefCell<Option<gtk::Widget>>,
    ui: Weak<Ui>,
    owner: glib::WeakRef<gtk::Window>,
    project: Option<PathBuf>,
    settings: RefCell<Settings>,
    ready: Cell<bool>,
    busy: Cell<bool>,
    changing: Cell<bool>,
    queue: RefCell<VecDeque<Option<Change>>>,
    changed: Rc<dyn Fn()>,
    model: gtk::StringList,
    list: gtk::ListView,
    scroll: gtk::ScrolledWindow,
    sets: gtk::DropDown,
    filter: gtk::DropDown,
    remove_set: gtk::Button,
    excludes: gtk::Entry,
    known: gtk::CheckButton,
    feedback: gtk::Label,
    exclusions_generation: Cell<u64>,
    queued_exclusions_generation: Cell<u64>,
}
pub(crate) fn config_root() -> Result<PathBuf, String> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .ok_or("No configuration directory")?;
    if !root.is_absolute() {
        return Err("Configuration directory must be absolute".into());
    }
    Ok(root)
}
fn label(lang: Language, de: &'static str, en: &'static str) -> gtk::Label {
    let label = gtk::Label::new(Some(lang.text(de, en)));
    label.set_xalign(0.);
    label.set_width_request(80);
    label.add_css_class("search-field-label");
    label
}
impl Controls {
    pub fn new(
        ui: &Rc<Ui>,
        owner: &gtk::Window,
        project: Option<PathBuf>,
        excludes: &gtk::Entry,
        known: &gtk::CheckButton,
        changed: Rc<dyn Fn()>,
    ) -> Rc<Self> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let model = gtk::StringList::new(&[]);
        let factory = gtk::SignalListItemFactory::new();
        let list = gtk::ListView::new(
            Some(gtk::NoSelection::new(Some(model.clone()))),
            Some(factory.clone()),
        );
        list.add_css_class("search-folder-list");
        let scroll = gtk::ScrolledWindow::builder()
            .child(&list)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .max_content_height(168)
            .propagate_natural_height(true)
            .build();
        scroll.add_css_class("search-folder-sources");
        let sets = gtk::DropDown::from_strings(&[]);
        let set_factory = gtk::SignalListItemFactory::new();
        set_factory.connect_setup(|_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let label = gtk::Label::new(None);
            label.set_xalign(0.);
            label.set_width_chars(1);
            label.set_max_width_chars(28);
            label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            item.set_child(Some(&label));
        });
        set_factory.connect_bind(|_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let text = item
                .item()
                .and_downcast::<gtk::StringObject>()
                .unwrap()
                .string();
            let label = item.child().and_downcast::<gtk::Label>().unwrap();
            use unicode_segmentation::UnicodeSegmentation;
            let characters = text.graphemes(true).collect::<Vec<_>>();
            let shown = if characters.len() > 28 {
                format!(
                    "{}…{}",
                    characters[..14].concat(),
                    characters[characters.len() - 13..].concat()
                )
            } else {
                text.to_string()
            };
            label.set_text(&shown);
            label.set_tooltip_text(Some(&text));
        });
        sets.set_factory(Some(&set_factory));
        sets.set_hexpand(true);
        sets.set_width_request(120);
        let filter = gtk::DropDown::from_strings(&[
            ui.lang.text("Bekannte Textformate", "Known text formats"),
            ui.lang.text("Alle Dateien", "All files"),
        ]);
        sets.update_property(&[gtk::accessible::Property::Label(
            ui.lang.text("Datei-Set", "File set"),
        )]);
        filter.update_property(&[gtk::accessible::Property::Label(
            ui.lang.text("Dateitypen", "File types"),
        )]);
        list.update_property(&[gtk::accessible::Property::Label(
            ui.lang.text("Suchordner", "Search folders"),
        )]);
        let feedback = git_view::label("");
        feedback.add_css_class("search-feedback");
        feedback.set_visible(false);
        let remove_set = chrome::icon(
            "list-remove-symbolic",
            ui.lang
                .text("Aktives Datei-Set löschen", "Delete active file set"),
        );
        let s = Rc::new(Self {
            root,
            header: RefCell::new(None),
            ui: Rc::downgrade(ui),
            owner: owner.downgrade(),
            project,
            settings: RefCell::new(Settings::default()),
            ready: Cell::new(false),
            busy: Cell::new(false),
            changing: Cell::new(false),
            queue: RefCell::new(VecDeque::new()),
            changed,
            model,
            list,
            scroll,
            sets,
            filter,
            remove_set,
            excludes: excludes.clone(),
            known: known.clone(),
            feedback,
            exclusions_generation: Cell::new(0),
            queued_exclusions_generation: Cell::new(0),
        });
        if s.project.is_some() {
            s.project_layout(ui);
        } else {
            s.folder_layout(ui, &factory);
        }
        s.root.append(&s.feedback);
        let weak = Rc::downgrade(&s);
        s.filter.connect_selected_notify(move |filter| {
            if let Some(s) = weak.upgrade() {
                if !s.changing.get() {
                    s.known.set_active(filter.selected() == 0);
                    let change = if let Some(root) = s.project.as_ref() {
                        Change::Project(
                            root.clone(),
                            ProjectChange::KnownText(filter.selected() == 0),
                        )
                    } else {
                        Change::KnownText(filter.selected() == 0)
                    };
                    s.enqueue(Some(change));
                }
            }
        });
        let weak = Rc::downgrade(&s);
        s.excludes.connect_changed(move |_| {
            if let Some(s) = weak.upgrade() {
                if s.changing.get() {
                    return;
                }
                (s.changed)();
                if let Some(root) = s.project.clone() {
                    let generation = s.exclusions_generation.get().wrapping_add(1);
                    s.exclusions_generation.set(generation);
                    let weak = Rc::downgrade(&s);
                    glib::timeout_add_local_once(Duration::from_millis(200), move || {
                        if let Some(s) = weak
                            .upgrade()
                            .filter(|s| s.exclusions_generation.get() == generation)
                        {
                            s.queued_exclusions_generation.set(generation);
                            s.enqueue(Some(Change::Project(
                                root,
                                ProjectChange::Exclusions(s.excludes.text().into()),
                            )));
                        }
                    });
                }
            }
        });
        s.enqueue(None);
        s
    }
    pub fn header(&self, scopes: &gtk::Box) -> Option<gtk::Widget> {
        self.project.as_ref()?;
        let original = self.root.first_child()?.downcast::<gtk::FlowBox>().ok()?;
        let header = chrome::wrap_row::Row::new(8, 8);
        header.append(scopes);
        for row in chrome::children(&original) {
            let row = row.downcast::<gtk::FlowBoxChild>().unwrap();
            let group = row.child().unwrap();
            row.set_child(None::<&gtk::Widget>);
            original.remove(&row);
            let container = group.downcast::<gtk::Box>().unwrap();
            let label = container
                .first_child()
                .unwrap()
                .downcast::<gtk::Label>()
                .unwrap();
            container.remove(&label);
            header.append_labeled(&label, &container);
        }
        self.root.remove(&original);
        let header: gtk::Widget = header.upcast();
        *self.header.borrow_mut() = Some(header.clone());
        Some(header)
    }
    pub fn set_busy(&self, busy: bool) {
        self.root.set_sensitive(!busy);
        if let Some(header) = self.header.borrow().as_ref() {
            header.set_sensitive(!busy);
        }
    }
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |ui| ui.lang)
    }
    pub fn busy(&self) -> bool {
        self.busy.get()
            || !self.queue.borrow().is_empty()
            || self.exclusions_generation.get() != self.queued_exclusions_generation.get()
    }
    pub fn request(&self) -> Result<Request, String> {
        if !self.ready.get() || self.busy() {
            return Err(self
                .lang()
                .text(
                    "Suchquellen werden geladen. Bitte warten.",
                    "Loading search sources. Please wait.",
                )
                .into());
        }
        let settings = self.settings.borrow();
        let (roots, paths) = if let Some(root) = self.project.as_ref() {
            let p = settings.project(root);
            (
                vec![root.clone()],
                Some(p.selected().paths.iter().map(PathBuf::from).collect()),
            )
        } else {
            (
                settings
                    .folders
                    .iter()
                    .filter(|f| f.enabled)
                    .map(|f| f.path())
                    .collect::<Vec<_>>(),
                None,
            )
        };
        if roots.len() > 64 {
            return Err(self.lang().text("Höchstens 64 Ordner gleichzeitig auswählen. Auswahl verkleinern; keine Teilsuche ausgeführt.", "Select at most 64 folders at once. Reduce the selection; no partial search was performed.").into());
        }
        if roots.is_empty() {
            return Err(self
                .lang()
                .text(
                    "Kein Ordner ausgewählt. Mindestens einen aktivieren.",
                    "No folder selected. Enable at least one.",
                )
                .into());
        }
        let mut exclusions = self
            .excludes
            .text()
            .split([',', ';', '\n', '\r'])
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect::<Vec<_>>();
        if self.project.is_some() && !exclusions.iter().any(|p| p == "DerivedData") {
            exclusions.push("DerivedData".into());
        }
        Ok(Request {
            roots,
            paths,
            exclusions,
        })
    }
    #[cfg(debug_assertions)]
    pub fn test_root(self: &Rc<Self>, path: PathBuf) {
        let old = self
            .settings
            .borrow()
            .folders
            .iter()
            .map(|f| f.path())
            .collect::<Vec<_>>();
        for folder in old {
            self.enqueue(Some(Change::EnableFolder(folder, false)));
        }
        self.enqueue(Some(Change::AddFolders(vec![path])));
    }
    pub fn choose(self: &Rc<Self>) {
        let dialog = gtk::FileDialog::builder()
            .title(self.lang().text("Ordner hinzufügen", "Add folders"))
            .build();
        let weak = Rc::downgrade(self);
        dialog.select_multiple_folders(
            self.owner.upgrade().as_ref(),
            None::<&gio::Cancellable>,
            move |result| {
                if let (Some(s), Ok(files)) = (weak.upgrade(), result) {
                    let paths = (0..files.n_items())
                        .filter_map(|i| {
                            files
                                .item(i)
                                .and_downcast::<gio::File>()
                                .and_then(|f| f.path())
                        })
                        .collect();
                    s.enqueue(Some(Change::AddFolders(paths)));
                }
            },
        );
    }
    pub fn enqueue(self: &Rc<Self>, change: Option<Change>) {
        if change.is_some() {
            (self.changed)();
        }
        self.queue.borrow_mut().push_back(change);
        self.run_next();
    }
}

#[cfg(debug_assertions)]
pub(super) mod selftest;

mod editor;
mod folder_list;
mod persistence;
mod project;
