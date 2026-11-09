use super::*;
use std::time::Instant;
fn xid(view: &impl IsA<gtk::Widget>) -> String {
    let native = view.native().unwrap();
    let surface = native.surface().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let getter: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    unsafe { getter(surface.as_ptr().cast()) }.to_string()
}
fn input(view: &impl IsA<gtk::Widget>, x: f64, y: f64, keys: Option<&str>) {
    let native = view.native().unwrap();
    let id = xid(view);
    let point = view
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(x as f32, y as f32),
        )
        .unwrap();
    let (sx, sy) = native.surface_transform();
    let mut args = vec![
        "windowmove".into(),
        "--sync".into(),
        id.clone(),
        "0".into(),
        "0".into(),
        "windowraise".into(),
        id.clone(),
        "windowfocus".into(),
        "--sync".into(),
        id.clone(),
    ];
    if let Some(keys) = keys {
        args.extend(["key".into(), keys.into()]);
    } else {
        args.extend([
            "mousemove".into(),
            "--window".into(),
            id,
            (point.x() as f64 - sx).round().to_string(),
            (point.y() as f64 - sy).round().to_string(),
            "click".into(),
            "1".into(),
        ]);
    }
    std::thread::spawn(move || {
        assert!(std::process::Command::new("timeout")
            .args(["5s", "xdotool"])
            .args(args)
            .status()
            .unwrap()
            .success());
    });
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
        let id = xid(window);
        let path = PathBuf::from(std::env::var_os("FASTRA_TOOL_SCREENSHOTS").unwrap())
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
fn text_point(text: &str) -> String {
    format!("const word={};const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n;while((n=walker.nextNode())){{const at=n.textContent.indexOf(word);if(at<0||n.parentElement.closest('script'))continue;n.parentElement.scrollIntoView({{block:'center'}});await new Promise(r=>setTimeout(r,120));const range=document.createRange();range.setStart(n,at);range.setEnd(n,at+1);const r=range.getBoundingClientRect();return JSON.stringify({{x:r.x+.1,y:r.y+r.height/2}});}}return JSON.stringify(null);",serde_json::json!(text))
}
fn query(preview: &MarkdownView, script: &str, answer: &Rc<RefCell<Option<serde_json::Value>>>) {
    let answer = answer.clone();
    preview.inspect(script, move |v| *answer.borrow_mut() = Some(v));
}
fn read_html(
    preview: &MarkdownView,
    root: PathBuf,
    answer: &Rc<RefCell<Option<serde_json::Value>>>,
) {
    let clipboard = preview.view.clipboard();
    let answer = answer.clone();
    glib::MainContext::default().spawn_local(async move {
        let (stream, mime) = clipboard
            .read_future(&["text/html"], glib::Priority::DEFAULT)
            .await
            .unwrap();
        assert_eq!(mime, "text/html");
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
            assert!(bytes.len() < 128 * 1024);
        }
        std::fs::write(root.join("math-copy.html"), &bytes).unwrap();
        eprintln!("NATIVE_CLIPBOARD_HTML_BYTES {}", bytes.len());
        *answer.borrow_mut() = Some(serde_json::json!(String::from_utf8(bytes).unwrap()));
    });
}
fn find_button(root: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(button) = root
        .downcast_ref::<gtk::Button>()
        .filter(|b| b.is_mapped() && b.label().as_deref() == Some(label))
    {
        return Some(button.clone());
    }
    let mut child = root.first_child();
    while let Some(node) = child {
        if let Some(button) = find_button(&node, label) {
            return Some(button);
        }
        child = node.next_sibling();
    }
    None
}
pub(super) fn start(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(
        std::env::var("FASTRA_TOOL_WIDTH").unwrap().parse().unwrap(),
        1100,
    );
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("math-static.md");
    let lf="# Math parity\n\n==Before== ä🙂 and $x^2$ then TAIL SAME\n\n$$\n\\begin{aligned}\na &= b \\\\\n  \nc &= d\n\\end{aligned}\n$$\n\n  \n## After ==Mark==\n\nAFTER TARGET 雪🙂\n\nBad formula: $\\frac{$\n\n$`x`$\n\n$$\n`code`\n$$\n\n```swift\nlet text = \"ä🙂 <&>\";\n  \n$x$\n```\n\n~~~text\n==literal==\n~~~\n\n```md\n# hidden\n![fake](missing.png)\n```\n\n![picture][p]\n\n[p]: pixel.png\n\nMixed before\n$$\nu + v\n\nw + z\n$$\nMixed after target\n";
    let eol = if std::env::var("FASTRA_MATH_EOL").as_deref() == Ok("cr") {
        "\r"
    } else {
        "\r\n"
    };
    let review = std::env::var_os("FASTRA_MATH_STATIC_REVIEW_SELFTEST").is_some();
    let mut source = lf.replace('\n', eol);
    if review {
        source.push_str(&"\n![alt $x$](FASTRAMATH00000000000000000000000000000000TOKEN.png)\n\n![picture][$id$]\n\n[$id$]: pixel.png\n\n~~~text\n$$\ninside\n~~~~\noutside-boundary\n$$\n".replace('\n', eol));
        std::fs::write(
            root.join("FASTRAMATH00000000000000000000000000000000TOKEN.png"),
            include_bytes!("../../tests/fixtures/pixel-1.png"),
        )
        .unwrap();
    }
    std::fs::write(&path, &source).unwrap();
    std::fs::write(
        root.join("pixel.png"),
        include_bytes!("../../tests/fixtures/pixel-1.png"),
    )
    .unwrap();
    ui.load_path(path.clone());
    let doc_slot = RefCell::new(None::<Rc<Document>>);
    let preview_slot = RefCell::new(None::<Rc<MarkdownView>>);
    let answer = Rc::new(RefCell::new(None::<serde_json::Value>));
    let stage = Cell::new(0u32);
    let previous = Cell::new(u32::MAX);
    let code_index = Cell::new(0usize);
    let code_texts = RefCell::new(Vec::<String>::new());
    let expected_cursor = Cell::new(0);
    let revision = Cell::new(0);
    let rich_slot = RefCell::new(None::<Rc<crate::rich_editor::RichEditor>>);
    let saved = RefCell::new(String::new());
    let capture_state = RefCell::new(None);
    let started = Instant::now();
    let entered = Cell::new(started);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            started.elapsed() < Duration::from_secs(65),
            "math stage {} status {}",
            stage.get(),
            ui.status.text()
        );
        if previous.replace(stage.get()) != stage.get() {
            eprintln!("math native stage {}", stage.get());
            entered.set(Instant::now());
        }
        match stage.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                doc.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                revision.set(doc.revision.get());
                *doc_slot.borrow_mut() = Some(doc.clone());
                *preview_slot.borrow_mut() = doc.markdown.borrow().clone();
                stage.set(1);
            }
            1 => {
                let preview = preview_slot.borrow().clone().unwrap();
                let doc = doc_slot.borrow().clone().unwrap();
                if preview.print_token(doc.revision.get()).is_none() {
                    return glib::ControlFlow::Continue;
                }
                query(&preview,"if(!window.fastraPreviewReady||!document.documentElement.dataset.fastraPositionEpoch)return JSON.stringify(null);await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));await new Promise(r=>setTimeout(r,120));scrollTo(0,0);return JSON.stringify({math:document.querySelectorAll('math').length,block:document.querySelectorAll('math[display=block]').length,errors:document.querySelectorAll('.katex-error').length,tex:document.querySelectorAll('[data-tex]').length,notices:[...document.querySelectorAll('.math-source-notice')].map(n=>n.textContent),source:[...document.querySelectorAll('.math-source')].map(n=>n.textContent),codes:[...document.querySelectorAll('pre>code')].map(n=>n.textContent),headings:document.querySelectorAll('h1,h2').length,blank:document.querySelectorAll('.fastra-visible-blank-line').length,images:document.querySelectorAll('img').length,marks:document.querySelectorAll('mark').length,overflow:document.documentElement.scrollWidth<=innerWidth+1,internals:document.body.innerText.includes('FASTRACODE')});",&answer);
                stage.set(2);
            }
            2 => {
                if let Some(v) = answer.borrow_mut().take() {
                    if v.is_null() {
                        stage.set(1);
                        return glib::ControlFlow::Continue;
                    }
                    eprintln!("MATH_DOM {}", v);
                    assert_eq!(v["math"], 3);
                    assert_eq!(v["block"], 2);
                    assert_eq!(v["errors"], 1);
                    assert_eq!(v["tex"], 4);
                    assert_eq!(v["headings"], 2);
                    assert_eq!(v["blank"], 1);
                    assert_eq!(v["images"], if review { 3 } else { 1 });
                    assert_eq!(v["marks"], 2);
                    assert_eq!(v["overflow"], true);
                    assert_eq!(v["internals"], false);
                    let notice = ui.lang.text(
                        "Formel mit eingebettetem Code bleibt als Quelltext erhalten",
                        "Formula with embedded code is preserved as source text",
                    );
                    assert_eq!(v["notices"], serde_json::json!([notice, notice]));
                    assert_eq!(v["source"][0], "$`x`$");
                    *code_texts.borrow_mut() = v["codes"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|s| s.as_str().unwrap().to_owned())
                        .collect();
                    assert_eq!(code_texts.borrow().len(), if review { 4 } else { 3 });
                    if review {
                        assert_eq!(code_texts.borrow()[3], "$$\ninside\n");
                    }
                    assert_eq!(code_texts.borrow()[1], "==literal==\n");
                    if !capture(ui.window.upcast_ref(), "math-static-top", &capture_state) {
                        stage.set(1);
                        return glib::ControlFlow::Continue;
                    }
                    stage.set(3);
                }
            }
            3 => {
                let preview = preview_slot.borrow().clone().unwrap();
                let i = code_index.get();
                query(&preview,&format!("const p=document.querySelectorAll('pre[data-fastra-code]')[{i}];p.scrollIntoView({{block:'center'}});await new Promise(r=>setTimeout(r,150));const b=document.querySelectorAll('.fastra-code-copy')[{i}],r=b.getBoundingClientRect();return JSON.stringify({{x:r.x+16,y:r.y+16,visible:!b.hidden}});"),&answer);
                stage.set(4);
            }
            4 => {
                if let Some(v) = answer.borrow_mut().take() {
                    assert_eq!(v["visible"], true);
                    let preview = preview_slot.borrow().clone().unwrap();
                    preview.view.clipboard().set_text("math-copy-sentinel");
                    input(
                        &preview.view,
                        v["x"].as_f64().unwrap(),
                        v["y"].as_f64().unwrap(),
                        None,
                    );
                    stage.set(5);
                }
            }
            5 if entered.get().elapsed() > Duration::from_millis(350) => {
                let preview = preview_slot.borrow().clone().unwrap();
                let reply = answer.clone();
                let clipboard = preview.view.clipboard();
                glib::MainContext::default().spawn_local(async move {
                    *reply.borrow_mut() = Some(serde_json::json!(clipboard
                        .read_text_future()
                        .await
                        .unwrap()
                        .unwrap()
                        .to_string()));
                });
                stage.set(6);
            }
            6 => {
                if let Some(v) = answer.borrow_mut().take() {
                    assert_eq!(
                        v.as_str(),
                        Some(code_texts.borrow()[code_index.get()].as_str())
                    );
                    if code_index.get() + 1 < code_texts.borrow().len() {
                        code_index.set(code_index.get() + 1);
                        stage.set(3)
                    } else {
                        stage.set(7)
                    }
                }
            }
            7 => {
                let preview = preview_slot.borrow().clone().unwrap();
                expected_cursor.set(source[..source.find("$$").unwrap()].chars().count() as i32);
                query(&preview,"const m=document.querySelector('.math-block math');m.scrollIntoView({block:'center'});await new Promise(r=>setTimeout(r,120));const r=m.getBoundingClientRect();return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2});",&answer);
                stage.set(8);
            }
            8 => {
                if let Some(v) = answer.borrow_mut().take() {
                    let p = preview_slot.borrow().clone().unwrap();
                    input(
                        &p.view,
                        v["x"].as_f64().unwrap(),
                        v["y"].as_f64().unwrap(),
                        None,
                    );
                    stage.set(9)
                }
            }
            9 => {
                let doc = doc_slot.borrow().clone().unwrap();
                if doc.buffer.cursor_position() != expected_cursor.get() {
                    return glib::ControlFlow::Continue;
                }
                let preview = preview_slot.borrow().clone().unwrap();
                expected_cursor.set(source[..source.find("$x^2$").unwrap()].chars().count() as i32);
                query(&preview,"const m=document.querySelector('.math-inline math');m.scrollIntoView({block:'center'});await new Promise(r=>setTimeout(r,120));const r=m.getBoundingClientRect();return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2});",&answer);
                stage.set(10);
            }
            10 => {
                if let Some(v) = answer.borrow_mut().take() {
                    let p = preview_slot.borrow().clone().unwrap();
                    input(
                        &p.view,
                        v["x"].as_f64().unwrap(),
                        v["y"].as_f64().unwrap(),
                        None,
                    );
                    stage.set(11)
                }
            }
            11 => {
                let doc = doc_slot.borrow().clone().unwrap();
                if doc.buffer.cursor_position() != expected_cursor.get() {
                    return glib::ControlFlow::Continue;
                }
                let preview = preview_slot.borrow().clone().unwrap();
                expected_cursor
                    .set(source[..source.find("TAIL SAME").unwrap()].chars().count() as i32);
                query(&preview, &text_point("TAIL SAME"), &answer);
                stage.set(30);
            }
            12 if answer.borrow_mut().take().is_some() => {
                if !capture(
                    ui.window.upcast_ref(),
                    "math-source-warning",
                    &capture_state,
                ) {
                    stage.set(11);
                    return glib::ControlFlow::Continue;
                }
                let doc = doc_slot.borrow().clone().unwrap();
                assert_eq!(buffer_text(&doc.buffer), source);
                assert_eq!(doc.revision.get(), revision.get());
                assert!(!doc.buffer.can_undo());
                assert_eq!(std::fs::read(&path).unwrap(), source.as_bytes());
                let preview = preview_slot.borrow().clone().unwrap();
                query(&preview,"const r=document.createRange();r.selectNodeContents(document.body);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&answer);
                stage.set(25);
            }
            13 => {
                let doc = doc_slot.borrow().clone().unwrap();
                let Some(ed) = doc.rich.borrow().clone().filter(|e| e.active.get()) else {
                    return glib::ControlFlow::Continue;
                };
                let reply = answer.clone();
                ed.evaluate("if(typeof fastraVisual==='undefined'||!document.getElementById('fastra-visual')?.isContentEditable)return JSON.stringify(null);return JSON.stringify({source:fastraVisual.markdown(),opaque:document.querySelectorAll('[data-md-opaque]').length,images:document.querySelectorAll('img[data-md-src]').length,math:document.querySelectorAll('math').length,literal:document.getElementById('fastra-visual').innerText.includes('==literal==')});",move|v|*reply.borrow_mut()=v);
                *rich_slot.borrow_mut() = Some(ed);
                stage.set(14);
            }
            14 => {
                if let Some(v) = answer.borrow_mut().take() {
                    if v.is_null() {
                        stage.set(13);
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(v["source"], source);
                    assert_eq!(v["images"], 1);
                    assert_eq!(v["math"], 3);
                    assert_eq!(v["literal"], true);
                    assert!(v["opaque"].as_u64().unwrap() >= 5);
                    let ed = rich_slot.borrow().clone().unwrap();
                    let reply = answer.clone();
                    ed.evaluate("const p=[...document.querySelectorAll('#fastra-visual p')].find(n=>n.textContent==='AFTER TARGET 雪🙂');p.scrollIntoView({block:'center'});const r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return JSON.stringify(true);",move|v|*reply.borrow_mut()=v);
                    stage.set(15);
                }
            }
            15 if answer.borrow_mut().take().is_some() => {
                let ed = rich_slot.borrow().clone().unwrap();
                ed.view.grab_focus();
                input(&ed.view, 0., 0., Some("x"));
                stage.set(16);
            }
            16 => {
                let doc = doc_slot.borrow().clone().unwrap();
                if !buffer_text(&doc.buffer).contains("AFTER TARGET 雪🙂x") {
                    return glib::ControlFlow::Continue;
                }
                let ed = rich_slot.borrow().clone().unwrap();
                let undo = find_button(ed.widget.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                    .unwrap();
                input(
                    &undo,
                    undo.width() as f64 / 2.,
                    undo.height() as f64 / 2.,
                    None,
                );
                stage.set(17);
            }
            17 => {
                let doc = doc_slot.borrow().clone().unwrap();
                if buffer_text(&doc.buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                if !capture(
                    ui.window.upcast_ref(),
                    "math-rich-cr-source",
                    &capture_state,
                ) {
                    return glib::ControlFlow::Continue;
                }
                let ed = rich_slot.borrow().clone().unwrap();
                let reply = answer.clone();
                ed.evaluate("const p=[...document.querySelectorAll('#fastra-visual p')].find(n=>n.textContent==='AFTER TARGET 雪🙂');const r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",move|v|*reply.borrow_mut()=v);
                stage.set(18);
            }
            18 if answer.borrow_mut().take().is_some() => {
                let ed = rich_slot.borrow().clone().unwrap();
                ed.view.grab_focus();
                input(&ed.view, 0., 0., Some("x"));
                stage.set(19);
            }
            19 => {
                let doc = doc_slot.borrow().clone().unwrap();
                let text = buffer_text(&doc.buffer);
                if !text.contains("AFTER TARGET 雪🙂x") {
                    return glib::ControlFlow::Continue;
                }
                assert!(text.contains(&format!("~~~text{eol}==literal=={eol}~~~")));
                assert!(text.contains(&format!("$${eol}\\begin{{aligned}}{eol}a &= b \\\\{eol}  {eol}c &= d{eol}\\end{{aligned}}{eol}$$")));
                assert!(text.contains(&format!("$${eol}")));
                *saved.borrow_mut() = text;
                let save = find_button(
                    ui.window.child().unwrap().upcast_ref(),
                    ui.lang.text("Speichern", "Save"),
                )
                .unwrap();
                input(
                    &save,
                    save.width() as f64 / 2.,
                    save.height() as f64 / 2.,
                    None,
                );
                stage.set(20);
            }
            20 => {
                let doc = doc_slot.borrow().clone().unwrap();
                if doc.saving.get()
                    || doc.buffer.is_modified()
                    || std::fs::read_to_string(&path).unwrap() != *saved.borrow()
                {
                    return glib::ControlFlow::Continue;
                }
                let ed = rich_slot.borrow().clone().unwrap();
                ed.view.grab_focus();
                input(&ed.view, 0., 0., Some("ctrl+w"));
                stage.set(21);
            }
            21 => {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, doc_slot.borrow().as_ref().unwrap()))
                {
                    return glib::ControlFlow::Continue;
                }
                ui.load_path(path.clone());
                stage.set(22);
            }
            22 => {
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(buffer_text(&doc.buffer), *saved.borrow());
                assert!(!Rc::ptr_eq(&doc, doc_slot.borrow().as_ref().unwrap()));
                doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
                *doc_slot.borrow_mut() = Some(doc);
                stage.set(23);
            }
            23 => {
                let doc = doc_slot.borrow().clone().unwrap();
                let Some(ed) = doc.rich.borrow().clone().filter(|e| e.active.get()) else {
                    return glib::ControlFlow::Continue;
                };
                let reply = answer.clone();
                ed.evaluate("if(typeof fastraVisual==='undefined'||!document.getElementById('fastra-visual')?.isContentEditable)return JSON.stringify(null);await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));await new Promise(r=>setTimeout(r,150));return JSON.stringify({source:fastraVisual.markdown(),math:document.querySelectorAll('math').length,literal:document.getElementById('fastra-visual').innerText.includes('==literal==')});",move|v|*reply.borrow_mut()=v);
                *rich_slot.borrow_mut() = Some(ed);
                stage.set(24);
            }
            24 => {
                if let Some(v) = answer.borrow_mut().take() {
                    if v.is_null() {
                        stage.set(23);
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(v["source"], *saved.borrow());
                    assert_eq!(v["math"], 3);
                    assert_eq!(v["literal"], true);
                    assert_eq!(std::fs::read_to_string(&path).unwrap(), *saved.borrow());
                    if !capture(ui.window.upcast_ref(), "math-rich-reopened", &capture_state) {
                        stage.set(23);
                        return glib::ControlFlow::Continue;
                    }
                    println!("PASS math static genuine KaTeX MathML+error/source warnings/three true CodeCopy reads/actual Ctrl+C MathML HTML with source-metadata cleanup/original MathML click positions; Rich CR/CRLF fences+opaque formula/source reconstruction/native edit+Undo+Save+close+reopen; Mark/global refs unchanged");
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
            }
            25 if answer.borrow_mut().take().is_some() => {
                let preview = preview_slot.borrow().clone().unwrap();
                preview.view.grab_focus();
                input(&preview.view, 0., 0., Some("ctrl+c"));
                stage.set(26);
            }
            26 if entered.get().elapsed() > Duration::from_millis(350) => {
                read_html(
                    preview_slot.borrow().as_ref().unwrap(),
                    root.clone(),
                    &answer,
                );
                stage.set(27);
            }
            27 => {
                if let Some(value) = answer.borrow_mut().take() {
                    let html = value.as_str().unwrap();
                    assert!(html.contains("<math"));
                    assert!(html.contains("==literal=="));
                    for internal in [
                        "data-srcline",
                        "data-srccol",
                        "fastra-code-controls",
                        "data-fastra-code",
                        "<script",
                        "FASTRAMATH",
                        "FASTRACODE",
                    ] {
                        assert!(
                            !html.contains(internal),
                            "clipboard metadata leak {internal}"
                        );
                    }
                    let doc = doc_slot.borrow().clone().unwrap();
                    assert_eq!(buffer_text(&doc.buffer), source);
                    if review {
                        assert_eq!(html.matches("<img").count(), 3);
                        assert!(html.contains("alt $x$"));
                        assert!(html.contains("outside-boundary"));
                        assert_eq!(std::fs::read(&path).unwrap(), source.as_bytes());
                        query(preview_slot.borrow().as_ref().unwrap(), "getSelection().removeAllRanges();const p=[...document.querySelectorAll('pre')].at(-1);p.scrollIntoView({block:'center'});await new Promise(r=>setTimeout(r,150));return JSON.stringify({images:[...document.querySelectorAll('img')].map(n=>({alt:n.alt,loaded:n.complete&&n.naturalWidth>0})),code:p.textContent,outside:document.body.innerText.includes('outside-boundary')});", &answer);
                        stage.set(40);
                        return glib::ControlFlow::Continue;
                    }
                    doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
                    stage.set(13);
                }
            }
            40 => {
                if let Some(value) = answer.borrow_mut().take() {
                    assert_eq!(value["images"].as_array().unwrap().len(), 3);
                    assert!(value["images"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .all(|v| v["loaded"] == true));
                    assert_eq!(value["images"][1]["alt"], "alt $x$");
                    assert_eq!(value["outside"], true);
                    eprintln!("REVIEW_IMAGES_BOUNDARY {}", value);
                    stage.set(41);
                }
            }
            41 => {
                if !capture(
                    ui.window.upcast_ref(),
                    "math-review-boundary",
                    &capture_state,
                ) {
                    return glib::ControlFlow::Continue;
                }
                println!("PASS math review v2 actual three loaded images/four CodeCopy reads including partial fence/real Ctrl+C HTML with original alt/source and disk unchanged");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            30 => {
                if let Some(v) = answer.borrow_mut().take() {
                    let p = preview_slot.borrow().clone().unwrap();
                    input(
                        &p.view,
                        v["x"].as_f64().unwrap(),
                        v["y"].as_f64().unwrap(),
                        None,
                    );
                    stage.set(31)
                }
            }
            31 => {
                let doc = doc_slot.borrow().clone().unwrap();
                if doc.buffer.cursor_position() != expected_cursor.get() {
                    assert!(
                        entered.get().elapsed() < Duration::from_secs(2),
                        "text after inline MathML: actual {} expected {}",
                        doc.buffer.cursor_position(),
                        expected_cursor.get()
                    );
                    return glib::ControlFlow::Continue;
                }
                expected_cursor.set(
                    source[..source.find("Mixed after target").unwrap()]
                        .chars()
                        .count() as i32,
                );
                let p = preview_slot.borrow().clone().unwrap();
                query(&p, &text_point("Mixed after target"), &answer);
                stage.set(32);
            }
            32 => {
                if let Some(v) = answer.borrow_mut().take() {
                    let p = preview_slot.borrow().clone().unwrap();
                    input(
                        &p.view,
                        v["x"].as_f64().unwrap(),
                        v["y"].as_f64().unwrap(),
                        None,
                    );
                    stage.set(33)
                }
            }
            33 => {
                let doc = doc_slot.borrow().clone().unwrap();
                if doc.buffer.cursor_position() != expected_cursor.get() {
                    assert!(
                        entered.get().elapsed() < Duration::from_secs(2),
                        "text after multiline MathML in same paragraph: actual {} expected {}",
                        doc.buffer.cursor_position(),
                        expected_cursor.get()
                    );
                    return glib::ControlFlow::Continue;
                }
                let preview = preview_slot.borrow().clone().unwrap();
                query(&preview,"document.querySelector('.math-source').scrollIntoView({block:'center'});await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));await new Promise(r=>setTimeout(r,150));return JSON.stringify(true);",&answer);
                stage.set(12);
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
