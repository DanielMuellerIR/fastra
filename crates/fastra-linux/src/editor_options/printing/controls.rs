use super::*;
pub(super) struct Form {
    switches: [glib::WeakRef<gtk::Switch>; 3],
    size: glib::WeakRef<gtk::SpinButton>,
    title: glib::WeakRef<gtk::Label>,
    lang: crate::Language,
}
pub(super) struct Feedback {
    status: glib::WeakRef<gtk::Label>,
    retry: glib::WeakRef<gtk::Button>,
    lang: crate::Language,
}
pub(super) fn form(state: &Rc<State>, lang: crate::Language, root: &gtk::Box) {
    let group = super::super::settings_form::section(root, lang.text("Drucken", "Printing"));
    let switches: Vec<_> = [
        (
            "Zeilennummern drucken",
            "Print line numbers",
            "print-line-numbers",
        ),
        (
            "Kopf- und Fußzeile drucken",
            "Print header and footer",
            "print-header-footer",
        ),
        (
            "Syntaxfarben drucken",
            "Print syntax colors",
            "print-syntax-colors",
        ),
    ]
    .into_iter()
    .enumerate()
    .map(|(index, (de, en, name))| {
        let row = super::super::settings_form::row(&group);
        let title = lang.text(de, en);
        super::super::settings_form::label(&row, title);
        let choice = gtk::Switch::new();
        choice.set_valign(gtk::Align::Center);
        choice.set_widget_name(name);
        choice.update_property(&[gtk::accessible::Property::Label(title)]);
        row.append(&choice);
        let owner = Rc::downgrade(state);
        choice.connect_active_notify(move |choice| {
            if let Some(state) = owner.upgrade() {
                let value = Some(choice.is_active());
                state.choose(match index {
                    0 => Changes {
                        line_numbers: value,
                        ..Changes::default()
                    },
                    1 => Changes {
                        header_footer: value,
                        ..Changes::default()
                    },
                    _ => Changes {
                        syntax_colors: value,
                        ..Changes::default()
                    },
                });
            }
        });
        choice.downgrade()
    })
    .collect();
    let row = super::super::settings_form::row(&group);
    let title = super::super::settings_form::label(&row, "");
    let size = super::super::settings_form::stepper(6., 18.);
    size.set_widget_name("print-font-size");
    size.update_property(&[gtk::accessible::Property::Label(
        lang.text("Schriftgröße im Ausdruck", "Print font size"),
    )]);
    row.append(&size);
    let owner = Rc::downgrade(state);
    size.connect_value_changed(move |size| {
        if let Some(state) = owner.upgrade() {
            state.choose(Changes {
                font_size: Some(size.value_as_int() as u8),
                ..Changes::default()
            });
        }
    });
    state.forms.borrow_mut().push(Form {
        switches: switches.try_into().unwrap(),
        size: size.downgrade(),
        title: title.downgrade(),
        lang,
    });
    super::super::settings_form::note(&group, lang.text(
        "Die Schriftgröße gilt für Quelltext, Hex-Abzüge und die gedruckte Markdown-Vorschau. Zeilennummern und Syntaxfarben gibt es nur beim Quelltext; die Farben folgen dem hellen Editor-Farbsatz der Sprache, unabhängig vom Erscheinungsbild. Kopf- und Fußzeile tragen Quelltext-, Hex- und Bildausdrucke. Papiergröße und Ausrichtung stehen im Druckdialog.",
        "The font size applies to source text, hex dumps, and the printed Markdown preview. Line numbers and syntax colors are available for source text only; the colors follow the language's light editor color set regardless of the appearance. Header and footer appear on source, hex, and image printouts. Paper size and orientation are set in the print dialog.",
    ));
    feedback(state, lang, &group);
    refresh(state);
}
pub(super) fn feedback(state: &Rc<State>, lang: crate::Language, root: &gtk::Box) {
    let status = crate::git_view::label("");
    status.add_css_class("settings-feedback");
    root.append(&status);
    let retry = gtk::Button::with_label(lang.text("Erneut versuchen", "Retry"));
    retry.set_widget_name("print-preferences-retry");
    retry.set_halign(gtk::Align::End);
    retry.add_css_class("settings-feedback");
    root.append(&retry);
    let owner = Rc::downgrade(state);
    retry.connect_clicked(move |_| {
        if let Some(state) = owner.upgrade() {
            state.retry();
        }
    });
    state.feedback.borrow_mut().push(Feedback {
        status: status.downgrade(),
        retry: retry.downgrade(),
        lang,
    });
    refresh(state);
}
pub(super) fn commit(state: &State) {
    let controls: Vec<_> = state
        .forms
        .borrow()
        .iter()
        .filter_map(|form| form.size.upgrade())
        .collect();
    for control in controls {
        control.update();
    }
}
pub(super) fn refresh(state: &State) {
    state.updating.set(true);
    let values = state.values.get();
    state.forms.borrow_mut().retain(|form| {
        let Some(size) = form.size.upgrade() else {
            return false;
        };
        size.set_sensitive(state.loaded.get());
        size.set_value(f64::from(values.font_size));
        if let Some(title) = form.title.upgrade() {
            title.set_text(&format!(
                "{}: {} pt",
                form.lang
                    .text("Schriftgröße im Ausdruck", "Print font size"),
                values.font_size
            ));
        }
        for (choice, active) in form.switches.iter().zip([
            values.line_numbers,
            values.header_footer,
            values.syntax_colors,
        ]) {
            if let Some(choice) = choice.upgrade() {
                choice.set_active(active);
                choice.set_sensitive(state.loaded.get());
            }
        }
        true
    });
    state.feedback.borrow_mut().retain(|feedback| {
        let Some(status) = feedback.status.upgrade() else {
            return false;
        };
        let text = if let Some(error) = state.error.borrow().as_ref() {
            format!(
                "{}: {error}",
                feedback.lang.text(
                    "Druckeinstellungen konnten nicht geladen oder gespeichert werden",
                    "Print preferences could not be loaded or saved"
                )
            )
        } else if state.busy.get() {
            feedback
                .lang
                .text(
                    "Druckeinstellungen werden geladen oder gespeichert …",
                    "Loading or saving print preferences …",
                )
                .into()
        } else {
            String::new()
        };
        status.set_text(&text);
        status.set_visible(!text.is_empty());
        if let Some(retry) = feedback.retry.upgrade() {
            retry.set_visible(state.error.borrow().is_some());
            retry.set_sensitive(!state.busy.get());
        }
        true
    });
    state.updating.set(false);
}
