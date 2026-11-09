use super::*;

pub(super) fn input(title: String, mut args: Vec<String>) {
    std::thread::spawn(move || {
        let snapshot = args.first().and_then(|arg| {
            if arg == "snapshot" {
                std::env::var_os("FASTRA_RECTANGLE_SCREENSHOT").map(std::path::PathBuf::from)
            } else {
                arg.strip_prefix("snapshot:").and_then(|name| {
                    std::env::var_os("FASTRA_TOOL_SCREENSHOTS")
                        .map(|dir| std::path::PathBuf::from(dir).join(format!("{name}.png")))
                })
            }
        });
        if args
            .first()
            .is_some_and(|arg| arg == "snapshot" || arg.starts_with("snapshot:"))
        {
            args.remove(0);
        }
        let id = std::process::Command::new("xdotool")
            .args(["search", "--name", &title])
            .output()
            .unwrap();
        let id = String::from_utf8(id.stdout).unwrap();
        let id = id.lines().next().unwrap();
        assert!(std::process::Command::new("xdotool")
            .args(["windowmove", "--sync", id, "0", "0"])
            .status()
            .unwrap()
            .success());
        if let Some(path) = snapshot {
            std::thread::sleep(Duration::from_millis(100));
            let capture = if path.file_stem().is_some_and(|name| {
                name == "rectangle-text-menu" || name == "rectangle-document-menu"
            }) {
                "root"
            } else {
                id
            };
            assert!(std::process::Command::new("import")
                .args(["-window", capture])
                .arg(path)
                .status()
                .unwrap()
                .success());
        }
        if args.is_empty() {
            return;
        }
        assert!(std::process::Command::new("xdotool")
            .args(["windowfocus", "--sync", id])
            .status()
            .unwrap()
            .success());
        assert!(std::process::Command::new("xdotool")
            .args(args)
            .status()
            .unwrap()
            .success());
    });
}
pub(super) fn menu_button(widget: &gtk::Widget, title: &str) -> Option<gtk::MenuButton> {
    if let Some(button) = widget.downcast_ref::<gtk::MenuButton>().filter(|button| {
        button.is_mapped()
            && (button.label().as_deref() == Some(title)
                || button.tooltip_text().as_deref() == Some(title))
    }) {
        return Some(button.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(button) = menu_button(&widget, title) {
            return Some(button);
        }
        child = widget.next_sibling();
    }
    None
}
pub(super) fn document_menu(ui: &Ui, doc: &Document) -> gtk::MenuButton {
    menu_button(
        doc.container.upcast_ref(),
        ui.lang
            .text("Darstellung und Bearbeitung", "View and editing"),
    )
    .unwrap()
}
fn find_button(widget: &gtk::Widget, text: &str) -> Option<gtk::Button> {
    if let Some(button) = widget.downcast_ref::<gtk::Button>() {
        if button.label().as_deref() == Some(text) {
            return Some(button.clone());
        }
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(button) = find_button(&widget, text) {
            return Some(button);
        }
        child = widget.next_sibling();
    }
    None
}
fn find_toggle(widget: &gtk::Widget, label: &str) -> Option<gtk::CheckButton> {
    if let Some(button) = widget.downcast_ref::<gtk::CheckButton>() {
        if button.label().as_deref() == Some(label) {
            return Some(button.clone());
        }
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(button) = find_toggle(&widget, label) {
            return Some(button);
        }
        child = widget.next_sibling();
    }
    None
}
pub(super) fn source_view(widget: &gtk::Widget) -> Option<sourceview5::View> {
    if let Some(view) = widget.downcast_ref::<sourceview5::View>() {
        return Some(view.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(view) = source_view(&widget) {
            return Some(view);
        }
        child = widget.next_sibling();
    }
    None
}
fn source_point(ui: &Ui, view: &sourceview5::View, line: i32, character: i32) -> (i32, i32) {
    let at = view.buffer().iter_at_line_offset(line, character).unwrap();
    let rect = view.iter_location(&at);
    let (x, y) = view.buffer_to_window_coords(
        gtk::TextWindowType::Widget,
        rect.x() + 1,
        rect.y() + rect.height() / 2,
    );
    let point = view
        .compute_point(&ui.window, &gtk::graphene::Point::new(x as f32, y as f32))
        .unwrap();
    (point.x() as i32, point.y() as i32)
}
fn drag_points(title: &str, a: (i32, i32), b: (i32, i32)) {
    input(
        title.into(),
        vec![
            "mousemove".into(),
            a.0.to_string(),
            a.1.to_string(),
            "mousedown".into(),
            "1".into(),
            "sleep".into(),
            "0.1".into(),
            "mousemove".into(),
            b.0.to_string(),
            b.1.to_string(),
            "sleep".into(),
            "0.1".into(),
            "mouseup".into(),
            "1".into(),
        ],
    );
}
fn drag(ui: &Ui, rect: &rectangle::Rectangle, title: &str, end: i32) {
    let a = rect.test_point(&ui.window, 0, 1);
    let b = rect.test_point(&ui.window, 2, end);
    drag_points(title, a, b);
}
pub fn run(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_RECTANGLE_COMMANDS_SELFTEST").is_some() {
        rectangle::commands_selftest(ui);
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let title = format!("Fastra Rectangle Test {}", std::process::id());
    ui.window.set_title(Some(&title));
    let width = std::env::var("FASTRA_RECTANGLE_WIDTH")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(900);
    ui.window.set_default_size(width, 900);
    ui.add_document("rectangle.txt", "one\nx\nabc\n");
    let stage = Cell::new(0);
    let started = std::time::Instant::now();
    let changed = Cell::new(std::time::Instant::now());
    glib::timeout_add_local(Duration::from_millis(150), move || {
        assert!(
            started.elapsed() < Duration::from_secs(30),
            "rectangle timeout stage {}",
            stage.get()
        );
        if changed.get().elapsed() < Duration::from_millis(400) {
            return glib::ControlFlow::Continue;
        }
        let doc = ui.active().unwrap();
        let rect = doc.rectangles.borrow()[0].clone();
        let text = buffer_text(&doc.buffer);
        match stage.get() {
            0 => {
                crate::git_view::test_click(&document_menu(&ui, &doc), &[]);
                stage.set(100);
                changed.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            100 => {
                let toggle = find_toggle(
                    doc.container.upcast_ref(),
                    ui.lang.text("Rechteckmodus", "Rectangle mode"),
                )
                .unwrap();
                crate::git_view::test_click(&toggle, &[]);
                stage.set(1);
                changed.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            1 => {
                assert!(find_toggle(
                    doc.container.upcast_ref(),
                    ui.lang.text("Rechteckmodus", "Rectangle mode")
                )
                .unwrap()
                .is_active());
                crate::git_view::test_input_completed(
                    &document_menu(&ui, &doc),
                    &["Escape"],
                    false,
                );
                stage.set(101);
                changed.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            101 => {
                let (a, b) = doc.buffer.bounds();
                doc.buffer.select_range(&a, &b);
                drag(&ui, &rect, &title, 2);
                stage.set(2);
                changed.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            2 => {
                assert!(rect.is_selected());
                input(title.clone(), vec!["key".into(), "a".into()]);
            }
            3 => {
                assert_eq!(text, "oae\nxa\naac\n");
                assert!(rect.is_selected());
                input(title.clone(), vec!["key".into(), "b".into()]);
            }
            4 => {
                assert_eq!(text, "oabe\nxab\naabc\n");
                input(
                    title.clone(),
                    vec!["snapshot".into(), "key".into(), "ctrl+z".into()],
                );
            }
            5 => {
                assert_eq!(text, "oae\nxa\naac\n");
                assert!(!rect.is_selected());
                input(title.clone(), vec!["key".into(), "ctrl+z".into()]);
            }
            6 => {
                assert_eq!(text, "one\nx\nabc\n");
                drag(&ui, &rect, &title, 1);
            }
            7 => {
                ui.window.clipboard().set_text("P\nQ\nR");
                crate::git_view::test_click(&document_menu(&ui, &doc), &[]);
                stage.set(70);
                changed.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            70 => {
                let button = find_button(
                    doc.container.upcast_ref(),
                    ui.lang.text("Spaltenpaste", "Column paste"),
                )
                .unwrap();
                crate::git_view::test_click(&button, &[]);
                stage.set(8);
                changed.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            8 => {
                assert_eq!(text, "oPne\nxQ\naRbc\n");
                assert!(rect.is_selected());
                input(title.clone(), vec!["key".into(), "z".into()]);
            }
            9 => {
                assert_eq!(text, "oPzne\nxQz\naRzbc\n");
                input(title.clone(), vec!["key".into(), "BackSpace".into()]);
            }
            10 => {
                assert_eq!(text, "oPne\nxQ\naRbc\n");
                input(title.clone(), vec!["key".into(), "ctrl+z".into()]);
            }
            11 => {
                assert_eq!(text, "oPzne\nxQz\naRzbc\n");
                input(
                    title.clone(),
                    vec!["key".into(), "ctrl+z".into(), "ctrl+z".into()],
                );
            }
            12 => {
                assert_eq!(text, "one\nx\nabc\n");
                doc.buffer.set_text("\n\n");
                rect.select((0, 0), (2, 0));
                input(title.clone(), vec!["key".into(), "BackSpace".into()]);
            }
            13 => {
                assert_eq!(text, "");
                input(title.clone(), vec!["key".into(), "c".into()]);
            }
            14 => {
                assert_eq!(text, "c");
                input(title.clone(), vec!["key".into(), "Escape".into()]);
            }
            15 => {
                assert!(!rect.is_selected());
                let view = source_view(doc.container.upcast_ref()).unwrap();
                view.set_tab_width(8);
                view.set_insert_spaces_instead_of_tabs(true);
                doc.buffer.set_text("\tABC\n        ABC\n\tABC\n");
            }
            16 | 20 => {
                let view = source_view(doc.container.upcast_ref()).unwrap();
                drag_points(
                    &title,
                    source_point(&ui, &view, 0, 1),
                    source_point(&ui, &view, 2, 2),
                );
            }
            17 | 21 => {
                assert!(rect.is_selected());
                input(title.clone(), vec!["key".into(), "x".into()]);
            }
            18 | 22 => {
                let spaces = if stage.get() == 18 { "        " } else { "  " };
                assert_eq!(
                    text,
                    format!("\txBC\n{spaces}xBC\n\txBC\n"),
                    "rectangle uses displayed tab width"
                );
                let name = if stage.get() == 18 {
                    "rectangle-tab-8"
                } else {
                    "rectangle-tab-2"
                };
                input(
                    title.clone(),
                    vec![format!("snapshot:{name}"), "key".into(), "ctrl+z".into()],
                );
            }
            19 => {
                assert_eq!(text, "\tABC\n        ABC\n\tABC\n");
                source_view(doc.container.upcast_ref())
                    .unwrap()
                    .set_tab_width(2);
                doc.buffer.set_text("\tABC\n  ABC\n\tABC\n");
            }
            23 => {
                assert_eq!(text, "\tABC\n  ABC\n\tABC\n");
                let view = source_view(doc.container.upcast_ref()).unwrap();
                view.set_tab_width(8);
                view.set_insert_spaces_instead_of_tabs(true);
                doc.buffer.set_text("\tAB\nx\n\tAB\n");
            }
            24 => {
                let view = source_view(doc.container.upcast_ref()).unwrap();
                drag_points(
                    &title,
                    source_point(&ui, &view, 0, 1),
                    source_point(&ui, &view, 2, 1),
                );
            }
            25 => {
                assert!(rect.is_selected());
                ui.window.clipboard().set_text("P\nQ\nR");
                crate::git_view::test_click(&document_menu(&ui, &doc), &[]);
                stage.set(250);
                changed.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            250 => {
                let button = find_button(
                    doc.container.upcast_ref(),
                    ui.lang.text("Spaltenpaste", "Column paste"),
                )
                .unwrap();
                crate::git_view::test_click(&button, &[]);
                stage.set(26);
                changed.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            26 => {
                assert_eq!(
                    text, "\tPAB\nx       Q\n\tRAB\n",
                    "column paste pads to the actual tab stop"
                );
                input(
                    title.clone(),
                    vec![
                        "snapshot:rectangle-tab-8-paste".into(),
                        "key".into(),
                        "ctrl+z".into(),
                    ],
                );
            }
            27 => {
                assert_eq!(text, "\tAB\nx\n\tAB\n");
                rect.select((0, 8), (2, 9));
                assert!(rect.is_selected());
                source_view(doc.container.upcast_ref())
                    .unwrap()
                    .set_tab_width(2);
                assert!(
                    !rect.is_selected(),
                    "changed tab geometry invalidates the old rectangle"
                );
                assert_eq!(buffer_text(&doc.buffer), text);
                println!("FASTRA_RECTANGLE_SELFTEST_OK mouse-toggle/plain-drag/two-keys/per-key-undo/column-paste/persistent-paste/backspace/undo/merged-cursors/escape/real-tab-width-2-8-drag-typing-undo/tab-width-column-paste-padding/width-change-invalidates");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        changed.set(std::time::Instant::now());
        glib::ControlFlow::Continue
    });
}
