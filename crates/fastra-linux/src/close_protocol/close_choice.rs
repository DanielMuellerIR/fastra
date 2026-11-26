use super::*;

thread_local! {
    static ACTIVE_PROMPTS: Cell<usize> = const { Cell::new(0) };
}

pub(super) fn any_active() -> bool {
    ACTIVE_PROMPTS.with(|count| count.get() > 0)
}

#[derive(Clone, Copy)]
pub(super) enum Answer {
    Cancel,
    Discard,
    Save,
}

pub(super) struct Prompt {
    overlay: glib::WeakRef<gtk::Overlay>,
    backdrop: glib::WeakRef<gtk::Box>,
    blocked: Vec<glib::WeakRef<gtk::Widget>>,
    focus: Vec<glib::WeakRef<gtk::Widget>>,
}

impl Prompt {
    pub(super) fn show(
        ui: &Ui,
        overlay: &gtk::Overlay,
        filename: &str,
        answer: impl Fn(Answer) + 'static,
    ) -> Self {
        // GTK kann beim AT-SPI-Abfragen eines gerade entfernten Fensters
        // abstürzen. Die Rückfrage lebt in diesem Fenster, dessen Identität bleibt bestehen.
        let mut focus = Vec::new();
        if let Some(widget) = gtk::prelude::GtkWindowExt::focus(&ui.window) {
            focus.push(widget.downgrade());
        }
        let mut blocked: Vec<_> = [overlay.child(), ui.window.titlebar()]
            .into_iter()
            .flatten()
            .collect();
        let toplevels = gtk::Window::toplevels();
        for index in 0..toplevels.n_items() {
            let Some(window) = toplevels.item(index).and_downcast::<gtk::Window>() else {
                continue;
            };
            if !window.is_visible() || &window == ui.window.upcast_ref::<gtk::Window>() {
                continue;
            }
            if let Some(widget) = gtk::prelude::GtkWindowExt::focus(&window) {
                focus.push(widget.downgrade());
            }
            blocked.extend([window.child(), window.titlebar()].into_iter().flatten());
        }
        // Die Sitzungsverwaltung kann ein Fenster nach einem Schreibvorgang freigeben.
        // Die Rückfrage sperrt deshalb dessen Inhalt und Titelleiste eigenständig.
        blocked.retain(gtk::prelude::WidgetExt::get_sensitive);
        for widget in &blocked {
            widget.set_sensitive(false);
        }

        let question = ui.lang.text(
            "Änderungen in diesem Tab sichern?",
            "Save changes in this tab?",
        );
        let panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .halign(gtk::Align::Center)
            .valign(gtk::Align::Center)
            .accessible_role(gtk::AccessibleRole::AlertDialog)
            .css_classes(["fastra-close-prompt"])
            .build();
        panel.update_property(&[
            gtk::accessible::Property::Label(question),
            gtk::accessible::Property::Modal(true),
        ]);
        let heading = gtk::Label::new(Some(question));
        heading.add_css_class("heading");
        panel.append(&heading);
        let detail = gtk::Label::new(Some(filename));
        detail.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        detail.set_max_width_chars(56);
        panel.append(&detail);
        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        buttons.set_halign(gtk::Align::End);
        panel.append(&buttons);
        let cancel = gtk::Button::with_label(ui.lang.text("Abbrechen", "Cancel"));
        let discard = gtk::Button::with_label(
            ui.lang.text("Ohne Speichern schließen", "Close without saving"),
        );
        let save = gtk::Button::with_label(ui.lang.text("Speichern und schließen", "Save and close"));
        save.add_css_class("suggested-action");
        let answer = Rc::new(answer);
        for (button, choice) in [
            (&cancel, Answer::Cancel),
            (&discard, Answer::Discard),
            (&save, Answer::Save),
        ] {
            let answer = answer.clone();
            button.connect_clicked(move |_| answer(choice));
            buttons.append(button);
        }

        let backdrop = gtk::Box::new(gtk::Orientation::Vertical, 0);
        backdrop.set_valign(gtk::Align::Fill);
        panel.set_vexpand(true);
        backdrop.add_css_class("fastra-close-backdrop");
        backdrop.append(&panel);
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gtk::gdk::Key::Escape {
                answer(Answer::Cancel);
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        backdrop.add_controller(keys);
        overlay.add_overlay(&backdrop);
        ui.window.present();
        save.grab_focus();
        ACTIVE_PROMPTS.with(|count| count.set(count.get() + 1));
        Self {
            overlay: overlay.downgrade(),
            backdrop: backdrop.downgrade(),
            blocked: blocked.iter().map(gtk::prelude::ObjectExt::downgrade).collect(),
            focus,
        }
    }
}

impl Drop for Prompt {
    fn drop(&mut self) {
        ACTIVE_PROMPTS.with(|count| count.set(count.get().saturating_sub(1)));
        if let (Some(overlay), Some(backdrop)) = (self.overlay.upgrade(), self.backdrop.upgrade()) {
            overlay.remove_overlay(&backdrop);
        }
        for widget in self.blocked.iter().filter_map(glib::WeakRef::upgrade) {
            widget.set_sensitive(true);
        }
        for focus in self.focus.iter().filter_map(glib::WeakRef::upgrade) {
            focus.grab_focus();
        }
    }
}
