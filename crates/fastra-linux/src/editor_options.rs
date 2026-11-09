use super::{Document, Ui};
use gtk::{glib, prelude::*};
use sourceview5::prelude::*;
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::{Rc, Weak},
};
pub(super) mod font;
mod font_selection;
pub(crate) mod printing;
pub(crate) mod startup;
pub(super) mod reading_font;
pub(super) mod markdown_preview;
pub(super) mod markdown_mode;
pub(super) mod appearance;
pub(super) mod zoom;
pub(super) mod settings_form;
mod page_guide;
mod profile;
mod store;
mod soft_wrap;
#[cfg(debug_assertions)]
pub(crate) mod async_gui_test;

type LanguageWidget = (glib::WeakRef<gtk::DropDown>, Vec<Option<String>>);
struct DialogSelection {
    buffer: glib::WeakRef<sourceview5::Buffer>,
    view: glib::WeakRef<sourceview5::View>,
    head: gtk::TextMark,
    anchor: gtk::TextMark,
    revision: u64,
    epoch: u64,
    interaction: u64,
    pane: crate::source_panes::Target,
}
impl Drop for DialogSelection {
    fn drop(&mut self) {
        if let Some(buffer) = self.buffer.upgrade() {
            for mark in [&self.head, &self.anchor] {
                if !mark.is_deleted() {
                    buffer.delete_mark(mark);
                }
            }
        }
    }
}
pub(super) struct Options {
    ui: Weak<Ui>,
    doc: Weak<Document>,
    views: [glib::WeakRef<sourceview5::View>; 2],
    choice: RefCell<Option<String>>,
    generation: Cell<u64>,
    numbers: Cell<bool>,
    guide_controls: page_guide::Controls,
    soft_wrap: soft_wrap::State,
    source_pane: Cell<usize>,
    source_interaction: Cell<u64>,
    dialog_epoch: Cell<u64>,
    dialog_selection: RefCell<Option<DialogSelection>>,
    root_input: RefCell<Option<gtk::EventControllerLegacy>>,
    tab_switch: RefCell<Option<glib::SignalHandlerId>>,
    profile_key: RefCell<String>,
    profile_generation: Cell<u64>,
    profile_edits: RefCell<profile::Patch>,
    profile_spins: RefCell<Vec<(glib::WeakRef<gtk::SpinButton>, u8)>>,
    spaces_widget: RefCell<Option<glib::WeakRef<gtk::CheckButton>>>,
    wrap_widget: RefCell<Option<glib::WeakRef<gtk::CheckButton>>>,
    loaded: Cell<bool>,
    language_pending: Cell<bool>,
    language_read: Cell<u64>,
    profile_status: RefCell<Option<glib::WeakRef<gtk::Label>>>,
    writing: Cell<bool>,
    write_again: Cell<bool>,
    updating: Cell<bool>,
    language_widget: RefCell<Option<LanguageWidget>>,
    window: RefCell<Option<glib::WeakRef<gtk::Window>>>,
}
pub(super) fn comparison_attached(doc: &Document) {
    if let Some(options) = doc.editor_options.borrow().as_ref() {
        options.load_profile();
    }
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
pub(super) fn install(
    ui: &Rc<Ui>,
    doc: &Rc<Document>,
    views: [&sourceview5::View; 2],
    options: &gtk::FlowBox,
) {
    let state = Rc::new(Options {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(doc),
        views: views.map(|v| v.downgrade()),
        choice: RefCell::new(None),
        generation: Cell::new(0),
        numbers: Cell::new(true),
        guide_controls: page_guide::Controls::default(),
        soft_wrap: soft_wrap::State::default(),
        source_pane: Cell::new(0),
        source_interaction: Cell::new(0),
        dialog_epoch: Cell::new(0),
        dialog_selection: RefCell::new(None),
        root_input: RefCell::new(None),
        tab_switch: RefCell::new(None),
        profile_key: RefCell::new(String::new()),
        profile_generation: Cell::new(0),
        profile_edits: RefCell::new(profile::Patch::default()),
        profile_spins: RefCell::new(Vec::new()),
        spaces_widget: RefCell::new(None),
        wrap_widget: RefCell::new(None),
        loaded: Cell::new(false),
        language_pending: Cell::new(false),
        language_read: Cell::new(0),
        profile_status: RefCell::new(None),
        writing: Cell::new(false),
        write_again: Cell::new(false),
        updating: Cell::new(false),
        language_widget: RefCell::new(None),
        window: RefCell::new(None),
    });
    let button = gtk::Button::with_label(ui.lang.text("Editoroptionen …", "Editor options …"));
    let weak = Rc::downgrade(&state);
    button.connect_clicked(move |button| {
        // Den Menü-Grab vor dem neuen Fenster lösen; sonst verschluckt das
        // noch offene Popover dessen ersten Klick.
        if let Some(popover) = button.ancestor(gtk::Popover::static_type()).and_downcast::<gtk::Popover>() {
            popover.popdown();
        }
        if let Some(state) = weak.upgrade() {
            state.show();
        }
    });
    options.insert(&button, -1);
    state.apply_language();
    *doc.editor_options.borrow_mut() = Some(state.clone());
    profile::install(&state);
    page_guide::install(&state);
    soft_wrap::install(&state);
    state.watch_source_selection(ui, doc);
}
fn automatic(doc: &Document) {
    let path = doc
        .snapshot
        .borrow()
        .as_ref()
        .map(|s| s.path().to_path_buf());
    let name = path.as_ref().and_then(|p| p.to_str()).unwrap_or(&doc.name);
    doc.buffer.set_language(
        sourceview5::LanguageManager::default()
            .guess_language(Some(name), None)
            .as_ref(),
    );
}
impl Drop for Options {
    fn drop(&mut self) {
        if let Some(input) = self.root_input.get_mut().take() {
            if let Some(widget) = input.widget() {
                widget.remove_controller(&input);
            }
        }
        if let (Some(ui), Some(signal)) = (self.ui.upgrade(), self.tab_switch.get_mut().take()) {
            ui.tabs.disconnect(signal);
        }
    }
}
impl Options {
    fn cancel_dialog_selection(&self) {
        self.source_interaction
            .set(self.source_interaction.get().wrapping_add(1));
        self.dialog_selection.borrow_mut().take();
    }
    fn watch_source_selection(self: &Rc<Self>, ui: &Rc<Ui>, _doc: &Rc<Document>) {
        let input = gtk::EventControllerLegacy::new();
        input.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(self);
        input.connect_event(move |_, event| {
            if matches!(
                event.event_type(),
                gtk::gdk::EventType::ButtonPress
                    | gtk::gdk::EventType::KeyPress
                    | gtk::gdk::EventType::Scroll
                    | gtk::gdk::EventType::TouchBegin
            ) {
                if let Some(state) = weak.upgrade() {
                    state.cancel_dialog_selection();
                }
            }
            glib::Propagation::Proceed
        });
        ui.window.add_controller(input.clone());
        *self.root_input.borrow_mut() = Some(input);
        let weak = Rc::downgrade(self);
        *self.tab_switch.borrow_mut() = Some(ui.tabs.connect_switch_page(move |_, _, _| {
            if let Some(state) = weak.upgrade() {
                state.cancel_dialog_selection();
            }
        }));
        for (index, view) in self.views.iter().enumerate() {
            if let Some(view) = view.upgrade() {
                let weak = Rc::downgrade(self);
                view.connect_has_focus_notify(move |view| {
                    if view.has_focus() {
                        if let Some(state) = weak.upgrade() {
                            state.source_pane.set(index);
                        }
                    }
                });
                let weak = Rc::downgrade(self);
                view.connect_buffer_notify(move |_| {
                    if let Some(state) = weak.upgrade() {
                        state.cancel_dialog_selection();
                    }
                });
                let weak = Rc::downgrade(self);
                view.connect_unmap(move |_| {
                    if let Some(state) = weak.upgrade() {
                        state.cancel_dialog_selection();
                    }
                });
            }
        }
        for view in self.views.iter().filter_map(|v|v.upgrade()) {
        let weak = Rc::downgrade(self);
        view.buffer().connect_mark_set(move |buffer, _, mark| {
            if !matches!(mark.name().as_deref(), Some("insert" | "selection_bound")) {
                return;
            }
            let Some(state) = weak.upgrade() else {
                return;
            };
            if state.dialog_selection.borrow().as_ref().is_some_and(|snapshot| snapshot.buffer.upgrade().is_none_or(|b|b.upcast_ref::<gtk::TextBuffer>()!=buffer)) {return;}
            let keep = {
                let held = state.dialog_selection.borrow();
                held.as_ref().is_some_and(|snapshot| {
                    let head = buffer.cursor_position();
                    let anchor = buffer.iter_at_mark(&buffer.selection_bound()).offset();
                    let saved_head = buffer.iter_at_mark(&snapshot.head).offset();
                    let saved_anchor = buffer.iter_at_mark(&snapshot.anchor).offset();
                    let dialog_active = state
                        .window
                        .borrow()
                        .as_ref()
                        .and_then(|w| w.upgrade())
                        .is_some_and(|w| w.is_active());
                    // Gtk-PRIMARY darf beim Editieren im Dialog nur den Auswahlanker einklappen.
                    mark.name().as_deref() != Some("insert")
                        && head == saved_head
                        && (anchor == saved_anchor || anchor == head && dialog_active)
                })
            };
            #[cfg(debug_assertions)]
            if std::env::var_os("FASTRA_OPTIONS_FOCUS_SELFTEST").is_some() {
                eprintln!(
                    "OPTIONS source mark {:?} head={} anchor={} keep={keep}",
                    mark.name(),
                    buffer.cursor_position(),
                    buffer.iter_at_mark(&buffer.selection_bound()).offset()
                );
            }
            if !keep {
                state.cancel_dialog_selection();
            }
        });
        }
    }
    fn selection_owner(
        &self,
        snapshot: &DialogSelection,
    ) -> Option<(Rc<Ui>, Rc<Document>, sourceview5::View)> {
        let ui = self.ui.upgrade()?;
        let doc = self.doc.upgrade()?;
        let view = snapshot.view.upgrade()?;

        if !ui.window.is_visible()
            || !view.is_mapped()
            || !doc.has_source_text()
            || doc.is_rich_active()
            || doc.folded.borrow().is_some()
            || crate::close_protocol::active(&ui)
            || ui.window_close_dialog.get()
            || doc.revision.get() != snapshot.revision
            || self.dialog_epoch.get() != snapshot.epoch
            || self.source_interaction.get() != snapshot.interaction
            || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
            || !ui.documents.borrow().iter().any(|d| Rc::ptr_eq(d, &doc))
        {
            return None;
        }
        let bound = gtk::prelude::TextViewExt::buffer(&view);
        let buffer=snapshot.buffer.upgrade()?;
        if bound != buffer.clone().upcast::<gtk::TextBuffer>() || !snapshot.pane.same_pane_for_reading(&doc)
            || !doc.source_panes.borrow().as_ref().is_some_and(|p|p.owns(&view)) {return None;}
        let head=buffer.cursor_position();
        let anchor=buffer.iter_at_mark(&buffer.selection_bound()).offset();
        if head != buffer.iter_at_mark(&snapshot.head).offset()
            || !(anchor == head || anchor == buffer.iter_at_mark(&snapshot.anchor).offset())
        {
            return None;
        }
        Some((ui, doc, view))
    }
    fn capture_dialog_selection(&self, ui: &Rc<Ui>, doc: &Rc<Document>) {
        self.dialog_epoch
            .set(self.dialog_epoch.get().wrapping_add(1));
        self.dialog_selection.borrow_mut().take();
        if !ui.active().is_some_and(|active| Rc::ptr_eq(&active, doc))
            || !doc.has_source_text()
            || doc.is_rich_active()
            || doc.folded.borrow().is_some()
        {
            return;
        }
        let Some(pane)=crate::source_panes::capture(doc) else{return};
        let view=pane.view.clone();
        if self.views[self.source_pane.get()].upgrade().as_ref()!=Some(&view){return;}
        let buffer=pane.buffer.clone();
        let head=buffer.iter_at_mark(&buffer.get_insert());
        let anchor=buffer.iter_at_mark(&buffer.selection_bound());
        *self.dialog_selection.borrow_mut() = Some(DialogSelection {
            buffer: buffer.downgrade(),
            view: view.downgrade(),
            head: buffer.create_mark(None, &head, true),
            anchor: buffer.create_mark(None, &anchor, true),
            pane,
            revision: doc.revision.get(),
            epoch: self.dialog_epoch.get(),
            interaction: self.source_interaction.get(),
        });
    }
    fn restore_dialog_selection(self: &Rc<Self>, snapshot: DialogSelection) {
        let Some((ui, _, _)) = self.selection_owner(&snapshot) else {
            return;
        };
        ui.window.present();
        let weak = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            let Some(state) = weak.upgrade() else {
                return;
            };
            let Some((ui, _doc, view)) = state.selection_owner(&snapshot) else {
                return;
            };
            if !ui.window.is_active()
                || state
                    .window
                    .borrow()
                    .as_ref()
                    .and_then(|w| w.upgrade())
                    .is_some()
            {
                return;
            }
            let Some(buffer)=snapshot.buffer.upgrade() else{return};
            let head=buffer.iter_at_mark(&snapshot.head);
            let anchor=buffer.iter_at_mark(&snapshot.anchor);
            buffer.select_range(&head,&anchor);
            view.grab_focus();
        });
    }
    fn apply_language(&self) {
        let Some(doc) = self.doc.upgrade() else {
            return;
        };
        match self.choice.borrow().as_deref() {
            None => automatic(&doc),
            Some("") => doc.buffer.set_language(None),
            Some(id) => {
                if let Some(language) = sourceview5::LanguageManager::default().language(id) {
                    doc.buffer.set_language(Some(&language));
                }
            }
        }
    }
    fn report(&self, error: String) {
        if let Some(ui) = self.ui.upgrade() {
            ui.status.set_text(&format!(
                "{}: {error}",
                ui.lang.text(
                    "Formatwahl konnte nicht gespeichert oder geladen werden",
                    "Could not save or load the format choice"
                )
            ));
        }
    }
    fn sync_widget(&self) {
        if let Some((widget, choices)) = self.language_widget.borrow_mut().as_mut() {
            if let Some(widget) = widget.upgrade() {
                if let Some(id) = self.choice.borrow().as_ref() {
                    if !choices.iter().any(|choice| choice.as_ref() == Some(id)) {
                        if let Some(model) = widget
                            .model()
                            .and_then(|m| m.downcast::<gtk::StringList>().ok())
                        {
                            let title = self.ui.upgrade().map_or("Not installed", |ui| {
                                ui.lang.text("Nicht installiert", "Not installed")
                            });
                            model.append(&format!("{title}: {id}"));
                            choices.push(Some(id.clone()));
                        }
                    }
                }
                self.updating.set(true);
                widget.set_selected(
                    choices
                        .iter()
                        .position(|c| *c == *self.choice.borrow())
                        .unwrap_or(0) as u32,
                );
                self.updating.set(false);
            }
        }
    }
    fn persist(self: &Rc<Self>) {
        if !self.loaded.get() {
            return;
        }
        if self.writing.get() {
            self.write_again.set(true);
            return;
        }
        let Some(doc) = self.doc.upgrade() else {
            return;
        };
        let Some(path) = doc
            .snapshot
            .borrow()
            .as_ref()
            .map(|s| s.path().to_path_buf())
        else {
            return;
        };
        self.writing.set(true);
        let choice = self.choice.borrow().clone();
        let weak = Rc::downgrade(self);
        super::git_view::background(
            move || store::set(&config_root()?, &path, choice.as_deref()),
            move |result| {
                if let Some(state) = weak.upgrade() {
                    state.writing.set(false);
                    if let Err(error) = result {
                        state.report(error);
                    }
                    if state.write_again.replace(false) {
                        state.persist();
                    }
                }
            },
        );
    }
    fn show(self: &Rc<Self>) {
        let Some(ui) = self.ui.upgrade() else { return };
        let Some(doc) = self.doc.upgrade() else {
            return;
        };
        if let Some(window) = self.window.borrow().as_ref().and_then(|w| w.upgrade()) {
            window.present();
            return;
        }
        self.capture_dialog_selection(&ui, &doc);
        let epoch = self.dialog_epoch.get();
        let window =
            super::git_view::window(&ui, ui.lang.text("Editoroptionen", "Editor options"), false);
        window.set_default_size(640, 660);
        window.set_size_request(640, 620);
        let root = super::git_view::column();
        root.append(&super::git_view::label(ui.lang.text("Die Syntaxformatwahl wird für gespeicherte Dateien lokal gemerkt. Einrückung und visueller Zeilenumbruch gelten pro Syntaxformat in beiden Ansichten. Zeilennummern und automatisches Einrücken gelten für diesen Tab.", "The syntax format choice is remembered locally for saved files. Indentation and visual wrapping apply per syntax format in both views. Line numbers and automatic indentation apply to this tab.")));
        font::controls(&ui, &root);
        let manager = sourceview5::LanguageManager::default();
        let mut languages: Vec<_> = manager
            .language_ids()
            .iter()
            .filter_map(|id| manager.language(id))
            .collect();
        languages.sort_by_key(|l| l.name().to_lowercase());
        let mut labels = vec![
            ui.lang
                .text(
                    "Automatisch anhand des Dateinamens",
                    "Automatic from filename",
                )
                .to_owned(),
            ui.lang.text("Reiner Text", "Plain text").to_owned(),
        ];
        let mut choices = vec![None, Some(String::new())];
        for language in languages {
            labels.push(format!("{} ({})", language.name(), language.id()));
            choices.push(Some(language.id().to_string()));
        }
        if let Some(id) = self.choice.borrow().as_ref() {
            if !choices.iter().any(|choice| choice.as_ref() == Some(id)) {
                labels.push(format!(
                    "{}: {id}",
                    ui.lang.text("Nicht installiert", "Not installed")
                ));
                choices.push(Some(id.clone()));
            }
        }
        let refs: Vec<_> = labels.iter().map(String::as_str).collect();
        root.append(&super::git_view::label(
            ui.lang.text("Syntaxformat", "Syntax format"),
        ));
        let language = gtk::DropDown::from_strings(&refs);
        language.set_enable_search(true);
        language.set_selected(
            choices
                .iter()
                .position(|c| *c == *self.choice.borrow())
                .unwrap_or(0) as u32,
        );
        let weak = Rc::downgrade(self);
        *self.language_widget.borrow_mut() = Some((language.downgrade(), choices.clone()));
        language.connect_selected_notify(move |button| {
            let Some(state) = weak.upgrade() else { return };
            if state.updating.get() {
                return;
            }
            let Some(choice) = choices.get(button.selected() as usize) else {
                return;
            };
            state.loaded.set(true);
            state.generation.set(state.generation.get().wrapping_add(1));
            *state.choice.borrow_mut() = choice.clone();
            state.finish_language_read();
            state.apply_language();
            state.load_profile();
            state.persist();
        });
        root.append(&language);
        let loading = super::git_view::label(ui.lang.text(
            "Syntaxformat wird wiederhergestellt. Formatprofil wird danach verfügbar.",
            "Restoring the syntax format. Format profile options will become available afterwards.",
        ));
        loading.set_visible(self.language_pending.get());
        *self.profile_status.borrow_mut() = Some(loading.downgrade());
        root.append(&loading);
        let views: Vec<_> = self.views.iter().filter_map(|v| v.upgrade()).collect();
        let Some(first) = views.first() else { return };
        for (kind, label, value) in [
            (
                0,
                ui.lang.text("Tabbreite", "Tab width"),
                first.tab_width() as f64,
            ),
            (
                1,
                ui.lang.text("Einrückungsbreite", "Indentation width"),
                first.indent_width() as f64,
            ),
        ] {
            let spin = gtk::SpinButton::with_range(1., 16., 1.);
            spin.set_value(value);
            spin.set_sensitive(kind == 0 || first.is_insert_spaces_instead_of_tabs());
            self.profile_spins
                .borrow_mut()
                .push((spin.downgrade(), kind));
            let weak = Rc::downgrade(self);
            spin.connect_value_changed(move |spin| {
                if let Some(state) = weak.upgrade() {
                    let mut patch = profile::Patch::default();
                    if kind == 0 {
                        patch.tab = Some(spin.value_as_int() as u32);
                    } else {
                        patch.indent = Some(spin.value_as_int());
                    }
                    state.change_profile(patch);
                }
            });
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
            let label = super::git_view::label(label);
            label.set_hexpand(true);
            row.append(&label);
            row.append(&spin);
            root.append(&row);
        }
        for (label, active, kind) in [
            (
                ui.lang
                    .text("Mit Leerzeichen einrücken", "Indent with spaces"),
                first.is_insert_spaces_instead_of_tabs(),
                0,
            ),
            (
                ui.lang
                    .text("Automatisch einrücken", "Automatic indentation"),
                first.is_auto_indent(),
                1,
            ),
            (
                ui.lang.text("Zeilennummern", "Line numbers"),
                self.numbers.get(),
                2,
            ),
            (
                ui.lang
                    .text("Aktuelle Zeile hervorheben", "Highlight current line"),
                first.is_highlight_current_line(),
                3,
            ),
        ] {
            let button = gtk::CheckButton::with_label(label);
            button.set_active(active);
            if kind == 0 {
                *self.spaces_widget.borrow_mut() = Some(button.downgrade());
            }
            let weak = Rc::downgrade(self);
            button.connect_toggled(move |button| {
                if let Some(state) = weak.upgrade() {
                    if state.updating.get() {
                        return;
                    }
                    if kind == 0 {
                        state.change_profile(profile::Patch {
                            spaces: Some(button.is_active()),
                            ..profile::Patch::default()
                        });
                        return;
                    }
                    if kind == 2 {
                        state.numbers.set(button.is_active());
                    }
                    let folded = state
                        .doc
                        .upgrade()
                        .is_some_and(|d| d.folded.borrow().is_some());
                    for view in state.views.iter().filter_map(|v| v.upgrade()) {
                        match kind {
                            0 => view.set_insert_spaces_instead_of_tabs(button.is_active()),
                            1 => view.set_auto_indent(button.is_active()),
                            2 => view.set_show_line_numbers(button.is_active() && !folded),
                            _ => view.set_highlight_current_line(button.is_active()),
                        }
                    }
                }
            });
            root.append(&button);
        }
        soft_wrap::controls(self, &ui, &root);
        page_guide::controls(self, &ui, &root);
        root.append(&super::git_view::label(ui.lang.text("Diese Optionen ändern die Darstellung und künftige Eingaben. Vorhandener Text, Kodierung und Zeilenenden bleiben erhalten. Die Syntaxformate stammen aus dem installierten GtkSourceView-Sprachpaket; 4D-Unterstützung wird getrennt ergänzt.", "These options change the display and future input. Existing text, encoding and line endings are retained. Syntax formats come from the installed GtkSourceView language package; 4D support is a separate addition.")));
        let close = gtk::Button::with_label(ui.lang.text("Schließen", "Close"));
        let weak = window.downgrade();
        close.connect_clicked(move |_| {
            if let Some(window) = weak.upgrade() {
                window.close();
            }
        });
        let layout = gtk::Box::new(gtk::Orientation::Vertical, 0);
        layout.append(&super::git_view::scroll(&root));
        let footer = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        footer.set_margin_start(16);
        footer.set_margin_end(16);
        footer.set_margin_top(10);
        footer.set_margin_bottom(16);
        close.set_hexpand(true);
        footer.append(&close);
        layout.append(&footer);
        window.set_child(Some(&layout));
        *self.window.borrow_mut() = Some(window.downgrade());
        // Das Optionsfenster darf den Tab nicht über dessen Lebensdauer hinaus halten.
        let weak = Rc::downgrade(self);
        window.connect_close_request(move |window| {
            if let Some(state) = weak.upgrade() {
                if state.dialog_epoch.get() != epoch {
                    return glib::Propagation::Proceed;
                }
                let snapshot = state.dialog_selection.borrow_mut().take();
                state.window.borrow_mut().take();
                state.language_widget.borrow_mut().take();
                state.profile_spins.borrow_mut().clear();
                state.spaces_widget.borrow_mut().take();
                state.profile_status.borrow_mut().take();
                state.guide_controls.clear();
                state.soft_wrap.commit_controls();
                state.soft_wrap.clear_controls();
                if window.is_active() {
                    if let Some(snapshot) = snapshot {
                        state.restore_dialog_selection(snapshot);
                    }
                }
            }
            glib::Propagation::Proceed
        });
        let active_seen = Cell::new(false);
        let weak = Rc::downgrade(self);
        window.connect_is_active_notify(move |window| {
            if window.is_active() {
                active_seen.set(true);
            } else if active_seen.get() {
                if let Some(state) = weak.upgrade() {
                    let open = state.dialog_selection.borrow().is_some();
                    if open {
                        state.cancel_dialog_selection();
                    }
                }
            }
        });
        self.profile_readiness();
        drop(doc);
        window.present();
    }
}
pub(super) fn line_numbers(doc: &Document) -> bool {
    doc.editor_options
        .borrow()
        .as_ref()
        .is_none_or(|o| o.numbers.get())
}
pub(super) fn indentation(doc: &Document) -> (bool, usize, usize) {
    let Some(view) = doc
        .editor_options
        .borrow()
        .as_ref()
        .and_then(|state| state.views.iter().find_map(|view| view.upgrade()))
    else {
        return (false, 4, 4);
    };
    let tab = view.tab_width().max(1) as usize;
    let indent = usize::try_from(view.indent_width())
        .ok()
        .filter(|width| *width > 0)
        .unwrap_or(tab);
    (!view.is_insert_spaces_instead_of_tabs(), indent, tab)
}
pub(super) fn restore(ui: &Rc<Ui>, doc: &Rc<Document>) {
    let Some(state) = doc.editor_options.borrow().clone() else {
        return;
    };
    let Some(path) = doc
        .snapshot
        .borrow()
        .as_ref()
        .map(|s| s.path().to_path_buf())
    else {
        return;
    };
    let expected = path.clone();
    let generation = state.generation.get();
    let read = state.begin_language_read();
    let weak = Rc::downgrade(&state);
    let weak_ui = Rc::downgrade(ui);
    super::git_view::background(
        move || {
            let result = store::get(&config_root()?, &path);
            #[cfg(debug_assertions)]
            if std::env::var_os("FASTRA_PROFILE_READINESS_SELFTEST").is_some() {
                std::thread::sleep(std::time::Duration::from_millis(800));
            }
            result
        },
        move |result| {
            let (Some(state), Some(ui)) = (weak.upgrade(), weak_ui.upgrade()) else {
                return;
            };
            let Some(doc) = state.doc.upgrade() else {
                return;
            };
            if state.language_read.get() != read {
                return;
            }
            state.finish_language_read();
            if !ui.window.is_visible()
                || state.generation.get() != generation
                || !doc
                    .snapshot
                    .borrow()
                    .as_ref()
                    .is_some_and(|s| s.path() == expected)
            {
                state.load_profile();
                return;
            }
            match result {
                Ok(choice) => {
                    state.loaded.set(true);
                    *state.choice.borrow_mut() = choice.clone();
                    if let Some(id) = choice.as_deref().filter(|id| !id.is_empty()) {
                        if sourceview5::LanguageManager::default()
                            .language(id)
                            .is_none()
                        {
                            state.sync_widget();
                            state.load_profile();
                            state.report(format!(
                                "{}: {id}",
                                ui.lang.text(
                                    "Gespeichertes Syntaxformat ist nicht installiert",
                                    "Saved syntax format is not installed"
                                )
                            ));
                            return;
                        }
                    }
                    *state.choice.borrow_mut() = choice;
                    state.apply_language();
                    state.load_profile();
                    state.sync_widget();
                }
                Err(error) => {
                    state.load_profile();
                    state.report(error);
                }
            }
        },
    );
}
pub(super) fn saved(doc: &Document) {
    if let Some(state) = doc.editor_options.borrow().as_ref() {
        state.apply_language();
        state.persist();
    }
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
mod profile_gui_test;
#[cfg(debug_assertions)]
mod page_guide_gui_test;
#[cfg(debug_assertions)]
pub(super) fn run_selftest(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_WRAP_PROFILE_SELFTEST").is_some() {soft_wrap::selftest(ui);return;}
    gui_test::run(ui);
}

pub(super) fn save_as_stamp(doc: &Document) -> Option<(u64, Option<String>, bool)> {
    doc.editor_options.borrow().as_ref().map(|state| {
        (
            state.generation.get(),
            state.choice.borrow().clone(),
            state.loaded.get(),
        )
    })
}

pub(super) fn install_wrap(doc: &Document, wrap: &gtk::CheckButton) {
    profile::wrap(doc, wrap);
}

pub(super) fn profiles_pending() -> bool {
    printing::pending() || startup::pending() || profile::pending() || font::pending() || zoom::pending() || appearance::pending() || reading_font::pending() || markdown_preview::pending() || markdown_mode::pending()
}
pub(super) fn profiles_can_close(ui: &Ui) -> bool {
    page_guide::commit_forms();
    printing::commit_forms();
    // Spintext vor der letzten Freigabe übernehmen, nicht erst beim Fokusverlust während Close.
    let states: Vec<_> = ui
        .documents
        .borrow()
        .iter()
        .filter_map(|doc| doc.editor_options.borrow().clone())
        .collect();
    for state in states {
        state.guide_controls.commit();
        state.soft_wrap.commit_controls();
        let spins = state
            .profile_spins
            .borrow()
            .iter()
            .filter_map(|(spin, _)| spin.upgrade())
            .collect::<Vec<_>>();
        for spin in spins {
            spin.update();
        }
    }
    let profiles_ready = profile::can_close(ui);
    let printing_ready = printing::can_close(ui);
    let font_ready = startup::can_close(ui) & font::can_close(ui);
    let zoom_ready = zoom::can_close(ui);
    let appearance_ready = appearance::can_close(ui);
    let reading_font_ready = reading_font::can_close(ui);
    let markdown_preview_ready = markdown_preview::can_close(ui);
    let markdown_mode_ready = markdown_mode::can_close(ui);
    printing_ready && markdown_mode_ready && markdown_preview_ready && reading_font_ready && profiles_ready && font_ready && zoom_ready && appearance_ready
}
