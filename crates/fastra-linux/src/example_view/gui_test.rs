use super::*;
use std::time::Instant;
fn menu(widget: &gtk::Widget) -> Option<gtk::MenuButton> {
    if let Some(menu) = widget.downcast_ref::<gtk::MenuButton>() {
        if matches!(menu.label().as_deref(), Some("Werkzeuge" | "Tools")) {
            return Some(menu.clone());
        }
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(menu) = menu(&widget) {
            return Some(menu);
        }
        child = widget.next_sibling();
    }
    None
}
fn tool(widget: &gtk::Widget) -> Option<gtk::Button> {
    if let Some(button) = widget.downcast_ref::<gtk::Button>() {
        if matches!(
            button.label().as_deref(),
            Some("Transformation per Beispiel …" | "Transformation by example …")
        ) {
            return Some(button.clone());
        }
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(button) = tool(&widget) {
            return Some(button);
        }
        child = widget.next_sibling();
    }
    None
}
fn current() -> Option<Rc<State>> {
    TEST_STATE.with(|slot| slot.borrow().upgrade())
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.add_document("example.txt", "unchanged document\n$1\\x");
    ui.scope.set_selected(0);
    ui.case.set_active(false);
    ui.whole_word.set_active(true);
    let doc = ui.active().unwrap();
    let original = buffer_text(&doc.buffer);
    let stage = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let held: RefCell<Option<Rc<State>>> = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(40),
            "example stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        let unchanged = || {
            assert_eq!(buffer_text(&doc.buffer), original);
            assert!(!doc.buffer.is_modified());
            assert!(ui.pending.borrow().is_none());
            assert_eq!(ui.scope.selected(), 0);
            assert!(!ui.case.is_active());
            assert!(ui.whole_word.is_active());
        };
        match stage.get() {
            0 => {
                chrome::show_commands(&ui);
                let ui = ui.clone();
                glib::timeout_add_local_once(Duration::from_millis(100), move || { menu(ui.window.upcast_ref()).unwrap().popup(); });
                pause.set(Instant::now());
                stage.set(1);
            }
            1 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let menu = menu(ui.window.upcast_ref()).unwrap();
                git_view::test_click(&tool(menu.popover().unwrap().upcast_ref()).unwrap(), &[]);
                stage.set(2);
            }
            2 => {
                let Some(state) = current().filter(|s| !s.busy.get() && s.apply.is_sensitive())
                else {
                    return glib::ControlFlow::Continue;
                };
                let width = std::env::var("FASTRA_TOOL_WIDTH")
                    .unwrap_or_else(|_| "560".into())
                    .parse::<i32>()
                    .unwrap();
                state.window.set_default_size(width, 330);
                *held.borrow_mut() = Some(state);
                pause.set(Instant::now());
                stage.set(3);
            }
            3 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert_eq!(state.find.text(), "*, The");
                assert_eq!(state.replace.text(), "The *");
                assert_eq!(state.result.text(), "The ring");
                git_view::capture(&state.window, "example-default");
                git_view::test_click(&state.apply, &[]);
                stage.set(4);
            }
            4 => {
                if held.borrow().as_ref().unwrap().window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.find.text(), "*, The");
                assert_eq!(ui.replace.text(), "The *");
                assert_eq!(ui.mode.selected(), 1);
                unchanged();
                let state = create(&ui);
                state.source.buffer().set_text("old");
                state.destination.buffer().set_text("older");
                state.source.buffer().set_text("a\na\\$b tail");
                state.destination.buffer().set_text("head a\\$b\nz");
                *held.borrow_mut() = Some(state);
                stage.set(5);
            }
            5 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if state.busy.get() || !state.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(state.result.text(), "head a\\\\$b\\n\nz");
                git_view::capture(&state.window, "example-literals");
                git_view::test_click(&state.source, &["Return"]);
                stage.set(6);
            }
            6 => {
                if held.borrow().as_ref().unwrap().window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.find.text(), "a\n* tail");
                assert_eq!(ui.replace.text(), "head *\nz");
                unchanged();
                let state = create(&ui);
                state.source.buffer().set_text("before α\nβ");
                state.destination.buffer().set_text("α\nβ after");
                *held.borrow_mut() = Some(state);
                stage.set(7);
            }
            7 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!state.apply.is_sensitive());
                assert_eq!(state.find.text(), "before *");
                assert!(state.result.text().contains("\\n"));
                git_view::capture(&state.window, "example-multiline-refused");
                git_view::test_click(&state.source, &["Return"]);
                pause.set(Instant::now());
                stage.set(8);
            }
            8 => {
                if pause.get().elapsed() < Duration::from_millis(200) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert!(state.window.is_visible());
                git_view::test_click(&state.source, &["Escape"]);
                stage.set(9);
            }
            9 => {
                if held.borrow().as_ref().unwrap().window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                unchanged();
                let state = create(&ui);
                *held.borrow_mut() = Some(state);
                stage.set(10);
            }
            10 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if state.busy.get() || !state.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                ui.find.set_text("stale form");
                git_view::test_click(&state.apply, &[]);
                pause.set(Instant::now());
                stage.set(11);
            }
            11 => {
                if pause.get().elapsed() < Duration::from_millis(200) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert!(state.window.is_visible());
                assert_eq!(ui.find.text(), "stale form");
                assert!(!state.apply.is_sensitive());
                unchanged();
                git_view::capture(&state.window, "example-stale");
                git_view::test_click(&state.source, &["Escape"]);
                stage.set(12);
            }
            12 => {
                if held.borrow().as_ref().unwrap().window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                unchanged();
                println!("FASTRA_TOOL_SELFTEST_OK example");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
