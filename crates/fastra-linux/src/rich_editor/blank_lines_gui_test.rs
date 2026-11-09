use super::*;
use std::time::{Duration, Instant};
fn query(editor: &Rc<RichEditor>, reply: &Rc<RefCell<Option<Value>>>, select: bool) {
    reply.borrow_mut().take();
    let reply = reply.clone();
    let selection = if select {
        "const p=Array.from(document.querySelectorAll('#fastra-visual p')).find(n=>n.textContent==='Omega');const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);"
    } else {
        ""
    };
    editor.evaluate(&format!("{selection}await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));return JSON.stringify({{count:document.querySelectorAll('.fastra-visible-blank-line').length,lists:document.querySelectorAll('#fastra-visual ul').length,items:document.querySelectorAll('#fastra-visual li').length,heights:Array.from(document.querySelectorAll('.fastra-visible-blank-line')).map(n=>n.getBoundingClientRect().height),source:fastraVisual.markdown()}});"),move|value|*reply.borrow_mut()=value);
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(
        std::env::var("FASTRA_RICH_WIDTH")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(1180),
        1100,
    );
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("blank-lines.md");
    let source =
        "  \r\nTitel 雪\r\n  \r\n- Eins\r\n  \r\n- Zwei\r\n  \r\n  \r\nOmega\r\n  ".to_string();
    std::fs::write(&path, &source).unwrap();
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let started = Instant::now();
    let reply = Rc::new(RefCell::new(None::<Value>));
    let document = RefCell::new(None::<Rc<Document>>);
    let editor = RefCell::new(None::<Rc<RichEditor>>);
    let saved = RefCell::new(String::new());
    let shots = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            started.elapsed() < Duration::from_secs(65),
            "blank-line phase {}",
            phase.get()
        );
        let advance = |n| {
            eprintln!("Blank-line phase {n}");
            phase.set(n);
        };
        match phase.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                mode_toggle(&doc, ui.lang).set_active(true);
                *document.borrow_mut() = Some(doc);
                advance(1);
            }
            1 => {
                let Some(ed) = document
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .rich
                    .borrow()
                    .clone()
                    .filter(|e| e.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                query(&ed, &reply, true);
                *editor.borrow_mut() = Some(ed);
                advance(2);
            }
            2 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["count"], 6);
                assert_eq!(value["lists"], 1);
                assert_eq!(value["items"], 2);
                assert_eq!(value["source"], source);
                assert!(value["heights"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|n| n.as_f64().unwrap() >= 18.));
                if !gui_test::capture(&ui.window, "blank-lines-initial", &shots) {
                    *reply.borrow_mut() = Some(value);
                    return glib::ControlFlow::Continue;
                }
                let ed = editor.borrow().clone().unwrap();
                reply.borrow_mut().take();
                let result = reply.clone();
                ed.evaluate("const n=document.querySelector('.fastra-visible-blank-line'),r=document.createRange();r.selectNodeContents(n);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",move|value|*result.borrow_mut()=value);
                advance(20);
            }
            20 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(&editor.borrow().as_ref().unwrap().view, false, &["x"]);
                advance(21);
            }
            21 => {
                if !buffer_text(&document.borrow().as_ref().unwrap().buffer).starts_with('x') {
                    return glib::ControlFlow::Continue;
                }
                let ed = editor.borrow().clone().unwrap();
                gui_test::input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                        .unwrap(),
                    true,
                    &[],
                );
                advance(22);
            }
            22 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                query(editor.borrow().as_ref().unwrap(), &reply, true);
                advance(23);
            }
            23 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["source"], source);
                assert_eq!(value["count"], 6);
                let ed = editor.borrow().clone().unwrap();
                gui_test::input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Fett", "Bold"))
                        .unwrap(),
                    true,
                    &[],
                );
                advance(3);
            }
            3 => {
                if !buffer_text(&document.borrow().as_ref().unwrap().buffer).contains("**Omega**") {
                    return glib::ControlFlow::Continue;
                }
                let ed = editor.borrow().clone().unwrap();
                gui_test::input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                        .unwrap(),
                    true,
                    &[],
                );
                advance(4);
            }
            4 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                query(editor.borrow().as_ref().unwrap(), &reply, true);
                advance(5);
            }
            5 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["count"], 6);
                assert_eq!(value["source"], source);
                let ed = editor.borrow().clone().unwrap();
                gui_test::input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Fett", "Bold"))
                        .unwrap(),
                    true,
                    &[],
                );
                advance(6);
            }
            6 => {
                let text = buffer_text(&document.borrow().as_ref().unwrap().buffer);
                if !text.contains("**Omega**") {
                    return glib::ControlFlow::Continue;
                }
                *saved.borrow_mut() = text;
                gui_test::input(
                    &gui_test::button(
                        ui.window.child().unwrap().upcast_ref(),
                        ui.lang.text("Speichern", "Save"),
                    )
                    .unwrap(),
                    true,
                    &[],
                );
                advance(7);
            }
            7 => {
                let doc = document.borrow().clone().unwrap();
                if doc.saving.get()
                    || doc.buffer.is_modified()
                    || std::fs::read_to_string(&path).unwrap() != *saved.borrow()
                {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(&editor.borrow().as_ref().unwrap().view, false, &["ctrl+w"]);
                advance(8);
            }
            8 => {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, document.borrow().as_ref().unwrap()))
                {
                    return glib::ControlFlow::Continue;
                }
                ui.load_path(path.clone());
                advance(9);
            }
            9 => {
                let Some(doc) = ui.active().filter(|d| {
                    d.disk_path().as_ref() == Some(&path)
                        && buffer_text(&d.buffer) == *saved.borrow()
                }) else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!Rc::ptr_eq(&doc, document.borrow().as_ref().unwrap()));
                mode_toggle(&doc, ui.lang).set_active(true);
                *document.borrow_mut() = Some(doc);
                advance(10);
            }
            10 => {
                let Some(ed) = document
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .rich
                    .borrow()
                    .clone()
                    .filter(|e| e.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                query(&ed, &reply, false);
                *editor.borrow_mut() = Some(ed);
                advance(11);
            }
            11 => {
                let Some(value) = reply.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["count"], 6);
                assert_eq!(value["lists"], 1);
                assert_eq!(value["items"], 2);
                assert_eq!(value["source"], *saved.borrow());
                if !gui_test::capture(&ui.window, "blank-lines-reopened", &shots) {
                    return glib::ControlFlow::Continue;
                }
                println!("PASS visible blank lines: native blank-line typing/Undo and Bold/Undo, original CRLF UTF8 bytes, one list/two items, six measured line heights, Save/close/reopen");
                ui.discard_confirmed.set(true);
                ui.window.close();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
