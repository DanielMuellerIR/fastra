//! Beispielpaare füllen nur das gebundene Suchformular; keine Editor-/Dateiänderung.
use super::*;
use fastra_core::example_transformation::{self, Inference, Refusal};
use std::rc::Weak;

struct State {
    ui: Weak<Ui>,
    doc: Option<Weak<Document>>,
    owner_generation: u64,
    window: gtk::Window,
    source: gtk::TextView,
    destination: gtk::TextView,
    find: gtk::Label,
    replace: gtk::Label,
    result: gtk::Label,
    status: gtk::Label,
    apply: gtk::Button,
    job: Cell<u64>,
    busy: Cell<bool>,
    cancel: RefCell<Cancellation>,
    inference: RefCell<Option<Inference>>,
}
#[cfg(debug_assertions)]
thread_local! { static TEST_STATE: RefCell<Weak<State>> = const { RefCell::new(Weak::new()) }; }

fn refusal(lang: Language, error: &Refusal) -> String {
    match error {
        Refusal::Empty => lang.text("Vorher und Nachher dürfen nicht leer sein.", "Before and After must both contain text."),
        Refusal::Equal => lang.text("Die Beispiele sind gleich, auch bei unterschiedlicher Unicode-Zusammensetzung.", "The examples are equal, including canonically equivalent Unicode."),
        Refusal::Wildcard => lang.text("Beispiele dürfen kein Sternchen (*) enthalten; es bezeichnet den abgeleiteten Platzhalter.", "Examples cannot contain an asterisk (*); it denotes the inferred wildcard."),
        Refusal::TooLong => lang.text("Je Beispiel höchstens 512 Zeichen (Grapheme) und 4 MiB UTF-8 verwenden.", "Use at most 512 characters (graphemes) and 4 MiB UTF-8 per example."),
        Refusal::NoCommonPart => lang.text("Kein gemeinsamer, sicher abgrenzbarer Textteil gefunden.", "No shared text with safe boundaries was found."),
        Refusal::Core(error) => return error_text(lang, error),
    }.into()
}
impl State {
    fn owner(&self) -> Option<Rc<Ui>> {
        let ui = self.ui.upgrade()?;
        if !self.window.is_visible()
            || !ui.window.is_visible()
            || ui.generation.get() != self.owner_generation
        {
            return None;
        }
        let same_doc = match (&self.doc, ui.active()) {
            (Some(bound), Some(active)) => {
                bound.upgrade().is_some_and(|doc| Rc::ptr_eq(&doc, &active))
            }
            (None, None) => true,
            _ => false,
        };
        same_doc.then_some(ui)
    }
    fn stop(&self) {
        self.cancel.borrow().cancel();
        self.busy.set(false);
        self.job.set(self.job.get().wrapping_add(1));
        self.inference.borrow_mut().take();
        self.apply.set_sensitive(false);
    }
    fn update(self: &Rc<Self>) {
        self.stop();
        self.find.set_text("");
        self.replace.set_text("");
        self.result.set_text("");
        let Some(ui) = self.owner() else {
            self.status.set_text(self.ui.upgrade().map_or("", |ui| ui.lang.text(
                "Suchformular oder Dokument inzwischen geändert. Werkzeug neu öffnen; nichts übernommen.",
                "The search form or document changed. Reopen this tool; nothing was adopted.")));
            return;
        };
        // GTK kann NUL nicht verlustfrei im Formular darstellen.
        let source = buffer_text(&self.source.buffer());
        let destination = buffer_text(&self.destination.buffer());
        if source.contains('\0') || destination.contains('\0') {
            self.status.set_text(ui.lang.text(
                "U+0000 ist im Suchformular nicht darstellbar.",
                "U+0000 cannot be displayed in the search form.",
            ));
            return;
        }
        self.busy.set(true);
        let job = self.job.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.status.set_text(
            ui.lang
                .text("Beispiel wird geprüft …", "Checking the example …"),
        );
        let weak = Rc::downgrade(self);
        let lang = ui.lang;
        git_view::background(
            move || {
                let inference = example_transformation::infer(&source, &destination, &cancel)
                    .map_err(|e| refusal(lang, &e))?;
                let preview = inference
                    .preview(&source, &destination, &cancel)
                    .map_err(|e| error_text(lang, &e))?;
                let render = |text: &str| {
                    fastra_core::display::escaped_text(text, &cancel, 64 * 1024)
                    .map_err(|_| lang.text("Die vollständige Darstellung überschreitet 64 KiB. Beispiel verkürzen; nichts übernommen.", "The complete display exceeds 64 KiB. Shorten the example; nothing was adopted.").to_string())
                };
                let find = render(&inference.find_pattern)?;
                let replace = render(&inference.replace_pattern)?;
                let result = render(&preview.text)?;
                Ok((inference, preview, find, replace, result))
            },
            move |answer| {
                let Some(state) = weak.upgrade() else { return };
                if state.job.get() != job {
                    return;
                }
                state.busy.set(false);
                let Some(ui) = state.owner() else {
                    state.stop();
                    state.status.set_text(state.ui.upgrade().map_or("", |ui| {
                        ui.lang.text(
                            "Suchformular oder Dokument inzwischen geändert. Werkzeug neu öffnen.",
                            "The search form or document changed. Reopen this tool.",
                        )
                    }));
                    return;
                };
                match answer {
                    Ok((inference, preview, find, replace, result)) => {
                        state.find.set_text(&find);
                        state.replace.set_text(&replace);
                        state.result.set_text(&result);
                        state.apply.set_sensitive(preview.reproduces_destination);
                        if preview.reproduces_destination {
                            state.status.set_text(ui.lang.text("Beispiel stimmt überein. Übernehmen füllt nur das Suchformular; danach neue Vorschau berechnen und freigeben.", "The example matches. Apply only fills the search form; then calculate and approve a fresh preview."));
                            *state.inference.borrow_mut() = Some(inference);
                        } else {
                            state.status.set_text(ui.lang.text("Das abgeleitete Muster erzeugt nicht Nachher. * erfasst keine Zeilenumbrüche; $N kann eine Rückreferenz sein. Beispiele ändern; nichts wird übernommen.", "The inferred pattern does not produce After. * does not capture line breaks; $N may be a backreference. Change the examples; nothing will be adopted."));
                        }
                    }
                    Err(message) => state.status.set_text(&message),
                }
            },
        );
    }
    fn fill(&self) {
        let Some(ui) = self.owner() else {
            self.stop();
            self.status.set_text(self.ui.upgrade().map_or("", |ui| ui.lang.text("Suchformular oder Dokument inzwischen geändert. Werkzeug neu öffnen; nichts übernommen.", "The search form or document changed. Reopen this tool; nothing was adopted.")));
            return;
        };
        let Some(inference) = self
            .inference
            .borrow()
            .clone()
            .filter(|_| self.apply.is_sensitive() && !self.busy.get())
        else {
            return;
        };
        ui.invalidate();
        ui.find.set_text(&inference.find_pattern);
        ui.replace.set_text(&inference.replace_pattern);
        ui.mode.set_selected(1);
        chrome::show_search(&ui);
        ui.status.set_text(ui.lang.text(
            "Beispielmuster im Suchformular. Jetzt neue Vorschau berechnen und freigeben.",
            "Example patterns filled the search form. Now calculate and approve a fresh preview.",
        ));
        self.window.close();
    }
}
fn text_field() -> gtk::TextView {
    gtk::TextView::builder()
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .accepts_tab(false)
        .build()
}
fn input(root: &gtk::Box, title: &str, field: &gtk::TextView) {
    field.update_property(&[gtk::accessible::Property::Label(title)]);
    root.append(
        &gtk::ScrolledWindow::builder()
            .child(field)
            .height_request(26)
            .hexpand(true)
            .build(),
    );
}
fn output(root: &gtk::Box, title: &str) -> gtk::Label {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let caption = git_view::label(title); caption.add_css_class("monospace"); row.append(&caption);
    let value = git_view::label(""); value.set_selectable(true); value.add_css_class("monospace"); value.set_hexpand(true); row.append(&value); root.append(&row); value
}
fn create(ui: &Rc<Ui>) -> Rc<State> {
    let lang = ui.lang;
    let window = git_view::window(
        ui,
        lang.text("Transformation per Beispiel", "Transformation by example"),
        false,
    );
    window.set_size_request(500, 270);
    window.set_default_size(520, 300);
    let root = git_view::column();
    root.add_css_class("example-dialog");
    root.append(&git_view::label(lang.text("Fastra übernimmt den gemeinsamen Teil als Platzhalter und zeigt die daraus abgeleiteten Suchen-und-Ersetzen-Muster.", "Fastra uses the shared text as a placeholder and shows the resulting Find and Replace patterns.")));
    let source = text_field();
    let destination = text_field();
    input(&root, lang.text("Vorher", "Before"), &source);
    input(&root, lang.text("Nachher", "After"), &destination);
    let patterns = gtk::Box::new(gtk::Orientation::Vertical, 3); patterns.add_css_class("example-patterns");
    let find = output(&patterns, lang.text("Suchen:", "Find:"));
    let replace = output(&patterns, lang.text("Ersetzen:", "Replace:")); root.append(&patterns);
    let result_box = gtk::Box::new(gtk::Orientation::Vertical, 3); result_box.set_visible(false);
    let result = output(&result_box, lang.text("Ergebnis:", "Result:")); root.append(&result_box);
    let status = git_view::label("");
    root.append(&status);
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    footer.set_halign(gtk::Align::End);
    let close = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    let apply = gtk::Button::with_label(lang.text("Übernehmen", "Apply"));
    apply.add_css_class("suggested-action");
    apply.set_sensitive(false);
    footer.append(&close);
    footer.append(&apply);
    root.append(&footer);
    let result_weak = result_box.downgrade(); let status_weak = status.downgrade(); let result_label = result.downgrade();
    apply.connect_sensitive_notify(move |apply| {
        if let (Some(result), Some(label)) = (result_weak.upgrade(), result_label.upgrade()) { result.set_visible(!apply.is_sensitive() && !label.text().is_empty()); }
        if let Some(status) = status_weak.upgrade() { status.set_visible(!apply.is_sensitive() && !status.text().is_empty()); }
    });
    root.remove(&footer);
    let outer = gtk::Box::new(gtk::Orientation::Vertical, 0);
    outer.append(&gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).child(&root).build());
    footer.set_margin_start(16); footer.set_margin_end(16); footer.set_margin_bottom(16); outer.append(&footer);
    window.set_child(Some(&outer));
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        doc: ui.active().map(|doc| Rc::downgrade(&doc)),
        owner_generation: ui.generation.get(),
        window: window.clone(),
        source,
        destination,
        find,
        replace,
        result,
        status,
        apply,
        job: Cell::new(0),
        busy: Cell::new(false),
        cancel: RefCell::new(Cancellation::default()),
        inference: RefCell::new(None),
    });
    for buffer in [state.source.buffer(), state.destination.buffer()] {
        let weak = Rc::downgrade(&state);
        buffer.connect_changed(move |_| {
            if let Some(state) = weak.upgrade() {
                state.update();
            }
        });
    }
    let weak = Rc::downgrade(&state);
    state.apply.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.fill();
        }
    });
    let weak = Rc::downgrade(&state);
    close.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.window.close();
        }
    });
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(&state);
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        let Some(state) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        if key == gtk::gdk::Key::Escape {
            state.window.close();
            return glib::Propagation::Stop;
        }
        if key == gtk::gdk::Key::Return && !modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK) {
            state.fill();
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    window.add_controller(keys);
    git_view::hold(&window, state.clone(), State::stop);
    #[cfg(debug_assertions)]
    TEST_STATE.with(|slot| *slot.borrow_mut() = Rc::downgrade(&state));
    #[cfg(debug_assertions)]
    git_view::test_size(&window);
    window.present();
    state.source.buffer().set_text("ring, The");
    state.destination.buffer().set_text("The ring");
    state.source.grab_focus();
    state
}
pub(super) fn open(ui: &Rc<Ui>) {
    create(ui);
}
#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
