use super::*;
fn send(title: String, args: Vec<String>) {
    std::thread::spawn(move || {
        let output = std::process::Command::new("xdotool")
            .args(["search", "--name", &format!("^{title}$")])
            .output()
            .unwrap();
        let ids = String::from_utf8(output.stdout).unwrap();
        let id = ids.lines().next().expect("test window");
        assert!(std::process::Command::new("xdotool")
            .args(["windowraise", id, "windowfocus", "--sync", id])
            .status()
            .unwrap()
            .success());
        let args: Vec<_> = args
            .into_iter()
            .map(|s| if s == "WINDOW" { id.into() } else { s })
            .collect();
        assert!(std::process::Command::new("xdotool")
            .args(args)
            .status()
            .unwrap()
            .success());
    });
}
fn click_with_keys(window: &impl IsA<gtk::Window>, widget: &impl IsA<gtk::Widget>, keys: &[&str]) {
    let window = window.as_ref();
    let widget = widget.as_ref();
    let native = widget.native().expect("native test surface");
    let native_widget = native.clone().dynamic_cast::<gtk::Widget>().unwrap();
    let point = widget
        .compute_point(
            &native_widget,
            &gtk::graphene::Point::new(widget.width() as f32 / 2., widget.height() as f32 / 2.),
        )
        .unwrap();
    let (x, y) = native.surface_transform();
    let surface = native.surface().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null(), "X11 backend required for XTest");
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(surface.as_ptr().cast()) };
    let mut args = vec![
        "mousemove".into(),
        "--window".into(),
        id.to_string(),
        (point.x() as f64 - x).round().to_string(),
        (point.y() as f64 - y).round().to_string(),
        "click".into(),
        "1".into(),
    ];
    if !keys.is_empty() {
        args.push("key".into());
        args.extend(keys.iter().map(|key| key.to_string()));
    }
    send(window.title().unwrap().into(), args);
}
fn select(doc: &Document, start: i32, end: i32) {
    doc.buffer.select_range(
        &doc.buffer.iter_at_offset(start),
        &doc.buffer.iter_at_offset(end),
    );
}
fn selection_toggle(ui: &Ui) -> gtk::CheckButton {
    fn find(widget: &gtk::Widget, title: &str) -> Option<gtk::CheckButton> {
        if let Some(check) = widget
            .downcast_ref::<gtk::CheckButton>()
            .filter(|check| check.label().as_deref() == Some(title))
        {
            return Some(check.clone());
        }
        chrome::children(widget)
            .iter()
            .find_map(|child| find(child, title))
    }
    find(
        ui.chrome
            .borrow()
            .as_ref()
            .unwrap()
            .search_window
            .upcast_ref(),
        ui.lang.text("Nur in Auswahl", "Selection only"),
    )
    .unwrap()
}
fn search(ui: &Rc<Ui>) {
    ui.search();
}

fn apply(ui: &Rc<Ui>) {
    if ui.apply.is_mapped() {
        git_view::test_click(&ui.apply, &[]);
        return;
    }
    git_view::test_click(&ui.approval.test_review_button(), &[]);
    let weak = Rc::downgrade(ui);
    let started = std::time::Instant::now();
    let mapped = Cell::new(None::<std::time::Instant>);
    glib::timeout_add_local(Duration::from_millis(20), move || {
        let Some(ui) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "native review did not open"
        );
        if ui.apply.is_mapped() && ui.approval.review_test_visible() {
            let since = mapped.get().unwrap_or_else(|| { let now=std::time::Instant::now(); mapped.set(Some(now)); now });
            if since.elapsed() < Duration::from_millis(250) { return glib::ControlFlow::Continue; }
            git_view::test_click(&ui.apply, &[]);
            glib::ControlFlow::Break
        } else {
            glib::ControlFlow::Continue
        }
    });
}
fn has_text(widget: &gtk::Widget, needle: &str) -> bool {
    if widget
        .downcast_ref::<gtk::Label>()
        .is_some_and(|label| label.text().contains(needle))
    {
        return true;
    }
    let mut child = widget.first_child();
    while let Some(w) = child {
        if has_text(&w, needle) {
            return true;
        }
        child = w.next_sibling();
    }
    false
}
fn inject_result(ui: &Ui, replacement: String) {
    let doc = ui.active().unwrap();
    let preview = fastra_core::preview(
        &buffer_text(&doc.buffer),
        doc.revision.get(),
        ui.generation.get(),
        &SearchRequest {
            pattern: "(cat)".into(),
            replacement,
            mode: SearchMode::Regex,
            case_sensitive: true,
            range: None,
        },
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap();
    ui.pending.borrow_mut().as_mut().unwrap().preview = std::sync::Arc::new(preview);
}
fn source_view(root: &gtk::Widget) -> Option<sourceview5::View> {
    if let Some(v) = root.downcast_ref::<sourceview5::View>() {
        return Some(v.clone());
    }
    let mut child = root.first_child();
    while let Some(w) = child {
        if let Some(v) = source_view(&w) {
            return Some(v);
        }
        child = w.next_sibling();
    }
    None
}
pub fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let stage = Cell::new(0);
    let previous = Cell::new(255);
    let paint = Cell::new(std::time::Instant::now());
    let start = std::time::Instant::now();
    let generation = Cell::new(0);
    let expanded_source = "cat ".repeat(10_000);
    let baseline = "cat🙂\r\ncat e\u{301} cat\r\noutside cat";
    let expected = "cat🙂\r\ndog e\u{301} dog\r\noutside cat";
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            start.elapsed() < Duration::from_secs(70),
            "selection selftest timed out stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        if previous.replace(stage.get()) != stage.get() {
            eprintln!("Selection test stage {}", stage.get());
        }
        match stage.get() {
            0 => {
                if !ui.window.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                ui.add_document("selection.txt", baseline);
                ui.window.set_title(Some(&format!(
                    "Fastra Selection Test {}",
                    std::process::id()
                )));
                ui.find.set_text("cat");
                ui.replace.set_text("dog");
                ui.mode.set_selected(0);
                ui.case.set_active(true);
                ui.whole_word.set_active(false);
                assert_eq!(ui.scope.model().unwrap().n_items(), 5);
                chrome::show_search(&ui);
                paint.set(std::time::Instant::now());
                stage.set(100);
            }
            100 => {
                let toggle = selection_toggle(&ui);
                if !toggle.is_mapped()
                    || toggle.width() < 10
                    || paint.get().elapsed() < Duration::from_millis(220)
                {
                    return glib::ControlFlow::Continue;
                }
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                if !git_view::try_capture(&window, "selection-initial") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&toggle, &[]);
                paint.set(std::time::Instant::now());
                stage.set(1);
            }
            1 => {
                if ui.scope.selected() != 4 {
                    assert!(
                        paint.get().elapsed() < Duration::from_secs(2),
                        "native Selection only checkbox did not switch scope: active={} visible={} width={}",
                        selection_toggle(&ui).is_active(),
                        selection_toggle(&ui).is_mapped(),
                        selection_toggle(&ui).width()
                    );
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                select(&doc, 6, 16);
                assert_eq!(selected_offsets(&doc), Some((6, 16)));
                ui.scope.set_selected(0);
                ui.scope.set_selected(4);
                search(&ui);
                stage.set(2);
            }
            2 => {
                if !ui.approval.test_approve_initial() {
                    return glib::ControlFlow::Continue;
                }
                let pending = ui.pending.borrow();
                let p = pending.as_ref().unwrap();
                assert_eq!(p.selection, Some((6, 16)));
                assert_eq!(p.preview.matches().len(), 2);
                assert_eq!(
                    p.preview.matches()[0].range,
                    fastra_core::Utf16Range {
                        location: 7,
                        length: 3
                    }
                );
                assert_eq!(
                    p.preview.matches()[1].range,
                    fastra_core::Utf16Range {
                        location: 14,
                        length: 3
                    }
                );
                assert_eq!(ui.approval.test_display(0), baseline.replace("\r\n", "\n"));
                assert_eq!(ui.approval.test_display(1), expected.replace("\r\n", "\n"));
                drop(pending);
                ui.window.set_default_size(760, 950);
                paint.set(std::time::Instant::now());
                stage.set(20);
            }
            20 | 21 => {
                if paint.get().elapsed() < Duration::from_millis(350) {
                    return glib::ControlFlow::Continue;
                }
                git_view::capture(
                    ui.window.upcast_ref(),
                    &format!(
                        "selection-{}-{}",
                        ui.lang.text("de", "en"),
                        if stage.get() == 20 { "min" } else { "wide" }
                    ),
                );
                if stage.get() == 20 {
                    ui.window.set_default_size(1280, 950);
                    paint.set(std::time::Instant::now());
                    stage.set(21);
                } else {
                    apply(&ui);
                    stage.set(3);
                }
            }
            3 => {
                let doc = ui.active().unwrap();
                if buffer_text(&doc.buffer) != expected {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.pending.borrow().is_none());
                ui.chrome.borrow().as_ref().unwrap().search_window.close();
                paint.set(std::time::Instant::now());
                stage.set(31);
            }
            31 => {
                if paint.get().elapsed() < Duration::from_millis(200) {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                git_view::test_click(&source_panes::capture(&doc).unwrap().view, &["ctrl+z"]);
                stage.set(4);
            }
            4 => {
                let doc = ui.active().unwrap();
                if buffer_text(&doc.buffer) != baseline {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    !doc.buffer.can_undo(),
                    "selection apply must be exactly one Undo"
                );
                chrome::show_search(&ui);
                select(&doc, 6, 16);
                ui.scope.set_selected(0);
                ui.scope.set_selected(4);
                search(&ui);
                stage.set(5);
            }
            5 => {
                if !ui.approval.test_approve_initial() {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                select(&doc, 0, 3);
                assert!(ui.pending.borrow().is_some() && ui.apply.is_sensitive());
                assert_eq!(search_selection::range(&ui, &doc), Some((6, 16)));
                assert_eq!(buffer_text(&doc.buffer), baseline);
                ui.scope.set_selected(0);
                doc.buffer.place_cursor(&doc.buffer.start_iter());
                ui.scope.set_selected(4);
                search(&ui);
                stage.set(6);
            }
            6 => {
                if !ui
                    .status
                    .text()
                    .contains(ui.lang.text("nichtleere", "nonempty"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.pending.borrow().is_none());
                assert!(!ui.apply.is_sensitive());
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), baseline);
                git_view::test_click(&selection_toggle(&ui), &[]);
                stage.set(7);
            }
            7 => {
                if ui.scope.selected() != 0 {
                    return glib::ControlFlow::Continue;
                }
                search(&ui);
                stage.set(8);
            }
            8 => {
                if !ui.approval.test_approve_initial() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    ui.pending
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .preview
                        .matches()
                        .len(),
                    4
                );
                generation.set(ui.generation.get());
                let doc = ui.active().unwrap();
                doc.buffer.place_cursor(&doc.buffer.end_iter());
                select(&doc, 0, 3);
                assert_eq!(ui.generation.get(), generation.get());
                assert!(
                    ui.pending.borrow().is_some()
                        && ui.approval.is_ready()
                        && ui.apply.is_sensitive()
                );
                if std::env::var_os("FASTRA_SPLIT_REVIEW_SCOPE0").is_some() {
                    click_with_keys(
                        &ui.window,
                        &source_view(doc.container.upcast_ref()).unwrap(),
                        &["ctrl+Home", "Right"],
                    );
                    paint.set(std::time::Instant::now());
                    stage.set(89);
                    return glib::ControlFlow::Continue;
                }
                select(&doc, 6, 16);
                ui.scope.set_selected(4);
                ui.search();
                doc.buffer.place_cursor(&doc.buffer.start_iter());
                paint.set(std::time::Instant::now());
                stage.set(9);
            }
            9 => {
                if paint.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                if !ui.approval.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    ui.pending.borrow().as_ref().unwrap().selection,
                    Some((6, 16))
                );
                assert_eq!(
                    ui.pending
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .preview
                        .matches()
                        .len(),
                    2
                );
                let doc = ui.active().unwrap();
                assert_eq!(buffer_text(&doc.buffer), baseline);
                doc.buffer.set_enable_undo(false);
                doc.buffer.set_text("cat");
                doc.buffer.set_enable_undo(true);
                ui.scope.set_selected(0);
                ui.mode.set_selected(2);
                ui.find.set_text("(cat)");
                ui.replace.set_text("dog");
                search(&ui);
                stage.set(10);
            }
            10 => {
                if !ui.approval.test_approve_initial() {
                    return glib::ControlFlow::Continue;
                }
                inject_result(&ui, "\0".into());
                apply(&ui);
                stage.set(11);
            }
            11 => {
                if !ui.status.text().contains("U+0000") {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                assert_eq!(buffer_text(&doc.buffer), "cat");
                assert!(!doc.buffer.can_undo());
                assert!(ui.pending.borrow().is_none());
                search(&ui);
                stage.set(12);
            }
            12 => {
                if !ui.approval.test_approve_initial() {
                    return glib::ControlFlow::Continue;
                }
                inject_result(&ui, "x".repeat(65537));
                apply(&ui);
                stage.set(13);
            }
            13 => {
                if !ui.status.text().contains("64 KiB") {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                assert_eq!(buffer_text(&doc.buffer), "cat");
                assert!(!doc.buffer.can_undo());
                assert!(ui.pending.borrow().is_none());
                doc.buffer.set_enable_undo(false);
                doc.buffer.set_text(&expanded_source);
                doc.buffer.set_enable_undo(true);
                ui.find.set_text("(.+)");
                ui.replace.set_text("$1$1");
                search(&ui);
                stage.set(14);
            }
            14 => {
                if ui.approval.is_ready() {
                    ui.approval.test_approve_initial();
                }
                if !has_text(ui.approval.root.upcast_ref(), "64 KiB") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!ui.apply.is_sensitive() && !ui.approval.is_ready());
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), expanded_source);
                assert!(!ui.active().unwrap().buffer.can_undo());
                eprintln!(
                    "FASTRA_SELECTION_SELFTEST_OK native-scope-menu/utf16-emoji-combining-crlf/selected-hits-only/full-document-preview/real-apply-one-undo/frozen-selection-survives-caret-and-pending-reply/empty-refused/no-whole-file-fallback/scope0-cursor-keeps-preview/cancel-late-completion/last-apply-nul-and-longline-guard/source-and-undo-preserved/normal-longline-preview-disabled"
                );
                std::process::exit(0);
            }
            89 => {
                if paint.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                assert_eq!(doc.buffer.cursor_position(), 1, "actual source Right key");
                assert_eq!(ui.generation.get(), generation.get());
                assert!(
                    ui.pending.borrow().is_some()
                        && ui.approval.is_ready()
                        && ui.apply.is_sensitive(),
                    "scope0 remains approved after caret movement"
                );
                eprintln!("REVIEW SCOPE0 ready after real caret move: applying whole document");
                apply(&ui);
                paint.set(std::time::Instant::now());
                stage.set(90);
            }
            90 => {
                if paint.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                let actual = buffer_text(&doc.buffer);
                let expected = baseline.replace("cat", "dog");
                eprintln!(
                    "REVIEW SCOPE0 after Apply actual={actual:?} expected={expected:?} pending={} ready={} status={}",
                    ui.pending.borrow().is_some(),
                    ui.approval.is_ready(),
                    ui.status.text()
                );
                assert_eq!(
                    actual, expected,
                    "whole-document Apply remains valid after a pure caret move"
                );
                assert!(doc.buffer.can_undo());
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), baseline);
                println!("PASS REVIEW SCOPE0 real caret move then Apply, oneUndo");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
