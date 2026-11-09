//! Sichtbare Projektliste; jede IO läuft auf einem Worker, Labels sind niemals Pfadquelle.
use super::super::{git_view as support, Language, Ui};
use fastra_workflow::recent_projects::{Change, Store};
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    path::PathBuf,
    rc::{Rc, Weak},
};

pub(super) struct Menu {
    pub(super) button: gtk::MenuButton,
    popover: gtk::Popover,
    list: gtk::Box,
    status: gtk::Label,
    clear: gtk::Button,
    ui: Weak<Ui>,
    owner: glib::WeakRef<gtk::Window>,
    on_open: Rc<dyn Fn(PathBuf)>,
    busy: Cell<bool>,
    pending_remember: RefCell<VecDeque<PathBuf>>,
}
fn config_root() -> Result<PathBuf, String> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .ok_or("No configuration directory available")?;
    if !root.is_absolute() {
        return Err("Configuration directory must be absolute".into());
    }
    Ok(root)
}
impl Menu {
    pub(super) fn new(ui: &Rc<Ui>, owner: &gtk::Window, on_open: Rc<dyn Fn(PathBuf)>) -> Rc<Self> {
        let lang = ui.lang;
        let button = gtk::MenuButton::builder()
            .label(lang.text("Zuletzt benutzte Projekte …", "Recent projects …"))
            .halign(gtk::Align::Start)
            .build();
        let popover = gtk::Popover::new();
        let root = support::column();
        root.set_size_request(450, -1);
        root.append(&support::label(
            lang.text("Zuletzt benutzte Projekte", "Recent projects"),
        ));
        let status = support::label(lang.text(
            "Liste wird beim Öffnen frisch gelesen.",
            "The list is refreshed when opened.",
        ));
        root.append(&status);
        let list = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let scroll = gtk::ScrolledWindow::builder()
            .child(&list)
            .min_content_height(80)
            .max_content_height(340)
            .propagate_natural_height(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        root.append(&scroll);
        let clear =
            gtk::Button::with_label(lang.text("Alle Einträge entfernen", "Clear all entries"));
        root.append(&clear);
        root.append(&support::label(lang.text(
            "Nur die Liste wird geändert; Projekte und Dateien bleiben erhalten.",
            "Only the list changes; projects and files are retained.",
        )));
        popover.set_child(Some(&root));
        button.set_popover(Some(&popover));
        let menu = Rc::new(Self {
            button,
            popover,
            list,
            status,
            clear,
            ui: Rc::downgrade(ui),
            owner: owner.downgrade(),
            on_open,
            busy: Cell::new(false),
            pending_remember: RefCell::new(VecDeque::new()),
        });
        let weak = Rc::downgrade(&menu);
        menu.popover.connect_visible_notify(move |popover| {
            if popover.is_visible() {
                if let Some(menu) = weak.upgrade() {
                    menu.refresh();
                }
            }
        });
        let weak = Rc::downgrade(&menu);
        menu.clear.connect_clicked(move |_| {
            if let Some(menu) = weak.upgrade() {
                menu.run(Some(Change::Clear));
            }
        });
        menu
    }
    fn language(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |ui| ui.lang)
    }
    fn alive(&self) -> bool {
        self.ui.upgrade().is_some_and(|ui| ui.window.is_visible())
            && self.owner.upgrade().is_some_and(|w| w.is_visible())
    }
    pub(super) fn remember(self: &Rc<Self>, path: PathBuf) {
        if self.busy.get() {
            let mut pending = self.pending_remember.borrow_mut();
            pending.retain(|p| p != &path);
            pending.push_back(path);
            if pending.len() > 12 {
                pending.pop_front();
            }
        } else {
            self.run(Some(Change::Remember(path)));
        }
    }
    fn refresh(self: &Rc<Self>) {
        self.run(None);
    }
    fn run(self: &Rc<Self>, change: Option<Change>) {
        if self.busy.replace(true) {
            return;
        }
        self.list.set_sensitive(false);
        self.clear.set_sensitive(false);
        self.status.set_text(self.language().text(
            "Projektliste wird aktualisiert …",
            "Updating project list …",
        ));
        let weak = Rc::downgrade(self);
        let writing = change.is_some();
        support::background(
            move || {
                let store = Store::open(&config_root()?).map_err(|e| e.to_string())?;
                match change {
                    Some(change) => store.apply(&change),
                    None => store.load(),
                }
                .map_err(|e| e.to_string())
            },
            move |result| {
                let Some(menu) = weak.upgrade() else { return };
                menu.busy.set(false);
                if menu.alive() {
                    match result {
                        Ok(paths) => menu.render(paths),
                        Err(error) => {
                            menu.status.set_text(&format!("{}: {error}",menu.language().text("Projektliste nicht geändert oder geladen. Erneut öffnen, um es nochmals zu versuchen", "Project list not changed or loaded. Reopen to retry")));
                            menu.list.set_sensitive(false);
                            if writing {
                                if let Some(ui) = menu.ui.upgrade() {
                                    ui.status.set_text(&format!("{}: {error}",ui.lang.text("Projektliste nicht gespeichert; Projektdateien unverändert", "Project list not saved; project files unchanged")));
                                }
                            }
                        }
                    }
                }
                let next = menu.pending_remember.borrow_mut().pop_front();
                if let Some(path) = next {
                    menu.remember(path);
                }
            },
        );
    }
    fn render(self: &Rc<Self>, paths: Vec<PathBuf>) {
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let lang = self.language();
        self.clear.set_sensitive(!paths.is_empty());
        self.list.set_sensitive(true);
        self.status.set_text(lang.text(
            "Öffnen liest den Ordner neu; kein automatischer Projektstart.",
            "Open scans the folder again; projects never start automatically.",
        ));
        if paths.is_empty() {
            self.list.append(&support::label(
                lang.text("Noch keine Projekte gemerkt.", "No recent projects yet."),
            ));
        }
        for path in paths {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            let label = gtk::Label::new(Some(&super::display(&path)));
            label.set_xalign(0.);
            label.set_hexpand(true);
            label.set_width_chars(14);
            label.set_max_width_chars(40);
            label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            label.set_tooltip_text(Some(&super::display(&path)));
            let open = gtk::Button::with_label(lang.text("Öffnen", "Open"));
            let remove = gtk::Button::with_label(lang.text("Entfernen", "Remove"));
            row.append(&label);
            row.append(&open);
            row.append(&remove);
            self.list.append(&row);
            let selected = path.clone();
            let weak = Rc::downgrade(self);
            open.connect_clicked(move |_| {
                if let Some(menu) = weak.upgrade() {
                    if menu.alive() && !menu.busy.get() {
                        menu.popover.popdown();
                        (menu.on_open)(selected.clone());
                    }
                }
            });
            let weak = Rc::downgrade(self);
            remove.connect_clicked(move |_| {
                if let Some(menu) = weak.upgrade() {
                    menu.run(Some(Change::Remove(path.clone())));
                }
            });
        }
    }
}

#[cfg(debug_assertions)]
#[path = "recent_projects/gui_test.rs"]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}

pub(super) fn welcome(ui: &Rc<Ui>) -> gtk::Box {
    let list = gtk::Box::new(gtk::Orientation::Vertical, 3);
    let weak = Rc::downgrade(ui);
    let generation = Rc::new(Cell::new(0u64));
    list.connect_map(move |list| {
        let request = generation.get().wrapping_add(1);
        generation.set(request);
        let generation = generation.clone();
        let target = list.downgrade();
        let weak = weak.clone();
        support::background(
            || Store::open(&config_root()?).and_then(|store| store.load()).map_err(|error| error.to_string()),
            move |result| {
                let (Some(list), Some(ui)) = (target.upgrade(), weak.upgrade()) else { return; };
                if !list.is_mapped() || generation.get() != request { return; }
                while let Some(child) = list.first_child() { list.remove(&child); }
                match result {
                    Ok(paths) if !paths.is_empty() => {
                        for path in paths.into_iter().take(5) {
                            let button = gtk::Button::new();
                            button.add_css_class("welcome-action");
                            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
                            row.append(&gtk::Image::from_icon_name("fastra-folder-symbolic"));
                            let name = gtk::Label::new(Some(&super::display(path.file_name().map(std::path::Path::new).unwrap_or(&path))));
                            name.set_xalign(0.); name.set_hexpand(true); row.append(&name);
                            let location = gtk::Label::new(Some(&super::display(&path)));
                            location.set_max_width_chars(28); location.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
                            location.add_css_class("welcome-description"); row.append(&location);
                            button.set_child(Some(&row));
                            button.set_tooltip_text(Some(&super::display(&path)));
                            let weak = Rc::downgrade(&ui);
                            button.connect_clicked(move |_| { if let Some(ui) = weak.upgrade() { super::super::chrome::open_project(&ui, path.clone()); } });
                            list.append(&button);
                        }
                    }
                    result => {
                        let text = match result {
                            Ok(_) => ui.lang.text("Projekte merkt sich Fastra von selbst: Öffne einen Ordner.", "Fastra remembers projects automatically: open a folder.").into(),
                            Err(error) => format!("{}: {error}", ui.lang.text("Projektliste nicht gelesen", "Could not read recent projects")),
                        };
                        let label = gtk::Label::new(Some(&text));
                        label.set_wrap(true); label.set_xalign(0.); label.set_max_width_chars(52);
                        label.add_css_class("welcome-description"); list.append(&label);
                    }
                }
            },
        );
    });
    list
}
