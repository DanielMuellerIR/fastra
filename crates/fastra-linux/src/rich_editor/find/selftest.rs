use super::*;
use std::time::Instant;

fn focused(entry: &gtk::Entry) -> bool {
    entry
        .root()
        .and_then(|root| root.focus())
        .is_some_and(|focus| {
            focus == *entry.upcast_ref::<gtk::Widget>() || focus.is_ancestor(entry)
        })
}
fn label(widget: &gtk::Widget, text: &str) -> bool {
    widget.is_mapped()
        && widget
            .downcast_ref::<gtk::Label>()
            .is_some_and(|value| value.text() == text)
        || chrome::children(widget)
            .iter()
            .any(|child| label(child, text))
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(
        std::env::var("FASTRA_TOOL_WIDTH")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(760),
        780,
    );
    let source = "alpha **beta** alpha\n";
    ui.add_document("find.md", source);
    let doc = ui.active().unwrap();
    doc.buffer
        .select_range(&doc.buffer.iter_at_offset(5), &doc.buffer.start_iter());
    let phase = Cell::new(0);
    let painted = Cell::new(false);
    let started = Instant::now();
    let pause = Cell::new(started);
    let long = RefCell::new(None::<Rc<Document>>);
    let original = RefCell::new(String::new());
    let response = Rc::new(RefCell::new(None::<Value>));
    let shots = RefCell::new(None::<mpsc::Receiver<bool>>);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed().as_secs() < 45,
            "Rich find phase {}",
            phase.get()
        );
        if pause.get().elapsed() < Duration::from_millis(180) {
            return glib::ControlFlow::Continue;
        }
        let editor = doc.rich.borrow().clone();
        match phase.get() {
            0 => {
                if !label(ui.window.upcast_ref(), "5 / 1 / 1") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(doc.rich_toggle.borrow().as_ref().unwrap(), &[]);
            }
            1 => {
                let Some(editor) = editor.filter(|e| e.ready.get()) else {
                    return glib::ControlFlow::Continue;
                };
                if !label(ui.window.upcast_ref(), "21 / 3 / 2") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!label(ui.window.upcast_ref(), "Sel"));
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(
                    editor.widget.first_child().unwrap().height() <= 38,
                    "compact toolbar"
                );
                if !painted.replace(true) {
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                if !gui_test::capture(&ui.window, "rich-toolbar-min", &shots) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&editor.view, &["ctrl+f"]);
            }
            2 => {
                let editor = editor.unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                if !focused(&bar.entry) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(
                    &bar.entry,
                    &["b", "e", "t", "a", "space", "a", "l", "p", "h", "a"],
                );
            }
            3 => {
                let editor = editor.unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                if !bar.status.text().starts_with("1 ") {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), source);
                if !gui_test::capture(&ui.window, "rich-find-across-formatting", &shots) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&bar.entry, &["Return", "ctrl+a", "asterisk", "asterisk"]);
            }
            4 => {
                let editor = editor.unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                if bar.status.text() != editor.text("Kein Treffer", "No match") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&bar.entry, &["ctrl+a", "A", "L", "P", "H", "A"]);
            }
            5 => {
                let editor = editor.unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                if !bar.status.text().starts_with("2 ") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&bar.case, &[]);
            }
            6 => {
                let editor = editor.unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                if bar.status.text() != editor.text("Kein Treffer", "No match") {
                    return glib::ControlFlow::Continue;
                }
                if !gui_test::capture(&ui.window, "rich-find-case", &shots) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&bar.entry, &["Escape"]);
            }
            7 => {
                let editor = editor.unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                if bar.root.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&editor.view, &["ctrl+f"]);
            }
            8 => {
                let editor = editor.unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                if !bar.root.is_mapped() || !focused(&bar.entry) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(bar.entry.text(), "ALPHA");
                assert!(bar.case.is_active());
                assert_eq!(buffer_text(&doc.buffer), source);
                let text = format!("alpha\n\n{}alpha\n", "Synthetic paragraph.\n\n".repeat(100));
                ui.add_document("long-find.md", &text);
                *original.borrow_mut() = text;
                let active = ui.active().unwrap();
                *long.borrow_mut() = Some(active.clone());
                active
                    .rich_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
            }
            9 => {
                let current = long.borrow().as_ref().unwrap().clone();
                let Some(editor) = current.rich.borrow().clone().filter(|e| e.ready.get()) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_keys(&editor.view, &["ctrl+f"]);
            }
            10 => {
                let current = long.borrow().as_ref().unwrap().clone();
                let editor = current.rich.borrow().clone().unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                if !focused(&bar.entry) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&bar.entry, &["a", "l", "p", "h", "a"]);
            }
            11 => {
                let current = long.borrow().as_ref().unwrap().clone();
                let editor = current.rich.borrow().clone().unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                if !bar.status.text().starts_with("2 ") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&bar.entry, &["ctrl+g"]);
            }
            12 => {
                let current = long.borrow().as_ref().unwrap().clone();
                let editor = current.rich.borrow().clone().unwrap();
                let received = response.clone();
                editor.evaluate("return JSON.stringify({y:window.scrollY});", move |value| {
                    *received.borrow_mut() = value;
                });
            }
            13 => {
                let Some(value) = response.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                if value["y"].as_f64().unwrap_or(0.) < 300. {
                    phase.set(12);
                    return glib::ControlFlow::Continue;
                }
                let current = long.borrow().as_ref().unwrap().clone();
                assert_eq!(buffer_text(&current.buffer), *original.borrow());
                assert!(!current.buffer.is_modified());
                phase.set(131);
                return glib::ControlFlow::Continue;
            }
            131 => {
                let current = long.borrow().as_ref().unwrap().clone();
                if !gui_test::capture(&ui.window, "rich-find-scrolled", &shots) {
                    return glib::ControlFlow::Continue;
                }
                let editor = current.rich.borrow().clone().unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                git_view::test_keys(&bar.entry, &["ctrl+shift+g"]);
                phase.set(132);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            132 => {
                let current = long.borrow().as_ref().unwrap().clone();
                let editor = current.rich.borrow().clone().unwrap();
                let received = response.clone();
                editor.evaluate("return JSON.stringify({y:window.scrollY});", move |value| {
                    *received.borrow_mut() = value;
                });
            }
            133 => {
                let Some(value) = response.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                if value["y"].as_f64().unwrap_or(f64::MAX) > 100. {
                    phase.set(132);
                    return glib::ControlFlow::Continue;
                }
                let current = long.borrow().as_ref().unwrap().clone();
                let editor = current.rich.borrow().clone().unwrap();
                let bar = editor.find.borrow().clone().unwrap();
                let source = bar.root.last_child().unwrap().prev_sibling().unwrap();
                git_view::test_click(&source, &[]);
                phase.set(14);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            14 => {
                let current = long.borrow().as_ref().unwrap().clone();
                if current.rich.borrow().is_some()
                    || !ui
                        .chrome
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .search_window
                        .is_mapped()
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&current.buffer), *original.borrow());
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!current.buffer.is_modified());
                source_appearance::cleanup_schemes();
                eprintln!(
                    "RICH_FIND_SELFTEST PASS native mode icon/Ctrl+F/typed search/Return/Escape/reopen/Ctrl+G/Ctrl+Shift+G, matches across inline formatting, hidden Markdown syntax, case, whole-source Rich footer, real scroll, source search transition, unchanged Markdown/Undo"
                );
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
