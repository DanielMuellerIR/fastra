//! Gemeinsamer Suchpaarverlauf; Dateizugriffe und CAS laufen ausschließlich im Worker.
use super::{git_view as support, Language, Ui};
use fastra_workflow::search_history::{Change, Entry, Store, MAX_ENTRIES};
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
    focus: glib::WeakRef<gtk::Entry>,
    shortcut: gtk::ShortcutController,
    busy: Cell<bool>,
    queue: RefCell<VecDeque<Option<Change>>>,
}
fn config_root() -> Result<PathBuf, String> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .ok_or("No configuration directory available")?;
    if !root.is_absolute() {
        return Err("Configuration directory must be absolute".into());
    }
    Ok(root)
}
fn store_error(error: &fastra_workflow::Error, lang: Language) -> String {
    use fastra_workflow::Error;
    match error {
        Error::Limit => lang.text("Ein Such- oder Ersetzfeld darf für den Verlauf höchstens 64 KiB enthalten.", "Each history find or replace field may contain at most 64 KiB.").into(),
        Error::Json(_) | Error::Invalid(_) => lang.text("Die gespeicherte Liste ist beschädigt oder nicht sicher zugänglich. Die Datei bleibt erhalten.", "The saved list is damaged or cannot be accessed safely. The file is retained.").into(),
        Error::Stale => lang.text("Die Liste wurde gleichzeitig geändert. Bitte erneut versuchen.", "The list changed concurrently. Please retry.").into(),
        Error::Io(error) => error.to_string(),
        _ => lang.text("Die Liste konnte nicht verarbeitet werden.", "The list could not be processed.").into(),
    }
}
impl Menu {
    pub(super) fn new(ui: &Rc<Ui>) -> Rc<Self> {
        Self::for_window(ui, ui.window.upcast_ref(), &ui.find)
    }
    pub(super) fn for_window(ui: &Rc<Ui>, window: &gtk::Window, focus: &gtk::Entry) -> Rc<Self> {
        let lang = ui.lang;
        let button = gtk::MenuButton::builder()
            .label(lang.text("Suchverlauf", "Search history"))
            .build();
        button.set_tooltip_text(Some(lang.text(
            "Die letzten 15 Such-/Ersetz-Paare. Alt+H",
            "The last 15 find/replace pairs. Alt+H",
        )));
        let popover = gtk::Popover::new();
        let root = support::column();
        root.set_size_request(380, -1);
        root.append(&support::label(
            lang.text("Such-/Ersetz-Verlauf", "Find/replace history"),
        ));
        let status = support::label(lang.text(
            "Verlauf wird beim Öffnen frisch gelesen.",
            "History is refreshed when opened.",
        ));
        status.set_max_width_chars(48);
        root.append(&status);
        let list = gtk::Box::new(gtk::Orientation::Vertical, 4);
        let scroll = gtk::ScrolledWindow::builder()
            .child(&list)
            .min_content_height(70)
            .max_content_height(330)
            .propagate_natural_height(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        root.append(&scroll);
        let clear =
            gtk::Button::with_label(lang.text("Suchverlauf leeren", "Clear search history"));
        clear.set_sensitive(false);
        root.append(&clear);
        let explanation = support::label(lang.text(
            "Eine Auswahl füllt beide Felder. Suchmodus und Bereich bleiben erhalten.",
            "Select a pair to fill both fields. Search mode and scope are retained.",
        ));
        explanation.set_max_width_chars(48);
        root.append(&explanation);
        popover.set_child(Some(&root));
        button.set_popover(Some(&popover));
        let shortcuts = gtk::ShortcutController::new();
        let menu = Rc::new(Self {
            shortcut: shortcuts.clone(),
            button,
            popover,
            list,
            status,
            clear,
            ui: Rc::downgrade(ui),
            focus: focus.downgrade(),
            busy: Cell::new(false),
            queue: RefCell::new(VecDeque::new()),
        });
        let weak = Rc::downgrade(&menu);
        menu.popover.connect_visible_notify(move |popover| {
            if popover.is_visible() {
                if let Some(menu) = weak.upgrade() {
                    menu.enqueue(None);
                }
            }
        });
        let weak = Rc::downgrade(&menu);
        menu.clear.connect_clicked(move |_| {
            if let Some(menu) = weak.upgrade() {
                menu.enqueue(Some(Change::Clear));
            }
        });
        shortcuts.set_scope(gtk::ShortcutScope::Managed);
        let weak = Rc::downgrade(&menu);
        shortcuts.add_shortcut(gtk::Shortcut::new(
            gtk::ShortcutTrigger::parse_string("<Alt>h"),
            Some(gtk::CallbackAction::new(move |_, _| {
                if let Some(menu) = weak.upgrade() {
                    menu.button.popup();
                }
                glib::Propagation::Stop
            })),
        ));
        window.add_controller(shortcuts);
        menu
    }
    pub(super) fn attach_shortcut(&self, window: &gtk::Window) {
        if let Some(owner) = self.shortcut.widget() {
            owner.remove_controller(&self.shortcut);
        }
        window.add_controller(self.shortcut.clone());
    }
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |ui| ui.lang)
    }
    fn alive(&self) -> bool {
        self.ui.upgrade().is_some_and(|ui| ui.window.is_visible())
    }
    pub(super) fn remember(self: &Rc<Self>, find: String, replace: String) {
        if find.is_empty() {
            return;
        }
        self.enqueue(Some(Change::Remember(Entry { find, replace })));
    }
    fn enqueue(self: &Rc<Self>, change: Option<Change>) {
        let mut queue = self.queue.borrow_mut();
        match &change {
            Some(Change::Remember(entry)) => {
                // Nur nach dem letzten expliziten Leeren zusammenfassen; dessen Reihenfolge gilt.
                let barrier = queue
                    .iter()
                    .rposition(|c| matches!(c, Some(Change::Clear)))
                    .map_or(0, |n| n + 1);
                let mut tail = queue.split_off(barrier);
                tail.retain(|c| !matches!(c, Some(Change::Remember(old)) if old == entry));
                tail.push_back(change);
                let mut count = tail
                    .iter()
                    .filter(|c| matches!(c, Some(Change::Remember(_))))
                    .count();
                while count > MAX_ENTRIES {
                    let i = tail
                        .iter()
                        .position(|c| matches!(c, Some(Change::Remember(_))))
                        .unwrap();
                    tail.remove(i);
                    count -= 1;
                }
                queue.extend(tail);
            }
            Some(Change::Clear) => {
                queue.clear();
                queue.push_back(change);
            }
            None => {
                if !queue.iter().any(Option::is_none) {
                    queue.push_back(None);
                }
            }
        }
        drop(queue);
        self.drain();
    }
    fn drain(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(change) = self.queue.borrow_mut().pop_front() else {
            return;
        };
        self.busy.set(true);
        self.list.set_sensitive(false);
        self.clear.set_sensitive(false);
        self.status.set_text(self.lang().text(
            "Suchverlauf wird aktualisiert …",
            "Updating search history …",
        ));
        let writing = change.is_some();
        let lang = self.lang();
        let menu = self.clone();
        // Die begrenzte Auftragsliste bleibt auch beim Schließen des Fensters am Leben.
        // Rückgaben fassen ausschließlich ihr ursprüngliches, noch sichtbares Fenster an.
        support::background(
            move || {
                let store = Store::open(&config_root()?).map_err(|e| store_error(&e, lang))?;
                match change {
                    Some(change) => store.apply(&change),
                    None => store.load(),
                }
                .map_err(|e| store_error(&e, lang))
            },
            move |result| {
                menu.busy.set(false);
                if menu.alive() {
                    match result {
                        Ok(entries) => menu.render(entries),
                        Err(error) => {
                            let message = format!("{}: {error}", menu.lang().text("Suchverlauf konnte nicht geladen oder gespeichert werden. Erneut öffnen, um es nochmals zu versuchen.", "Search history could not be loaded or saved. Reopen to retry."));
                            menu.status.set_text(&message);
                            menu.list.set_sensitive(false);
                            if writing {
                                if let Some(ui) = menu.ui.upgrade() {
                                    ui.status.set_text(&message);
                                }
                            }
                        }
                    }
                }
                menu.drain();
            },
        );
    }
    fn render(self: &Rc<Self>, entries: Vec<Entry>) {
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        self.list.set_sensitive(true);
        self.clear.set_sensitive(!entries.is_empty());
        self.status.set_text(self.lang().text(
            "Zuletzt benutzt zuerst · höchstens 15 Paare",
            "Most recent first · up to 15 pairs",
        ));
        if entries.is_empty() {
            self.list.append(&support::label(
                self.lang()
                    .text("Noch keine Suche gemerkt.", "No searches remembered yet."),
            ));
        }
        for entry in entries {
            let button = gtk::Button::new();
            let row = gtk::Box::new(gtk::Orientation::Vertical, 2);
            for (prefix, text) in [
                (self.lang().text("Suchen", "Find"), entry.find.as_str()),
                (
                    self.lang().text("Ersetzen", "Replace"),
                    entry.replace.as_str(),
                ),
            ] {
                let shown: String = text
                    .chars()
                    .take(180)
                    .flat_map(|c| match c {
                        '\n' => "↵".chars().collect::<Vec<_>>(),
                        '\r' => "␍".chars().collect(),
                        '\t' => "⇥".chars().collect(),
                        '\0' => "␀".chars().collect(),
                        c => vec![c],
                    })
                    .collect();
                let label = gtk::Label::new(Some(&format!("{prefix}: {shown}")));
                label.set_xalign(0.);
                label.set_width_chars(32);
                label.set_max_width_chars(48);
                label.set_ellipsize(gtk::pango::EllipsizeMode::End);
                row.append(&label);
            }
            button.set_child(Some(&row));
            self.list.append(&button);
            let weak = Rc::downgrade(self);
            button.connect_clicked(move |_| {
                if let Some(menu) = weak.upgrade() {
                    if menu.alive() && !menu.busy.get() {
                        if let Some(ui) = menu.ui.upgrade() {
                            // Reguläre Entry-Signale invalidieren jede alte Vorschau.
                            ui.find.set_text(&entry.find);
                            ui.replace.set_text(&entry.replace);
                            menu.popover.popdown();
                            if let Some(field) = menu.focus.upgrade() {
                                field.grab_focus();
                            }
                        }
                    }
                }
            });
        }
    }
}
pub(super) fn remember(ui: &Ui) {
    if let Some(menu) = ui.search_history.borrow().as_ref() {
        menu.remember(ui.find.text().into(), ui.replace.text().into());
    }
}
#[cfg(debug_assertions)]
#[path = "search_history/gui_test.rs"]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
