use super::*;
fn labelled_icon(button: &gtk::Button, name: &str, title: &str) -> gtk::Label {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 3);
    let image = gtk::Image::from_icon_name(name);
    row.append(&image);
    let text = gtk::Label::new(Some(title));
    row.append(&text);
    button.set_child(Some(&row));
    button.set_tooltip_text(Some(title));
    button.update_property(&[gtk::accessible::Property::Label(title)]);
    text
}
fn font_controls(
    player: &Rc<Player>,
    spin: &gtk::SpinButton,
    title: &str,
    kind: &str,
    root: &gtk::Box,
) {
    let label = gtk::Label::new(None);
    root.append(&label);
    let weak = label.downgrade();
    let caption = title.to_owned();
    let refresh = move |spin: &gtk::SpinButton| {
        if let Some(label) = weak.upgrade() {
            label.set_text(&format!("{caption}: {} pt", spin.value() as i32));
        }
    };
    refresh(spin);
    spin.connect_value_changed(refresh);
    for (caption, delta) in [("−", -1.), ("+", 1.)] {
        let button = gtk::Button::with_label(caption);
        button.add_css_class("explanation-font-step");
        button.set_widget_name(&format!(
            "explanation-{kind}-{}",
            if delta > 0. { "larger" } else { "smaller" }
        ));
        button.update_property(&[gtk::accessible::Property::Label(&format!(
            "{title} {caption}"
        ))]);
        let spin = spin.clone();
        let weak = Rc::downgrade(player);
        button.connect_clicked(move |_| {
            if let Some(player) = weak.upgrade() {
                player.resize_font(&spin, delta);
            }
        });
        root.append(&button);
    }
}
pub(super) fn mount(player: &Rc<Player>, end: &gtk::Button) -> gtk::ScrolledWindow {
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let name = gtk::MenuButton::builder()
        .child(&player.path)
        .has_frame(false)
        .build();
    name.set_widget_name("explanation-source-info");
    name.set_tooltip_text(Some(
        player
            .lang
            .text("Quelle und Frage anzeigen", "Show source and question"),
    ));
    let information = support::column();
    information.add_css_class("snapshot-information");
    let question = support::label(&visible(&player.package.manifest.question));
    question.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    question.set_max_width_chars(48);
    information.append(
        &gtk::ScrolledWindow::builder()
            .child(&question)
            .max_content_height(160)
            .propagate_natural_height(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build(),
    );
    information.append(&player.source_select);
    let popup = gtk::Popover::new();
    popup.set_child(Some(&information));
    name.set_popover(Some(&popup));
    let weak_player = Rc::downgrade(player);
    let weak_popup = popup.downgrade();
    player.source_select.connect_selected_notify(move |choice| {
        let Some(player) = weak_player.upgrade().filter(|player| !player.setting.get()) else {
            return;
        };
        if let Some(popup) = weak_popup.upgrade() {
            popup.popdown();
        }
        let selected = choice.selected() as usize;
        let weak = Rc::downgrade(&player);
        glib::idle_add_local_once(move || {
            if let Some(player) = weak.upgrade().filter(|player| {
                player.selected_source.get() == selected
                    && player.window.is_active()
                    && player.source.is_mapped()
            }) {
                player.source.grab_focus();
            }
        });
    });
    root.append(&crate::chrome::snapshot::header(
        &name,
        &player.header_status,
    ));
    let code = gtk::ScrolledWindow::builder()
        .child(&player.source)
        .min_content_height(120)
        .build();
    let panel = gtk::Box::new(gtk::Orientation::Vertical, 8);
    panel.add_css_class("explanation-panel");
    panel.append(&player.step_title);
    player.step_title.add_css_class("explanation-title");
    panel.append(
        &gtk::ScrolledWindow::builder()
            .child(&player.explanation)
            .min_content_height(70)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .build(),
    );
    let split = gtk::Paned::builder()
        .orientation(gtk::Orientation::Vertical)
        .start_child(&code)
        .end_child(&panel)
        .shrink_start_child(false)
        .shrink_end_child(false)
        .resize_start_child(false)
        .vexpand(true)
        .build();
    root.append(&split);
    let allocation = Cell::new((0, 0));
    let stable_frames = Cell::new(0);
    split.add_tick_callback(move |split, _| {
        let size = (split.width(), split.height());
        if size.0 <= 0 || size.1 <= 0 {
            return glib::ControlFlow::Continue;
        }
        if allocation.replace(size) == size {
            stable_frames.set(stable_frames.get() + 1);
        } else {
            stable_frames.set(0);
        }
        if stable_frames.get() < 2 {
            return glib::ControlFlow::Continue;
        }
        split.set_position((f64::from(size.1) * 0.44).round() as i32);
        glib::ControlFlow::Break
    });
    let footer = gtk::Box::new(gtk::Orientation::Vertical, 3);
    footer.add_css_class("explanation-footer");
    let first = gtk::Box::new(gtk::Orientation::Horizontal, 7);
    player.step_select.add_css_class("explanation-steps");
    first.append(&player.step_select);
    first.append(&player.status);
    player.status.set_width_chars(
        (player.package.manifest.steps.len().to_string().len().max(2) * 2 + 3) as i32,
    );
    let fonts = gtk::Box::new(gtk::Orientation::Horizontal, 3);
    font_controls(
        player,
        &player.code_size,
        player.lang.text("Code", "Code"),
        "code",
        &fonts,
    );
    font_controls(
        player,
        &player.text_size,
        player.lang.text("Erklärung", "Explanation"),
        "text",
        &fonts,
    );
    fonts.set_visible(false);
    first.append(&fonts);
    let font_menu = gtk::MenuButton::builder()
        .label(player.lang.text("Schrift", "Font"))
        .build();
    font_menu.set_widget_name("explanation-font-menu");
    let compact_fonts = gtk::Box::new(gtk::Orientation::Vertical, 8);
    for (title, spin, delta) in [
        (
            player
                .lang
                .text("Codeschrift verkleinern", "Decrease code font"),
            &player.code_size,
            -1.,
        ),
        (
            player
                .lang
                .text("Codeschrift vergrößern", "Increase code font"),
            &player.code_size,
            1.,
        ),
        (
            player
                .lang
                .text("Erklärschrift verkleinern", "Decrease explanation font"),
            &player.text_size,
            -1.,
        ),
        (
            player
                .lang
                .text("Erklärschrift vergrößern", "Increase explanation font"),
            &player.text_size,
            1.,
        ),
    ] {
        let button = gtk::Button::with_label(title);
        let kind = if spin == &player.code_size {
            "code"
        } else {
            "text"
        };
        button.set_widget_name(&format!(
            "explanation-{kind}-{}",
            if delta > 0. { "larger" } else { "smaller" }
        ));
        let spin = spin.clone();
        let menu = font_menu.downgrade();
        let weak = Rc::downgrade(player);
        button.connect_clicked(move |_| {
            if let Some(menu) = menu.upgrade() {
                menu.popdown();
            }
            if let Some(player) = weak.upgrade() {
                player.resize_font(&spin, delta);
            }
        });
        compact_fonts.append(&button);
    }
    let popup = gtk::Popover::new();
    popup.set_child(Some(&compact_fonts));
    font_menu.set_popover(Some(&popup));
    first.append(&font_menu);
    footer.append(&first);
    let second = gtk::Box::new(gtk::Orientation::Horizontal, 5);
    let captions = [
        labelled_icon(
            &player.previous,
            "fastra-chevron-left-symbolic",
            player.lang.text("Zurück", "Back"),
        ),
        labelled_icon(
            &player.next,
            "fastra-chevron-right-symbolic",
            player.lang.text("Weiter", "Next"),
        ),
        labelled_icon(
            &player.return_button,
            "fastra-scope-symbolic",
            player.lang.text("Zur Stelle", "Return"),
        ),
    ];
    for button in [
        &player.previous,
        &player.next,
        &player.pause_button,
        &player.return_button,
    ] {
        second.append(button);
    }
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    second.append(&spacer);
    second.append(&player.wrap);
    second.append(end);
    footer.append(&second);
    let extra = gtk::Box::new(gtk::Orientation::Horizontal, 5);
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    extra.append(&spacer);
    extra.set_visible(false);
    footer.append(&extra);
    // Der kompakte Fuß darf die Fenster-Mindestbreite nicht durch gerade
    // noch sichtbare Vollbeschriftungen festhalten. Der native Viewport gibt
    // die verfügbare Breite vor; der nächste Frame wählt passende Controls.
    let footer_view = gtk::ScrolledWindow::builder()
        .child(&footer)
        .hscrollbar_policy(gtk::PolicyType::External)
        .vscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .build();
    footer_view.add_css_class("explanation-footer-viewport");
    root.append(&footer_view);
    for caption in &captions {
        caption.set_visible(false);
    }
    let observed_first = first.downgrade();
    let observed_fonts = fonts.downgrade();
    let observed_menu = font_menu.downgrade();
    let viewport = footer_view.downgrade();
    let wrap = player.wrap.downgrade();
    let second_row = second.downgrade();
    let extra_row = extra.downgrade();
    let close = end.downgrade();
    player.wrap.set_tooltip_text(Some("Soft Wrap"));
    player
        .wrap
        .update_property(&[gtk::accessible::Property::Label("Soft Wrap")]);
    footer.add_tick_callback(move |_, _| {
        let (Some(first), Some(fonts), Some(menu)) = (
            observed_first.upgrade(),
            observed_fonts.upgrade(),
            observed_menu.upgrade(),
        ) else {
            return glib::ControlFlow::Break;
        };
        let scale = crate::editor_options::zoom::ui_scale();
        let Some(viewport) = viewport.upgrade() else {
            return glib::ControlFlow::Break;
        };
        let width = f64::from(viewport.width());
        if let (Some(wrap), Some(close), Some(second), Some(extra)) = (
            wrap.upgrade(),
            close.upgrade(),
            second_row.upgrade(),
            extra_row.upgrade(),
        ) {
            let narrow = width < 350. * scale;
            let destination = if narrow { &extra } else { &second };
            for widget in [wrap.upcast_ref::<gtk::Widget>(), close.upcast_ref()] {
                if widget.parent().as_ref() != Some(destination.upcast_ref()) {
                    let focused = widget.has_focus();
                    if let Some(parent) = widget.parent().and_downcast::<gtk::Box>() {
                        parent.remove(widget);
                    }
                    destination.append(widget);
                    if focused {
                        widget.grab_focus();
                    }
                }
            }
            extra.set_visible(narrow);
        }
        let compact = width < 580. * scale;
        fonts.set_visible(!compact);
        menu.set_visible(compact);
        for caption in &captions {
            caption.set_visible(width >= 470. * scale);
        }
        first.set_hexpand(true);
        glib::ControlFlow::Continue
    });
    player.window.set_child(Some(&root));
    code
}

#[cfg(debug_assertions)]
pub(super) fn check_geometry(window: &gtk::Window) {
    if let Ok(expected) = std::env::var("FASTRA_INITIAL_ZOOM") {
        let expected = expected.parse::<i32>().unwrap();
        let scale = crate::editor_options::zoom::ui_scale();
        assert!(
            (scale - (1. + f64::from(expected) * 0.13)).abs() < 0.0001,
            "the preset must really be loaded"
        );
        let height = window.create_pango_layout(Some("M")).pixel_size().1;
        assert!(
            height > 20,
            "maximum interface font must actually render larger: {height}"
        );
        eprintln!("PLAYER actual UI scale={scale}; native interface glyph height={height}");
    }
    fn walk(widget: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
        all.push(widget.clone());
        for child in crate::chrome::children(widget) {
            walk(&child, all);
        }
    }
    let mut all = Vec::new();
    walk(window.upcast_ref(), &mut all);
    let footer = all
        .iter()
        .find(|widget| widget.has_css_class("explanation-footer-viewport"))
        .unwrap();
    for widget in &all {
        if !widget.is_mapped() || !widget.is::<gtk::Button>() {
            continue;
        }
        if widget.ancestor(gtk::ScrolledWindow::static_type()).as_ref() != Some(footer) {
            continue;
        }
        let rect = widget.compute_bounds(footer).unwrap();
        assert!(
            rect.x() >= -1. && rect.x() + rect.width() <= footer.width() as f32 + 1.,
            "footer control clipped: {} {rect:?} within {}",
            widget.widget_name(),
            footer.width()
        );
    }
}
