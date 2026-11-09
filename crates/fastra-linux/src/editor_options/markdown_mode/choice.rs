use super::*;
pub(super) struct Dialog {
    window: gtk::Window,
    owner: Weak<Ui>,
    status: gtk::Label,
    buttons: [gtk::Button; 2],
    lang: crate::Language,
}
fn owner_eligible(ui: &Ui) -> bool {
    ui.window.is_visible()
        && ui.active().is_some_and(|doc| {
            super::super::markdown_preview::eligible(&doc) && !doc.is_read_only()
        })
}
pub(super) fn refresh(state: &State) {
    let close = state.dialog.borrow().as_ref().is_some_and(|dialog| {
        state.choice.get().is_some()
            || !dialog.owner.upgrade().is_some_and(|ui| owner_eligible(&ui))
    });
    if close {
        let old = state.dialog.borrow_mut().take();
        if let Some(dialog) = old {
            dialog.window.destroy();
        }
        return;
    }
    if let Some(dialog) = state.dialog.borrow().as_ref() {
        let text = controls::feedback(state, dialog.lang);
        dialog.status.set_text(&text);
        dialog.status.set_visible(!text.is_empty());
        for button in &dialog.buttons {
            button.set_sensitive(state.loaded.get() && !state.transaction.get());
        }
    }
}
pub(super) fn offer(state: &Rc<State>, ui: &Rc<Ui>, doc: &Rc<Document>) {
    refresh(state);
    if !state.loaded.get()
        || state.choice.get().is_some()
        || state.transaction.get()
        || state.dialog.borrow().is_some()
        || !owner_eligible(ui)
        || !doc.container.is_mapped()
        || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, doc))
    {
        return;
    }
    // Wie der Mac-Runner unterdrücken andere isolierte Selbsttests den ersten
    // Modusdialog. Release-Builds durchlaufen immer den wirklichen Produktpfad.
    #[cfg(debug_assertions)]
    if std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref() == Ok("1")
        && !std::env::var("FASTRA_MARKDOWN_MODE_SELFTEST")
            .is_ok_and(|mode| mode.starts_with("choice"))
    {
        return;
    }
    let Some(app) = ui.window.application() else {
        return;
    };
    let lang = ui.lang;
    let window = gtk::Window::builder()
        .application(&app)
        .transient_for(&ui.window)
        .modal(true)
        .decorated(false)
        .resizable(false)
        .destroy_with_parent(true)
        .build();
    window.set_title(Some(
        lang.text("Markdown-Modus wählen", "Choose Markdown mode"),
    ));
    window.set_widget_name("fastra-markdown-mode-choice");
    window.add_css_class("markdown-mode-choice");
    crate::chrome::theme_widget(&window);
    window.connect_close_request(|_| glib::Propagation::Stop);
    let root = gtk::Box::new(gtk::Orientation::Vertical, 16);
    root.add_css_class("mode-choice-body");
    let title = crate::git_view::label(lang.text(
        "Wie möchtest du Markdown bearbeiten?",
        "How would you like to edit Markdown?",
    ));
    title.add_css_class("mode-choice-title");
    title.set_wrap(true);
    root.append(&title);
    let description=crate::git_view::label(lang.text("Im WYSIWYG-Modus arbeitest du direkt in der formatierten Ansicht, ohne Markdown-Kürzel zu sehen. Im Quelltext-Modus stehen Text und Vorschau nebeneinander.","In WYSIWYG mode you work directly in the formatted view without seeing Markdown syntax. In source mode, text and preview appear side by side."));
    description.set_wrap(true);
    description.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    root.append(&description);
    let hint=crate::git_view::label(lang.text("Mit dem Button rechts vom Text/Hex-Umschalter wechselst du den Modus für das aktuelle Dokument (Ctrl Shift Alt M). Den Standard änderst du jederzeit in den Einstellungen.","Use the button to the right of the Text/Hex switch to change mode for the current document (Ctrl Shift Alt M). You can change the default in Settings at any time."));
    hint.set_wrap(true);
    hint.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    hint.add_css_class("mode-choice-hint");
    root.append(&hint);
    let status = crate::git_view::label("");
    status.set_wrap(true);
    status.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    status.add_css_class("mode-choice-feedback");
    status.set_visible(false);
    root.append(&status);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let source = gtk::Button::with_label(lang.text("Quelltext und Vorschau", "Source and Preview"));
    source.set_widget_name("fastra-markdown-choose-source");
    source.set_tooltip_text(Some(lang.text(
        "Quelltext und Vorschau als Standard verwenden (Alt Return).",
        "Use source and preview as the default (Alt Return).",
    )));
    source.add_css_class("suggested-action");
    row.append(&source);
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    row.append(&spacer);
    let visual = gtk::Button::with_label(lang.text("WYSIWYG verwenden", "Use WYSIWYG"));
    visual.set_widget_name("fastra-markdown-choose-visual");
    visual.add_css_class("suggested-action");
    visual.set_tooltip_text(Some(lang.text(
        "In der formatierten Ansicht schreiben (Return).",
        "Write in the formatted view (Return).",
    )));
    row.append(&visual);
    root.append(&row);
    window.set_child(Some(&root));
    window.set_default_widget(Some(&visual));
    for (button, visual) in [(&source, false), (&visual, true)] {
        let weak = Rc::downgrade(state);
        button.connect_clicked(move |_| {
            if let Some(state) = weak.upgrade() {
                state.choose(visual);
            }
        });
    }
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(state);
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        if crate::application_lifecycle::quit_shortcut(key, modifiers) {
            crate::application_lifecycle::request_quit();
            return glib::Propagation::Stop;
        }

        if key == gtk::gdk::Key::Escape {
            return glib::Propagation::Stop;
        }
        if matches!(key, gtk::gdk::Key::Return | gtk::gdk::Key::KP_Enter)
            && modifiers.contains(gtk::gdk::ModifierType::ALT_MASK)
            && !modifiers.intersects(
                gtk::gdk::ModifierType::CONTROL_MASK
                    | gtk::gdk::ModifierType::SHIFT_MASK
                    | gtk::gdk::ModifierType::SUPER_MASK
                    | gtk::gdk::ModifierType::META_MASK
                    | gtk::gdk::ModifierType::HYPER_MASK,
            )
        {
            if let Some(state) = weak.upgrade() {
                state.choose(false);
            }
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    window.add_controller(keys);
    let metrics = vec![
        (title.clone(), 20.),
        (description.clone(), 16.),
        (hint.clone(), 16.),
        (status.clone(), 16.),
        (source.child().and_downcast::<gtk::Label>().unwrap(), 16.),
        (visual.child().and_downcast::<gtk::Label>().unwrap(), 16.),
    ];
    let weak_window = window.downgrade();
    let weak_root = root.downgrade();
    let weak_row = row.downgrade();
    let weak_metrics: Vec<_> = metrics
        .iter()
        .map(|(label, height)| (label.downgrade(), *height))
        .collect();
    let weak_buttons = [source.downgrade(), visual.downgrade()];
    super::super::zoom::watch(move || {
        let (Some(window), Some(root), Some(row)) = (
            weak_window.upgrade(),
            weak_root.upgrade(),
            weak_row.upgrade(),
        ) else {
            return false;
        };
        let metrics: Vec<_> = weak_metrics
            .iter()
            .filter_map(|(label, height)| Some((label.upgrade()?, *height)))
            .collect();
        let buttons: Vec<_> = weak_buttons
            .iter()
            .filter_map(glib::WeakRef::upgrade)
            .collect();
        resize(&window, &root, &row, &metrics, &buttons);
        true
    });
    resize(
        &window,
        &root,
        &row,
        &metrics,
        &[source.clone(), visual.clone()],
    );
    let weak = Rc::downgrade(state);
    window.connect_destroy(move |window| {
        if let Some(state) = weak.upgrade() {
            let current = state
                .dialog
                .borrow()
                .as_ref()
                .is_some_and(|dialog| &dialog.window == window);
            if current {
                state.dialog.borrow_mut().take();
            }
        }
    });
    let focus = visual.clone();
    *state.dialog.borrow_mut() = Some(Dialog {
        window: window.clone(),
        owner: Rc::downgrade(ui),
        status,
        buttons: [source, visual],
        lang,
    });
    state.refresh();
    window.present();
    focus.grab_focus();
}

fn resize(
    window: &gtk::Window,
    root: &gtk::Box,
    row: &gtk::Box,
    metrics: &[(gtk::Label, f64)],
    buttons: &[gtk::Button],
) {
    let scale = super::super::zoom::ui_scale();
    window.set_default_size((470. * scale).round() as i32, -1);
    root.set_spacing((16. * scale).round() as i32);
    row.set_spacing((12. * scale).round() as i32);
    root.set_margin_top((24. * scale).round() as i32);
    root.set_margin_bottom((24. * scale).round() as i32);
    root.set_margin_start((24. * scale).round() as i32);
    root.set_margin_end((24. * scale).round() as i32);
    for (label, height) in metrics {
        let attributes = gtk::pango::AttrList::new();
        attributes.insert(gtk::pango::AttrInt::new_line_height_absolute(
            (height * scale * f64::from(gtk::pango::SCALE)).round() as i32,
        ));
        label.set_attributes(Some(&attributes));
    }
    for button in buttons {
        button.set_height_request((20. * scale).round() as i32);
        if let Some(label) = button.child().and_downcast::<gtk::Label>() {
            label.set_margin_start((8. * scale).round() as i32);
            label.set_margin_end((8. * scale).round() as i32);
        }
    }
}
