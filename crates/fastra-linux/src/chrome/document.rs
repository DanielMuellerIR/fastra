use super::*;

pub(crate) struct DocumentChrome {
    pub(crate) footer: gtk::Box,
    #[cfg(debug_assertions)]
    pub(crate) settings: gtk::Button,
    pub(crate) welcome: gtk::Box,
    pub(crate) refresh_context: Rc<dyn Fn()>,
    _options: gtk::MenuButton,
}

pub(crate) fn is_pristine(doc: &Document) -> bool {
    doc.buffer.char_count() == 0
        && doc.snapshot.borrow().is_none()
        && !doc.buffer.is_modified()
        && !doc.buffer.can_undo()
        && !doc.buffer.can_redo()
        && !doc.is_read_only()
        && doc
            .rich_toggle
            .borrow()
            .as_ref()
            .is_none_or(|toggle| !toggle.is_active())
}

fn welcome(ui: &Rc<Ui>, doc: &Rc<Document>) -> gtk::Box {
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    root.set_halign(gtk::Align::Center);
    root.set_valign(gtk::Align::Center);
    root.set_width_request(380);
    let name = brand::wordmark(34.);
    name.add_css_class("welcome-wordmark");
    root.append(&name);
    let version = gtk::Label::new(Some(&format!(
        "{} {} · {}",
        ui.lang.text("Version", "Version"),
        env!("CARGO_PKG_VERSION"),
        env!("FASTRA_VERSION_DATE")
    )));
    version.add_css_class("welcome-version");
    root.append(&version);
    for (name, icon_name, shortcut, action) in [
        (
            ui.lang.text("Neue Datei", "New file"),
            "document-new-symbolic",
            "Ctrl+T",
            0,
        ),
        (
            ui.lang.text("Datei öffnen …", "Open file …"),
            "text-x-generic-symbolic",
            "Ctrl+O",
            1,
        ),
        (
            ui.lang.text("Ordner öffnen …", "Open folder …"),
            "folder-symbolic",
            "Ctrl+Shift+O",
            2,
        ),
    ] {
        let button = gtk::Button::new();
        button.add_css_class("welcome-action");
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 9);
        row.append(&gtk::Image::from_icon_name(icon_name));
        let label = gtk::Label::new(Some(name));
        label.set_xalign(0.);
        label.set_hexpand(true);
        row.append(&label);
        let key = gtk::Label::new(Some(shortcut));
        key.add_css_class("welcome-description");
        row.append(&key);
        button.set_child(Some(&row));
        let weak = Rc::downgrade(ui);
        button.connect_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                match action {
                    0 => ui.new_document(),
                    1 => ui.open(),
                    _ => choose_project(&ui),
                }
            }
        });
        root.append(&button);
    }
    let title = gtk::Label::new(Some(
        ui.lang.text("ZULETZT BENUTZTE PROJEKTE", "RECENT PROJECTS"),
    ));
    title.set_xalign(0.);
    title.add_css_class("welcome-recent-title");
    root.append(&title);
    root.append(&project_view::welcome_recent(ui));
    let update = Rc::new({
        let root = root.downgrade();
        let doc = Rc::downgrade(doc);
        move || {
            if let (Some(root), Some(doc)) = (root.upgrade(), doc.upgrade()) {
                root.set_visible(is_pristine(&doc));
            }
        }
    });
    let refresh = update.clone();
    doc.buffer.connect_changed(move |_| refresh());
    let refresh = update.clone();
    doc.label.connect_label_notify(move |_| refresh());
    let refresh = update.clone();
    doc.buffer.connect_modified_changed(move |_| refresh());
    for property in ["can-undo", "can-redo"] {
        let refresh = update.clone();
        doc.buffer
            .connect_notify_local(Some(property), move |_, _| refresh());
    }
    if let Some(toggle) = doc.rich_toggle.borrow().as_ref() {
        let refresh = update.clone();
        toggle.connect_toggled(move |_| refresh());
    }
    update();
    root
}

pub(crate) fn choose_project(ui: &Rc<Ui>) {
    let weak = Rc::downgrade(ui);
    gtk::FileDialog::builder()
        .title(ui.lang.text("Ordner öffnen", "Open folder"))
        .build()
        .select_folder(Some(&ui.window), None::<&gio::Cancellable>, move |result| {
            if let (Some(ui), Ok(file)) = (weak.upgrade().filter(|ui| ui.window.is_visible()), result) {
                if let Some(path) = file.path() { super::open_project(&ui, path); }
            }
        });
}

pub(crate) struct Controls<'a> {
    pub pane: &'a gtk::Box,
    pub format: &'a gtk::Box,
    pub options: &'a gtk::FlowBox,
    pub editor: &'a gtk::Stack,
    pub split: &'a gtk::CheckButton,
    pub wrap: &'a gtk::CheckButton,
}

pub(crate) fn install(ui: &Rc<Ui>, doc: &Rc<Document>, controls: Controls<'_>) {
    let Controls {
        pane,
        format,
        options,
        editor,
        split,
        wrap,
    } = controls;
    let controls = children(options)
        .into_iter()
        .filter_map(|wrapper| wrapper.downcast::<gtk::FlowBoxChild>().ok())
        .filter_map(|wrapper| wrapper.child().map(|widget| (wrapper, widget)))
        .collect::<Vec<_>>();
    #[cfg(debug_assertions)]
    let settings = controls
        .iter()
        .find_map(|(_, widget)| {
            widget
                .downcast_ref::<gtk::Button>()
                .filter(|button| {
                    button.label().as_deref()
                        == Some(ui.lang.text("Editoroptionen …", "Editor options …"))
                })
                .cloned()
        })
        .expect("document options action");
    let menu = gtk::Box::new(gtk::Orientation::Vertical, 4);
    menu.set_margin_top(8);
    menu.set_margin_bottom(8);
    menu.set_margin_start(8);
    menu.set_margin_end(8);
    let rich = doc.rich_toggle.borrow().clone();
    let mut outline=None;
    for (wrapper, widget) in controls {
        wrapper.set_child(None::<&gtk::Widget>);
        options.remove(&wrapper);
        if widget.widget_name()=="fastra-document-outline-controls" {
            outline=Some(widget);continue;
        }
        if widget != *split.upcast_ref::<gtk::Widget>()
            && widget != *wrap.upcast_ref::<gtk::Widget>()
            && !rich
                .as_ref()
                .is_some_and(|toggle| widget == *toggle.upcast_ref::<gtk::Widget>())
        {
            menu.append(&widget);
        }
    }
    let mut inline = None;
    for child in children(pane) {
        if child.widget_name() == "fastra-markdown-inline" {
            pane.remove(&child);
            inline = Some(child);
        }
    }
    let options_button = gtk::MenuButton::builder()
        .icon_name("view-more-symbolic")
        .tooltip_text(
            ui.lang
                .text("Darstellung und Bearbeitung", "View and editing"),
        )
        .build();
    options_button.add_css_class("chrome-icon");
    let popover = gtk::Popover::new();
    popover.set_child(Some(&menu));
    options_button.set_popover(Some(&popover));
    super::dismiss_command_popovers(menu.upcast_ref(), &mut std::collections::HashSet::new());
    pane.remove(format);
    pane.remove(options);
    pane.remove(editor);
    pane.set_spacing(0);
    if doc
        .buffer
        .language()
        .is_some_and(|language| language.id() == "html")
    {
        let banner = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        banner.add_css_class("import-banner");
        banner.append(&gtk::Image::from_icon_name("edit-paste-symbolic"));
        let label = gtk::Label::new(Some(ui.lang.text(
            "HTML erkannt — Fastra kann das Dokument in Markdown umwandeln.",
            "HTML detected — Fastra can convert this document to Markdown.",
        )));
        label.set_xalign(0.);
        label.set_hexpand(true);
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        banner.append(&label);
        let convert =
            gtk::Button::with_label(ui.lang.text("In Markdown umwandeln", "Convert to Markdown"));
        convert.set_has_frame(false);
        let weak = Rc::downgrade(ui);
        let document = Rc::downgrade(doc);
        convert.connect_clicked(move |_| {
            if let (Some(ui), Some(doc)) = (weak.upgrade(), document.upgrade()) {
                if ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc)) {
                    if let Some(path) = doc.disk_path() {
                        import_view::open_for_file(&ui, path);
                    }
                }
            }
        });
        banner.append(&convert);
        let close = icon(
            "window-close-symbolic",
            ui.lang.text("Hinweis schließen", "Dismiss notice"),
        );
        let weak = banner.downgrade();
        close.connect_clicked(move |_| {
            if let Some(banner) = weak.upgrade() {
                banner.set_visible(false);
            }
        });
        banner.append(&close);
        pane.append(&banner);
    }
    let tools = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    tools.add_css_class("editor-tools");
    let snippets = gtk::Button::new();
    snippets.set_sensitive(!doc.source_edits_locked());
    snippets.set_child(Some(&button_content(
        "fastra-snippets-symbolic",
        ui.lang.text("Textbausteine …", "Text snippets …"),
    )));
    snippets.set_has_frame(false);
    let weak = Rc::downgrade(ui);
    snippets.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            super::command(&ui, ui.lang.text("Textbausteine …", "Text snippets …"));
        }
    });
    if let Some(outline)=outline {tools.append(&outline);}
    snippets.set_visible(!doc.buffer.language().is_some_and(|language|language.id()=="markdown"));
    let saved=snippets.downgrade();doc.buffer.connect_language_notify(move|buffer|{if let Some(button)=saved.upgrade(){button.set_visible(!buffer.language().is_some_and(|language|language.id()=="markdown"));}});
    tools.append(&snippets);
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    if let Some(inline) = inline {
        spacer.set_hexpand(!inline.is_visible());
        let space=spacer.downgrade();
        inline.connect_visible_notify(move|inline|{if let Some(spacer)=space.upgrade(){spacer.set_hexpand(!inline.is_visible());}});
        tools.append(&inline);
    }
    tools.append(&spacer);
    split.set_label(Some(
        ui.lang
            .text("Quelltextansicht teilen", "Split source editor"),
    ));
    split.set_widget_name("fastra-source-split");
    split.add_css_class("split-source");
    tools.append(split);
    tools.append(&options_button);
    pane.append(&tools);
    if let Some(toggle) = rich.as_ref() {
        let tools = tools.downgrade();
        toggle.connect_toggled(move |toggle| {
            if let Some(tools) = tools.upgrade() {
                tools.set_visible(!toggle.is_active());
            }
        });
    }
    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(editor));
    let welcome = welcome(ui, doc);
    overlay.add_overlay(&welcome);
    overlay.set_vexpand(true);
    pane.append(&overlay);
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    footer.add_css_class("document-status");
    footer.set_hexpand(true);
    let encoding = gtk::MenuButton::builder().label("UTF-8").build();
    let encoding_popover = gtk::Popover::new();
    encoding_popover.set_child(Some(format));
    encoding.set_popover(Some(&encoding_popover));
    footer.append(&encoding);
    let encoding_weak = encoding.downgrade();
    let label = doc.format_label.downgrade();
    let update_encoding = Rc::new(move || {
        if let (Some(button), Some(label)) = (encoding_weak.upgrade(), label.upgrade()) {
            button.set_label(label.text().split(" · ").next().unwrap_or("UTF-8"));
            button.set_tooltip_text(Some(&label.text()));
        }
    });
    let update = update_encoding.clone();
    doc.format_label.connect_label_notify(move |_| update());
    update_encoding();
    let language = gtk::Label::new(Some("Text"));
    language.set_ellipsize(gtk::pango::EllipsizeMode::End);
    language.set_max_width_chars(10);
    footer.append(&language);
    let weak_language = language.downgrade();
    let buffer = doc.buffer.downgrade();
    let update_language = Rc::new(move || {
        if let (Some(label), Some(buffer)) = (weak_language.upgrade(), buffer.upgrade()) {
            label.set_text(
                buffer
                    .language()
                    .map(|language| language.name().to_string())
                    .as_deref()
                    .unwrap_or("Text"),
            );
        }
    });
    let update = update_language.clone();
    doc.buffer.connect_language_notify(move |_| update());
    update_language();
    let format_button = operations::menu(ui);
    format_button.set_child(Some(&button_content(
        "fastra-format-symbolic",
        ui.lang.text("Formatieren", "Format"),
    )));
    footer.append(&format_button);
    wrap.set_label(Some(ui.lang.text("Soft Wrap: Ein", "Soft Wrap: On")));
    wrap.add_css_class("soft-wrap");
    footer.append(wrap);
    let weak = wrap.downgrade();
    let lang = ui.lang;
    wrap.connect_toggled(move |_| {
        if let Some(button) = weak.upgrade() {
            button.set_label(Some(if button.is_active() {
                lang.text("Soft Wrap: Ein", "Soft Wrap: On")
            } else {
                lang.text("Soft Wrap: Aus", "Soft Wrap: Off")
            }));
        }
    });
    let position = gtk::Label::new(None);
    footer.append(&position);
    if let Some(choice) = format.last_child().and_downcast::<gtk::DropDown>() {
        format.remove(&choice);
        if let Some(label) = format.last_child().and_downcast::<gtk::Label>() {
            if label.text() == ui.lang.text("Zeilenenden", "Line endings") {
                format.remove(&label);
            }
        }
        footer.append(&choice);
    }
    let stats = gtk::Label::new(None);
    stats.set_ellipsize(gtk::pango::EllipsizeMode::End);
    stats.set_max_width_chars(18);
    let statistics = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    statistics.append(&stats);
    let selected = gtk::Label::new(Some("Sel"));
    selected.set_tooltip_text(Some(
        ui.lang
            .text("Statistik der Auswahl", "Statistics for the selection"),
    ));
    selected.add_css_class("selection-statistics");
    selected.set_visible(false);
    statistics.append(&selected);
    footer.append(&statistics);
    let weak = Rc::downgrade(doc);
    let weak_position = position.downgrade();
    let update = Rc::new(move || {
        if let (Some(doc), Some(position)) = (weak.upgrade(), weak_position.upgrade()) {
            if doc
                .rich_toggle
                .borrow()
                .as_ref()
                .is_some_and(|toggle| toggle.is_active())
            {
                position.set_text("WYSIWYG");
                return;
            }
            if doc.comparison.borrow().is_some() {
                position.set_text(lang.text("Z — · Sp —", "Ln — · Col —"));
                return;
            }
            let buffer = source_panes::buffer(&doc);
            let caret = buffer.iter_at_mark(&buffer.get_insert());
            position.set_text(&format!(
                "{} {} · {} {}",
                lang.text("Z", "Ln"),
                caret.line() + 1,
                lang.text("Sp", "Col"),
                caret.line_offset() + 1
            ));
        }
    });
    if let Some(panes) = doc.source_panes.borrow().as_ref() {
        for buffer in &panes.buffers {
            let refresh = update.clone();
            buffer.connect_changed(move |_| refresh());
            let refresh = update.clone();
            buffer.connect_mark_set(move |_, _, _| refresh());
        }
    }
    if let Some(toggle) = doc.rich_toggle.borrow().as_ref() {
        let wrap = wrap.downgrade();
        let refresh = update.clone();
        toggle.connect_toggled(move |toggle| {
            if let Some(wrap) = wrap.upgrade() {
                wrap.set_visible(!toggle.is_active());
            }
            refresh();
        });
    }
    update();
    let statistics = super::statistics::install(doc, &stats, &selected, lang);
    let refresh_context: Rc<dyn Fn()> = Rc::new(move || {
        update();
        statistics();
    });
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    footer.append(&spacer);
    let modes = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    modes.add_css_class("view-segments");
    let text = gtk::Button::with_label("Text");
    text.add_css_class("selected");
    modes.append(&text);
    let hex = gtk::Button::with_label("Hex");
    hex.set_tooltip_text(Some(ui.lang.text(
        "Gespeicherte Dateibytes in einem eigenen Hex-Tab öffnen. Ungespeicherter Text bleibt erhalten.",
        "Open saved file bytes in a separate Hex tab. Unsaved text is retained.",
    )));
    let weak = Rc::downgrade(ui);
    hex.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            hex_routes::open(&ui);
        }
    });
    modes.append(&hex);
    footer.append(&modes);
    if let Some(toggle) = doc.rich_toggle.borrow().as_ref() {
        toggle.set_label(None);
        toggle.add_css_class("view-mode");
        let image = gtk::Image::from_icon_name("fastra-edit-rich-symbolic");
        image.set_pixel_size(13);
        toggle.set_child(Some(&image));
        let lang = ui.lang;
        let presentation = Rc::new(move |toggle: &gtk::CheckButton| {
            let (symbol, title) = if toggle.is_active() {
                (
                    "fastra-code-symbolic",
                    lang.text("Markdown-Quelltext bearbeiten", "Edit Markdown source"),
                )
            } else {
                (
                    "fastra-edit-rich-symbolic",
                    lang.text(
                        "Markdown im WYSIWYG-Modus bearbeiten",
                        "Edit Markdown in WYSIWYG mode",
                    ),
                )
            };
            image.set_icon_name(Some(symbol));
            toggle.set_tooltip_text(Some(&format!("{title} (Ctrl Shift Alt M)")));
            toggle.update_property(&[gtk::accessible::Property::Label(title)]);
        });
        let refresh = presentation.clone();
        toggle.connect_toggled(move |toggle| refresh(toggle));
        presentation(toggle);
        toggle.set_visible(
            doc.buffer
                .language()
                .is_some_and(|language| language.id() == "markdown"),
        );
        let toggle_weak = toggle.downgrade();
        doc.buffer.connect_language_notify(move |buffer| {
            if let Some(toggle) = toggle_weak.upgrade() {
                toggle.set_visible(
                    buffer
                        .language()
                        .is_some_and(|language| language.id() == "markdown"),
                );
            }
        });
        footer.append(toggle);
    }
    if let Some(preview) = doc.markdown_toggle.borrow().as_ref() {
        let weak = Rc::downgrade(ui);
        preview.connect_sensitive_notify(move |_| {
            if let Some(ui) = weak.upgrade() {
                super::refresh(&ui);
            }
        });
    }
    let find = gtk::Button::new();
    find.set_child(Some(&button_content(
        "fastra-search-symbolic",
        ui.lang.text("Suchen", "Find"),
    )));
    let weak = Rc::downgrade(ui);
    find.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            if let Some(editor) = ui.active().and_then(|doc| doc.rich.borrow().clone()) {
                editor.show_find();
            } else {
                chrome::find(&ui);
            }
        }
    });
    footer.append(&find);
    *doc.chrome.borrow_mut() = Some(Rc::new(DocumentChrome {
        footer,
        #[cfg(debug_assertions)]
        settings,
        welcome,
        refresh_context,
        _options: options_button,
    }));
}
