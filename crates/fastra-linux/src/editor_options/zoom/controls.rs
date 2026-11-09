use super::*;
use crate::Language;
fn lang() -> Language {
    Language(
        std::env::var("LANGUAGE")
            .or_else(|_| std::env::var("LANG"))
            .unwrap_or_default()
            .starts_with("de"),
    )
}
fn stepper(root: &gtk::Box, lang: Language, document: bool) {
    let row = super::super::settings_form::row(root);
    let label = super::super::settings_form::label(&row, "");
    label.set_widget_name(if document {
        "document-zoom-level"
    } else {
        "ui-zoom-level"
    });
    let spin = super::super::settings_form::stepper(
        if document { -4. } else { -3. },
        if document { 8. } else { 5. },
    );
    spin.set_widget_name(if document {
        "fastra-document-zoom-stepper"
    } else {
        "fastra-ui-zoom-stepper"
    });
    spin.update_property(&[gtk::accessible::Property::Label(if document {
        lang.text("Dokumentschrift", "Document font")
    } else {
        lang.text("Gesamte Oberfläche", "Entire interface")
    })]);
    row.append(&spin);
    let updating = Rc::new(Cell::new(false));
    let guard = updating.clone();
    spin.connect_value_changed(move |spin| {
        let state = state();
        if guard.get() || !state.loaded.get() {
            return;
        }
        let mut levels = state.levels.get();
        if document {
            levels.document = spin.value_as_int();
        } else {
            levels.ui = spin.value_as_int();
        }
        state.choose(levels);
    });
    let weak_label = label.downgrade();
    let weak_spin = spin.downgrade();
    watch(move || {
        let (Some(label), Some(spin)) = (weak_label.upgrade(), weak_spin.upgrade()) else {
            return false;
        };
        let state = state();
        let levels = state.levels.get();
        let value = if document { levels.document } else { levels.ui };
        updating.set(true);
        spin.set_value(f64::from(value));
        spin.set_sensitive(state.loaded.get());
        label.set_text(&format!(
            "{}: {}{}",
            if document {
                lang.text("Dokumentschrift", "Document font")
            } else {
                lang.text("Gesamte Oberfläche", "Entire interface")
            },
            if value > 0 { "+" } else { "" },
            value
        ));
        updating.set(false);
        true
    });
}

pub(super) fn open(app: &gtk::Application) {
    let state = crate::editor_options::zoom::state();
    if let Some(window) = state.window.borrow().upgrade().filter(|window| app.windows().contains(window)) {
        window.present();
        return;
    }
    let lang = lang();
    let parent = app.active_window();
    let focus = crate::application_lifecycle::ordinary_windows()
        .and_then(|windows| {
            windows.into_iter().find(|ui| {
                parent
                    .as_ref()
                    .is_some_and(|parent| parent == ui.window.upcast_ref::<gtk::Window>())
            })
        })
        .and_then(|ui| ui.active())
        .and_then(|doc| {
            crate::source_panes::capture(&doc).map(|target| (Rc::downgrade(&doc), target))
        });
    let window = gtk::Window::builder()
        .application(app)
        .default_width((680. * ui_scale()).round() as i32)
        .default_height((720. * ui_scale()).round() as i32)
        .build();
    window.set_widget_name("fastra-global-settings");
    window.add_css_class("fastra-settings");
    let weak = window.downgrade();
    watch(move || {
        if let Some(window) = weak.upgrade() {
            window.set_size_request(
                (480. * ui_scale()).round() as i32,
                (380. * ui_scale()).round() as i32,
            );
            super::super::appearance::resize_controls(&window);
            true
        } else {
            false
        }
    });
    if let Some(parent) = parent {
        window.set_transient_for(Some(&parent));
    }
    crate::chrome::dialog::decorate(&window, lang.text("Einstellungen", "Settings"), lang);
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    root.add_css_class("settings-form");
    super::super::appearance::controls(lang, &root);
    let fonts = super::super::settings_form::section(
        &root,
        lang.text("Schrift und Größe", "Font and size"),
    );
    super::super::font::form_controls(lang, &fonts);
    stepper(&fonts, lang, false);
    stepper(&fonts, lang, true);
    super::super::settings_form::note(
        &fonts,
        lang.text(
            "Ctrl −/+/0 skaliert die Oberfläche. Ctrl Shift −/+/0 ändert nur die Dokument-Schrift.",
            "Ctrl −/+/0 scales the interface. Ctrl Shift −/+/0 changes only the document font.",
        ),
    );
    super::super::page_guide::form_controls(lang, &root);
    super::super::startup::controls(lang, &root);
    super::super::markdown_preview::controls(lang, &root);
    super::super::printing::form(lang, &root);
    let status = crate::git_view::label("");
    status.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    status.set_lines(4);
    status.add_css_class("settings-feedback");
    fonts.append(&status);
    let retry = gtk::Button::with_label(lang.text("Erneut versuchen", "Retry"));
    retry.set_halign(gtk::Align::End);
    retry.add_css_class("settings-feedback");
    fonts.append(&retry);
    let weak_status = status.downgrade();
    let weak_retry = retry.downgrade();
    watch(move || {
        let (Some(status), Some(retry)) = (weak_status.upgrade(), weak_retry.upgrade()) else {
            return false;
        };
        let state = crate::editor_options::zoom::state();
        let error = state.error.borrow();
        status.set_text(if error.is_some() { lang.text("Größeneinstellung konnte nicht geladen oder gespeichert werden. Die vorhandene Datei bleibt erhalten.", "Size preference could not be loaded or saved. The existing file is retained.") }
            else if !state.loaded.get() { lang.text("Größeneinstellung wird geladen …", "Loading size preference …") }
            else if state.busy.get() || state.queued.get() { lang.text("Größe angewendet; Einstellung wird gespeichert …", "Size applied; saving preference …") }
            else { "" });
        status.set_visible(!status.text().is_empty());
        status.set_tooltip_text(error.as_deref());
        retry.set_visible(error.is_some());
        retry.set_sensitive(!state.busy.get());
        true
    });
    let owner = state.clone();
    retry.connect_clicked(move |_| {
        if owner.loaded.get() {
            owner.save();
        } else {
            owner.load();
        }
    });
    let scroll = gtk::ScrolledWindow::builder()
        .child(&root)
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build();
    window.set_child(Some(&scroll));
    window.connect_notify_local(Some("default-width"), |window, _| {
        super::super::appearance::resize_controls(window)
    });
    window.connect_close_request(|_| {
        super::super::page_guide::commit_forms();
        glib::Propagation::Proceed
    });
    let keys = gtk::EventControllerKey::new();
    let weak = window.downgrade();
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        if key == gtk::gdk::Key::Escape
            || key == gtk::gdk::Key::w && modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK)
        {
            if let Some(window) = weak.upgrade() {
                window.close();
            }
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    window.add_controller(keys);
    // Nur den unveränderten Quellbereich wieder fokussieren; keine alte Auswahl
    // zurückschreiben und kein inzwischen fremdes Fenster aktivieren.
    let focus = Rc::new(RefCell::new(focus));
    window.connect_destroy(move |_| {
        if let Some((doc, target)) = focus.borrow_mut().take() {
            glib::idle_add_local_once(move || {
                if let Some(doc) = doc.upgrade() {
                    if target.valid_document_for_reading(&doc) {
                        target.view.grab_focus();
                    }
                }
            });
        }
    });
    *state.window.borrow_mut() = window.downgrade();
    state.refresh();
    window.present();
}
pub(super) fn menu(ui: &Rc<Ui>, commands: &gtk::Box, popover: &gtk::Popover) {
    let settings = gtk::Button::with_label(ui.lang.text("Einstellungen …", "Settings …"));
    settings.set_widget_name("fastra-settings-command");
    let weak = ui.window.downgrade();
    let popup = popover.downgrade();
    settings.connect_clicked(move |_| {
        if let Some(popup) = popup.upgrade() {
            popup.popdown();
        }
        let weak = weak.clone();
        glib::idle_add_local_once(move || {
            if let Some(app) = weak.upgrade().and_then(|window| window.application()) {
                open(&app);
            }
        });
    });
    commands.prepend(&settings);
    let model = gio::Menu::new();
    for (title, prefix) in [
        (ui.lang.text("Gesamte Oberfläche", "Entire interface"), "ui"),
        (ui.lang.text("Dokumentschrift", "Document text"), "document"),
    ] {
        let section = gio::Menu::new();
        for (title, suffix) in [
            (ui.lang.text("Vergrößern", "Larger"), "larger"),
            (ui.lang.text("Verkleinern", "Smaller"), "smaller"),
            (ui.lang.text("Originalgröße", "Original size"), "original"),
        ] {
            section.append(Some(title), Some(&format!("app.{prefix}-{suffix}")));
        }
        model.append_section(Some(title), &section);
    }
    let view = gtk::MenuButton::builder()
        .label(ui.lang.text("Darstellung", "View"))
        .menu_model(&model)
        .build();
    commands.prepend(&view);
}
