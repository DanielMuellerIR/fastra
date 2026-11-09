use super::*;
use std::time::Instant;
fn menu(root: &gtk::Widget, label: &str) -> Option<gtk::MenuButton> {
    if let Some(b) = root.downcast_ref::<gtk::MenuButton>() {
        if b.label().as_deref() == Some(label) {
            return Some(b.clone());
        }
    }
    let mut child = root.first_child();
    while let Some(w) = child {
        if let Some(b) = menu(&w, label) {
            return Some(b);
        }
        child = w.next_sibling();
    }
    None
}
fn button(root: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(b) = root.downcast_ref::<gtk::Button>() {
        if b.label().as_deref() == Some(label) {
            return Some(b.clone());
        }
    }
    let mut child = root.first_child();
    while let Some(w) = child {
        if let Some(b) = button(&w, label) {
            return Some(b);
        }
        child = w.next_sibling();
    }
    None
}
fn current() -> Option<Rc<State>> {
    TEST_STATE.with(|slot| slot.borrow().upgrade())
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let source = "first\r\n🙂éline\r\nlast\u{2028}tail";
    ui.add_document("navigation.swift", source);
    let doc = ui.active().unwrap();
    let page = ui.tabs.current_page().unwrap();
    doc.buffer.insert(&mut doc.buffer.end_iter(), "x");
    let stage = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    let held: RefCell<Option<Rc<State>>> = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(40),
            "goto stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        match stage.get() {
            0 => {
                menu(ui.window.upcast_ref(), ui.lang.text("Werkzeuge", "Tools"))
                    .unwrap()
                    .popup();
                pause.set(Instant::now());
                stage.set(1);
            }
            1 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let tools =
                    menu(ui.window.upcast_ref(), ui.lang.text("Werkzeuge", "Tools")).unwrap();
                let target = button(
                    tools.popover().unwrap().upcast_ref(),
                    ui.lang
                        .text("Zu Zeile/Spalte springen …", "Go to line/column …"),
                )
                .unwrap();
                git_view::test_click(&target, &[]);
                stage.set(2);
            }
            2 => {
                let Some(state) = current().filter(|s| s.window.is_visible()) else {
                    return glib::ControlFlow::Continue;
                };
                let width = std::env::var("FASTRA_TOOL_WIDTH")
                    .unwrap_or_else(|_| "640".into())
                    .parse::<i32>()
                    .unwrap();
                state.window.set_default_size(width, 300);
                *held.borrow_mut() = Some(state);
                pause.set(Instant::now());
                stage.set(3);
            }
            3 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let s = held.borrow().as_ref().unwrap().clone();
                git_view::test_click(&s.input, &["ctrl+a", "2", "colon", "0"]);
                stage.set(4);
            }
            4 => {
                let s = held.borrow().as_ref().unwrap().clone();
                if s.input.text().as_str() != "2:0" {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&s.go, &[]);
                pause.set(Instant::now());
                stage.set(5);
            }
            5 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let s = held.borrow().as_ref().unwrap().clone();
                assert!(s.window.is_visible());
                assert!(!s.busy.get());
                assert_eq!(doc.buffer.cursor_position(), doc.buffer.char_count());
                assert!(doc.buffer.can_undo());
                git_view::capture(&s.window, "goto-invalid-input");
                s.input.set_text("2:4");
                pause.set(Instant::now());
                stage.set(6);
            }
            6 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let s = held.borrow().as_ref().unwrap().clone();
                git_view::capture(&s.window, "goto-line-column");
                git_view::test_click(&s.go, &[]);
                stage.set(7);
            }
            7 => {
                let s = held.borrow().as_ref().unwrap().clone();
                if s.window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(doc.buffer.cursor_position(), 9);
                assert_eq!(buffer_text(&doc.buffer), format!("{source}x"));
                assert!(doc.buffer.can_undo());
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.is_modified());
                ui.window.present();
                git_view::test_click(&ui.window, &["ctrl+l"]);
                stage.set(8);
            }
            8 => {
                let Some(s) = current().filter(|s| s.window.is_visible()) else {
                    return glib::ControlFlow::Continue;
                };
                s.input.set_text("2:2");
                s.go.emit_clicked();
                *held.borrow_mut() = Some(s);
                stage.set(9);
            }
            9 => {
                let s = held.borrow().as_ref().unwrap().clone();
                if s.window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(doc.buffer.cursor_position(), 7);
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                doc.buffer.place_cursor(&doc.buffer.iter_at_offset(10));
                let s = create(&ui).unwrap();
                s.input.set_text("1:1");
                s.go.emit_clicked();
                doc.rectangles.borrow()[0].select((0, 1), (1, 3));
                assert_eq!(doc.buffer.cursor_position(), 10);
                assert!(selected_offsets(&doc).is_none());
                *held.borrow_mut() = Some(s);
                stage.set(90);
            }
            90 => {
                let s = held.borrow().as_ref().unwrap().clone();
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.window.is_visible());
                assert!(doc.rectangles.borrow()[0].is_selected());
                assert_eq!(doc.buffer.cursor_position(), 10);
                doc.rectangles.borrow()[0].clear();
                git_view::test_click(&s.input, &["Escape"]);
                stage.set(91);
            }
            91 => {
                if held.borrow().as_ref().unwrap().window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                let s = create(&ui).unwrap();
                s.input.set_text("1:1");
                s.go.emit_clicked();
                doc.buffer.place_cursor(&doc.buffer.end_iter());
                doc.buffer.insert_at_cursor("edit");
                *held.borrow_mut() = Some(s);
                stage.set(10);
            }
            10 => {
                let s = held.borrow().as_ref().unwrap().clone();
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.window.is_visible());
                assert_eq!(doc.buffer.cursor_position(), doc.buffer.char_count());
                ui.add_document("foreign", "untouched");
                s.go.emit_clicked();
                assert!(!s.busy.get());
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "untouched");
                ui.tabs.set_current_page(Some(page));
                *doc.folded.borrow_mut() = Some(
                    doc.buffer
                        .create_tag(None, &[("invisible", &true)])
                        .unwrap(),
                );
                assert!(create(&ui).is_none());
                s.go.emit_clicked();
                assert!(!s.busy.get());
                doc.folded.borrow_mut().take();
                s.input.set_text("1:1");
                s.go.emit_clicked();
                ui.window.set_visible(false);
                stage.set(11);
            }
            11 => {
                let s = held.borrow().as_ref().unwrap().clone();
                assert!(!s.window.is_visible());
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), format!("{source}edit"));
                assert_eq!(doc.buffer.cursor_position(), doc.buffer.char_count());
                println!("FASTRA goto selftest PASS: actual Tools/Go/input/Ctrl+L/Escape, UTF16/CRLF position, surrogate-safe caret, text/Undo preserved, invalid input, stale rectangle with unchanged cursor, stale source, foreign tab, folded source and parent hide refused");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
