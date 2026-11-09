use super::*;
use std::time::{Duration, Instant};
const CASES: &[&str] = &[
    "  \r\nTitel 雪\r\n  \r\n- Eins\r\n  \r\n- Zwei\r\n  \r\n  \r\nOmega\r\n  ",
    "- Outer\n  - First\n    \n  - Second\n\n- Tail\n",
    "- First paragraph\n\n  Second paragraph\n  \n- Other\n",
    "- Code:\n\n  ```text\n  alpha\n    \n  beta\n  ```\n\n- End\n",
    "- A  \n  B&nbsp;&nbsp;C\n  \n- D\\\n  E\n",
];
fn snapshot(editor: &Rc<RichEditor>, reply: &Rc<RefCell<Option<Value>>>, select: bool) {
    reply.borrow_mut().take();
    let result = reply.clone();
    let select = if select {
        "const r=document.createRange();r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);"
    } else {
        ""
    };
    editor.evaluate(&format!("const root=document.getElementById('fastra-visual');{select}await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return JSON.stringify({{blank:root.querySelectorAll('.fastra-visible-blank-line').length,lists:root.querySelectorAll('ul,ol').length,items:root.querySelectorAll('li').length,breaks:Array.from(root.querySelectorAll('br')).filter(n=>!n.closest('.fastra-visible-blank-line,[data-md-edit-boundary]')).length,code:Array.from(root.querySelectorAll('pre')).map(n=>n.textContent.replace(/\\n$/,'')),text:root.textContent.replace(/[ \\t\\r\\n]+/g,' ').trim()}});"),move|value|*result.borrow_mut()=value);
}
fn literal_code(source: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut inside = false;
    for event in Parser::new_ext(source, Options::ENABLE_MATH) {
        match event {
            Event::Start(Tag::CodeBlock(_)) => {
                result.push(String::new());
                inside = true;
            }
            Event::End(TagEnd::CodeBlock) => inside = false,
            Event::Text(text) if inside => result.last_mut().unwrap().push_str(&text),
            _ => {}
        }
    }
    result
}
fn read_clipboard(view: &webkit6::WebView, reply: &Rc<RefCell<Option<Value>>>, markdown: bool) {
    let clipboard = view.clipboard();
    let result = reply.clone();
    reply.borrow_mut().take();
    glib::spawn_future_local(async move {
        let (stream, mime) = clipboard
            .read_future(&["text/html"], glib::Priority::DEFAULT)
            .await
            .unwrap();
        let transfer::Transfer::Html(html) = transfer::stream(stream, &mime).await.unwrap() else {
            panic!("HTML clipboard MIME");
        };
        let source = if markdown {
            let (stream, mime) = clipboard
                .read_future(&[clipboard::MIME], glib::Priority::DEFAULT)
                .await
                .unwrap();
            let transfer::Transfer::Markdown { source, .. } =
                transfer::stream(stream, &mime).await.unwrap()
            else {
                panic!("Markdown clipboard MIME");
            };
            source
        } else {
            String::new()
        };
        *result.borrow_mut() = Some(json!({"html":html,"markdown":source}));
    });
}
pub(super) fn run(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_BLANK_TYPED_COPY_SELFTEST").is_some() {
        run_typed(ui);
        return;
    }
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
    for (index, source) in CASES.iter().enumerate() {
        std::fs::write(root.join(format!("copy-source-{index}.md")), source).unwrap();
        std::fs::write(root.join(format!("copy-receiver-{index}.md")), "").unwrap();
    }
    ui.load_path(root.join("copy-source-0.md"));
    let case = Cell::new(0);
    let phase = Cell::new(0);
    let started = Instant::now();
    let reply = Rc::new(RefCell::new(None::<Value>));
    let expected = RefCell::new(Value::Null);
    let copied = RefCell::new(String::new());
    let source_doc = RefCell::new(None::<Rc<Document>>);
    let source_editor = RefCell::new(None::<Rc<RichEditor>>);
    let receiver_doc = RefCell::new(None::<Rc<Document>>);
    let receiver_editor = RefCell::new(None::<Rc<RichEditor>>);
    let shots = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            started.elapsed() < Duration::from_secs(100),
            "copy case {} phase {}",
            case.get(),
            phase.get()
        );
        let advance = |n| {
            eprintln!("Blank copy case {} phase {n}", case.get());
            phase.set(n);
        };
        let source_path = root.join(format!("copy-source-{}.md", case.get()));
        let receiver_path = root.join(format!("copy-receiver-{}.md", case.get()));
        match phase.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&source_path))
                else {
                    return glib::ControlFlow::Continue;
                };
                mode_toggle(&doc, ui.lang).set_active(true);
                *source_doc.borrow_mut() = Some(doc);
                advance(1);
            }
            1 => {
                let Some(ed) = source_doc
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
                snapshot(&ed, &reply, true);
                *source_editor.borrow_mut() = Some(ed);
                advance(2);
            }
            2 => {
                let Some(value) = reply.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    value["blank"],
                    if case.get() == 0 {
                        6
                    } else if case.get() == 3 {
                        0
                    } else {
                        1
                    }
                );
                if case.get() == 0 && !gui_test::capture(&ui.window, "blank-copy-source", &shots) {
                    return glib::ControlFlow::Continue;
                }
                *expected.borrow_mut() = value;
                gui_test::input(
                    &source_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+c"],
                );
                advance(3);
            }
            3 => {
                let ed = source_editor.borrow().clone().unwrap();
                if ed.clipboard_busy.get()
                    || !ed
                        .view
                        .clipboard()
                        .formats()
                        .contain_mime_type(clipboard::MIME)
                {
                    return glib::ControlFlow::Continue;
                }
                read_clipboard(&ed.view, &reply, true);
                advance(4);
            }
            4 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                let html = value["html"].as_str().unwrap();
                assert!(
                    !html.contains("fastra-visible-blank-line"),
                    "Rich HTML exports internal blank-line class: {html}"
                );
                assert!(!html.contains("data-srcline"));
                *copied.borrow_mut() = value["markdown"].as_str().unwrap().into();
                std::fs::write(
                    root.join(format!("copy-bytes-{}.json", case.get())),
                    serde_json::to_vec_pretty(&value).unwrap(),
                )
                .unwrap();
                ui.load_path(receiver_path.clone());
                advance(5);
            }
            5 => {
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&receiver_path))
                else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(buffer_text(&doc.buffer), "");
                mode_toggle(&doc, ui.lang).set_active(true);
                *receiver_doc.borrow_mut() = Some(doc);
                advance(6);
            }
            6 => {
                let Some(ed) = receiver_doc
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
                let result = reply.clone();
                reply.borrow_mut().take();
                ed.evaluate("const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",move|value|*result.borrow_mut()=value);
                *receiver_editor.borrow_mut() = Some(ed);
                advance(7);
            }
            7 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(
                    &receiver_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+v"],
                );
                advance(8);
            }
            8 => {
                let doc = receiver_doc.borrow().clone().unwrap();
                let ed = receiver_editor.borrow().clone().unwrap();
                if buffer_text(&doc.buffer).is_empty() || ed.busy.get() || ed.clipboard_busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!ed.failed.get());
                snapshot(&ed, &reply, false);
                advance(9);
            }
            9 => {
                let Some(value) = reply.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                // Das äußere Dokument-Newline wird beim Kopieren kanonisiert;
                // der tatsächliche Codeinhalt einschließlich leerer Zeilen muss exakt bleiben.
                assert_eq!(
                    literal_code(&buffer_text(
                        &receiver_doc.borrow().as_ref().unwrap().buffer
                    )),
                    literal_code(CASES[case.get()])
                );
                assert_eq!(
                    value,
                    *expected.borrow(),
                    "Actual Ctrl+C/Ctrl+V changed rendered structure, copy bytes {:?}",
                    *copied.borrow()
                );
                if case.get() == 0 && !gui_test::capture(&ui.window, "blank-copy-receiver", &shots)
                {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(
                    &receiver_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+z"],
                );
                advance(10);
            }
            10 => {
                if !buffer_text(&receiver_doc.borrow().as_ref().unwrap().buffer).is_empty() {
                    return glib::ControlFlow::Continue;
                }
                snapshot(receiver_editor.borrow().as_ref().unwrap(), &reply, false);
                advance(11);
            }
            11 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["blank"], 0);
                assert_eq!(
                    buffer_text(&source_doc.borrow().as_ref().unwrap().buffer),
                    CASES[case.get()]
                );
                assert_eq!(
                    std::fs::read_to_string(&source_path).unwrap(),
                    CASES[case.get()]
                );
                assert_eq!(std::fs::read_to_string(&receiver_path).unwrap(), "");
                gui_test::input(
                    &receiver_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+w"],
                );
                advance(12);
            }
            12 => {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, receiver_doc.borrow().as_ref().unwrap()))
                {
                    let label = ui
                        .lang
                        .text("Ohne Speichern schließen", "Close without saving");
                    if let Some(button) = gtk::Window::list_toplevels()
                        .iter()
                        .find_map(|window| gui_test::button(window, label))
                    {
                        // Die eigene Empfängerquelle und Plattendatei sind bereits
                        // als leer belegt; ein verbleibender Dirty-Marker ist kein Copytest.
                        assert!(
                            buffer_text(&receiver_doc.borrow().as_ref().unwrap().buffer).is_empty()
                        );
                        gui_test::input(&button, true, &[]);
                        advance(121);
                    }
                    return glib::ControlFlow::Continue;
                }
                advance(121);
            }
            121 => {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, receiver_doc.borrow().as_ref().unwrap()))
                {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(
                    &source_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+w"],
                );
                advance(13);
            }
            13 => {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, source_doc.borrow().as_ref().unwrap()))
                {
                    return glib::ControlFlow::Continue;
                }
                case.set(case.get() + 1);
                if case.get() < CASES.len() {
                    ui.load_path(root.join(format!("copy-source-{}.md", case.get())));
                    advance(0);
                } else {
                    ui.load_path(root.join("copy-source-0.md"));
                    advance(20);
                }
            }
            20 => {
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&root.join("copy-source-0.md")))
                else {
                    return glib::ControlFlow::Continue;
                };
                doc.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                *source_doc.borrow_mut() = Some(doc);
                advance(21);
            }
            21 => {
                let Some(preview) = source_doc
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .markdown
                    .borrow()
                    .clone()
                else {
                    return glib::ControlFlow::Continue;
                };
                let result = reply.clone();
                reply.borrow_mut().take();
                preview.inspect("if(!window.fastraPreviewReady)return JSON.stringify(false);const r=document.createRange();r.selectNodeContents(document.body);getSelection().removeAllRanges();getSelection().addRange(r);await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return JSON.stringify({blank:document.querySelectorAll('.fastra-visible-blank-line').length});",move|value|*result.borrow_mut()=Some(value));
                advance(22);
            }
            22 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                if value == false {
                    advance(21);
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(value["blank"], 6);
                gui_test::input(
                    &source_doc
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .markdown
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .view,
                    false,
                    &["ctrl+c"],
                );
                advance(23);
            }
            23 => {
                let preview = source_doc
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .markdown
                    .borrow()
                    .clone()
                    .unwrap();
                let formats = preview.view.clipboard().formats();
                if formats.contain_mime_type(clipboard::MIME)
                    || !formats.contain_mime_type("text/html")
                {
                    return glib::ControlFlow::Continue;
                }
                read_clipboard(&preview.view, &reply, false);
                advance(24);
            }
            24 => {
                let Some(value) = reply.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                let html = value["html"].as_str().unwrap();
                assert!(
                    !html.contains("fastra-visible-blank-line"),
                    "Static HTML exports internal blank-line class: {html}"
                );
                assert!(!html.contains("data-srcline"));
                assert!(!html.contains("<script"));
                assert!(html.matches("<br").count() >= 6);
                if !gui_test::capture(&ui.window, "blank-copy-static", &shots) {
                    return glib::ControlFlow::Continue;
                }
                println!("PASS blank-line clipboard: five native Ctrl+C/V roundtrips, six visible lines unchanged, nested/loose lists, literal multiline code/whitespace, NBSP/hardbreak, real Undo, original source/disk unchanged, Rich/static HTML has no internal blank/source metadata");
                ui.discard_confirmed.set(true);
                ui.window.close();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

fn run_typed(ui: Rc<Ui>) {
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
    let source_path = root.join("typed-source.md");
    let receiver_path = root.join("typed-receiver.md");
    let original = "  \r\nTail\r\n";
    std::fs::write(&source_path, original).unwrap();
    std::fs::write(&receiver_path, "").unwrap();
    ui.load_path(source_path.clone());
    let source_doc = RefCell::new(None::<Rc<Document>>);
    let source_editor = RefCell::new(None::<Rc<RichEditor>>);
    let receiver_doc = RefCell::new(None::<Rc<Document>>);
    let receiver_editor = RefCell::new(None::<Rc<RichEditor>>);
    let reply = Rc::new(RefCell::new(None::<Value>));
    let phase = Cell::new(0);
    let started = Instant::now();
    let shots = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            started.elapsed() < Duration::from_secs(65),
            "typed-copy phase {}",
            phase.get()
        );
        let advance = |n| {
            eprintln!("Typed blank copy phase {n}");
            phase.set(n);
        };
        let select = |ed: &Rc<RichEditor>| {
            reply.borrow_mut().take();
            let result = reply.clone();
            ed.evaluate("const root=document.getElementById('fastra-visual'),n=Array.from(root.querySelectorAll('div,p')).find(n=>n.textContent==='g' && n.classList.contains('fastra-visible-blank-line')) || Array.from(root.querySelectorAll('div,p')).find(n=>n.textContent==='g');const r=document.createRange();r.selectNodeContents(n);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify({outer:n.outerHTML});",move|value|*result.borrow_mut()=value);
        };
        match phase.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&source_path))
                else {
                    return glib::ControlFlow::Continue;
                };
                mode_toggle(&doc, ui.lang).set_active(true);
                *source_doc.borrow_mut() = Some(doc);
                advance(1);
            }
            1 => {
                let Some(ed) = source_doc
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
                reply.borrow_mut().take();
                let result = reply.clone();
                ed.evaluate("const n=document.querySelector('.fastra-visible-blank-line'),r=document.createRange();r.selectNodeContents(n);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",move|value|*result.borrow_mut()=value);
                *source_editor.borrow_mut() = Some(ed);
                advance(2);
            }
            2 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(
                    &source_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["g"],
                );
                advance(3);
            }
            3 => {
                if !buffer_text(&source_doc.borrow().as_ref().unwrap().buffer).starts_with('g') {
                    return glib::ControlFlow::Continue;
                }
                select(source_editor.borrow().as_ref().unwrap());
                advance(4);
            }
            4 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                eprintln!("ACTUAL TYPED DOM {}", value["outer"]);
                std::fs::write(
                    root.join("typed-dom.json"),
                    serde_json::to_vec_pretty(&value).unwrap(),
                )
                .unwrap();
                gui_test::input(
                    &source_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+c"],
                );
                advance(5);
            }
            5 => {
                let ed = source_editor.borrow().clone().unwrap();
                if ed.clipboard_busy.get()
                    || !ed
                        .view
                        .clipboard()
                        .formats()
                        .contain_mime_type(clipboard::MIME)
                {
                    return glib::ControlFlow::Continue;
                }
                read_clipboard(&ed.view, &reply, true);
                advance(6);
            }
            6 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                let html = value["html"].as_str().unwrap();
                assert!(
                    html.contains(">g<") || html == "g",
                    "Typed user text lost from real Copy HTML: {html}"
                );
                assert!(!html.contains("fastra-visible-blank-line"));
                assert!(!html.contains("data-srcline"));
                assert_eq!(value["markdown"], "g");
                ui.load_path(receiver_path.clone());
                advance(7);
            }
            7 => {
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&receiver_path))
                else {
                    return glib::ControlFlow::Continue;
                };
                mode_toggle(&doc, ui.lang).set_active(true);
                *receiver_doc.borrow_mut() = Some(doc);
                advance(8);
            }
            8 => {
                let Some(ed) = receiver_doc
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
                let result = reply.clone();
                reply.borrow_mut().take();
                ed.evaluate("const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",move|value|*result.borrow_mut()=value);
                *receiver_editor.borrow_mut() = Some(ed);
                advance(9);
            }
            9 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(
                    &receiver_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+v"],
                );
                advance(10);
            }
            10 => {
                let pasted = buffer_text(&receiver_doc.borrow().as_ref().unwrap().buffer);
                if pasted.is_empty() {
                    return glib::ControlFlow::Continue;
                }
                eprintln!("ACTUAL TYPED PASTE BYTES {pasted:?}");
                // Der bestehende Serializer trennt neue Absätze mit zwei LF.
                assert_eq!(pasted, "g\n\n");
                let ed = receiver_editor.borrow().clone().unwrap();
                let result = reply.clone();
                reply.borrow_mut().take();
                ed.evaluate("return JSON.stringify({text:document.getElementById('fastra-visual').textContent,blank:document.querySelectorAll('.fastra-visible-blank-line').length});",move|value|*result.borrow_mut()=value);
                advance(11);
            }
            11 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["text"].as_str().unwrap().trim(), "g");
                assert_eq!(value["blank"], 0);
                gui_test::input(
                    &receiver_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+z"],
                );
                advance(12);
            }
            12 => {
                if !buffer_text(&receiver_doc.borrow().as_ref().unwrap().buffer).is_empty() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&receiver_path).unwrap(), "");
                gui_test::input(
                    &receiver_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+w"],
                );
                advance(13);
            }
            13 => {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, receiver_doc.borrow().as_ref().unwrap()))
                {
                    if let Some(button) = gtk::Window::list_toplevels().iter().find_map(|window| {
                        gui_test::button(
                            window,
                            ui.lang
                                .text("Ohne Speichern schließen", "Close without saving"),
                        )
                    }) {
                        gui_test::input(&button, true, &[]);
                        advance(14);
                    }
                    return glib::ControlFlow::Continue;
                }
                advance(14);
            }
            14 => {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, receiver_doc.borrow().as_ref().unwrap()))
                {
                    return glib::ControlFlow::Continue;
                }
                select(source_editor.borrow().as_ref().unwrap());
                advance(15);
            }
            15 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(
                    &source_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+x"],
                );
                advance(16);
            }
            16 => {
                let ed = source_editor.borrow().clone().unwrap();
                if buffer_text(&source_doc.borrow().as_ref().unwrap().buffer).starts_with('g')
                    || ed.clipboard_busy.get()
                {
                    return glib::ControlFlow::Continue;
                }
                read_clipboard(&ed.view, &reply, true);
                advance(17);
            }
            17 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                let html = value["html"].as_str().unwrap();
                assert!(
                    html.contains(">g<") || html == "g",
                    "Typed user text lost from real Cut HTML: {html}"
                );
                assert!(!html.contains("fastra-visible-blank-line"));
                gui_test::input(
                    &source_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+z"],
                );
                advance(18);
            }
            18 => {
                if !buffer_text(&source_doc.borrow().as_ref().unwrap().buffer).starts_with('g') {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(
                    &source_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+z"],
                );
                advance(19);
            }
            19 => {
                if buffer_text(&source_doc.borrow().as_ref().unwrap().buffer) != original {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&source_path).unwrap(), original);
                if !gui_test::capture(&ui.window, "typed-blank-undo", &shots) {
                    return glib::ControlFlow::Continue;
                }
                println!("PASS typed visible blank: actual DOM retains class+text, real Copy HTML/private Markdown and Paste retain user text, real Cut HTML/Undo preserve text, final Undo restores exact CRLF original source/disk");
                ui.discard_confirmed.set(true);
                ui.window.close();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
