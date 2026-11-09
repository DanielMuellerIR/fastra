use super::*;
mod drop_cursor;
mod elements;

#[cfg(debug_assertions)]
fn test_width(window: &gtk::Window) {
    if let Some(width) = std::env::var("FASTRA_SEARCH_LAYOUT_WIDTH")
        .ok()
        .and_then(|s| s.parse::<i32>().ok())
    {
        window.set_default_size(width.max(520), window.default_size().1);
    }
}

pub(crate) fn decorate(ui: &Rc<Ui>, window: &gtk::Window) {
    window.add_css_class("fastra-search");
    window.set_modal(false);
    window.set_default_size(520, 485);
    window.set_size_request(520, 450);
    super::dialog::decorate(
        window,
        ui.lang.text("Suchen & Ersetzen", "Search & Replace"),
        ui.lang,
    );
}

pub(crate) fn scopes(ui: &Rc<Ui>, window: &gtk::Window, selected: u32) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    row.add_css_class("search-scopes");
    let title = field_label(ui.lang.text("Suchbereich", "Search scope"));
    row.append(&title);
    for (index, title) in [
        (0, ui.lang.text("Datei", "File")),
        (1, ui.lang.text("Geöffnet", "Open")),
        (2, ui.lang.text("Ordner", "Folder")),
        (3, ui.lang.text("Projekt", "Project")),
    ] {
        let button = gtk::ToggleButton::with_label(title);
        button.set_active(index == selected.min(3));
        button.add_css_class("scope-tab");
        if index == 3 {
            let weak = Rc::downgrade(ui);
            let target = button.downgrade();
            window.connect_map(move |_| {
                if let (Some(ui), Some(button)) = (weak.upgrade(), target.upgrade()) {
                    button.set_sensitive(project_view::current_binding(&ui).is_some());
                }
            });
        }
        let scope_info = if index == 1 && selected == 1 {
            let popover = gtk::Popover::new();
            let info = git_view::label(ui.lang.text("Alle offenen editierbaren Tabs. Die Übernahme ändert nur den Editor; Dateien werden separat gespeichert. Grenzen: 128 Tabs, 4 MiB je Eingabe, 10.000 Treffer, 64 MiB Quelltext. Überschreitungen sperren den gesamten Plan.","All open editable tabs. Applying changes the editor only; save files separately. Limits: 128 tabs, 4 MiB per input, 10,000 matches, 64 MiB source text. Exceeding a limit blocks the entire plan."));
            info.set_max_width_chars(52);
            let content = git_view::column();
            content.append(&info);
            popover.set_child(Some(&content));
            popover.set_parent(&button);
            button.set_tooltip_text(Some(ui.lang.text(
                "Hinweise zum Suchbereich anzeigen",
                "About this search scope",
            )));
            let weak = popover.downgrade();
            button.connect_unrealize(move |_| {
                if let Some(popover) = weak.upgrade() {
                    popover.unparent();
                }
            });
            Some(popover)
        } else {
            None
        };
        let weak = Rc::downgrade(ui);
        let owner = window.downgrade();
        button.connect_clicked(move |button| {
            if index == selected {
                button.set_active(true);
                if let Some(info) = scope_info.as_ref() {
                    info.popup();
                }
                return;
            }
            if let (Some(ui), Some(window)) = (weak.upgrade(), owner.upgrade()) {
                window.close();
                // Laufende Dateivorgänge dürfen den Bereichswechsel ablehnen.
                if window.is_visible() {
                    button.set_active(false);
                    return;
                }
                ui.scope
                    .set_selected(if index == 0 && search_selection::available(&ui) {
                        4
                    } else {
                        index
                    });
                match index {
                    0 => super::show_search(&ui),
                    1 => tabs_search::open(&ui),
                    2 => folder::open(&ui),
                    _ => project_view::search(&ui),
                }
            }
        });
        row.append(&button);
    }
    row
}

fn field_label(text: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.add_css_class("search-field-label");
    label.set_width_request(80);
    label.set_xalign(0.);
    label
}

fn find_extras(ui: &Rc<Ui>, window: &gtk::Window, selected: u32, find: &gtk::Entry) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    row.append(&elements::picker(ui, find));
    let menu = if selected == 0 {
        ui.search_history.borrow().as_ref().unwrap().clone()
    } else {
        let menu = search_history::Menu::for_window(ui, window, find);
        let retained = RefCell::new(Some(menu.clone()));
        window.connect_hide(move |_| {
            retained.borrow_mut().take();
        });
        menu
    };
    if let Some(parent) = menu.button.parent().and_downcast::<gtk::Box>() {
        parent.remove(&menu.button);
    }
    if selected == 0 {
        menu.attach_shortcut(window);
    }
    menu.button.set_icon_name("fastra-history-symbolic");
    menu.button.add_css_class("chrome-icon");
    menu.button
        .set_tooltip_text(Some(ui.lang.text("Suchverlauf", "Search history")));
    row.append(&menu.button);
    row.append(&template_menu::controls(ui, window));
    row
}

fn mode_toggle(mode: &gtk::DropDown, title: &str, selected: u32) -> gtk::CheckButton {
    let toggle = gtk::CheckButton::with_label(title);
    toggle.set_active(mode.selected() == selected);
    let canonical = mode.clone();
    toggle.connect_toggled(move |toggle| {
        if toggle.is_active() {
            canonical.set_selected(selected);
        } else if canonical.selected() == selected {
            canonical.set_selected(1);
        }
    });
    let target = toggle.downgrade();
    mode.connect_selected_notify(move |mode| {
        if let Some(toggle) = target.upgrade() {
            toggle.set_active(mode.selected() == selected);
        }
    });
    toggle
}

fn form(
    ui: &Rc<Ui>,
    form: &gtk::Grid,
    entries: (&gtk::Entry, &gtk::Entry),
    flags: (&gtk::DropDown, &gtk::CheckButton, &gtk::CheckButton),
    pane: &Rc<approval::ApprovalPane>,
    context: (&gtk::Window, u32),
) {
    let (find, replace) = entries;
    let (mode, case, word) = flags;
    let (window, selected) = context;
    if let Some(model) = ui.search_pattern.borrow().as_ref() {
        model.field(find);
    }
    drop_cursor::install(find);
    drop_cursor::install(replace);
    for widget in children(form) {
        form.remove(&widget);
    }
    form.set_column_spacing(8);
    form.set_row_spacing(6);
    find.set_hexpand(true);
    find.set_placeholder_text(Some(
        ui.lang
            .text("Suchausdruck eingeben…", "Enter a search expression…"),
    ));
    replace.set_hexpand(true);
    replace.set_placeholder_text(Some(ui.lang.text(
        "Ersetzen durch… ($1, $2 für Gruppen)",
        "Replace with… ($1, $2 for groups)",
    )));
    form.attach(&field_label(ui.lang.text("Suchen", "Find")), 0, 0, 1, 1);
    form.attach(find, 1, 0, 1, 1);
    form.attach(&find_extras(ui, window, selected, find), 2, 0, 2, 1);
    let flags = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    flags.add_css_class("search-options");
    let regex = mode_toggle(mode, "RegEx", 2);
    let literal = gtk::CheckButton::with_label(ui.lang.text("∗ wörtlich", "Literal ∗"));
    let syncing = Rc::new(Cell::new(false));
    let field = find.downgrade();
    let target = literal.downgrade();
    let canonical = mode.downgrade();
    let guard = syncing.clone();
    let previously_literal = Cell::new(false);
    let update = Rc::new(move || {
        if let (Some(field), Some(toggle), Some(mode)) =
            (field.upgrade(), target.upgrade(), canonical.upgrade())
        {
            guard.set(true);
            let enabled = mode.selected() != 2 && field.text().contains('*');
            if previously_literal.replace(enabled && mode.selected() == 0)
                && !enabled
                && mode.selected() == 0
            {
                mode.set_selected(1);
            }
            toggle.set_sensitive(enabled);
            toggle.set_active(enabled && mode.selected() == 0);
            guard.set(false);
        }
    });
    let refresh = update.clone();
    find.connect_changed(move |_| refresh());
    let refresh = update.clone();
    mode.connect_selected_notify(move |_| refresh());
    let canonical = mode.clone();
    literal.connect_toggled(move |toggle| {
        if !syncing.get() && toggle.is_sensitive() {
            canonical.set_selected(if toggle.is_active() { 0 } else { 1 });
        }
    });
    update();
    let ignore_case = gtk::CheckButton::with_label(ui.lang.text("Groß = klein", "Ignore case"));
    ignore_case.set_active(!case.is_active());
    let canonical = case.clone();
    ignore_case.connect_toggled(move |toggle| canonical.set_active(!toggle.is_active()));
    let target = ignore_case.downgrade();
    case.connect_toggled(move |case| {
        if let Some(toggle) = target.upgrade() {
            toggle.set_active(!case.is_active());
        }
    });
    word.set_label(Some(ui.lang.text("Ganzes Wort", "Whole word")));
    let wrap = gtk::CheckButton::with_label("Wrap-around");
    pane.wrap_around.set(ui.approval.wrap_around.get());
    wrap.set_active(pane.wrap_around.get());
    let canonical = Rc::downgrade(&ui.approval);
    let weak = Rc::downgrade(pane);
    wrap.connect_toggled(move |toggle| {
        if let Some(pane) = weak.upgrade() {
            pane.wrap_around.set(toggle.is_active());
        }
        if let Some(pane) = canonical.upgrade() {
            pane.wrap_around.set(toggle.is_active());
        }
    });
    for widget in [&regex, &ignore_case, word, &wrap] {
        flags.append(widget);
    }
    let secondary = gtk::Box::new(gtk::Orientation::Horizontal, 16);
    let selection = gtk::CheckButton::with_label(ui.lang.text("Nur in Auswahl", "Selection only"));
    if selected == 0 {
        ui.selection_control.set(Some(&selection));
        search_selection::refresh(ui);
        selection.set_active(ui.scope.selected() == 4);
        let scope = ui.scope.downgrade();
        selection.connect_toggled(move |toggle| {
            if let Some(scope) = scope.upgrade() {
                if toggle.is_active() {
                    scope.set_selected(4);
                } else if scope.selected() == 4 {
                    scope.set_selected(0);
                }
            }
        });
        let target = selection.downgrade();
        ui.scope.connect_selected_notify(move |scope| {
            if let Some(toggle) = target.upgrade() {
                toggle.set_active(scope.selected() == 4);
            }
        });
    } else {
        selection.set_sensitive(false);
        selection.set_visible(false);
    }
    secondary.append(&selection);
    secondary.append(&literal);
    let flag_rows = super::wrap_row::Row::new(16, 4);
    flag_rows.add_css_class("search-options-wrap");
    for group in [flags, secondary] {
        flag_rows.append(&group);
    }
    let options_label = field_label(ui.lang.text("Optionen", "Options"));
    options_label.set_valign(gtk::Align::Start);
    options_label.set_margin_top(4);
    form.attach(&options_label, 0, 1, 1, 1);
    form.attach(&flag_rows, 1, 1, 3, 1);
    form.attach(
        &field_label(ui.lang.text("Ersetzen", "Replace")),
        0,
        2,
        1,
        1,
    );
    let replacement = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    replacement.append(replace);
    let swap = icon(
        "fastra-swap-symbolic",
        ui.lang
            .text("Suchen und Ersetzen vertauschen", "Swap Find and Replace"),
    );
    let a = find.downgrade();
    let b = replace.downgrade();
    swap.connect_clicked(move |_| {
        if let (Some(find), Some(replace)) = (a.upgrade(), b.upgrade()) {
            let value = find.text();
            find.set_text(&replace.text());
            replace.set_text(&value);
        }
    });
    replacement.append(&swap);
    form.attach(&replacement, 1, 2, 3, 1);
}

pub(super) fn install(ui: &Rc<Ui>, form_widget: &gtk::Grid, search: &gtk::Button) -> gtk::Window {
    ui.search_section.set_child(None::<&gtk::Widget>);
    ui.search_section.set_expanded(false);
    let window = gtk::Window::builder()
        .title(ui.lang.text("Suchen & Ersetzen", "Search & Replace"))
        .transient_for(&ui.window)
        .destroy_with_parent(true)
        .build();
    decorate(ui, &window);
    let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
    root.add_css_class("search-content");
    // Vor dem Umhängen alle bisherigen Eltern lösen; die Controls und ihre
    // Signalbindungen sind dieselben wie im ursprünglichen Suchbereich.
    for widget in [
        form_widget.upcast_ref::<gtk::Widget>(),
        ui.capture_scroll.upcast_ref(),
        ui.approval.root.upcast_ref(),
        ui.status.upcast_ref(),
    ] {
        if let Some(parent) = widget.parent().and_downcast::<gtk::Box>() {
            parent.remove(widget);
        }
    }
    for widget in [
        ui.case.upcast_ref::<gtk::Widget>(),
        ui.whole_word.upcast_ref(),
    ] {
        if let Some(parent) = widget.parent().and_downcast::<gtk::Box>() {
            parent.remove(widget);
        }
    }
    form(
        ui,
        form_widget,
        (&ui.find, &ui.replace),
        (&ui.mode, &ui.case, &ui.whole_word),
        &ui.approval,
        (&window, 0),
    );
    root.append(&scopes(ui, &window, 0));
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    root.append(form_widget);
    ui.capture_scroll.set_min_content_height(22);
    ui.capture_scroll.set_max_content_height(22);
    ui.capture_scroll.set_max_content_width(140);
    ui.capture_scroll
        .set_hscrollbar_policy(gtk::PolicyType::External);
    ui.capture_scroll
        .set_vscrollbar_policy(gtk::PolicyType::Never);
    ui.capture_scroll.set_propagate_natural_width(true);
    form_widget
        .child_at(1, 2)
        .unwrap()
        .downcast::<gtk::Box>()
        .unwrap()
        .append(&ui.capture_scroll);
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    ui.approval.root.add_css_class("search-approvals");
    ui.approval.root.set_height_request(180);
    root.append(&ui.approval.root);
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    search.set_visible(false);
    ui.apply
        .set_label(ui.lang.text("Freigegebene übernehmen", "Apply approved"));
    let review = ui.approval.search_layout(ui, &window, &ui.apply, false);
    root.append(&footer(ui, &window, &ui.approval, None, &review));
    ui.find.set_activates_default(true);
    ui.replace.set_activates_default(true);
    ui.status.add_css_class("search-status");
    ui.status.set_wrap(true);
    ui.status
        .connect_label_notify(|label| label.set_visible(!label.text().is_empty()));
    ui.status.set_visible(false);
    root.append(&ui.status);
    let weak = Rc::downgrade(ui);
    window.connect_map(move |_| {
        if let Some(ui) = weak.upgrade() {
            search_live::schedule(&ui);
        }
    });
    let weak = Rc::downgrade(ui);
    window.connect_hide(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.invalidate();
        }
    });
    window.set_child(Some(&root));
    #[cfg(debug_assertions)]
    test_width(&window);
    window
}

pub(crate) struct Collection<'a> {
    pub window: &'a gtk::Window,
    pub selected: u32,
    pub root: &'a gtk::Box,
    pub pane: &'a Rc<approval::ApprovalPane>,
    pub status: &'a gtk::Label,
    pub actions: &'a [&'a gtk::Button],
    pub extras: &'a [gtk::Widget],
    pub header: Option<&'a gtk::Widget>,
    pub changed: Rc<dyn Fn()>,
}

pub(crate) fn collection(ui: &Rc<Ui>, layout: Collection<'_>) {
    let Collection {
        window,
        selected,
        root,
        pane,
        status,
        actions,
        extras,
        header,
        changed,
    } = layout;
    decorate(ui, window);
    window.set_default_size(520, if selected > 1 { 600 } else { 510 });
    for child in children(root) {
        root.remove(&child);
    }
    root.set_spacing(8);
    root.add_css_class("search-content");
    root.set_margin_top(0);
    root.set_margin_bottom(0);
    root.set_margin_start(0);
    root.set_margin_end(0);
    if let Some(header) = header {
        root.append(header);
    } else {
        root.append(&scopes(ui, window, selected));
    }
    for extra in extras {
        root.append(extra);
    }
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    let find = gtk::Entry::new();
    let replace = gtk::Entry::new();
    for (source, target) in [(&ui.find, &find), (&ui.replace, &replace)] {
        source
            .bind_property("text", target, "text")
            .bidirectional()
            .sync_create()
            .build();
        let changed = changed.clone();
        target.connect_changed(move |_| changed());
    }
    let model = ui.mode.model().unwrap();
    let mode = gtk::DropDown::new(Some(model), None::<gtk::Expression>);
    ui.mode
        .bind_property("selected", &mode, "selected")
        .bidirectional()
        .sync_create()
        .build();
    let update = changed.clone();
    mode.connect_selected_notify(move |_| update());
    let case = gtk::CheckButton::with_label(&ui.case.label().unwrap_or_default());
    let word = gtk::CheckButton::with_label(&ui.whole_word.label().unwrap_or_default());
    for (source, target) in [(&ui.case, &case), (&ui.whole_word, &word)] {
        source
            .bind_property("active", target, "active")
            .bidirectional()
            .sync_create()
            .build();
        let changed = changed.clone();
        target.connect_toggled(move |_| changed());
    }
    let grid = gtk::Grid::new();
    form(
        ui,
        &grid,
        (&find, &replace),
        (&mode, &case, &word),
        pane,
        (window, selected),
    );
    let pills = search_pattern::empty();
    let capsule = gtk::ScrolledWindow::builder()
        .child(&pills)
        .min_content_height(22)
        .max_content_height(22)
        .max_content_width(140)
        .propagate_natural_width(true)
        .hscrollbar_policy(gtk::PolicyType::External)
        .vscrollbar_policy(gtk::PolicyType::Never)
        .build();
    pills
        .bind_property("visible", &capsule, "visible")
        .sync_create()
        .build();
    if let Some(model) = ui.search_pattern.borrow().as_ref() {
        model.row(&pills, &replace);
    }
    grid.child_at(1, 2)
        .unwrap()
        .downcast::<gtk::Box>()
        .unwrap()
        .append(&capsule);
    root.append(&grid);
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    pane.root.add_css_class("search-approvals");
    root.append(&pane.root);
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    for button in actions {
        if let Some(wrapper) = button.parent().and_downcast::<gtk::FlowBoxChild>() {
            wrapper.set_child(None::<&gtk::Widget>);
        }
    }
    let review = pane.search_layout(ui, window, actions.last().unwrap(), selected >= 2);
    root.append(&footer(
        ui,
        window,
        pane,
        (selected >= 2).then_some(actions[0]),
        &review,
    ));
    let extras = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    extras.set_halign(gtk::Align::End);
    for button in actions.iter().skip(1).take(actions.len() - 2) {
        if let Some(wrapper) = button.parent().and_downcast::<gtk::FlowBoxChild>() {
            wrapper.set_child(None::<&gtk::Widget>);
        }
        // Schließen/Escape bricht eine reine Puffersuche bereits ab.
        if selected == 1 && Some(button) == actions.get(1) {
            button.set_visible(false);
            continue;
        }
        extras.append(*button);
        button
            .bind_property("sensitive", *button, "visible")
            .sync_create()
            .build();
    }
    let refresh = extras.downgrade();
    let update_extras = Rc::new(move || {
        if let Some(extras) = refresh.upgrade() {
            extras.set_visible(children(&extras).iter().any(|w| w.is_visible()));
        }
    });
    for child in children(&extras) {
        let refresh = update_extras.clone();
        child.connect_visible_notify(move |_| refresh());
    }
    update_extras();
    root.append(&extras);
    status.add_css_class("search-status");
    status.connect_label_notify(|label| label.set_visible(!label.text().is_empty()));
    status.set_visible(false);
    if let Some(parent) = status
        .ancestor(gtk::ScrolledWindow::static_type())
        .and_downcast::<gtk::ScrolledWindow>()
    {
        parent.set_child(None::<&gtk::Widget>);
    }
    let status_scroll = gtk::ScrolledWindow::builder()
        .child(status)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .max_content_height(64)
        .propagate_natural_height(true)
        .build();
    status
        .bind_property("visible", &status_scroll, "visible")
        .sync_create()
        .build();
    root.append(&status_scroll);
    // Ctrl+F erhält dieselben Felder im aktiven Bereich; Escape geht durch
    // den bestehenden Close-Handler und kann keinen Dateivorgang übergehen.
    let keys = gtk::EventControllerKey::new();
    let weak = window.downgrade();
    let find_focus = find.downgrade();
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        if key == gtk::gdk::Key::f && modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK) {
            if let Some(find) = find_focus.upgrade() {
                find.grab_focus();
                find.select_region(0, -1);
            }
            return glib::Propagation::Stop;
        }
        if key == gtk::gdk::Key::Escape
            || (key == gtk::gdk::Key::w && modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK))
        {
            if let Some(window) = weak.upgrade() {
                window.close();
            }
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    find.set_activates_default(true);
    replace.set_activates_default(true);
    window.add_controller(keys);
    search_live::register(ui, window, &find, selected);
    let weak_pane = Rc::downgrade(pane);
    window.connect_hide(move |_| {
        if let Some(pane) = weak_pane.upgrade() {
            pane.clear();
        }
    });
    let weak = find.downgrade();
    window.connect_map(move |_| {
        if let Some(find) = weak.upgrade() {
            find.grab_focus();
        }
    });
    if let Some(shell) = ui.chrome.borrow().as_ref() {
        shell.search_window.set_visible(false);
    }
    #[cfg(debug_assertions)]
    test_width(window);
}

fn footer(
    ui: &Rc<Ui>,
    window: &gtk::Window,
    pane: &approval::ApprovalPane,
    search: Option<&gtk::Button>,
    review: &gtk::Button,
) -> gtk::FlowBox {
    let (previous, next) = pane.navigation_buttons();
    let navigation = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    if let Some(search) = search {
        search.set_label(ui.lang.text("Suchen", "Find"));
        navigation.append(search);
    }
    navigation.append(&previous);
    navigation.append(&next);
    let apply = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let example = gtk::Button::with_label(ui.lang.text("Aus Beispiel…", "From example…"));
    let weak = Rc::downgrade(ui);
    example.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            example_view::open(&ui);
        }
    });
    apply.append(&example);
    apply.append(&pane.replacement_button());
    apply.append(review);
    apply.set_halign(gtk::Align::End);
    let row = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(false)
        .min_children_per_line(1)
        .max_children_per_line(2)
        .column_spacing(8)
        .row_spacing(6)
        .build();
    row.add_css_class("search-footer");
    for group in [navigation, apply] {
        row.insert(&group, -1);
        group.parent().unwrap().set_focusable(false);
    }
    window.set_default_widget(Some(search.unwrap_or(&next)));
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let previous = previous.downgrade();
    let next = next.downgrade();
    let review = review.downgrade();
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        use gtk::gdk::{Key, ModifierType as M};
        if !modifiers.contains(M::CONTROL_MASK) || modifiers.intersects(M::ALT_MASK | M::SUPER_MASK)
        {
            return glib::Propagation::Proceed;
        }
        let target = if matches!(key, Key::g | Key::G) {
            if modifiers.contains(M::SHIFT_MASK) {
                &previous
            } else {
                &next
            }
        } else if matches!(key, Key::Return | Key::KP_Enter) && !modifiers.contains(M::SHIFT_MASK) {
            &review
        } else {
            return glib::Propagation::Proceed;
        };
        if let Some(button) = target.upgrade().filter(|b| b.is_sensitive()) {
            button.emit_clicked();
        }
        glib::Propagation::Stop
    });
    window.add_controller(keys);
    row
}
