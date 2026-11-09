use super::*;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
fn input(widget: &impl IsA<gtk::Widget>, click: bool, keys: &[&str]) {
    gui_test::input(widget, click, keys);
}
fn capture(
    window: &gtk::Window,
    name: &str,
    state: &RefCell<Option<std::sync::Arc<std::sync::atomic::AtomicI32>>>,
) -> bool {
    use std::sync::{
        atomic::{AtomicI32, Ordering},
        Arc,
    };
    let current = state.borrow().clone();
    if let Some(status) = current {
        match status.load(Ordering::SeqCst) {
            0 => return false,
            1 => {}
            _ => panic!("native X11 capture failed"),
        }
    } else {
        window.queue_draw();
        if let Some(clock) = window.frame_clock() {
            clock.request_phase(gtk::gdk::FrameClockPhase::PAINT);
        }
        let id = gui_test::xid(window);
        let path = PathBuf::from(std::env::var_os("FASTRA_RICH_SCREENSHOTS").unwrap())
            .join(format!("{name}.png"));
        let status = Arc::new(AtomicI32::new(0));
        *state.borrow_mut() = Some(status.clone());
        std::thread::spawn(move || {
            let moved = std::process::Command::new("xdotool")
                .args(["windowmove", "--sync", &id, "0", "0"])
                .status()
                .unwrap()
                .success();
            std::thread::sleep(Duration::from_millis(500));
            let captured = moved
                && std::process::Command::new("import")
                    .args(["-window", &id])
                    .arg(&path)
                    .status()
                    .unwrap()
                    .success();
            status.store(if captured { 1 } else { -1 }, Ordering::SeqCst);
        });
        return false;
    }
    state.borrow_mut().take();
    true
}
fn query(ed: &RichEditor, code: &str, answer: &Rc<RefCell<Option<Value>>>) {
    let reply = answer.clone();
    ed.evaluate(code, move |v| *reply.borrow_mut() = v);
}
fn select_pair(ed: &RichEditor, answer: &Rc<RefCell<Option<Value>>>) {
    query(ed,"const ps=[...document.querySelectorAll('#fastra-visual p')],a=ps.find(p=>p.textContent.endsWith(' after')),b=ps.find(p=>p.textContent.endsWith('Mixed after'));const r=document.createRange();r.setStartBefore(a);r.setEndAfter(b);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",answer);
}
fn select_tail(ed: &RichEditor, answer: &Rc<RefCell<Option<Value>>>) {
    query(ed,"const p=[...document.querySelectorAll('#fastra-visual p')].find(p=>p.textContent==='Tail');p.scrollIntoView({block:'center'});const r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",answer);
}
fn read_clipboard(
    ed: &RichEditor,
    root: PathBuf,
    label: &str,
    answer: &Rc<RefCell<Option<Value>>>,
) {
    let clipboard = ed.view.clipboard();
    let answer = answer.clone();
    let label = label.to_owned();
    glib::MainContext::default().spawn_local(async move {
        let mut values = serde_json::Map::new();
        for (mime, key, extension) in [
            (clipboard::MIME, "private", "json"),
            ("text/html", "html", "html"),
        ] {
            let (stream, actual) = clipboard
                .read_future(&[mime], glib::Priority::DEFAULT)
                .await
                .unwrap();
            assert_eq!(actual, mime);
            let mut bytes = Vec::new();
            loop {
                let chunk = stream
                    .read_bytes_future(8192, glib::Priority::DEFAULT)
                    .await
                    .unwrap();
                if chunk.is_empty() {
                    break;
                }
                bytes.extend_from_slice(&chunk);
                assert!(bytes.len() < 2 * MAX_BYTES);
            }
            std::fs::write(root.join(format!("math-{label}.{extension}")), &bytes).unwrap();
            values.insert(key.into(), Value::String(String::from_utf8(bytes).unwrap()));
        }
        let plain = clipboard
            .read_text_future()
            .await
            .unwrap()
            .unwrap()
            .to_string();
        std::fs::write(root.join(format!("math-{label}.txt")), plain.as_bytes()).unwrap();
        assert!(!plain.contains("FASTRARICHMATH"));
        values.insert("plain".into(), json!(plain));
        *answer.borrow_mut() = Some(Value::Object(values));
    });
}
fn source_view(root: &gtk::Widget) -> Option<sourceview5::View> {
    if let Some(view) = root
        .downcast_ref::<sourceview5::View>()
        .filter(|v| v.is_mapped())
    {
        return Some(view.clone());
    }
    let mut child = root.first_child();
    while let Some(node) = child {
        if let Some(view) = source_view(&node) {
            return Some(view);
        }
        child = node.next_sibling();
    }
    None
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(
        std::env::var("FASTRA_RICH_WIDTH")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1180),
        1000,
    );
    let root = PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    let eol = match std::env::var("FASTRA_MATH_EOL").as_deref() {
        Ok("cr") => "\r",
        Ok("lf") => "\n",
        _ => "\r\n",
    };
    let source="# Rich Math\n\nBefore ä🙂 $$x^2$$ after\n\nMixed before\n$$\na + b\n  \nc + d\n$$\nMixed after\n\nTail\n\n$$\n\\frac{a}{b}\n  \nc\n$$\n\n- List before $u$ after\n- Second\n\n> Quote before $v$ after\n\n| Cell | Value |\n| --- | --- |\n| keep | $a|b$ |\n| nested | before $`a|b`$ |\n\nNested before\n$$\n`code`\n$$\nNested after\n\nBad formula: $\\frac{$\n\n$`x`$\n\n$$\n`code`\n$$\n\nDas kostet $5 und $10 zusammen.\n\n![picture][$image$]\n\n[$image$]: pixel.png\n\n~~~text\n$x$\n~~~~\n\n<script>globalThis.richMathBad=true</script>\n".replace('\n',eol);
    let path = root.join("rich-math.md");
    let bom = std::env::var("FASTRA_RICH_WIDTH")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .is_some_and(|w| w > 1000);
    let encoded = move |text: &str| {
        let mut bytes = if bom {
            vec![0xef, 0xbb, 0xbf]
        } else {
            Vec::new()
        };
        bytes.extend_from_slice(text.as_bytes());
        bytes
    };
    std::fs::write(&path, encoded(&source)).unwrap();
    std::fs::write(
        root.join("pixel.png"),
        include_bytes!("../../tests/fixtures/pixel-1.png"),
    )
    .unwrap();
    ui.load_path(path.clone());
    ui.search_section.set_expanded(false);
    let stage = Cell::new(0);
    let answer = Rc::new(RefCell::new(None::<Value>));
    let document = RefCell::new(None::<Rc<Document>>);
    let editor = RefCell::new(None::<Rc<RichEditor>>);
    let began = Instant::now();
    let previous = Cell::new(u32::MAX);
    let entered = Cell::new(Instant::now());
    let close_fences = RefCell::new(None::<Rc<CloseFences>>);
    let nested_checks = RefCell::new(json!({}));
    let copied = RefCell::new(String::new());
    let receiver_doc = RefCell::new(None::<Rc<Document>>);
    let receiver_editor = RefCell::new(None::<Rc<RichEditor>>);
    let updated = RefCell::new(String::new());
    let saved = RefCell::new(String::new());
    let capture_pending = RefCell::new(None);

    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            began.elapsed() < Duration::from_secs(85),
            "rich Math gate timeout stage {}",
            stage.get()
        );
        if previous.get() != stage.get() {
            eprintln!("RICH_MATH_PHASE {}", stage.get());
            previous.set(stage.get());
            entered.set(Instant::now());
        }
        match stage.get() {
            0 => {
                if began.elapsed() < Duration::from_millis(500) {
                    return glib::ControlFlow::Continue;
                }
                let Some(doc) = ui.active().filter(|d| {
                    d.disk_path().as_ref() == Some(&path) && buffer_text(&d.buffer) == source
                }) else {
                    return glib::ControlFlow::Continue;
                };
                let toggle = mode_toggle(&doc, ui.lang);
                if !toggle.is_mapped() || toggle.width() <= 0 || toggle.height() <= 0 {
                    return glib::ControlFlow::Continue;
                }
                input(&toggle, true, &[]);
                *document.borrow_mut() = Some(doc);
                stage.set(1);
            }
            1 => {
                let doc = document.borrow().clone().unwrap();
                let Some(ed) = doc
                    .rich
                    .borrow()
                    .clone()
                    .filter(|e| e.ready.get() && e.active.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                let reply = answer.clone();
                ed.evaluate("return JSON.stringify({math:document.querySelectorAll('math').length,display:document.querySelectorAll('math[display=block]').length,errors:document.querySelectorAll('.katex-error').length,notices:document.querySelectorAll('.math-source-notice').length,images:[...document.querySelectorAll('img')].map(n=>n.complete&&n.naturalWidth>0),bad:typeof globalThis.richMathBad,source:fastraVisual.markdown()});",move|v|*reply.borrow_mut()=v);
                *editor.borrow_mut() = Some(ed);
                stage.set(2);
            }
            2 => {
                if let Some(v) = answer.borrow_mut().take() {
                    eprintln!("RICH_MATH_GATE_DOM {}", v);
                    assert_eq!(v["math"], 6);
                    assert_eq!(v["display"], 2);
                    assert_eq!(v["errors"], 1);
                    assert_eq!(v["notices"], 4);
                    assert_eq!(v["images"], json!([true]));
                    assert_eq!(v["bad"], "undefined");
                    assert!(document.borrow().as_ref().unwrap().source_edits_locked());
                    assert_eq!(v["source"], source);
                    let reply = answer.clone();
                    editor.borrow().as_ref().unwrap().evaluate("const p=[...document.querySelectorAll('#fastra-visual p')].find(p=>p.textContent.endsWith(' after'));p.scrollIntoView({block:'center'});const r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",move|v|*reply.borrow_mut()=v);
                    stage.set(3);
                }
            }
            3 => {
                if answer.borrow_mut().take().is_some() {
                    input(&editor.borrow().as_ref().unwrap().view, false, &["x"]);
                    stage.set(4);
                }
            }
            4 => {
                let doc = document.borrow().clone().unwrap();
                let text = buffer_text(&doc.buffer);
                if text == source {
                    return glib::ControlFlow::Continue;
                }
                eprintln!("RICH_MATH_GATE_EDIT {:?}", text);
                assert_eq!(text, source.replacen(" after", " afterx", 1));
                let ed = editor.borrow().clone().unwrap();
                input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                        .unwrap(),
                    true,
                    &[],
                );
                stage.set(5);
            }
            5 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                let reply = answer.clone();
                editor.borrow().as_ref().unwrap().evaluate("const p=[...document.querySelectorAll('#fastra-visual p')].find(p=>p.textContent.endsWith('Mixed after'));p.scrollIntoView({block:'center'});const r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",move|v|*reply.borrow_mut()=v);
                stage.set(6);
            }
            6 => {
                if answer.borrow_mut().take().is_some() {
                    input(&editor.borrow().as_ref().unwrap().view, false, &["x"]);
                    stage.set(7);
                }
            }
            7 => {
                let text = buffer_text(&document.borrow().as_ref().unwrap().buffer);
                if text == source {
                    return glib::ControlFlow::Continue;
                }
                eprintln!("RICH_MATH_GATE_MIXED_EDIT {:?}", text);
                assert_eq!(text, source.replacen("Mixed after", "Mixed afterx", 1));
                let ed = editor.borrow().clone().unwrap();
                input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                        .unwrap(),
                    true,
                    &[],
                );
                stage.set(8);
            }
            8 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&path).unwrap(), encoded(&source));
                let fences = CloseFences::new();
                *close_fences.borrow_mut() = Some(fences.clone());
                let reply = answer.clone();
                flush_close(
                    &ui,
                    fences,
                    Box::new(move |ok| *reply.borrow_mut() = Some(json!(ok))),
                );
                stage.set(9);
            }
            9 => {
                if let Some(value) = answer.borrow_mut().take() {
                    assert_eq!(value, true);
                    query(editor.borrow().as_ref().unwrap(),"return JSON.stringify({editable:document.getElementById('fastra-visual').isContentEditable,atoms:[...document.querySelectorAll('[data-tex]')].every(n=>n.contentEditable==='false')});",&answer);
                    stage.set(10);
                }
            }
            10 => {
                if let Some(value) = answer.borrow_mut().take() {
                    assert_eq!(value["editable"], false);
                    assert_eq!(value["atoms"], true);
                    input(&editor.borrow().as_ref().unwrap().view, false, &["z"]);
                    stage.set(11);
                }
            }
            11 if entered.get().elapsed() > Duration::from_millis(300) => {
                assert_eq!(
                    buffer_text(&document.borrow().as_ref().unwrap().buffer),
                    source
                );
                close_fences.borrow_mut().take().unwrap().cancel();
                query(editor.borrow().as_ref().unwrap(),"await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return JSON.stringify(document.getElementById('fastra-visual').isContentEditable);",&answer);
                stage.set(12);
            }
            12 => {
                if let Some(value) = answer.borrow_mut().take() {
                    assert_eq!(value, true);
                    select_pair(editor.borrow().as_ref().unwrap(), &answer);
                    stage.set(13);
                }
            }
            13 => {
                if answer.borrow_mut().take().is_some() {
                    input(&editor.borrow().as_ref().unwrap().view, false, &["ctrl+c"]);
                    stage.set(14);
                }
            }
            14 if entered.get().elapsed() > Duration::from_millis(350) => {
                read_clipboard(
                    editor.borrow().as_ref().unwrap(),
                    root.clone(),
                    "copy",
                    &answer,
                );
                stage.set(15);
            }
            15 => {
                if let Some(value) = answer.borrow_mut().take() {
                    let html = value["html"].as_str().unwrap();
                    assert_eq!(html.matches("<math").count(), 2);
                    assert!(!html.contains("data-md-"));
                    assert!(!html.contains("FASTRARICHMATH"));
                    let payload: Value =
                        serde_json::from_str(value["private"].as_str().unwrap()).unwrap();
                    let markdown = payload["markdown"].as_str().unwrap();
                    assert!(markdown.contains("$$x^2$$"));
                    assert!(markdown.contains(&format!("$${eol}a + b{eol}  {eol}c + d{eol}$$")));
                    *copied.borrow_mut() = markdown.to_owned();
                    assert_eq!(
                        buffer_text(&document.borrow().as_ref().unwrap().buffer),
                        source
                    );
                    select_pair(editor.borrow().as_ref().unwrap(), &answer);
                    stage.set(16);
                }
            }
            16 => {
                if answer.borrow_mut().take().is_some() {
                    input(&editor.borrow().as_ref().unwrap().view, false, &["ctrl+x"]);
                    stage.set(17);
                }
            }
            17 => {
                let text = buffer_text(&document.borrow().as_ref().unwrap().buffer);
                if text == source {
                    return glib::ControlFlow::Continue;
                }
                assert!(!text.contains("Before ä🙂"));
                assert!(!text.contains("Mixed before"));
                read_clipboard(
                    editor.borrow().as_ref().unwrap(),
                    root.clone(),
                    "cut",
                    &answer,
                );
                stage.set(18);
            }
            18 => {
                if let Some(value) = answer.borrow_mut().take() {
                    let payload: Value =
                        serde_json::from_str(value["private"].as_str().unwrap()).unwrap();
                    assert_eq!(payload["markdown"].as_str().unwrap(), *copied.borrow());
                    assert_eq!(value["html"].as_str().unwrap().matches("<math").count(), 2);
                    let ed = editor.borrow().clone().unwrap();
                    input(
                        &gui_test::button(
                            ed.widget.upcast_ref(),
                            ui.lang.text("Rückgängig", "Undo"),
                        )
                        .unwrap(),
                        true,
                        &[],
                    );
                    stage.set(19);
                }
            }
            19 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                select_tail(editor.borrow().as_ref().unwrap(), &answer);
                stage.set(20);
            }
            20 => {
                if answer.borrow_mut().take().is_some() {
                    input(&editor.borrow().as_ref().unwrap().view, false, &["ctrl+v"]);
                    stage.set(21);
                }
            }
            21 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) == source {
                    return glib::ControlFlow::Continue;
                }
                query(editor.borrow().as_ref().unwrap(),"await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return JSON.stringify({math:document.querySelectorAll('math').length,source:fastraVisual.markdown()});",&answer);
                stage.set(22);
            }
            22 => {
                if let Some(value) = answer.borrow_mut().take() {
                    assert_eq!(value["math"], 8);
                    assert!(value["source"]
                        .as_str()
                        .unwrap()
                        .contains(&format!("$${eol}a + b{eol}  {eol}c + d{eol}$$")));
                    let ed = editor.borrow().clone().unwrap();
                    input(
                        &gui_test::button(
                            ed.widget.upcast_ref(),
                            ui.lang.text("Rückgängig", "Undo"),
                        )
                        .unwrap(),
                        true,
                        &[],
                    );
                    stage.set(23);
                }
            }
            23 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                ui.add_document("math-paste.md", "");
                stage.set(70);
            }
            70 => {
                if entered.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let Some(doc) = ui.active().filter(|d| {
                    d.disk_path().is_none() && !Rc::ptr_eq(d, document.borrow().as_ref().unwrap())
                }) else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(buffer_text(&doc.buffer), "");
                let toggle = mode_toggle(&doc, ui.lang);
                if !toggle.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                input(&toggle, true, &[]);
                *receiver_doc.borrow_mut() = Some(doc);
                stage.set(71);
            }
            71 => {
                let doc = receiver_doc.borrow().clone().unwrap();
                let Some(ed) = doc
                    .rich
                    .borrow()
                    .clone()
                    .filter(|e| e.active.get() && e.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                query(&ed,"const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&answer);
                *receiver_editor.borrow_mut() = Some(ed);
                stage.set(72);
            }
            72 => {
                if answer.borrow_mut().take().is_some() {
                    input(
                        &receiver_editor.borrow().as_ref().unwrap().view,
                        false,
                        &["ctrl+v"],
                    );
                    stage.set(73);
                }
            }
            73 => {
                if buffer_text(&receiver_doc.borrow().as_ref().unwrap().buffer).is_empty() {
                    return glib::ControlFlow::Continue;
                }
                query(receiver_editor.borrow().as_ref().unwrap(),"await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return JSON.stringify({math:document.querySelectorAll('math').length,source:fastraVisual.markdown()});",&answer);
                stage.set(74);
            }
            74 => {
                if let Some(value) = answer.borrow_mut().take() {
                    eprintln!("RICH_MATH_EMPTY_PASTE {}", value);
                    assert_eq!(value["math"], 2);
                    assert!(value["source"].as_str().unwrap().contains("$$x^2$$"));
                    assert!(value["source"]
                        .as_str()
                        .unwrap()
                        .contains(&format!("$${eol}a + b{eol}  {eol}c + d{eol}$$")));
                    let ed = receiver_editor.borrow().clone().unwrap();
                    input(
                        &gui_test::button(
                            ed.widget.upcast_ref(),
                            ui.lang.text("Rückgängig", "Undo"),
                        )
                        .unwrap(),
                        true,
                        &[],
                    );
                    stage.set(75);
                }
            }
            75 => {
                if !buffer_text(&receiver_doc.borrow().as_ref().unwrap().buffer).is_empty() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    buffer_text(&document.borrow().as_ref().unwrap().buffer),
                    source
                );
                input(
                    &receiver_editor.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+w"],
                );
                stage.set(76);
            }
            76 | 77 => {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, receiver_doc.borrow().as_ref().unwrap()))
                {
                    if stage.get() == 76 {
                        let label = ui
                            .lang
                            .text("Ohne Speichern schließen", "Close without saving");
                        if let Some(button) = gtk::Window::list_toplevels()
                            .iter()
                            .find_map(|w| gui_test::button(w, label))
                        {
                            assert!(buffer_text(&receiver_doc.borrow().as_ref().unwrap().buffer)
                                .is_empty());
                            assert_eq!(
                                buffer_text(&document.borrow().as_ref().unwrap().buffer),
                                source
                            );
                            assert_eq!(std::fs::read(&path).unwrap(), encoded(&source));
                            input(&button, true, &[]);
                            stage.set(77);
                        }
                    }
                    return glib::ControlFlow::Continue;
                }
                let index = ui
                    .documents
                    .borrow()
                    .iter()
                    .position(|d| Rc::ptr_eq(d, document.borrow().as_ref().unwrap()))
                    .unwrap();
                ui.tabs.set_current_page(Some(index as u32));
                query(editor.borrow().as_ref().unwrap(),"const p=[...document.querySelectorAll('#fastra-visual p')].find(p=>p.textContent.endsWith(' after')),t=p.firstChild,r=document.createRange();r.setStart(t,0);r.setEnd(t,t.length-1);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&answer);
                stage.set(60);
            }
            60 => {
                if answer.borrow_mut().take().is_some() {
                    let ed = editor.borrow().clone().unwrap();
                    input(
                        &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Fett", "Bold"))
                            .unwrap(),
                        true,
                        &[],
                    );
                    stage.set(61);
                }
            }
            61 => {
                let text = buffer_text(&document.borrow().as_ref().unwrap().buffer);
                if text == source {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(text, source.replacen("Before ä🙂", "**Before ä🙂**", 1));
                let ed = editor.borrow().clone().unwrap();
                input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                        .unwrap(),
                    true,
                    &[],
                );
                stage.set(62);
            }
            62 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                query(editor.borrow().as_ref().unwrap(),"const p=[...document.querySelectorAll('li')].find(p=>p.textContent.endsWith(' after'));p.scrollIntoView({block:'center'});const r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&answer);
                stage.set(63);
            }
            63 => {
                if answer.borrow_mut().take().is_some() {
                    input(&editor.borrow().as_ref().unwrap().view, false, &["l"]);
                    stage.set(64);
                }
            }
            64 => {
                let text = buffer_text(&document.borrow().as_ref().unwrap().buffer);
                if text == source {
                    return glib::ControlFlow::Continue;
                }
                assert!(text.contains("List before $u$ afterl"));
                assert_eq!(text.matches("$u$").count(), 1);
                let ed = editor.borrow().clone().unwrap();
                input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                        .unwrap(),
                    true,
                    &[],
                );
                stage.set(65);
            }
            65 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                query(editor.borrow().as_ref().unwrap(),"const p=[...document.querySelectorAll('td')].find(p=>p.textContent==='keep');p.scrollIntoView({block:'center'});const r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&answer);
                stage.set(66);
            }
            66 => {
                if answer.borrow_mut().take().is_some() {
                    input(&editor.borrow().as_ref().unwrap().view, false, &["t"]);
                    stage.set(67);
                }
            }
            67 => {
                let text = buffer_text(&document.borrow().as_ref().unwrap().buffer);
                if text == source {
                    return glib::ControlFlow::Continue;
                }
                assert!(text.contains("| keept | $a|b$ |"), "{text:?}");
                assert_eq!(text.matches("$a|b$").count(), 1);
                let ed = editor.borrow().clone().unwrap();
                input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                        .unwrap(),
                    true,
                    &[],
                );
                stage.set(68);
            }
            68 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                query(editor.borrow().as_ref().unwrap(),"const cell=[...document.querySelectorAll('td')].find(n=>n.querySelector('.math-source')),t=cell.firstChild,r=document.createRange();cell.scrollIntoView({block:'center'});r.setStart(t,2);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&answer);
                stage.set(90);
            }
            90 => {
                if answer.borrow_mut().take().is_some() {
                    input(&editor.borrow().as_ref().unwrap().view, false, &["x"]);
                    stage.set(91);
                }
            }
            91 => {
                let text = buffer_text(&document.borrow().as_ref().unwrap().buffer);
                if text == source {
                    return glib::ControlFlow::Continue;
                }
                let exact = text.contains("bexfore")
                    && text.contains("$`a|b`$")
                    && !text.contains("$`a\\|b`$");
                nested_checks.borrow_mut()["table"] = json!(exact);
                eprintln!("NESTED_TABLE_EDIT exact={exact} source={text:?}");
                let ed = editor.borrow().clone().unwrap();
                input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                        .unwrap(),
                    true,
                    &[],
                );
                stage.set(92);
            }
            92 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                query(editor.borrow().as_ref().unwrap(),"const p=[...document.querySelectorAll('#fastra-visual p')].find(n=>n.textContent.startsWith('Nested before')),t=p.firstChild,r=document.createRange();p.scrollIntoView({block:'center'});r.setStart(t,1);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&answer);
                stage.set(93);
            }
            93 => {
                if answer.borrow_mut().take().is_some() {
                    input(&editor.borrow().as_ref().unwrap().view, false, &["x"]);
                    stage.set(94);
                }
            }
            94 => {
                let text = buffer_text(&document.borrow().as_ref().unwrap().buffer);
                if text == source {
                    return glib::ControlFlow::Continue;
                }
                let exact = text == source.replacen("Nested before", "Nxested before", 1);
                nested_checks.borrow_mut()["mixed"] = json!(exact);
                eprintln!("NESTED_MIXED_EDIT exact={exact} source={text:?}");
                let ed = editor.borrow().clone().unwrap();
                input(
                    &gui_test::button(ed.widget.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                        .unwrap(),
                    true,
                    &[],
                );
                stage.set(95);
            }
            95 => {
                if buffer_text(&document.borrow().as_ref().unwrap().buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                eprintln!("NESTED_REGRESSIONS {}", nested_checks.borrow());
                assert_eq!(*nested_checks.borrow(), json!({"table":true,"mixed":true}));
                input(
                    &mode_toggle(document.borrow().as_ref().unwrap(), ui.lang),
                    true,
                    &[],
                );
                stage.set(24);
            }
            24 => {
                let doc = document.borrow().clone().unwrap();
                if doc.rich.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!doc.source_edits_locked());
                let Some(view) = source_view(ui.window.child().unwrap().upcast_ref()) else {
                    return glib::ControlFlow::Continue;
                };
                view.grab_focus();
                let at = source[..source.find("x^2").unwrap()].chars().count() as i32;
                doc.buffer.select_range(
                    &doc.buffer.iter_at_offset(at),
                    &doc.buffer.iter_at_offset(at + 1),
                );
                input(&view, false, &["r"]);
                stage.set(25);
            }
            25 => {
                let doc = document.borrow().clone().unwrap();
                let text = buffer_text(&doc.buffer);
                if text == source {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(text, source.replacen("$$x^2$$", "$$r^2$$", 1));
                *updated.borrow_mut() = text;
                input(&mode_toggle(&doc, ui.lang), true, &[]);
                stage.set(26);
            }
            26 => {
                let doc = document.borrow().clone().unwrap();
                let Some(ed) = doc
                    .rich
                    .borrow()
                    .clone()
                    .filter(|e| e.active.get() && e.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                query(&ed,"return JSON.stringify({math:document.querySelectorAll('math').length,tex:[...document.querySelectorAll('[data-tex]')].map(n=>n.dataset.tex),source:fastraVisual.markdown()});",&answer);
                *editor.borrow_mut() = Some(ed);
                stage.set(27);
            }
            27 => {
                if let Some(value) = answer.borrow_mut().take() {
                    assert_eq!(value["math"], 6);
                    assert_eq!(value["tex"][0], "r^2");
                    assert_eq!(value["source"].as_str().unwrap(), *updated.borrow());
                    query(editor.borrow().as_ref().unwrap(),"scrollTo(0,0);await new Promise(r=>setTimeout(r,200));return JSON.stringify(true);",&answer);
                    stage.set(28);
                }
            }
            28 => {
                if answer.borrow_mut().take().is_some() {
                    stage.set(29);
                }
            }
            29 => {
                if !capture(ui.window.upcast_ref(), "rich-math-top", &capture_pending) {
                    return glib::ControlFlow::Continue;
                }
                query(editor.borrow().as_ref().unwrap(),"document.querySelector('ul').scrollIntoView({block:'start'});scrollTo(0,scrollY);await new Promise(r=>setTimeout(r,200));return JSON.stringify(true);",&answer);
                stage.set(50);
            }
            50 => {
                if answer.borrow_mut().take().is_some() {
                    stage.set(51);
                }
            }
            51 => {
                if !capture(
                    ui.window.upcast_ref(),
                    "rich-math-structures",
                    &capture_pending,
                ) {
                    return glib::ControlFlow::Continue;
                }
                query(editor.borrow().as_ref().unwrap(),"document.querySelector('.math-source').scrollIntoView({block:'center'});scrollTo(0,scrollY);await new Promise(r=>setTimeout(r,200));return JSON.stringify(true);",&answer);
                stage.set(52);
            }
            52 => {
                if answer.borrow_mut().take().is_some() {
                    stage.set(53);
                }
            }
            53 => {
                if !capture(
                    ui.window.upcast_ref(),
                    "rich-math-source-notice",
                    &capture_pending,
                ) {
                    return glib::ControlFlow::Continue;
                }
                select_tail(editor.borrow().as_ref().unwrap(), &answer);
                stage.set(30);
            }
            30 => {
                if answer.borrow_mut().take().is_some() {
                    input(&editor.borrow().as_ref().unwrap().view, false, &["q"]);
                    stage.set(31);
                }
            }
            31 => {
                let doc = document.borrow().clone().unwrap();
                let text = buffer_text(&doc.buffer);
                if text == *updated.borrow() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(text, updated.borrow().replacen("Tail", "Tailq", 1));
                *saved.borrow_mut() = text;
                input(&ui.window, false, &["ctrl+s"]);
                stage.set(32);
            }
            32 => {
                let doc = document.borrow().clone().unwrap();
                if doc.saving.get()
                    || doc.buffer.is_modified()
                    || std::fs::read(&path).unwrap() != encoded(&saved.borrow())
                {
                    return glib::ControlFlow::Continue;
                }
                input(&editor.borrow().as_ref().unwrap().view, false, &["ctrl+w"]);
                stage.set(33);
            }
            33 => {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, document.borrow().as_ref().unwrap()))
                {
                    return glib::ControlFlow::Continue;
                }
                ui.load_path(path.clone());
                stage.set(34);
            }
            34 => {
                let Some(doc) = ui.active().filter(|d| {
                    d.disk_path().as_ref() == Some(&path)
                        && buffer_text(&d.buffer) == *saved.borrow()
                }) else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!Rc::ptr_eq(&doc, document.borrow().as_ref().unwrap()));
                input(&mode_toggle(&doc, ui.lang), true, &[]);
                *document.borrow_mut() = Some(doc);
                stage.set(35);
            }
            35 => {
                let doc = document.borrow().clone().unwrap();
                let Some(ed) = doc
                    .rich
                    .borrow()
                    .clone()
                    .filter(|e| e.active.get() && e.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                query(&ed,"return JSON.stringify({math:document.querySelectorAll('math').length,tex:[...document.querySelectorAll('[data-tex]')].map(n=>n.dataset.tex),source:fastraVisual.markdown(),images:[...document.querySelectorAll('img')].map(n=>n.complete&&n.naturalWidth>0)});",&answer);
                *editor.borrow_mut() = Some(ed);
                stage.set(36);
            }
            36 => {
                if let Some(value) = answer.borrow_mut().take() {
                    assert_eq!(value["math"], 6);
                    assert_eq!(value["tex"][0], "r^2");
                    assert_eq!(value["source"].as_str().unwrap(), *saved.borrow());
                    assert_eq!(value["images"], json!([true]));
                    eprintln!("RICH_MATH_REOPEN {}", value);
                    query(editor.borrow().as_ref().unwrap(),"scrollTo(0,0);await new Promise(r=>setTimeout(r,200));return JSON.stringify(true);",&answer);
                    stage.set(37);
                }
            }
            37 => {
                if answer.borrow_mut().take().is_some() {
                    stage.set(38);
                }
            }
            38 => {
                if !capture(
                    ui.window.upcast_ref(),
                    "rich-math-reopened",
                    &capture_pending,
                ) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&path).unwrap(), encoded(&saved.borrow()));
                println!("PASS Rich Math complete: six genuine MathML incl table/list/quote/internal blank+visible error/source notice; actual same-paragraph/Bold/list/table+nested pipe/mixed edits+Undo, close-fence blocked input+release, real Copy/Cut/Paste into current and initially empty Rich MIME+MathML+Undo, native Source edit+Rich resync, Save+close+reopen exact EOL/UTF8/BOM/Math source");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
