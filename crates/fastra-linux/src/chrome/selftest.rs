use super::*;
use std::time::{Duration, Instant};

fn button(widget: &gtk::Widget, title: &str) -> Option<gtk::Button> {
    if let Some(button) = widget.downcast_ref::<gtk::Button>().filter(|button| {
        button.is_mapped()
            && (button.label().as_deref() == Some(title)
                || button.tooltip_text().as_deref() == Some(title))
    }) {
        return Some(button.clone());
    }
    children(widget)
        .into_iter()
        .find_map(|child| button(&child, title))
}
fn named(widget: &gtk::Widget, name: &str) -> Option<gtk::Widget> {
    if widget.is_mapped() && widget.widget_name() == name {
        return Some(widget.clone());
    }
    children(widget).iter().find_map(|child| named(child, name))
}
fn click(widget: &impl IsA<gtk::Widget>) {
    git_view::test_click(widget, &[]);
}
fn capture(ui: &Ui, name: &str) {
    git_view::capture(ui.window.upcast_ref(), name);
}

fn check(widget: &gtk::Widget, title: &str) -> Option<gtk::CheckButton> {
    if let Some(check) = widget
        .downcast_ref::<gtk::CheckButton>()
        .filter(|check| check.is_mapped() && check.label().as_deref() == Some(title))
    {
        return Some(check.clone());
    }
    children(widget)
        .into_iter()
        .find_map(|child| check(&child, title))
}

fn has_label(widget: &gtk::Widget, text: &str) -> bool {
    widget
        .downcast_ref::<gtk::Label>()
        .is_some_and(|label| label.is_mapped() && label.text() == text)
        || children(widget)
            .into_iter()
            .any(|child| has_label(&child, text))
}

fn search_window(ui: &Ui) -> Option<gtk::Window> {
    ui.window
        .application()?
        .windows()
        .into_iter()
        .find(|window| window.is_mapped() && window.has_css_class("fastra-search"))
}

fn assert_detail(window: &gtk::Window) {
    fn visit(widget: &gtk::Widget, count: &mut usize) {
        if let Some(view) = widget
            .downcast_ref::<gtk::TextView>()
            .filter(|view| view.is_mapped())
        {
            assert!(
                view.width() >= 120 && view.height() >= 18,
                "readable preview viewport: {}x{}",
                view.width(),
                view.height()
            );
            let scroll = view.ancestor(gtk::ScrolledWindow::static_type()).unwrap();
            assert!(
                scroll.height() >= 28,
                "compact detail frame contains its text line"
            );
            *count += 1;
        }
        for child in children(widget) {
            visit(&child, count);
        }
    }
    let mut count = 0;
    visit(window.upcast_ref(), &mut count);
    assert_eq!(count, 1);
}

pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let fixture = root.join("project");
    std::fs::create_dir_all(fixture.join("styles")).unwrap();
    let file = fixture.join("check.txt");
    std::fs::write(&file, "original\n").unwrap();
    ui.window.set_default_size(
        std::env::var("FASTRA_TOOL_WIDTH")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1100),
        780,
    );
    let phase = Cell::new(if std::env::var_os("FASTRA_HOME_KEYS_SELFTEST").is_some() {
        270
    } else {
        0
    });
    let tabs_before_shortcut = Cell::new(0usize);
    let folder_chooser = Rc::new(Cell::new(None::<bool>));
    let case_cycle = Cell::new(0);
    let review_stage = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let saved = RefCell::new(None::<Rc<Document>>);
    let working = RefCell::new(None::<Rc<Document>>);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(55),
            "chrome phase {} review{} case{} approvals={:?}: {}",
            phase.get(),
            review_stage.get(),
            case_cycle.get(),
            ui.approval.approvals(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(350) {
            return glib::ControlFlow::Continue;
        }
        let shell = ui.chrome.borrow().as_ref().unwrap().clone();
        match phase.get() {
            0 => {
                assert_eq!(ui.documents.borrow().len(), 1);
                assert_eq!(ui.active().unwrap().buffer.char_count(), 0);
                assert!(!shell.search_window.is_visible());
                assert!(!shell.sidebar.is_visible());
                capture(&ui, "chrome-welcome");
                project_view::open_path(&ui, fixture.clone());
                ui.load_path(file.clone());
            }
            1 => {
                if ui.active().and_then(|doc| doc.disk_path()).as_ref() != Some(&file)
                    || project_view::current_binding(&ui).is_none()
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    ui.documents.borrow().len(),
                    1,
                    "opening replaces only pristine scratch"
                );
                assert!(shell.sidebar.is_mapped());
                let doc = ui.active().unwrap();
                let header = tab_header(&ui, &doc);
                assert!(header.is_mapped());
                let bounds = header.compute_bounds(&ui.window).unwrap();
                assert!(
                    bounds.height() <= 36. && bounds.y() <= 36.,
                    "compact titlebar: {bounds:?}"
                );
                *saved.borrow_mut() = Some(doc);
                click(
                    &button(ui.window.upcast_ref(), ui.lang.text("Neuer Tab", "New tab")).unwrap(),
                );
            }
            2 => {
                if ui.documents.borrow().len() != 2 {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                assert_eq!(doc.buffer.char_count(), 0);
                doc.buffer.begin_user_action();
                doc.buffer.insert_at_cursor("temporary");
                doc.buffer.end_user_action();
                doc.buffer.begin_user_action();
                doc.buffer
                    .delete(&mut doc.buffer.start_iter(), &mut doc.buffer.end_iter());
                doc.buffer.end_user_action();
                assert!(doc.buffer.can_undo());
                assert!(
                    !doc.chrome.borrow().as_ref().unwrap().welcome.is_visible(),
                    "edited empty scratch retains history instead of showing welcome"
                );
                doc.buffer.begin_irreversible_action();
                doc.buffer.set_text("");
                doc.buffer.end_irreversible_action();
                doc.buffer.begin_user_action();
                doc.buffer.insert_at_cursor("cat Cat");
                doc.buffer.end_user_action();
                *working.borrow_mut() = Some(doc.clone());
                git_view::test_click(&doc.container, &["ctrl+f"]);
            }
            3 => {
                if !shell.search_window.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.find.is_mapped());
                git_view::test_click(&ui.find, &["ctrl+a", "c", "a", "t"]);
            }
            4 => {
                if ui.find.text() != "cat" {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&ui.replace, &["ctrl+a", "d", "o", "g"]);
            }
            5 => {
                if ui.replace.text() != "dog" {
                    return glib::ControlFlow::Continue;
                }
                let regex = check(shell.search_window.upcast_ref(), "RegEx").unwrap();
                regex.set_active(true);
                assert_eq!(ui.mode.selected(), 2);
                regex.set_active(false);
                assert_eq!(ui.mode.selected(), 1);
                let literal = check(
                    shell.search_window.upcast_ref(),
                    ui.lang.text("∗ wörtlich", "Literal ∗"),
                )
                .unwrap();
                assert!(!literal.is_sensitive() && !literal.is_active());
                ui.find.set_text("*");
                assert!(literal.is_sensitive());
                literal.set_active(true);
                assert_eq!(ui.mode.selected(), 0);
                literal.set_active(false);
                assert_eq!(ui.mode.selected(), 1);
                ui.find.set_text("cat");
            }
            6 => {
                if ui.pending.borrow().is_none() || !ui.approval.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                if !ui.approval.has_approvals() {
                    assert!(!ui.apply.is_sensitive());
                    assert!(!button(
                        shell.search_window.upcast_ref(),
                        ui.lang.text("Freigaben prüfen · 0", "Review approvals · 0")
                    )
                    .unwrap()
                    .is_sensitive());
                    if !git_view::try_capture(&shell.search_window, "chrome-search-initial") {
                        return glib::ControlFlow::Continue;
                    }
                    click(
                        &button(
                            shell.search_window.upcast_ref(),
                            ui.lang.text("Alle", "All"),
                        )
                        .unwrap(),
                    );
                    return glib::ControlFlow::Continue;
                }
                if !ui.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                if named(shell.search_window.upcast_ref(), "fastra-inline-preview")
                    .is_none_or(|widget| !widget.is_mapped() || widget.height() == 0)
                {
                    return glib::ControlFlow::Continue;
                }
                let ignore_case = check(
                    shell.search_window.upcast_ref(),
                    ui.lang.text("Groß = klein", "Ignore case"),
                )
                .unwrap();
                let matches = ui
                    .pending
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .preview
                    .matches()
                    .len();
                if case_cycle.get() < 2 {
                    assert_eq!(matches, if case_cycle.get() == 0 { 2 } else { 1 });
                    ignore_case.set_active(case_cycle.get() == 1);
                    assert_eq!(ui.case.is_active(), case_cycle.get() == 0);
                    case_cycle.set(case_cycle.get() + 1);
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(matches, 2);
                assert_eq!(ui.approval.test_display(0), "cat Cat");
                if review_stage.get() == 0 {
                    assert_eq!(ui.approval.test_display(1), "dog dog");
                }
                match review_stage.get() {
                    0 => {
                        assert!(!ui.approval.before.is_mapped() && !ui.approval.after.is_mapped());
                        if !git_view::try_capture(&shell.search_window, "chrome-search") {
                            return glib::ControlFlow::Continue;
                        }
                        let check = named(shell.search_window.upcast_ref(), "fastra-match-0-1")
                            .expect("visible match checkbox");
                        click(&check);
                        review_stage.set(1);
                        return glib::ControlFlow::Continue;
                    }
                    1 => {
                        if ui.approval.approvals() != Some(vec![vec![0]])
                            || ui.approval.test_display(1) != "dog Cat"
                        {
                            return glib::ControlFlow::Continue;
                        }
                        let review = button(
                            shell.search_window.upcast_ref(),
                            ui.lang.text("Freigaben prüfen · 1", "Review approvals · 1"),
                        )
                        .unwrap();
                        click(&review);
                        review_stage.set(2);
                        return glib::ControlFlow::Continue;
                    }
                    2 => {
                        if !ui.apply.is_mapped() {
                            return glib::ControlFlow::Continue;
                        }
                        if !ui.approval.review_test_visible() {
                            return glib::ControlFlow::Continue;
                        }
                        let review = ui.apply.root().unwrap().downcast::<gtk::Window>().unwrap();
                        if !git_view::try_capture(&review, "chrome-approval") {
                            return glib::ControlFlow::Continue;
                        }
                        git_view::test_keys(&ui.apply, &["Escape"]);
                        review_stage.set(3);
                        return glib::ControlFlow::Continue;
                    }
                    _ => {
                        if ui.apply.is_mapped() {
                            return glib::ControlFlow::Continue;
                        }
                        git_view::test_click(&ui.find, &["Escape"]);
                    }
                }
            }
            7 => {
                if shell.search_window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!ui.apply.is_sensitive());
                assert_eq!(
                    buffer_text(&working.borrow().as_ref().unwrap().buffer),
                    "cat Cat"
                );
                git_view::test_click(&working.borrow().as_ref().unwrap().container, &["ctrl+f"]);
            }
            8 => {
                if ui.pending.borrow().is_some()
                    && ui.approval.is_ready()
                    && !ui.approval.has_approvals()
                {
                    click(&named(shell.search_window.upcast_ref(), "fastra-match-0-0").unwrap());
                    return glib::ControlFlow::Continue;
                }
                if !shell.search_window.is_mapped() || !ui.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                if !ui.apply.is_mapped() {
                    click(
                        &button(
                            shell.search_window.upcast_ref(),
                            ui.lang.text("Freigaben prüfen · 1", "Review approvals · 1"),
                        )
                        .unwrap(),
                    );
                    return glib::ControlFlow::Continue;
                }
                click(&ui.apply);
            }
            9 => {
                let doc = working.borrow().as_ref().unwrap().clone();
                if buffer_text(&doc.buffer) != "dog Cat" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&file).unwrap(), "original\n");
                shell.search_window.close();
                git_view::test_click(&doc.container, &["ctrl+z"]);
            }
            10 => {
                let doc = working.borrow().as_ref().unwrap().clone();
                if buffer_text(&doc.buffer) != "cat Cat" {
                    return glib::ControlFlow::Continue;
                }
                let saved = saved.borrow();
                let header = tab_header(&ui, saved.as_ref().unwrap());
                click(
                    &header
                        .last_child()
                        .unwrap()
                        .downcast::<gtk::Button>()
                        .unwrap(),
                );
            }
            11 => {
                if ui.documents.borrow().len() != 1 {
                    return glib::ControlFlow::Continue;
                }
                assert!(Rc::ptr_eq(
                    &ui.active().unwrap(),
                    working.borrow().as_ref().unwrap()
                ));
                click(&shell.sidebar_toggle);
            }
            12 => {
                if shell.sidebar.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                click(&shell.sidebar_toggle);
            }
            13 => {
                if !shell.sidebar.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&file).unwrap(), "original\n");
                capture(&ui, "chrome-editor");
                show_search(&ui);
            }
            14 => {
                let Some(window) = search_window(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                click(&button(window.upcast_ref(), ui.lang.text("Ordner", "Folder")).unwrap());
            }
            15 => {
                if ui.scope.selected() != 2 {
                    return glib::ControlFlow::Continue;
                }
                let Some(window) = search_window(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                window.set_default_size(520, 680);
            }
            16 => {
                let window = search_window(&ui).unwrap();
                assert_eq!(window.width(), 520, "folder minimum width");
                assert_detail(&window);
                if !git_view::try_capture(&window, "chrome-folder-min") {
                    return glib::ControlFlow::Continue;
                }
                window.set_default_size(720, 680);
            }
            17 => {
                let window = search_window(&ui).unwrap();
                assert_eq!(window.width(), 720);
                assert_detail(&window);
                if !git_view::try_capture(&window, "chrome-folder-wide") {
                    return glib::ControlFlow::Continue;
                }
                click(&button(window.upcast_ref(), ui.lang.text("Projekt", "Project")).unwrap());
            }
            18 => {
                if ui.scope.selected() != 3 {
                    return glib::ControlFlow::Continue;
                }
                let Some(window) = search_window(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                window.set_default_size(520, 680);
            }
            19 => {
                let window = search_window(&ui).unwrap();
                assert_eq!(window.width(), 520, "project minimum width");
                assert_detail(&window);
                if !git_view::try_capture(&window, "chrome-project-min") {
                    return glib::ControlFlow::Continue;
                }
                window.set_default_size(720, 680);
            }
            20 => {
                let window = search_window(&ui).unwrap();
                assert_eq!(window.width(), 720);
                assert_detail(&window);
                if !git_view::try_capture(&window, "chrome-project-wide") {
                    return glib::ControlFlow::Continue;
                }
                click(&button(window.upcast_ref(), ui.lang.text("Datei", "File")).unwrap());
            }
            21 => {
                if ui.scope.selected() != 0 || !shell.search_window.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&ui.find, &["ctrl+w"]);
            }
            22 => {
                if shell.search_window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    !ui.window
                        .application()
                        .unwrap()
                        .windows()
                        .contains(&shell.search_window),
                    "hidden search must not keep application alive"
                );
                assert_eq!(std::fs::read_to_string(&file).unwrap(), "original\n");
                let empty = fixture.join("empty.txt");
                std::fs::write(&empty, "").unwrap();
                ui.load_path(empty);
            }
            23 => {
                let doc = ui.active().unwrap();
                if doc.disk_path().as_ref() != Some(&fixture.join("empty.txt")) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), 2);
                assert!(
                    !doc.chrome.borrow().as_ref().unwrap().welcome.is_visible(),
                    "saved empty file is an editor"
                );
                ui.load_path(file.clone());
            }
            24 => {
                if ui.active().and_then(|doc| doc.disk_path()).as_ref() != Some(&file) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    ui.documents.borrow().len(),
                    3,
                    "saved empty file must not be replaced"
                );
                ui.active()
                    .unwrap()
                    .buffer
                    .set_text("e\u{301} 👩\u{200d}💻\r\nx\u{85}z");
            }
            25 => {
                if !has_label(ui.window.upcast_ref(), "7 / 4 / 3") {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                doc.buffer
                    .select_range(&doc.buffer.iter_at_offset(6), &doc.buffer.iter_at_offset(3));
            }
            26 => {
                if !has_label(ui.window.upcast_ref(), "1 / 1 / 1")
                    || !has_label(ui.window.upcast_ref(), "Sel")
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&file).unwrap(), "original\n");
                tabs_before_shortcut.set(ui.documents.borrow().len());
                git_view::test_keys(&ui.active().unwrap().container, &["ctrl+t"]);
            }
            270 => {
                tabs_before_shortcut.set(ui.documents.borrow().len());
                git_view::test_keys(&ui.window, &["ctrl+t"]);
                phase.set(27);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            27 => {
                if ui.documents.borrow().len() != tabs_before_shortcut.get() + 1 {
                    return glib::ControlFlow::Continue;
                }
                assert!(is_pristine(&ui.active().unwrap()));
                git_view::test_keys(&ui.active().unwrap().container, &["ctrl+shift+o"]);
            }
            28 => {
                let result = folder_chooser.clone();
                let title = ui.lang.text("Ordner öffnen", "Open folder");
                git_view::background(
                    move || {
                        let output = std::process::Command::new("xdotool")
                            .args(["search", "--onlyvisible", "--name", title])
                            .output()
                            .map_err(|e| e.to_string())?;
                        let found = output.status.success() && !output.stdout.is_empty();
                        if found {
                            std::process::Command::new("xdotool")
                                .args(["key", "Escape"])
                                .status()
                                .map_err(|e| e.to_string())?;
                        }
                        Ok(found)
                    },
                    move |value| result.set(Some(value.unwrap())),
                );
            }
            29 => {
                let Some(visible) = folder_chooser.get() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(
                    visible,
                    "native folder chooser must appear after Ctrl+Shift+O"
                );
                assert_eq!(ui.documents.borrow().len(), tabs_before_shortcut.get() + 1);
                assert_eq!(std::fs::read_to_string(&file).unwrap(), "original\n");
                source_appearance::cleanup_schemes();
                if std::env::var_os("FASTRA_HOME_KEYS_SELFTEST").is_some() {
                    eprintln!("HOME_KEYS_SELFTEST PASS native Ctrl+T creates one pristine tab; Ctrl+Shift+O opens real folder chooser; Escape closes it; disk unchanged");
                } else {
                    eprintln!(
                    "CHROME_SELFTEST PASS welcome, pristine reuse, saved-empty retention, visible tabs, native Ctrl+F, typed fields, case/mode adapters, selective preview, hide/reopen, approved apply, native Undo, inactive close, sidebar toggle, folder/project min+wide, scope roundtrip, native Ctrl+W/Ctrl+T/Ctrl+Shift+O, hidden-window lifecycle, Unicode/CRLF/selection statistics, disk unchanged"
                );
                }
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
