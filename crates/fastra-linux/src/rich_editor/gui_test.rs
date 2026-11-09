use super::*;
use std::{
    path::PathBuf,
    sync::atomic::Ordering,
    time::{Duration, Instant},
};
static STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(super) fn button(root: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(button) = root
        .downcast_ref::<gtk::Button>()
        .filter(|b| b.label().as_deref() == Some(label) || b.tooltip_text().as_deref() == Some(label))
    {
        return Some(button.clone());
    }
    let mut child = root.first_child();
    while let Some(node) = child {
        if let Some(button) = button(&node, label) {
            return Some(button);
        }
        child = node.next_sibling();
    }
    None
}
fn check(root: &gtk::Widget, label: &str) -> Option<gtk::CheckButton> {
    if let Some(item) = root
        .downcast_ref::<gtk::CheckButton>()
        .filter(|c| c.label().as_deref() == Some(label))
    {
        return Some(item.clone());
    }
    let mut child = root.first_child();
    while let Some(node) = child {
        if let Some(item) = check(&node, label) {
            return Some(item);
        }
        child = node.next_sibling();
    }
    None
}
fn menu(root: &gtk::Widget, label: &str) -> Option<gtk::MenuButton> {
    if let Some(item) = root
        .downcast_ref::<gtk::MenuButton>()
        .filter(|m| m.label().as_deref() == Some(label) || m.tooltip_text().as_deref() == Some(label))
    {
        return Some(item.clone());
    }
    let mut child = root.first_child();
    while let Some(node) = child {
        if let Some(item) = menu(&node, label) {
            return Some(item);
        }
        child = node.next_sibling();
    }
    None
}
pub(super) fn xid(widget: &impl IsA<gtk::Widget>) -> String {
    let native = widget.as_ref().native().unwrap();
    let surface = native.surface().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let getter: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    unsafe { getter(surface.as_ptr().cast()) }.to_string()
}
pub(super) fn input(widget: &impl IsA<gtk::Widget>, click: bool, keys: &[&str]) {
    let widget = widget.as_ref();
    if !widget.is_mapped() {
        let mut parent=widget.parent();let mut menu=None;
        while let Some(node)=parent {
            parent=node.parent();
            if let Some(popover)=node.downcast_ref::<gtk::Popover>() {
                if let Some(button)=popover.parent().and_then(|p|p.downcast::<gtk::MenuButton>().ok()).filter(|b|b.is_mapped()) {menu=Some(button);break;}
            }
        }
        if let Some(menu)=menu {
            input(&menu,true,&[]);
            let widget=widget.clone();let keys=keys.iter().map(|key|key.to_string()).collect::<Vec<_>>();
            glib::timeout_add_local_once(Duration::from_millis(60),move|| {
                assert!(widget.is_mapped(),"Nested Rich action must be visible after opening More");
                input(&widget,click,&keys.iter().map(String::as_str).collect::<Vec<_>>());
            });return;
        }
    }
    let id = xid(widget);
    let mut args = vec![
        "windowraise".into(),
        id.clone(),
        "windowfocus".into(),
        "--sync".into(),
        id.clone(),
    ];
    if click {
        let native = widget.native().unwrap();
        let point = widget
            .compute_point(
                &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
                &gtk::graphene::Point::new(widget.width() as f32 / 2., widget.height() as f32 / 2.),
            )
            .unwrap();
        let (x, y) = native.surface_transform();
        args.extend([
            "mousemove".into(),
            "--window".into(),
            id,
            (point.x() as f64 - x).round().to_string(),
            (point.y() as f64 - y).round().to_string(),
            "click".into(),
            "1".into(),
        ]);
    } else {
        widget.grab_focus();
    }
    if !keys.is_empty() {
        args.push("key".into());
        args.extend(keys.iter().map(|s| s.to_string()));
    }
    std::thread::spawn(move || {
        assert!(std::process::Command::new("timeout")
            .args(["5s", "xdotool"])
            .args(args)
            .status()
            .unwrap()
            .success())
    });
}
fn js(editor: &Rc<RichEditor>, code: &str, reply: &Rc<RefCell<Option<Value>>>) {
    reply.borrow_mut().take();
    let reply = reply.clone();
    editor.evaluate(code, move |result| *reply.borrow_mut() = result);
}
pub(super) fn capture(
    window: &impl IsA<gtk::Widget>,
    name: &str,
    pending: &RefCell<Option<mpsc::Receiver<bool>>>,
) -> bool {
    let Some(directory) = std::env::var_os("FASTRA_RICH_SCREENSHOTS").or_else(|| std::env::var_os("FASTRA_TOOL_SCREENSHOTS")) else {
        return true;
    };
    if pending.borrow().is_none() {
        let id = xid(window);
        let path = std::path::PathBuf::from(directory).join(format!("{name}.png"));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let (tx, rx) = mpsc::channel();
        *pending.borrow_mut() = Some(rx);
        std::thread::spawn(move || {
            let ok = std::process::Command::new("timeout")
                .args(["5s", "import", "-silent", "-window", &id])
                .arg(path)
                .status()
                .is_ok_and(|v| v.success());
            let _ = tx.send(ok);
        });
        return false;
    }
    let value = pending.borrow().as_ref().unwrap().try_recv();
    match value {
        Ok(ok) => {
            assert!(ok);
            pending.borrow_mut().take();
            true
        }
        Err(mpsc::TryRecvError::Empty) => false,
        Err(_) => panic!("capture stopped"),
    }
}
fn set_html(editor: &Rc<RichEditor>, html: &str) {
    editor
        .view
        .clipboard()
        .set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
            "text/html",
            &glib::Bytes::from_owned(html.as_bytes().to_vec()),
        )))
        .unwrap();
}
pub(super) fn run(a: Rc<Ui>) {
    if STARTED.swap(true, Ordering::Relaxed) {
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let app = a.window.application().unwrap();
    let b = crate::build(&app);
    b.window.present();
    let width = std::env::var("FASTRA_RICH_WIDTH")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1180);
    a.window.set_default_size(width, 850);
    b.window.set_default_size(width, 850);
    let root = PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    std::fs::create_dir_all(&root).unwrap();
    let pa = root.join("source-a.md");
    let pb = root.join("receiver-b.md");
    let source_a = format!(
        "==Marked== and **Bold&nbsp;**\n\n{}\n<script>globalThis.scriptA=1</script>\n",
        (0..100)
            .map(|n| format!("Line {n} synthetic text.\n\n"))
            .collect::<String>()
    );
    let source_b = "Receiver text\n\n<script>globalThis.scriptB=1</script>\n";
    std::fs::write(&pa, &source_a).unwrap();
    std::fs::write(&pb, source_b).unwrap();
    a.load_path(pa.clone());
    b.load_path(pb.clone());
    let phase = Cell::new(0);
    let delay = Cell::new(Instant::now());
    let started = Instant::now();
    let reply = Rc::new(RefCell::new(None::<Value>));
    let ea = RefCell::new(None::<Rc<RichEditor>>);
    let eb = RefCell::new(None::<Rc<RichEditor>>);
    let da = RefCell::new(None::<Rc<Document>>);
    let db = RefCell::new(None::<Rc<Document>>);
    let dc = RefCell::new(None::<Rc<Document>>);
    let ec = RefCell::new(None::<Rc<RichEditor>>);
    let simple_base = RefCell::new(String::new());
    let saved = RefCell::new(String::new());
    let before_delete = RefCell::new(String::new());
    let before_cut = RefCell::new(String::new());
    let shots = RefCell::new(None);
    let scroll = Cell::new(0.0);
    let copied_source = Rc::new(RefCell::new(None::<String>));
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            started.elapsed() < Duration::from_secs(85),
            "clipboard phase{} {:?}",
            phase.get(),
            eb.borrow().as_ref().map(|e| e.status.text())
        );
        if delay.get().elapsed() < Duration::from_millis(150) {
            return glib::ControlFlow::Continue;
        }
        let advance = |next| {
            eprintln!("Rich clipboard phase {next}");
            phase.set(next);
            delay.set(Instant::now());
        };
        match phase.get() {
            0 => {
                let (Some(ad), Some(bd)) = (
                    a.active().filter(|d| d.disk_path().as_ref() == Some(&pa)),
                    b.active().filter(|d| d.disk_path().as_ref() == Some(&pb)),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                *da.borrow_mut() = Some(ad.clone());
                *db.borrow_mut() = Some(bd.clone());
                mode_toggle(&ad, a.lang).set_active(true);
                bd.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                check(
                    bd.container.upcast_ref(),
                    b.lang.text("Quelltextansicht teilen", "Split source editor"),
                )
                .unwrap()
                .set_active(true);
                mode_toggle(&bd, b.lang).set_active(true);
                advance(1);
            }
            1 => {
                let (Some(first), Some(second)) = (
                    da.borrow().as_ref().unwrap().rich.borrow().clone(),
                    db.borrow().as_ref().unwrap().rich.borrow().clone(),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                if !first.ready.get() || !second.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!first.failed.get() && !second.failed.get());
                *ea.borrow_mut() = Some(first);
                *eb.borrow_mut() = Some(second.clone());
                js(&second,"const p=document.querySelector('#fastra-visual p:not([data-md-edit-boundary])'),r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&reply);
                advance(2);
            }
            2 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let editor = eb.borrow().clone().unwrap();
                input(
                    &button(
                        editor.widget.upcast_ref(),
                        b.lang.text("Markierung", "Highlight"),
                    )
                    .unwrap(),
                    true,
                    &[],
                );
                advance(3);
            }
            3 => {
                if !buffer_text(&db.borrow().as_ref().unwrap().buffer).contains("==Receiver text==")
                {
                    return glib::ControlFlow::Continue;
                }
                let editor = eb.borrow().clone().unwrap();
                input(
                    &button(
                        editor.widget.upcast_ref(),
                        b.lang.text("Rückgängig", "Undo"),
                    )
                    .unwrap(),
                    true,
                    &[],
                );
                advance(4);
            }
            4 => {
                if buffer_text(&db.borrow().as_ref().unwrap().buffer) != source_b {
                    return glib::ControlFlow::Continue;
                }
                let editor = ea.borrow().clone().unwrap();
                js(&editor,"const r=document.createRange();r.selectNodeContents(document.querySelector('#fastra-visual'));getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&reply);
                advance(5);
            }
            5 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                input(&ea.borrow().as_ref().unwrap().view, false, &["ctrl+c"]);
                advance(6);
            }
            6 => {
                if !ea
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .view
                    .clipboard()
                    .formats()
                    .contain_mime_type(clipboard::MIME)
                {
                    return glib::ControlFlow::Continue;
                }
                let clipboard = ea.borrow().as_ref().unwrap().view.clipboard();
                let copied = copied_source.clone();
                glib::spawn_future_local(async move {
                    let value = clipboard::read(clipboard, false).await.unwrap();
                    let clipboard::Incoming::Markdown(source) = value else {
                        panic!("native Markdown MIME");
                    };
                    *copied.borrow_mut() = Some(source);
                });
                input(&eb.borrow().as_ref().unwrap().view, false, &[]);
                advance(60);
            }
            60 => {
                let Some(copied) = copied_source.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(
                    copied.contains("<script>globalThis.scriptA=1</script>"),
                    "copied atom source: {copied:?}"
                );
                let editor = eb.borrow().clone().unwrap();
                js(&editor,"const r=document.createRange();r.selectNode(document.querySelector('#fastra-visual p:not([data-md-edit-boundary])'));getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&reply);
                advance(7);
            }
            7 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                input(&eb.borrow().as_ref().unwrap().view, false, &["ctrl+v"]);
                advance(8);
            }
            8 => {
                let text = buffer_text(&db.borrow().as_ref().unwrap().buffer);
                if !text.contains("scriptA") || !text.contains("Marked") {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    text.contains("scriptB") && !text.contains("Receiver"),
                    "cross-document source: {text:?}"
                );
                assert_eq!(buffer_text(&da.borrow().as_ref().unwrap().buffer), source_a);
                let editor = eb.borrow().clone().unwrap();
                js(&editor,"window.scrollTo(0,0);await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return JSON.stringify({marked:document.querySelector('mark')?.textContent,bold:document.querySelector('strong')?.textContent,bad:typeof globalThis.scriptA+typeof globalThis.scriptB});",&reply);
                advance(9);
            }
            9 => {
                let Some(value) = reply.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["marked"], "Marked");
                assert_eq!(value["bold"], "Bold\u{a0}");
                assert_eq!(value["bad"], "undefinedundefined");
                assert!(buffer_text(&db.borrow().as_ref().unwrap().buffer)
                    .contains("<script>globalThis.scriptB=1</script>"));
                if !capture(&b.window, "rich-clipboard-pasted", &shots) {
                    return glib::ControlFlow::Continue;
                }
                b.add_document("simple.md", "");
                let doc = b.active().unwrap();
                mode_toggle(&doc, b.lang).set_active(true);
                *dc.borrow_mut() = Some(doc);
                advance(90);
            }
            90 => {
                let Some(editor) = dc.borrow().as_ref().unwrap().rich.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                if !editor.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                let providers = [
                    gtk::gdk::ContentProvider::for_value(&"Bold\u{a0}".to_value()),
                    gtk::gdk::ContentProvider::for_bytes(
                        clipboard::MIME,
                        &glib::Bytes::from_owned(
                            json!({"markdown":"**Bold&nbsp;**","images":""})
                                .to_string()
                                .into_bytes(),
                        ),
                    ),
                ];
                editor
                    .view
                    .clipboard()
                    .set_content(Some(&gtk::gdk::ContentProvider::new_union(&providers)))
                    .unwrap();
                *ec.borrow_mut() = Some(editor.clone());
                input(
                    &menu(
                        editor.widget.upcast_ref(),
                        b.lang.text("Zwischenablage", "Clipboard"),
                    )
                    .unwrap(),
                    true,
                    &[],
                );
                advance(901);
            }
            901 => {
                let editor = ec.borrow().clone().unwrap();
                let popup = menu(
                    editor.widget.upcast_ref(),
                    b.lang.text("Zwischenablage", "Clipboard"),
                )
                .unwrap()
                .popover()
                .unwrap();
                if !popup.is_mapped() {return glib::ControlFlow::Continue;}
                input(
                    &button(
                        popup.child().unwrap().upcast_ref(),
                        b.lang.text("Einfügen", "Paste"),
                    )
                    .unwrap(),
                    true,
                    &[],
                );
                advance(91);
            }
            91 => {
                let text = buffer_text(&dc.borrow().as_ref().unwrap().buffer);
                if !text.contains("Bold") {
                    return glib::ControlFlow::Continue;
                }
                assert!(text.contains("**Bold&nbsp;**"));
                *simple_base.borrow_mut() = text;
                let editor = ec.borrow().clone().unwrap();
                js(&editor,"const r=document.createRange();r.selectNodeContents(document.querySelector('strong'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&reply);
                advance(10);
            }
            10 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                input(&ec.borrow().as_ref().unwrap().view, false, &["Return"]);
                advance(11);
            }
            11 => {
                let text = buffer_text(&dc.borrow().as_ref().unwrap().buffer);
                if text == *simple_base.borrow() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!text.contains("**  "));
                *before_delete.borrow_mut() = text;
                let editor = ec.borrow().clone().unwrap();
                js(&editor,"const r=document.createRange();r.selectNodeContents(document.querySelector('#fastra-visual'));getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&reply);
                advance(12);
            }
            12 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                input(&ec.borrow().as_ref().unwrap().view, false, &["BackSpace"]);
                advance(13);
            }
            13 => {
                if !buffer_text(&dc.borrow().as_ref().unwrap().buffer).is_empty() {
                    return glib::ControlFlow::Continue;
                }
                input(&ec.borrow().as_ref().unwrap().view, false, &["ctrl+z"]);
                advance(14);
            }
            14 => {
                assert_eq!(
                    buffer_text(&dc.borrow().as_ref().unwrap().buffer),
                    *before_delete.borrow(),
                    "native Ctrl+Z restores full Delete"
                );
                let doc = db.borrow().clone().unwrap();
                let page = b
                    .documents
                    .borrow()
                    .iter()
                    .position(|item| Rc::ptr_eq(item, &doc))
                    .unwrap();
                b.tabs.set_current_page(Some(page as u32));
                advance(140);
            }
            140 => {
                crate::git_view::test_keys(&b.window, &["ctrl+s"]);
                advance(15);
            }
            15 => {
                let doc = db.borrow().clone().unwrap();
                if doc.saving.get()
                    || std::fs::read_to_string(&pb).unwrap() != buffer_text(&doc.buffer)
                {
                    return glib::ControlFlow::Continue;
                }
                *saved.borrow_mut() = buffer_text(&doc.buffer);
                let editor = eb.borrow().clone().unwrap();
                js(&editor,"window.scrollTo(0,1600);await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return JSON.stringify({y:window.scrollY});",&reply);
                advance(16);
            }
            16 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                scroll.set(value["y"].as_f64().unwrap());
                assert!(scroll.get() > 1400.0);
                input(
                    &mode_toggle(db.borrow().as_ref().unwrap(), b.lang),
                    true,
                    &[],
                );
                advance(17);
            }
            17 => {
                if db.borrow().as_ref().unwrap().rich.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    db.borrow()
                        .as_ref()
                        .unwrap()
                        .markdown_toggle
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .is_active(),
                    "source preview choice restored"
                );
                assert!(
                    check(
                        db.borrow().as_ref().unwrap().container.upcast_ref(),
                        b.lang.text("Quelltextansicht teilen", "Split source editor")
                    )
                    .unwrap()
                    .is_active(),
                    "split choice restored"
                );
                assert!(
                    viewport::get(db.borrow().as_ref().unwrap()).unwrap()["y"]
                        .as_f64()
                        .unwrap()
                        > 1400.0
                );
                let response = reply.clone();
                db.borrow()
                    .as_ref()
                    .unwrap()
                    .markdown
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .inspect(
                        "return JSON.stringify({marks:document.querySelectorAll('mark').length});",
                        move |value| *response.borrow_mut() = Some(value),
                    );
                advance(171);
            }
            171 => {
                let Some(value) = reply.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                if value["marks"].as_u64().unwrap_or(0) == 0 {
                    let response = reply.clone();
                    db.borrow().as_ref().unwrap().markdown.borrow().as_ref().unwrap().inspect("return JSON.stringify({marks:document.querySelectorAll('mark').length});",move|value|*response.borrow_mut()=Some(value));
                    return glib::ControlFlow::Continue;
                }
                if !capture(&b.window, "rich-source-split", &shots) {
                    return glib::ControlFlow::Continue;
                }
                input(
                    &mode_toggle(db.borrow().as_ref().unwrap(), b.lang),
                    true,
                    &[],
                );
                advance(18);
            }
            18 => {
                let Some(editor) = db.borrow().as_ref().unwrap().rich.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                if !editor.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!editor.failed.get());
                *eb.borrow_mut() = Some(editor.clone());
                js(&editor,"return JSON.stringify({y:window.scrollY,max:Math.max(0,document.documentElement.scrollHeight-window.innerHeight),marked:document.querySelector('mark')?.textContent,bad:typeof globalThis.scriptA+typeof globalThis.scriptB});",&reply);
                advance(19);
            }
            19 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                let expected = scroll.get().min(value["max"].as_f64().unwrap());
                assert!((value["y"].as_f64().unwrap() - expected).abs() < 1.0,
                    "restored scroll {} expected {} (saved {}, max {})",value["y"],expected,scroll.get(),value["max"]);
                assert_eq!(value["marked"], "Marked");
                assert_eq!(value["bad"], "undefinedundefined");
                assert_eq!(std::fs::read_to_string(&pb).unwrap(), *saved.borrow());
                let editor = eb.borrow().clone().unwrap();
                set_html(
                    &editor,
                    "<p><script>globalThis.injected=1</script>Unsafe</p>",
                );
                js(&editor,"const r=document.createRange();r.selectNodeContents(document.querySelector('#fastra-visual p:not([data-md-edit-boundary])'));getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&reply);
                advance(20);
            }
            20 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                input(&eb.borrow().as_ref().unwrap().view, false, &["ctrl+v"]);
                advance(21);
            }
            21 => {
                let editor = eb.borrow().clone().unwrap();
                if !editor
                    .status
                    .text()
                    .contains(b.lang.text("nicht unterstützt", "unsupported"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    buffer_text(&db.borrow().as_ref().unwrap().buffer),
                    *saved.borrow()
                );
                set_html(&editor,"<div data-md-block='0' data-md-origin='document-a'><p><mark>Marked</mark> and <mark data-md-opaque='0'>Foreign</mark> <strong>Bold&nbsp;</strong></p></div>");
                input(&editor.view, false, &["ctrl+v"]);
                advance(22);
            }
            22 => {
                let text = buffer_text(&db.borrow().as_ref().unwrap().buffer);
                if !text.contains("Foreign") {
                    return glib::ControlFlow::Continue;
                }
                assert!(text.contains("scriptA") && text.contains("scriptB"));
                *saved.borrow_mut() = text;
                let editor = eb.borrow().clone().unwrap();
                set_html(&editor, "<p>STALE CARET</p>");
                clipboard::delay_for_test(700);
                js(&editor,"const root=document.querySelector('#fastra-visual'),text=root.querySelector('p:not([data-md-edit-boundary]) mark').firstChild,r=document.createRange();root.focus();r.setStart(text,1);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);window.caretBefore={a:getSelection().anchorNode,ao:getSelection().anchorOffset,f:getSelection().focusNode,fo:getSelection().focusOffset};return JSON.stringify(true);",&reply);
                advance(220);
            }
            220 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                input(&eb.borrow().as_ref().unwrap().view, false, &["ctrl+v"]);
                advance(221);
            }
            221 => {
                if !clipboard::pending_for_test() {
                    return glib::ControlFlow::Continue;
                }
                input(&eb.borrow().as_ref().unwrap().view, false, &["Right"]);
                js(eb.borrow().as_ref().unwrap(),"const old=window.caretBefore,same=()=>{const live=getSelection();return live.anchorNode===old.a && live.anchorOffset===old.ao && live.focusNode===old.f && live.focusOffset===old.fo;};for(let n=0;n<60 && same()!==false;n++)await new Promise(r=>setTimeout(r,5));return JSON.stringify(same());",&reply);
                advance(222);
            }
            222 => {
                let Some(same) = reply.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    same, false,
                    "native caret actually moved without changing source"
                );
                if clipboard::pending_for_test() {
                    return glib::ControlFlow::Continue;
                }
                let editor = eb.borrow().clone().unwrap();
                assert_eq!(
                    buffer_text(&db.borrow().as_ref().unwrap().buffer),
                    *saved.borrow(),
                    "caret-only movement rejects delayed formatted paste"
                );
                assert!(editor
                    .status
                    .text()
                    .contains(b.lang.text("geändert", "changed")));
                editor.view.clipboard().set_text("STALE CARET ABA");
                js(&editor,"const root=document.querySelector('#fastra-visual'),text=root.querySelector('p:not([data-md-edit-boundary]) mark').firstChild,r=document.createRange();root.focus();r.setStart(text,1);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);window.caretBefore={a:getSelection().anchorNode,ao:getSelection().anchorOffset,f:getSelection().focusNode,fo:getSelection().focusOffset};return JSON.stringify(true);",&reply);
                advance(223);
            }
            223 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                input(
                    &eb.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+shift+v"],
                );
                advance(224);
            }
            224 => {
                if !clipboard::pending_for_test() {
                    return glib::ControlFlow::Continue;
                }
                input(&eb.borrow().as_ref().unwrap().view, false, &["Right"]);
                js(eb.borrow().as_ref().unwrap(),"const old=window.caretBefore,same=()=>{const live=getSelection();return live.anchorNode===old.a && live.anchorOffset===old.ao && live.focusNode===old.f && live.focusOffset===old.fo;};for(let n=0;n<60 && same()!==false;n++)await new Promise(r=>setTimeout(r,5));return JSON.stringify(same());",&reply);
                advance(2241);
            }
            2241 => {
                let Some(same) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(same, false, "native ABA intermediate caret differs");
                assert!(
                    clipboard::pending_for_test(),
                    "caret ABA completed during delayed read"
                );
                input(&eb.borrow().as_ref().unwrap().view, false, &["Left"]);
                js(eb.borrow().as_ref().unwrap(),"const old=window.caretBefore,same=()=>{const live=getSelection();return live.anchorNode===old.a && live.anchorOffset===old.ao && live.focusNode===old.f && live.focusOffset===old.fo;};for(let n=0;n<60 && same()!==true;n++)await new Promise(r=>setTimeout(r,5));return JSON.stringify(same());",&reply);
                advance(225);
            }
            225 => {
                let Some(same) = reply.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    same, true,
                    "native caret returned to exactly the old selection"
                );
                if clipboard::pending_for_test() {
                    return glib::ControlFlow::Continue;
                }
                let editor = eb.borrow().clone().unwrap();
                assert_eq!(
                    buffer_text(&db.borrow().as_ref().unwrap().buffer),
                    *saved.borrow(),
                    "caret ABA rejects delayed plain paste"
                );
                assert!(editor
                    .status
                    .text()
                    .contains(b.lang.text("geändert", "changed")));
                set_html(&editor, "<p>STALE</p>");
                js(&editor,"const r=document.createRange();r.selectNodeContents(document.querySelector('#fastra-visual p:not([data-md-edit-boundary])'));getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&reply);
                advance(23);
            }
            23 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                input(&eb.borrow().as_ref().unwrap().view, false, &["ctrl+v"]);
                advance(24);
            }
            24 => {
                if !clipboard::pending_for_test() {
                    return glib::ControlFlow::Continue;
                }
                let page = b.tabs.current_page().unwrap();
                let other = (0..b.tabs.n_pages()).find(|index| *index != page).expect("distinct tab for ABA");
                b.tabs.set_current_page(Some(other));
                b.tabs.set_current_page(Some(page));
                advance(25);
            }
            25 => {
                let editor = eb.borrow().clone().unwrap();
                if clipboard::pending_for_test()
                    || !editor
                        .status
                        .text()
                        .contains(b.lang.text("geändert", "changed"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    buffer_text(&db.borrow().as_ref().unwrap().buffer),
                    *saved.borrow()
                );
                set_html(&editor, "<p>OLD CLIPBOARD</p>");
                input(&editor.view, false, &["ctrl+v"]);
                advance(26);
            }
            26 => {
                if !clipboard::pending_for_test() {
                    return glib::ControlFlow::Continue;
                }
                eb.borrow()
                    .as_ref()
                    .unwrap()
                    .view
                    .clipboard()
                    .set_text("NEW CLIPBOARD");
                advance(27);
            }
            27 => {
                let editor = eb.borrow().clone().unwrap();
                if clipboard::pending_for_test() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    buffer_text(&db.borrow().as_ref().unwrap().buffer),
                    *saved.borrow()
                );
                clipboard::delay_for_test(6000);
                input(&editor.view, false, &["ctrl+v"]);
                advance(28);
            }
            28 => {
                let editor = eb.borrow().clone().unwrap();
                if clipboard::pending_for_test()
                    || !editor
                        .status
                        .text()
                        .contains(b.lang.text("nicht rechtzeitig", "in time"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    buffer_text(&db.borrow().as_ref().unwrap().buffer),
                    *saved.borrow()
                );
                clipboard::delay_for_test(0);
                js(&editor,"window.scrollTo(0,0);await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return JSON.stringify({bad:typeof globalThis.injected,source:fastraVisual.markdown()});",&reply);
                advance(29);
            }
            29 => {
                let Some(value) = reply.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["bad"], "undefined");
                assert_eq!(value["source"], *saved.borrow());
                if !capture(&b.window, "rich-clipboard-guards", &shots) {
                    return glib::ControlFlow::Continue;
                }
                let editor = eb.borrow().clone().unwrap();
                let providers = [
                    gtk::gdk::ContentProvider::for_value(&"==PLAIN==".to_value()),
                    gtk::gdk::ContentProvider::for_bytes(
                        "text/html",
                        &glib::Bytes::from_static(b"<p><mark>WRONG FORMAT</mark></p>"),
                    ),
                ];
                editor
                    .view
                    .clipboard()
                    .set_content(Some(&gtk::gdk::ContentProvider::new_union(&providers)))
                    .unwrap();
                js(&editor,"const r=document.createRange();r.selectNodeContents(document.querySelector('#fastra-visual p:not([data-md-edit-boundary])'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",&reply);
                advance(30);
            }
            30 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                input(
                    &eb.borrow().as_ref().unwrap().view,
                    false,
                    &["ctrl+shift+v"],
                );
                advance(31);
            }
            31 => {
                let text = buffer_text(&db.borrow().as_ref().unwrap().buffer);
                if !text.contains("PLAIN") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!text.contains("WRONG FORMAT"));
                *before_cut.borrow_mut() = text;
                let editor = eb.borrow().clone().unwrap();
                js(&editor,"const walker=document.createTreeWalker(document.querySelector('#fastra-visual'),NodeFilter.SHOW_TEXT);let n;while(n=walker.nextNode()){const at=n.data.indexOf('==PLAIN==');if(at<0)continue;const r=document.createRange();r.setStart(n,at);r.setEnd(n,at+9);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);}return JSON.stringify(false);",&reply);
                advance(32);
            }
            32 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value, true);
                input(&eb.borrow().as_ref().unwrap().view, false, &["ctrl+x"]);
                advance(33);
            }
            33 => {
                if buffer_text(&db.borrow().as_ref().unwrap().buffer).contains("PLAIN") {
                    return glib::ControlFlow::Continue;
                }
                let output = copied_source.clone();
                *output.borrow_mut() = None;
                let clipboard = eb.borrow().as_ref().unwrap().view.clipboard();
                glib::spawn_future_local(async move {
                    let clipboard::Incoming::Text(text) =
                        clipboard::read(clipboard, true).await.unwrap()
                    else {
                        panic!("plain cut MIME");
                    };
                    assert_eq!(text, "==PLAIN==");
                    *output.borrow_mut() = Some(text);
                });
                advance(34);
            }
            34 => {
                if copied_source.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                input(&eb.borrow().as_ref().unwrap().view, false, &["ctrl+z"]);
                advance(35);
            }
            35 => {
                if buffer_text(&db.borrow().as_ref().unwrap().buffer) != *before_cut.borrow() { return glib::ControlFlow::Continue; }
                *saved.borrow_mut() = before_cut.borrow().clone();
                crate::git_view::test_keys(&b.window, &["ctrl+s"]);
                advance(36);
            }
            36 => {
                let doc = db.borrow().clone().unwrap();
                if doc.saving.get()
                    || doc.buffer.is_modified()
                    || std::fs::read_to_string(&pb).unwrap() != *saved.borrow()
                {
                    return glib::ControlFlow::Continue;
                }
                input(&eb.borrow().as_ref().unwrap().view, false, &["ctrl+w"]);
                advance(37);
            }
            37 => {
                if b.documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, db.borrow().as_ref().unwrap()))
                {
                    return glib::ControlFlow::Continue;
                }
                b.load_path(pb.clone());
                advance(38);
            }
            38 => {
                let Some(doc) = b.active().filter(|d| {
                    d.disk_path().as_ref() == Some(&pb) && buffer_text(&d.buffer) == *saved.borrow()
                }) else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!Rc::ptr_eq(&doc, db.borrow().as_ref().unwrap()));
                mode_toggle(&doc, b.lang).set_active(true);
                *db.borrow_mut() = Some(doc);
                advance(39);
            }
            39 => {
                let Some(editor) = db
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
                assert!(!editor.failed.get());
                js(&editor,"return JSON.stringify({mark:Array.from(document.querySelectorAll('mark')).some(n=>n.textContent==='Marked'),foreign:Array.from(document.querySelectorAll('mark')).some(n=>n.textContent==='Foreign'),bad:typeof globalThis.scriptA+typeof globalThis.scriptB});",&reply);
                *eb.borrow_mut() = Some(editor);
                advance(40);
            }
            40 => {
                let Some(value) = reply.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["mark"], true);
                assert_eq!(value["foreign"], true);
                assert_eq!(value["bad"], "undefinedundefined");
                if !capture(&b.window, "rich-clipboard-reopened", &shots) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    buffer_text(&db.borrow().as_ref().unwrap().buffer),
                    *saved.borrow()
                );
                assert_eq!(std::fs::read_to_string(&pa).unwrap(), source_a);
                println!("PASS Rich formatted clipboard: native Highlight button/Undo, two-window Ctrl+C/V, NBSP/highlight/opaque ownership, Return/Delete/Ctrl+Z, real Save/reopen mode/viewport/preview, unsafe HTML refusal, foreign metadata stripping, caret-only/caret-ABA/tab-ABA/clipboard-change/timeout with no output, Ctrl+Shift+V plain bytes and Ctrl+X/Undo");
                a.discard_confirmed.set(true);
                b.discard_confirmed.set(true);
                a.window.close();
                b.window.close();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
