use super::*;
use fastra_core::navigation;
use std::rc::Weak;

struct State {
    ui: Weak<Ui>,
    doc: Weak<Document>,
    window: gtk::Window,
    input: gtk::Entry,
    go: gtk::Button,
    status: gtk::Label,
    busy: Cell<bool>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
    buffer_handler: RefCell<Option<glib::SignalHandlerId>>,
    parent_handler: RefCell<Option<glib::SignalHandlerId>>,
}
#[cfg(debug_assertions)]
thread_local! {static TEST_STATE: RefCell<Weak<State>> = const { RefCell::new(Weak::new()) };}
impl Drop for State {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
        if let (Some(doc), Some(id)) = (self.doc.upgrade(), self.buffer_handler.get_mut().take()) {
            doc.buffer.disconnect(id);
        }
        if let (Some(ui), Some(id)) = (self.ui.upgrade(), self.parent_handler.get_mut().take()) {
            ui.window.disconnect(id);
        }
    }
}
impl State {
    fn invalidate(&self) {
        self.cancel.borrow().cancel();
        self.generation.set(self.generation.get().wrapping_add(1));
        if self.busy.get() {
            if let Some(ui) = self.ui.upgrade() {
                self.status.set_text(ui.lang.text("Eingabe oder Quelltext geändert. Berechnung abgebrochen; Sprung erneut anfordern.", "Input or source changed. Calculation cancelled; request the jump again."));
            }
        }
    }
    fn owner(&self) -> Option<(Rc<Ui>, Rc<Document>)> {
        let ui = self.ui.upgrade()?;
        let doc = self.doc.upgrade()?;
        let valid = ui.window.is_visible()
            && ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
            && doc.has_source_text() && !doc.is_rich_active()
            && !doc.saving.get()
            && doc.folded.borrow().is_none();
        valid.then_some((ui, doc))
    }
    fn jump(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some((ui, doc)) = self.owner() else {
            self.status.set_text(self.ui.upgrade().map_or("", |ui|ui.lang.text(
                "Den gebundenen Quelltab aktivieren, entfalten und eine laufende Speicherung abschließen. Im Rich-, Hex- oder Vorschaumodus ist dieser Sprung gesperrt.",
                "Activate and unfold the bound source tab and finish any pending save. This jump is unavailable in Rich, hex or preview mode.")));
            return;
        };
        let Some(position) = navigation::parse(self.input.text().as_str()) else {
            self.status.set_text(ui.lang.text(
                "Eine positive Zeile oder Zeile:Spalte eingeben, zum Beispiel 42:8.",
                "Enter a positive line or line:column, for example 42:8.",
            ));
            return;
        };
        if doc.buffer.char_count() > 32 * 1024 * 1024 {
            self.status.set_text(ui.lang.text(
                "Quelltext überschreitet die Grenze von 32 MiB.",
                "Source exceeds the 32 MiB limit.",
            ));
            return;
        }
        self.invalidate();
        let generation = self.generation.get();
        let revision = doc.revision.get();
        let Some(target)=source_panes::capture(&doc) else {return};
        let cursor = target.buffer.cursor_position();
        let selection = selected_offsets(&doc);
        let rectangles: Vec<_> = doc
            .rectangles
            .borrow()
            .iter()
            .map(|r| r.selection_generation())
            .collect();
        let text = buffer_text(&doc.buffer);
        if text.len() > 32 * 1024 * 1024 {
            self.status.set_text(ui.lang.text(
                "Quelltext überschreitet die Grenze von 32 MiB.",
                "Source exceeds the 32 MiB limit.",
            ));
            return;
        }
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy.set(true);
        self.go.set_sensitive(false);
        self.status.set_text(ui.lang.text(
            "Quellposition wird berechnet …",
            "Calculating source position …",
        ));
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {#[cfg(debug_assertions)] source_panes::delay_reply();navigation::destination(&text,position,&cancel).map_err(|e|e.to_string())},
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.busy.set(false);
                state.go.set_sensitive(true);
                if !state.window.is_visible()
                    || state.generation.get() != generation
                    || state.cancel.borrow().check().is_err()
                {
                    return;
                }
                let Some((ui, doc)) = state.owner() else {
                    if let Some(ui) = state.ui.upgrade() {
                        state.status.set_text(ui.lang.text("Der gebundene Quelltab ist nicht mehr für den Sprung verfügbar. Aktivieren, entfalten und erneut anfordern.", "The bound source tab is no longer available for this jump. Activate, unfold and request again."));
                    }
                    return;
                };
                if doc.revision.get() != revision
                    || !target.valid_for_reading(&doc)
                    || target.buffer.cursor_position() != cursor
                    || selected_offsets(&doc) != selection
                    || doc
                        .rectangles
                        .borrow()
                        .iter()
                        .map(|r| r.selection_generation())
                        .collect::<Vec<_>>()
                        != rectangles
                {
                    state.status.set_text(ui.lang.text(
                        "Quelltext, Auswahl oder Cursor geändert. Sprung erneut anfordern.",
                        "Source, selection or cursor changed. Request the jump again.",
                    ));
                    return;
                }
                match result {
                    Ok(destination) => {
                        for rectangle in doc.rectangles.borrow().iter() {
                            rectangle.clear();
                        }
                        let mut iter=target.buffer.iter_at_offset(destination.character_offset as i32);
                        target.buffer.place_cursor(&iter);
                        target.view.scroll_to_iter(&mut iter,0.1,false,0.,0.);
                        state.window.close();ui.window.present();target.view.grab_focus();
                        ui.status.set_text(if destination.rounded_to_scalar {ui.lang.text("Spalte lag innerhalb eines UTF-16-Zeichenpaars; Cursor an dessen Anfang gesetzt.","Column was inside a UTF-16 character pair; cursor moved to its start.")} else {ui.lang.text("Zur Quellposition gesprungen. Zeile und Spalte werden am Text-/Zeilenende begrenzt.","Jumped to source position. Line and column are clamped at document/line end.")});
                    }
                    Err(error) => state.status.set_text(&format!(
                        "{}: {error}",
                        ui.lang
                            .text("Sprung nicht ausgeführt", "Jump not performed")
                    )),
                }
            },
        );
    }
}
fn create(ui: &Rc<Ui>) -> Option<Rc<State>> {
    let doc = ui.active()?;
    if (!doc.has_source_text() || doc.is_rich_active()) || doc.saving.get() || doc.folded.borrow().is_some() {
        ui.status.set_text(ui.lang.text("Zuerst einen Quelltab aktivieren, entfalten und laufendes Speichern abschließen.","First activate and unfold a source tab and finish any pending save."));
        return None;
    }
    let window = git_view::window(
        ui,
        ui.lang
            .text("Zu Zeile/Spalte springen", "Go to line/column"),
        false,
    );
    window.set_size_request(500, 200);
    window.set_default_size(640, 260);
    let root = git_view::column();
    let bound = git_view::label(&format!(
        "{}: {}",
        ui.lang.text("Gebundener Tab", "Bound tab"),
        doc.label.text()
    ));
    bound.set_wrap(false);
    bound.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    root.append(&bound);
    root.append(&git_view::label(ui.lang.text("Zeile oder Zeile:Spalte, ab 1. Spalten zählen UTF-16-Einheiten; Werte hinter dem Ende werden begrenzt.","Line or line:column, starting at 1. Columns count UTF-16 units; values beyond the end are clamped.")));
    let input = gtk::Entry::builder()
        .placeholder_text("42:8")
        .max_length(128)
        .activates_default(true)
        .build();
    root.append(&input);
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let go = gtk::Button::with_label(ui.lang.text("Springen", "Go"));
    let close = gtk::Button::with_label(ui.lang.text("Abbrechen", "Cancel"));
    actions.append(&go);
    actions.append(&close);
    root.append(&actions);
    let status = git_view::label(ui.lang.text(
        "Nur Cursor und Auswahl werden geändert. Text und Undo bleiben erhalten.",
        "Only cursor and selection change. Text and Undo are retained.",
    ));
    root.append(&status);
    window.set_child(Some(&root));
    window.set_default_widget(Some(&go));
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(&doc),
        window: window.clone(),
        input,
        go,
        status,
        busy: Cell::new(false),
        generation: Cell::new(0),
        cancel: RefCell::new(Cancellation::default()),
        buffer_handler: RefCell::new(None),
        parent_handler: RefCell::new(None),
    });
    #[cfg(debug_assertions)]
    TEST_STATE.with(|slot| *slot.borrow_mut() = Rc::downgrade(&state));
    let weak = Rc::downgrade(&state);
    state.go.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.jump();
        }
    });
    let weak = Rc::downgrade(&state);
    state.input.connect_activate(move |_| {
        if let Some(state) = weak.upgrade() {
            state.jump();
        }
    });
    let weak = Rc::downgrade(&state);
    state.input.connect_changed(move |_| {
        if let Some(state) = weak.upgrade() {
            let was_busy = state.busy.get();
            state.invalidate();
            if !was_busy {
                if let Some(ui) = state.ui.upgrade() {
                    state.status.set_text(ui.lang.text(
                        "Nur Cursor und Auswahl werden geändert. Text und Undo bleiben erhalten.",
                        "Only cursor and selection change. Text and Undo are retained.",
                    ));
                }
            }
        }
    });
    let weak = Rc::downgrade(&state);
    *state.buffer_handler.borrow_mut() = Some(doc.buffer.connect_changed(move |_| {
        if let Some(state) = weak.upgrade() {
            state.invalidate();
        }
    }));
    let weak = Rc::downgrade(&state);
    *state.parent_handler.borrow_mut() = Some(ui.window.connect_visible_notify(move |window| {
        if !window.is_visible() {
            if let Some(state) = weak.upgrade() {
                state.window.close();
            }
        }
    }));
    let weak = window.downgrade();
    close.connect_clicked(move |_| {
        if let Some(window) = weak.upgrade() {
            window.close();
        }
    });
    let keys = gtk::EventControllerKey::new();
    let weak = window.downgrade();
    keys.connect_key_pressed(move |_, key, _, _| {
        if key == gtk::gdk::Key::Escape {
            if let Some(window) = weak.upgrade() {
                window.close();
            }
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    window.add_controller(keys);
    git_view::hold(&window, state.clone(), State::invalidate);
    window.present();
    state.input.grab_focus();
    Some(state)
}
pub(super) fn open(ui: &Rc<Ui>) {
    let _ = create(ui);
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
