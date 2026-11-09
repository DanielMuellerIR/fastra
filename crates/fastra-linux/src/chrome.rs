//! Fensteraufteilung und Designwerte folgen der nativen Mac-Oberfläche.
use super::*;
pub(super) mod brand;
pub(super) mod dialog;
mod document;
pub(super) mod home;
pub(super) mod search;
#[cfg(debug_assertions)]
pub(super) mod selftest;
mod statistics;
pub(super) mod snapshot;
pub(super) mod wrap_row;
pub(super) use document::{
    Controls as DocumentControls, DocumentChrome, install as document, is_pristine, choose_project,
};

pub(super) struct Shell {
    pub(super) sidebar: gtk::Box,
    pub(super) body: gtk::Paned,
    tabs: gtk::Box,
    footer: gtk::Box,
    leading: gtk::Box,
    count: gtk::Label,
    preview: gtk::Button,
    sidebar_toggle: gtk::Button,
    commands: gtk::Box,
    #[cfg(debug_assertions)]
    menu: gtk::MenuButton,
    pub(super) search_window: gtk::Window,
    headers: RefCell<Vec<(std::rc::Weak<Document>, gtk::Box)>>,
}

pub(super) fn icon(name: &str, text: &str) -> gtk::Button {
    let button = gtk::Button::builder()
        .icon_name(name)
        .tooltip_text(text)
        .has_frame(false)
        .build();
    button.add_css_class("chrome-icon");
    button.update_property(&[gtk::accessible::Property::Label(text)]);
    button
}

fn button_content(name: &str, text: &str) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 7);
    let image = gtk::Image::from_icon_name(name);
    image.set_pixel_size(13);
    row.append(&image);
    row.append(&gtk::Label::new(Some(text)));
    row
}

pub(super) fn children(widget: &impl IsA<gtk::Widget>) -> Vec<gtk::Widget> {
    let mut result = Vec::new();
    let mut child = widget.first_child();
    while let Some(item) = child {
        child = item.next_sibling();
        result.push(item);
    }
    result
}

thread_local! {
    static THEMED_DISPLAYS: RefCell<Vec<glib::WeakRef<gtk::gdk::Display>>> = const { RefCell::new(Vec::new()) };
}

pub(super) fn theme(window: &gtk::ApplicationWindow) {
    window.add_css_class("fastra-shell");
    theme_widget(window);
}
pub(crate) fn theme_widget(window: &impl IsA<gtk::Widget>) {
    let display = gtk::prelude::WidgetExt::display(window);
    let installed = THEMED_DISPLAYS.with(|displays| {
        let mut displays = displays.borrow_mut();
        displays.retain(|display| display.upgrade().is_some());
        if displays
            .iter()
            .any(|item| item.upgrade().as_ref() == Some(&display))
        {
            return true;
        }
        displays.push(display.downgrade());
        false
    });
    if installed {
        return;
    }
    let provider = gtk::CssProvider::new();
    gtk::style_context_add_provider_for_display(
        &display,
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    let settings = window.settings();
    let observed = settings.downgrade();
    let refresh = Rc::new(move || {
        let Some(observed) = observed.upgrade() else {
            return;
        };
        let dark = super::editor_options::appearance::dark(&observed);
        let colors = if dark {
            "@define-color fastra_sheet #231e22; @define-color fastra_sheet_control #2e292d; @define-color fastra_sheet_selected #625f62; @define-color fastra_sheet_button #5a5659; @define-color fastra_warning #ff9f0a; @define-color fastra_base #272727; @define-color fastra_surface #171717; @define-color fastra_control #333333; @define-color fastra_text #f2f2f2; @define-color fastra_muted #a8a8a8; @define-color fastra_line alpha(white,.10); @define-color fastra_accent #8bb7f2; @define-color fastra_accent_fill #82ACEA; @define-color fastra_modified #DFA25A; @define-color fastra_removed #E88D7C; @define-color fastra_added #94CE9F;"
        } else {
            "@define-color fastra_sheet #ffffff; @define-color fastra_sheet_control #f2f2f2; @define-color fastra_sheet_selected #ffffff; @define-color fastra_sheet_button #ffffff; @define-color fastra_warning #ff9500; @define-color fastra_base #f7f7f7; @define-color fastra_surface #ffffff; @define-color fastra_control #ececec; @define-color fastra_text #363636; @define-color fastra_muted #868686; @define-color fastra_line alpha(black,.08); @define-color fastra_accent #3f69a8; @define-color fastra_accent_fill #4E78B7; @define-color fastra_modified #B56C1A; @define-color fastra_removed #A3392A; @define-color fastra_added #2F5D3A;"
        };
        provider.load_from_string(&format!("{colors}\n{}", super::editor_options::zoom::stylesheet()));
    });
    refresh();
    let callback = refresh.clone();
    let weak_display = display.downgrade();
    super::editor_options::zoom::watch(move || {
        if weak_display.upgrade().is_none() { return false; }
        callback(); true
    });
    let callback = refresh.clone(); let weak_display = display.downgrade();
    super::editor_options::appearance::watch(move || { if weak_display.upgrade().is_none() { return false; } callback(); true });
    // Ein Provider je Display bleibt auch nach dem Schließen des ersten
    // Fensters aktiv; weitere Dokumentfenster legen keine Observerkette an.
    for property in ["gtk-theme-name", "gtk-application-prefer-dark-theme"] {
        let refresh = refresh.clone();
        settings.connect_notify_local(Some(property), move |_, _| refresh());
    }
}

pub(super) fn mount(
    ui: &Rc<Ui>,
    toolbar: &gtk::FlowBox,
    document_search: &gtk::Paned,
    form: &gtk::Grid,
    search: &gtk::Button,
) {
    theme(&ui.window);
    ui.window.set_default_size(1100, 780);
    ui.window.set_size_request(760, 500);
    document_search.set_start_child(None::<&gtk::Widget>);
    document_search.set_end_child(None::<&gtk::Widget>);
    ui.tabs.set_show_tabs(false);
    ui.tabs.add_css_class("document-stack");
    let search_window = search::install(ui, form, search);
    super::tab_comparison::install_keys(ui, &search_window);

    let commands = gtk::Box::new(gtk::Orientation::Vertical, 2);
    commands.add_css_class("command-menu");
    for wrapper in children(toolbar) {
        if let Ok(wrapper) = wrapper.downcast::<gtk::FlowBoxChild>() {
            if let Some(widget) = wrapper.child() {
                wrapper.set_child(None::<&gtk::Widget>);
                toolbar.remove(&wrapper);
                commands.append(&widget);
            }
        }
    }
    let menu = gtk::MenuButton::builder()
        .icon_name("open-menu-symbolic")
        .tooltip_text(ui.lang.text("Fastra-Menü", "Fastra menu"))
        .build();
    menu.add_css_class("chrome-icon");
    menu.update_property(&[gtk::accessible::Property::Label(
        ui.lang.text("Fastra-Menü", "Fastra menu"),
    )]);
    let popover = gtk::Popover::new();
    let menu_scroll = gtk::ScrolledWindow::builder()
        .child(&commands)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .max_content_height(560)
        .propagate_natural_height(true)
        .build();
    popover.set_child(Some(&menu_scroll));
    menu.set_popover(Some(&popover));
    super::editor_options::zoom::menu(ui, &commands, &popover);
    dismiss_command_popovers(commands.upcast_ref(), &mut std::collections::HashSet::new());
    let leading = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    leading.add_css_class("chrome-leading");
    leading.set_size_request(208, 36);
    leading.set_hexpand(false);
    let controls = gtk::WindowControls::new(gtk::PackType::Start);
    controls.set_decoration_layout(Some("close,minimize,maximize:"));
    leading.append(&controls);
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    let leading_drag = gtk::WindowHandle::new();
    leading_drag.set_child(Some(&spacer));
    leading_drag.set_hexpand(true);
    leading.append(&leading_drag);
    let gear = icon(
        "emblem-system-symbolic",
        ui.lang.text("Einstellungen", "Settings"),
    );
    leading.append(&gear);
    let weak = Rc::downgrade(ui);
    gear.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            if let Some(app) = ui.window.application() { app.activate_action("settings", None); }
        }
    });
    let home = icon(
        "fastra-home-symbolic",
        ui.lang.text("Zum Willkommensbildschirm", "Show welcome"),
    );
    home.set_widget_name("fastra-home");
    let weak = Rc::downgrade(ui);
    home.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            home::reset(&ui, None);
        }
    });
    leading.append(&home);
    let toggle = icon(
        "fastra-sidebar-left-symbolic",
        ui.lang
            .text("Seitenleiste ein-/ausblenden", "Toggle sidebar"),
    );
    toggle.set_sensitive(false);
    let sidebar = gtk::Box::new(gtk::Orientation::Vertical, 0);
    sidebar.add_css_class("project-sidebar");
    sidebar.set_visible(false);
    sidebar.set_size_request(160, -1);
    let target = sidebar.downgrade();
    toggle.connect_clicked(move |_| {
        if let Some(sidebar) = target.upgrade() {
            if sidebar.first_child().is_some() {
                sidebar.set_visible(!sidebar.is_visible());
            }
        }
    });
    leading.append(&toggle);
    let tabstrip = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    tabstrip.add_css_class("chrome-tabs");
    let tab_region = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    tab_region.append(&tabstrip);
    // Fensterziehen gehört nur auf freie Flächen. Ein WindowHandle um die
    // gesamte Tab-Leiste würde die Dateidrags vor GtkDragSource beanspruchen.
    let free_area = gtk::WindowHandle::new();
    free_area.set_hexpand(true);
    free_area.set_child(Some(&gtk::Box::new(gtk::Orientation::Horizontal, 0)));
    tab_region.append(&free_area);
    let tab_scroll = gtk::ScrolledWindow::builder()
        .child(&tab_region)
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .vscrollbar_policy(gtk::PolicyType::Never)
        .hexpand(true)
        .build();
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    header.add_css_class("window-chrome");
    header.set_height_request(36);
    header.append(&leading);
    header.append(&tab_scroll);
    let new = icon("list-add-symbolic", ui.lang.text("Neuer Tab", "New tab"));
    let weak = Rc::downgrade(ui);
    new.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.add_document(ui.lang.text("Unbenannt", "Untitled"), "");
        }
    });
    header.append(&new);
    let count = gtk::Label::new(Some("1"));
    count.add_css_class("tab-count");
    header.append(&count);
    let preview = icon(
        "fastra-sidebar-right-symbolic",
        ui.lang.text(
            "Markdown-Vorschau ein-/ausblenden",
            "Toggle Markdown preview",
        ),
    );
    let weak = Rc::downgrade(ui);
    preview.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            if let Some(toggle) = ui
                .active()
                .and_then(|doc| doc.markdown_toggle.borrow().clone())
                .filter(|toggle| toggle.is_sensitive())
            {
                toggle.set_active(!toggle.is_active());
            }
        }
    });
    header.append(&preview);
    header.append(&menu);
    ui.window.set_titlebar(Some(&header));
    let body = gtk::Paned::new(gtk::Orientation::Horizontal);
    body.set_start_child(Some(&sidebar));
    body.set_end_child(Some(&ui.tabs));
    body.set_position(208);
    body.set_resize_start_child(false);
    body.set_shrink_start_child(false);
    body.set_shrink_end_child(false);
    body.set_vexpand(true);
    let header_lead = leading.downgrade();
    body.connect_position_notify(move |body| {
        if let Some(leading) = header_lead.upgrade() {
            leading.set_size_request(body.position().clamp(160, 420), 36);
        }
    });
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    footer.add_css_class("window-status");
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let canvas = gtk::Overlay::new();
    canvas.set_child(Some(&body));
    let message = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    message.add_css_class("document-message");
    message.set_halign(gtk::Align::End);
    message.set_valign(gtk::Align::End);
    message.set_margin_end(12);
    message.set_margin_bottom(12);
    message.set_visible(false);
    let text = gtk::Label::new(None);
    text.set_wrap(true);
    text.set_max_width_chars(65);
    ui.status
        .bind_property("label", &text, "label")
        .sync_create()
        .build();
    message.append(&text);
    let dismiss = icon(
        "window-close-symbolic",
        ui.lang.text("Hinweis schließen", "Dismiss notice"),
    );
    let weak_message = message.downgrade();
    dismiss.connect_clicked(move |_| {
        if let Some(message) = weak_message.upgrade() {
            message.set_visible(false);
        }
    });
    message.append(&dismiss);
    canvas.add_overlay(&message);
    let weak_message = message.downgrade();
    let weak = Rc::downgrade(ui);
    ui.status.connect_label_notify(move |label| {
        if let (Some(message), Some(ui)) = (weak_message.upgrade(), weak.upgrade()) {
            let text = label.text();
            let routine = text.is_empty()
                || text.as_str()
                    == ui.lang.text(
                        "Vorschau neu berechnen, bevor Änderungen übernommen werden.",
                        "Calculate a preview before applying changes.",
                    );
            message.set_visible(!routine && !ui.search_section.is_expanded());
        }
    });
    root.append(&canvas);
    root.append(&footer);
    ui.window.set_child(Some(&root));
    let shell = Rc::new(Shell {
        sidebar,
        body,
        tabs: tabstrip,
        footer,
        leading,
        count,
        preview,
        sidebar_toggle: toggle,
        commands,
        #[cfg(debug_assertions)]
        menu,
        search_window,
        headers: RefCell::new(Vec::new()),
    });
    *ui.chrome.borrow_mut() = Some(shell.clone());
    let weak = Rc::downgrade(ui);
    let window = shell.search_window.downgrade();
    ui.search_section.connect_expanded_notify(move |section| {
        if let (Some(ui), Some(window)) = (weak.upgrade(), window.upgrade()) {
            if section.is_expanded() {
                window.set_application(ui.window.application().as_ref());
                window.present();
                ui.find.grab_focus();
            } else {
                window.set_visible(false);
            }
        }
    });
    shell
        .search_window
        .connect_hide(|window| window.set_application(None::<&gtk::Application>));
    let weak = Rc::downgrade(ui);
    shell.search_window.connect_close_request(move |window| {
        window.set_visible(false);
        if let Some(ui) = weak.upgrade() {
            ui.search_section.set_expanded(false);
        }
        glib::Propagation::Stop
    });
    let keys = gtk::EventControllerKey::new();
    let weak = Rc::downgrade(ui);
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        if key == gtk::gdk::Key::f && modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK) {
            if let Some(ui) = weak.upgrade() {
                ui.find.grab_focus();
                ui.find.select_region(0, -1);
            }
            return glib::Propagation::Stop;
        }
        if key == gtk::gdk::Key::Escape
            || (key == gtk::gdk::Key::w && modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK))
        {
            if let Some(ui) = weak.upgrade() {
                ui.search_section.set_expanded(false);
            }
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    shell.search_window.add_controller(keys);
    let weak = Rc::downgrade(ui);
    ui.tabs.connect_switch_page(move |_, _, _| {
        schedule(&weak);
    });
    let weak = Rc::downgrade(ui);
    ui.tabs.connect_page_added(move |_, _, _| {
        schedule(&weak);
    });
    let weak = Rc::downgrade(ui);
    ui.tabs.connect_page_removed(move |_, _, _| {
        schedule(&weak);
    });
    refresh(ui);
}

fn schedule(weak: &std::rc::Weak<Ui>) {
    let weak = weak.clone();
    glib::idle_add_local_once(move || {
        if let Some(ui) = weak.upgrade() {
            refresh(&ui);
        }
    });
}

#[cfg(debug_assertions)]
pub(super) fn tab_header(ui: &Ui, doc: &Document) -> gtk::Widget {
    ui.chrome
        .borrow()
        .as_ref()
        .unwrap()
        .headers
        .borrow()
        .iter()
        .find(|(weak, _)| {
            weak.upgrade()
                .is_some_and(|item| std::ptr::eq(item.as_ref(), doc))
        })
        .map(|(_, header)| header.clone().upcast())
        .expect("visible tab header")
}

pub(super) fn refresh(ui: &Rc<Ui>) {
    let Some(shell) = ui.chrome.borrow().clone() else {
        return;
    };
    let documents = ui.documents.borrow().clone();
    let mut headers = shell.headers.borrow_mut();
    headers.retain(|(weak, header)| {
        let retained = weak
            .upgrade()
            .is_some_and(|doc| documents.iter().any(|item| Rc::ptr_eq(item, &doc)));
        if !retained {
            shell.tabs.remove(header);
        }
        retained
    });
    for doc in &documents {
        if headers
            .iter()
            .any(|(weak, _)| weak.upgrade().is_some_and(|item| Rc::ptr_eq(&item, doc)))
        {
            continue;
        }
        let header = tab_close::header(ui, doc);
        header.add_css_class("tab-pill");
        header.update_property(&[gtk::accessible::Property::Label(&doc.label.text())]);
        let target = header.downgrade();
        doc.label.connect_label_notify(move |label| {
            if let Some(header) = target.upgrade() {
                header.update_property(&[gtk::accessible::Property::Label(&label.text())]);
            }
        });
        shell.tabs.append(&header);
        headers.push((Rc::downgrade(doc), header));
    }
    let active = ui.active();
    let partner = super::tab_comparison::partner(ui);
    for (weak, header) in headers.iter() {
        let selected = weak.upgrade().is_some_and(|doc| {
            active
                .as_ref()
                .is_some_and(|active| Rc::ptr_eq(active, &doc))
        });
        if selected {
            header.add_css_class("active");
        } else {
            header.remove_css_class("active");
        }
        let comparison = weak.upgrade().is_some_and(|doc| partner.as_ref().is_some_and(|partner| Rc::ptr_eq(partner, &doc)));
        if comparison { header.add_css_class("comparison"); } else { header.remove_css_class("comparison"); }
        header.update_property(&[gtk::accessible::Property::Description(if selected { ui.lang.text("Aktueller Tab", "Current tab") } else if comparison { ui.lang.text("Vergleichspartner", "Comparison partner") } else { ui.lang.text("Tab", "Tab") })]);
    }
    while let Some(child) = shell.footer.first_child() {
        shell.footer.remove(&child);
    }
    shell
        .footer
        .set_visible(active.as_ref().is_some_and(|doc| doc.has_source_text() || doc.comparison.borrow().is_some()));
    if let Some(doc) = active.as_ref() {
        if let Some(chrome) = doc.chrome.borrow().as_ref() {
            chrome.welcome.set_visible(document::is_pristine(doc));
            shell.footer.append(&chrome.footer);
        }
    }
    shell.count.set_text(&documents.len().to_string());
    shell
        .preview
        .set_sensitive(active.as_ref().is_some_and(|doc| {
            doc.buffer
                .language()
                .is_some_and(|language| language.id() == "markdown")
        }));
    project_view::refresh_selection(ui);
    search_selection::refresh(ui);
}

pub(super) fn project(ui: &Rc<Ui>, root: &gtk::Box) {
    if let Some(shell) = ui.chrome.borrow().as_ref() {
        while let Some(child) = shell.sidebar.first_child() {
            shell.sidebar.remove(&child);
        }
        shell.sidebar.append(root);
        shell.sidebar.set_visible(true);
        shell.sidebar_toggle.set_sensitive(true);
        shell.body.set_position(208);
        shell.leading.set_size_request(208, 36);
    }
}

pub(super) fn settings(ui: &Rc<Ui>, widget: &impl IsA<gtk::Widget>) {
    if let Some(shell) = ui.chrome.borrow().as_ref() {
        let expander = gtk::Expander::builder()
            .label(ui.lang.text("Sitzungssicherung", "Session backups"))
            .child(widget)
            .build();
        for child in children(widget) {
            if let Some(flow) = child.downcast_ref::<gtk::FlowBox>() {
                flow.set_min_children_per_line(1);
                flow.set_max_children_per_line(1);
            }
            if let Some(label) = child.downcast_ref::<gtk::Label>() {
                label.set_max_width_chars(50);
            }
        }
        shell.commands.append(&expander);
    }
}

pub(super) fn find(ui: &Rc<Ui>) {
    let preserve = ui.chrome.borrow().as_ref().is_some_and(|s| s.search_window.is_visible()) && !ui.find.text().is_empty();
    if matches!(ui.scope.selected(), 0 | 4) && !preserve { search_selection::capture_multiline(ui); }
    show_search(ui);
}
pub(super) fn show_search(ui: &Rc<Ui>) {
    if matches!(ui.scope.selected(), 1..=3) {
        if search_live::present(ui) {
            return;
        }
        match ui.scope.selected() {
            1 => tabs_search::open(ui),
            2 => folder::open(ui),
            _ => project_view::search(ui),
        }
        return;
    }
    ui.search_section.set_expanded(true);
    if let Some(shell) = ui.chrome.borrow().as_ref() {
        shell
            .search_window
            .set_application(ui.window.application().as_ref());
        shell.search_window.present();
        ui.find.grab_focus();
        let stale = ui.pending.borrow().as_ref().is_some_and(|pending| {
            ui.active().is_none_or(|doc| {
                pending.target.as_ref().is_none_or(|target| {
                    !target.valid_document(&doc)
                        || !search_selection::valid(ui, &doc, pending.selection)
                })
            })
        });
        if stale {
            search_live::changed(ui);
        }
    }
}

pub(super) fn sidebar(
    ui: &Rc<Ui>,
    root: &gtk::Box,
    path: &gtk::Entry,
    filter: &gtk::Entry,
    list: &gtk::ScrolledWindow,
) {
    let controls = children(root);
    for child in &controls {
        root.remove(child);
    }
    root.set_spacing(0);
    root.set_margin_top(0);
    root.set_margin_bottom(0);
    root.set_margin_start(0);
    root.set_margin_end(0);
    root.set_vexpand(true);
    let brand = gtk::Box::new(gtk::Orientation::Horizontal, 9);
    brand.add_css_class("sidebar-brand");
    let wordmark = gtk::Box::new(gtk::Orientation::Vertical, 1);
    let title = brand::wordmark(19.);
    title.add_css_class("sidebar-wordmark");
    title.set_xalign(0.);
    wordmark.append(&title);
    let version = gtk::Label::new(Some(&format!("v{}", env!("CARGO_PKG_VERSION"))));
    version.add_css_class("sidebar-version");
    version.set_xalign(0.);
    wordmark.append(&version);
    brand.append(&wordmark);
    brand.append(&gtk::Separator::new(gtk::Orientation::Vertical));
    let folder = gtk::Image::from_icon_name("fastra-folder-symbolic");
    folder.set_pixel_size(14);
    let project_heading = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    project_heading.set_hexpand(true);
    project_heading.append(&folder);
    let menu = gtk::MenuButton::new();
    menu.set_hexpand(true);
    menu.add_css_class("project-menu");
    let heading = gtk::Box::new(gtk::Orientation::Vertical, 2);
    let name = gtk::Label::new(Some(ui.lang.text("Projekt", "Project")));
    name.set_xalign(0.);
    name.set_ellipsize(gtk::pango::EllipsizeMode::End);
    name.set_max_width_chars(12);
    name.add_css_class("sidebar-project-name");
    heading.append(&name);
    let location = gtk::Label::new(None);
    location.set_xalign(0.);
    location.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    location.set_max_width_chars(12);
    location.add_css_class("sidebar-path");
    heading.append(&location);
    menu.set_child(Some(&heading));
    let name_weak = name.downgrade();
    let location_weak = location.downgrade();
    let menu_weak = menu.downgrade();
    path.connect_changed(move |path| {
        if let (Some(name), Some(location), Some(menu)) = (
            name_weak.upgrade(),
            location_weak.upgrade(),
            menu_weak.upgrade(),
        ) {
            let text = path.text();
            name.set_text(text.trim_end_matches('/').rsplit('/').next().unwrap_or(""));
            location.set_text(&text);
            menu.set_tooltip_text(Some(&text));
        }
    });
    let settings = gtk::Box::new(gtk::Orientation::Vertical, 8);
    settings.set_margin_top(12);
    settings.set_margin_bottom(12);
    settings.set_margin_start(12);
    settings.set_margin_end(12);
    settings.set_width_request(400);
    for child in controls {
        if child != *filter.upcast_ref::<gtk::Widget>()
            && child != *list.upcast_ref::<gtk::Widget>()
        {
            settings.append(&child);
        }
    }
    let popover = gtk::Popover::new();
    popover.set_child(Some(&settings));
    menu.set_popover(Some(&popover));
    project_heading.append(&menu);
    brand.append(&project_heading);
    root.append(&brand);
    filter.set_placeholder_text(Some(ui.lang.text("Dateien filtern", "Filter files")));
    filter.set_primary_icon_name(Some("fastra-search-symbolic"));
    filter.set_secondary_icon_name(None);
    filter.connect_changed(|filter| {
        filter.set_secondary_icon_name(if filter.text().is_empty() {
            None
        } else {
            Some("edit-clear-symbolic")
        });
    });
    filter.connect_icon_press(|filter, icon| {
        if icon == gtk::EntryIconPosition::Secondary {
            filter.set_text("");
        }
    });
    filter.add_css_class("sidebar-filter");
    root.append(filter);
    root.append(list);
    let open = gtk::Button::new();
    open.set_child(Some(&button_content(
        "list-add-symbolic",
        ui.lang.text("Datei öffnen …", "Open file …"),
    )));
    open.add_css_class("sidebar-open");
    let weak = Rc::downgrade(ui);
    open.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.open();
        }
    });
    root.append(&open);
    project(ui, root);
}

pub(super) fn command(ui: &Rc<Ui>, label: &str) {
    fn find(widget: &gtk::Widget, label: &str) -> Option<gtk::Button> {
        if let Some(button) = widget
            .downcast_ref::<gtk::Button>()
            .filter(|button| button.label().as_deref() == Some(label))
        {
            return Some(button.clone());
        }
        for child in children(widget) {
            if let Some(button) = find(&child, label) {
                return Some(button);
            }
        }
        if let Some(popover) = widget
            .downcast_ref::<gtk::MenuButton>()
            .and_then(|button| button.popover())
        {
            return find(popover.upcast_ref(), label);
        }
        None
    }
    if let Some(shell) = ui.chrome.borrow().as_ref() {
        if let Some(button) = find(shell.commands.upcast_ref(), label) {
            button.emit_clicked();
        }
    }
}

pub(super) fn open_project(ui: &Rc<Ui>, path: std::path::PathBuf) {
    home::reset(ui, Some(path));
}

#[cfg(debug_assertions)]
pub(super) fn show_commands(ui: &Ui) {
    if let Some(shell) = ui.chrome.borrow().as_ref() {
        shell.menu.popup();
    }
}

fn dismiss_command_popovers(widget: &gtk::Widget, seen: &mut std::collections::HashSet<usize>) {
    if !seen.insert(widget.as_ptr() as usize) {
        return;
    }
    if let Some(button) = widget
        .downcast_ref::<gtk::Button>()
        .filter(|button| button.label().is_some())
    {
        button.connect_clicked(|button| {
            // Sonst behält das äußere App-Menü den Pointer-Grab: Der erste
            // Klick im neu geöffneten Werkzeug würde nur dieses Menü schließen.
            let mut parent = button.parent();
            while let Some(widget) = parent {
                parent = widget.parent();
                if let Some(popover) = widget.downcast_ref::<gtk::Popover>().filter(|popover| popover.is_visible()) {
                    popover.popdown();
                }
            }
        });
    }
    for child in children(widget) {
        dismiss_command_popovers(&child, seen);
    }
    if let Some(popover) = widget
        .downcast_ref::<gtk::MenuButton>()
        .and_then(|button| button.popover())
    {
        dismiss_command_popovers(popover.upcast_ref(), seen);
    }
}
