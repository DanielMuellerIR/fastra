use super::*;
use std::time::Instant;

fn input(view: &webkit6::WebView, x: f64, y: f64, keys: Option<&str>) {
    let native = view.native().unwrap();
    let surface = native.surface().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let getter: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { getter(surface.as_ptr().cast()) }.to_string();
    let point = view
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(x as f32, y as f32),
        )
        .unwrap();
    let (sx, sy) = native.surface_transform();
    let mut args = vec![
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
fn inspect(preview: &Rc<MarkdownView>, code: &str, reply: &Rc<RefCell<Option<serde_json::Value>>>) {
    let reply = reply.clone();
    preview.inspect(code, move |v| *reply.borrow_mut() = Some(v));
}
fn read(preview: &MarkdownView, reply: &Rc<RefCell<Option<serde_json::Value>>>) {
    let clipboard = preview.view.clipboard();
    let reply = reply.clone();
    glib::MainContext::default().spawn_local(async move {
        let value = clipboard.read_text_future().await.unwrap();
        *reply.borrow_mut() = Some(serde_json::json!(value.map(|s| s.to_string())));
    });
}
fn read_formats(preview: &MarkdownView, reply: &Rc<RefCell<Option<serde_json::Value>>>) {
    let clipboard = preview.view.clipboard();
    let reply = reply.clone();
    glib::MainContext::default().spawn_local(async move {
        let plain = clipboard
            .read_text_future()
            .await
            .unwrap()
            .unwrap()
            .to_string();
        let (stream, mime) = clipboard
            .read_future(&["text/html"], glib::Priority::DEFAULT)
            .await
            .unwrap();
        assert_eq!(mime, "text/html");
        let mut bytes = Vec::new();
        loop {
            let part = stream
                .read_bytes_future(8192, glib::Priority::DEFAULT)
                .await
                .unwrap();
            if part.is_empty() {
                break;
            }
            bytes.extend_from_slice(part.as_ref());
            assert!(bytes.len() < 128 * 1024);
        }
        *reply.borrow_mut() =
            Some(serde_json::json!({"plain":plain,"html":String::from_utf8(bytes).unwrap()}));
    });
}
pub(super) fn start(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let code = "let text = \"ä🙂 <&> e\u{301}\";\r\n\t  \r\n";
    let source=format!("# Code copy\r\n\r\n```swift\r\n{code}```\r\n\r\n  \r\nEnd.\r\n\r\n    Indented 🙂\r\n    second\r\n\r\n```text\r\n{}\r\n```\r\n", "Long visible code ".repeat(100));
    let eol = std::env::var("FASTRA_CODE_COPY_EOL").unwrap_or_default();
    let source = match eol.as_str() {
        "lf" => source.replace("\r\n", "\n"),
        "cr" => source.replace("\r\n", "\r"),
        _ => source,
    };
    ui.add_document("code-copy.md", &source);
    let doc = ui.active().unwrap();
    doc.buffer.set_modified(false);
    doc.markdown_toggle
        .borrow()
        .as_ref()
        .unwrap()
        .set_active(true);
    git_view::test_size(ui.window.upcast_ref());
    let preview = doc.markdown.borrow().clone().unwrap();
    let reply = Rc::new(RefCell::new(None));
    let stage = Cell::new(0);
    let token = RefCell::new(String::new());
    let expected = RefCell::new(String::new());
    let cursor = doc.buffer.cursor_position();
    let revision = doc.revision.get();
    let pause = Cell::new(Instant::now());
    let start = Instant::now();
    let previous = Cell::new(u32::MAX);
    let copy_round = Cell::new(0);
    let selected_plain = RefCell::new(String::new());
    let undo_revision = Cell::new(0);
    let resize_width = Cell::new(0);
    let printed = Rc::new(Cell::new(false));
    let print_job = RefCell::new(None::<webkit6::PrintOperation>);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            start.elapsed() < Duration::from_secs(70),
            "codecopy stage {} status {}",
            stage.get(),
            preview.status.text()
        );
        if previous.replace(stage.get()) != stage.get() {
            eprintln!("codecopy native stage {}", stage.get());
        }
        match stage.get() {
            0 => {
                if preview.print_token(doc.revision.get()).is_some() {
                    inspect(&preview,"try{await fetch('https://example.invalid/codecopy-csp')}catch{}await new Promise(r=>setTimeout(r,40));const b=document.querySelector('.fastra-code-copy'),c=document.querySelector('pre>code');return JSON.stringify(b&&window.fastraPreviewReady&&document.documentElement.dataset.fastraPositionEpoch?{x:b.getBoundingClientRect().x+16,y:b.getBoundingClientRect().y+16,text:c.textContent,token:document.documentElement.dataset.fastraRender+':'+document.documentElement.dataset.fastraPositionEpoch,blocked:fastraPreviewViolations.some(v=>v.blocked.startsWith('https://')),handlers:['markdownPosition','visualMarkdown','markdownCopy','markdownCodeCopy','apply','save','writeFile','execute'].filter(name=>typeof window.webkit?.messageHandlers?.[name]?.postMessage==='function').sort(),highlight:!!c.querySelector('span'),count:document.querySelectorAll('.fastra-code-copy').length}:null);",&reply);
                    stage.set(1);
                }
            }
            1 => {
                if let Some(v) = reply.borrow_mut().take() {
                    if v.is_null() {
                        stage.set(0);
                    } else {
                        assert_eq!(
                            v["handlers"],
                            serde_json::json!(["markdownCodeCopy", "markdownPosition"])
                        );
                        assert_eq!(v["blocked"], true);
                        assert_eq!(v["count"], 3);
                        assert_eq!(v["highlight"], true);
                        *expected.borrow_mut() = v["text"].as_str().unwrap().into();
                        *token.borrow_mut() = v["token"].as_str().unwrap().into();
                        let old_formats = [
                            gtk::gdk::ContentProvider::for_value(&"sentinel".to_value()),
                            gtk::gdk::ContentProvider::for_bytes(
                                "text/html",
                                &glib::Bytes::from_static(b"<b>old</b>"),
                            ),
                            gtk::gdk::ContentProvider::for_bytes(
                                "text/rtf",
                                &glib::Bytes::from_static(br"{\rtf1 old}"),
                            ),
                        ];
                        preview
                            .view
                            .clipboard()
                            .set_content(Some(&gtk::gdk::ContentProvider::new_union(&old_formats)))
                            .unwrap();
                        input(
                            &preview.view,
                            v["x"].as_f64().unwrap(),
                            v["y"].as_f64().unwrap(),
                            None,
                        );
                        pause.set(Instant::now());
                        stage.set(2);
                    }
                }
            }
            2 if pause.get().elapsed() > Duration::from_millis(300) => {
                read(&preview, &reply);
                stage.set(3);
            }
            3 => {
                if reply.borrow().is_some()
                    && !git_view::try_capture(ui.window.upcast_ref(), "code-copy-native")
                {
                    return glib::ControlFlow::Continue;
                }
                if let Some(v) = reply.borrow_mut().take() {
                    assert_eq!(v.as_str(), Some(expected.borrow().as_str()));
                    assert!(!preview
                        .view
                        .clipboard()
                        .formats()
                        .contain_mime_type("text/html"));
                    assert!(!preview
                        .view
                        .clipboard()
                        .formats()
                        .contain_mime_type("text/rtf"));
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert_eq!(doc.revision.get(), revision);
                    assert_eq!(doc.buffer.cursor_position(), cursor);
                    assert!(!doc.buffer.can_undo());
                    let providers = [
                        gtk::gdk::ContentProvider::for_value(&"sentinel".to_value()),
                        gtk::gdk::ContentProvider::for_bytes(
                            "text/html",
                            &glib::Bytes::from_static(b"<b>sentinel</b>"),
                        ),
                    ];
                    preview
                        .view
                        .clipboard()
                        .set_content(Some(&gtk::gdk::ContentProvider::new_union(&providers)))
                        .unwrap();
                    handle(
                        &preview,
                        Some(
                            &serde_json::json!({"token":*token.borrow(),"block":9999,"request":2})
                                .to_string(),
                        ),
                    );
                    read(&preview, &reply);
                    stage.set(4);
                }
            }
            4 => {
                if let Some(v) = reply.borrow_mut().take() {
                    assert_eq!(v, "sentinel");
                    assert!(preview
                        .view
                        .clipboard()
                        .formats()
                        .contain_mime_type("text/html"));
                    preview.schedule(&doc, ui.lang);
                    handle(
                        &preview,
                        Some(
                            &serde_json::json!({"token":*token.borrow(),"block":0,"request":3})
                                .to_string(),
                        ),
                    );
                    read(&preview, &reply);
                    stage.set(5);
                }
            }
            5 => {
                if let Some(v) = reply.borrow_mut().take() {
                    assert_eq!(v, "sentinel");
                    stage.set(6);
                }
            }
            6 => {
                if let Some(new) = preview
                    .print_token(doc.revision.get())
                    .filter(|t| !token.borrow().starts_with(t))
                {
                    *token.borrow_mut() = format!("{new}:{}", preview.positions.epoch());
                    let current = ui.tabs.current_page();
                    ui.add_document("other.md", "Other");
                    ui.tabs.set_current_page(current);
                    handle(
                        &preview,
                        Some(
                            &serde_json::json!({"token":*token.borrow(),"block":0,"request":4})
                                .to_string(),
                        ),
                    );
                    read(&preview, &reply);
                    stage.set(7);
                }
            }
            7 => {
                if let Some(v) = reply.borrow_mut().take() {
                    assert_eq!(v, "sentinel");
                    stage.set(8);
                }
            }
            8 => {
                if let Some(new) = preview.print_token(doc.revision.get()) {
                    preview.view.grab_focus();
                    *token.borrow_mut() = format!("{new}:{}", preview.positions.epoch());
                    inspect(&preview,"const b=document.querySelector('.fastra-code-copy');if(!b||!window.fastraPreviewReady||!document.documentElement.dataset.fastraPositionEpoch)return JSON.stringify(false);b.focus();return JSON.stringify(document.activeElement===b);",&reply);
                    stage.set(9);
                }
            }
            9 => {
                if let Some(v) = reply.borrow_mut().take() {
                    if v != true {
                        stage.set(8);
                    } else {
                        input(&preview.view, 0., 0., Some("space"));
                        pause.set(Instant::now());
                        stage.set(10);
                    }
                }
            }
            10 if pause.get().elapsed() > Duration::from_millis(300) => {
                read(&preview, &reply);
                stage.set(11);
            }
            11 => {
                if let Some(v) = reply.borrow_mut().take() {
                    assert_eq!(v.as_str(), Some(expected.borrow().as_str()));
                    inspect(&preview,"const c=document.querySelector('pre>code'),r=document.createRange();r.selectNodeContents(c);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify({selected:getSelection().toString(),controls:document.getElementById('fastra-code-controls').parentElement===document.body,overflow:document.documentElement.scrollWidth<=innerWidth+1,printRule:[...document.styleSheets].flatMap(s=>{try{return [...s.cssRules]}catch{return []}}).some(r=>r.conditionText==='print'&&r.cssText.includes('display: none'))});",&reply);
                    stage.set(12);
                }
            }
            12 => {
                if let Some(v) = reply.borrow_mut().take() {
                    assert_eq!(v["selected"].as_str(), Some(expected.borrow().as_str()));
                    assert_eq!(v["controls"], true);
                    assert_eq!(v["overflow"], true);
                    assert_eq!(v["printRule"], true);
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert_eq!(doc.revision.get(), revision);
                    assert!(!doc.buffer.can_undo());
                    stage.set(13);
                }
            }
            13 => {
                preview.view.grab_focus();
                let setup=match copy_round.get(){1=>"document.querySelectorAll('.fastra-visible-blank-line').forEach(n=>n.remove());const r=document.createRange();r.selectNodeContents(document.body);",2=>"const p=document.querySelector('p');if(!p?.hasAttribute('data-srcline'))return JSON.stringify(null);const r=document.createRange();r.selectNode(p);",_=>"const r=document.createRange();r.selectNodeContents(document.body);"};
                inspect(&preview,&format!("{setup}getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(getSelection().toString());"),&reply);
                stage.set(14);
            }
            14 => {
                if let Some(v) = reply.borrow_mut().take() {
                    *selected_plain.borrow_mut() = v.as_str().unwrap().into();
                    input(&preview.view, 0., 0., Some("ctrl+c"));
                    pause.set(Instant::now());
                    stage.set(15);
                }
            }
            15 if pause.get().elapsed() > Duration::from_millis(400) => {
                read_formats(&preview, &reply);
                stage.set(16);
            }
            16 => {
                if let Some(value) = reply.borrow_mut().take() {
                    let html = value["html"].as_str().unwrap();
                    let plain = value["plain"].as_str().unwrap();
                    assert!(
                        !html.contains("fastra-code-controls")
                            && !html.contains("fastra-code-copy")
                            && !html.contains("<svg")
                            && !html.contains("data-fastra-code")
                            && !html.contains("data-srcline"),
                        "control/marker leak: {html}"
                    );
                    assert_eq!(plain, selected_plain.borrow().as_str());
                    assert!(!plain.contains("Code copied") && !plain.contains("Code kopiert"));
                    let selector = if copy_round.get() == 2 {
                        "p"
                    } else {
                        "pre>code"
                    };
                    let script=format!("const d=new DOMParser().parseFromString({},'text/html');return JSON.stringify(d.querySelector('{selector}')?.textContent);",serde_json::json!(html));
                    inspect(&preview, &script, &reply);
                    stage.set(17);
                }
            }
            17 => {
                if let Some(value) = reply.borrow_mut().take() {
                    if copy_round.get() == 2 {
                        assert_eq!(value, "End.");
                    } else {
                        assert_eq!(value.as_str(), Some(expected.borrow().as_str()));
                    }
                    if copy_round.get() < 2 {
                        copy_round.set(copy_round.get() + 1);
                        stage.set(13);
                    } else {
                        inspect(
                            &preview,
                            "getSelection().removeAllRanges();return JSON.stringify(true);",
                            &reply,
                        );
                        stage.set(18);
                    }
                }
            }
            18 => {
                if reply.borrow_mut().take().is_some() {
                    let operation = webkit6::PrintOperation::new(&preview.view);
                    let done = printed.clone();
                    operation.connect_finished(move |_| done.set(true));
                    operation.connect_failed(|_, error| panic!("native code print: {error}"));
                    let settings = gtk::PrintSettings::new();
                    settings.set_printer("Print to File");
                    let path =
                        std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap())
                            .join("code-controls-hidden.pdf");
                    settings.set("output-uri", Some(&gio::File::for_path(path).uri()));
                    settings.set("output-file-format", Some("pdf"));
                    operation.set_print_settings(&settings);
                    operation.print();
                    *print_job.borrow_mut() = Some(operation);
                    stage.set(19);
                }
            }
            19 if printed.get() => {
                inspect(
                    &preview,
                    "return JSON.stringify({screen:getComputedStyle(document.getElementById('fastra-code-controls')).display,hidden:document.getElementById('fastra-code-controls').hidden});",
                    &reply,
                );
                stage.set(20);
            }
            20 => {
                if let Some(value) = reply.borrow_mut().take() {
                    assert_eq!(value["screen"], "block");
                    assert_eq!(value["hidden"], false);
                    let path =
                        std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap())
                            .join("code-controls-hidden.pdf");
                    assert!(std::fs::metadata(path).unwrap().len() > 1000);
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert_eq!(doc.revision.get(), revision);
                    assert!(!doc.buffer.can_undo());
                    preview.view.clipboard().set_text("revision-sentinel");
                    doc.buffer.begin_user_action();
                    let mut end = doc.buffer.end_iter();
                    doc.buffer.insert(&mut end, "source-change");
                    doc.buffer.end_user_action();
                    handle(
                        &preview,
                        Some(
                            &serde_json::json!({"token":*token.borrow(),"block":0,"request":50})
                                .to_string(),
                        ),
                    );
                    read(&preview, &reply);
                    stage.set(21);
                }
            }
            21 => {
                if let Some(value) = reply.borrow_mut().take() {
                    assert_eq!(value, "revision-sentinel");
                    assert_ne!(buffer_text(&doc.buffer), source);
                    doc.buffer.undo();
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert!(doc.buffer.can_redo());
                    undo_revision.set(doc.revision.get());
                    doc.markdown_toggle
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .set_active(false);
                    doc.markdown_toggle
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .set_active(true);
                    handle(
                        &preview,
                        Some(
                            &serde_json::json!({"token":*token.borrow(),"block":0,"request":51})
                                .to_string(),
                        ),
                    );
                    read(&preview, &reply);
                    stage.set(22);
                }
            }
            22 => {
                if let Some(value) = reply.borrow_mut().take() {
                    assert_eq!(value, "revision-sentinel");
                    stage.set(23);
                }
            }
            23 => {
                if let Some(new) = preview.print_token(doc.revision.get()) {
                    let script=format!("if(document.documentElement.dataset.fastraRender!=={}||!window.fastraPreviewReady||document.documentElement.dataset.fastraPositionEpoch!=={})return JSON.stringify(null);const b=document.querySelector('.fastra-code-copy');return JSON.stringify(b?{{x:b.getBoundingClientRect().x+16,y:b.getBoundingClientRect().y+16}}:null);",serde_json::json!(new),serde_json::json!(preview.positions.epoch()));
                    inspect(&preview, &script, &reply);
                    stage.set(24);
                }
            }
            24 => {
                if let Some(value) = reply.borrow_mut().take() {
                    if value.is_null() {
                        stage.set(23);
                    } else {
                        input(
                            &preview.view,
                            value["x"].as_f64().unwrap(),
                            value["y"].as_f64().unwrap(),
                            None,
                        );
                        pause.set(Instant::now());
                        stage.set(25);
                    }
                }
            }
            25 if pause.get().elapsed() > Duration::from_millis(300) => {
                read(&preview, &reply);
                stage.set(26);
            }
            26 => {
                if let Some(value) = reply.borrow_mut().take() {
                    assert_eq!(value.as_str(), Some(expected.borrow().as_str()));
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert_eq!(doc.revision.get(), undo_revision.get());
                    assert!(doc.buffer.can_redo());
                    assert!(!doc.buffer.can_undo());
                    inspect(&preview,"const pre=[...document.querySelectorAll('pre[data-fastra-code]')].at(-1);pre.scrollIntoView({block:'center'});const c=pre.querySelector('code');const s=c.scrollWidth>c.clientWidth?c:pre;s.scrollLeft=400;return JSON.stringify(true);",&reply);
                    stage.set(27);
                }
            }
            27 => {
                if reply.borrow_mut().take().is_some() {
                    pause.set(Instant::now());
                    stage.set(28);
                }
            }
            28 if pause.get().elapsed() > Duration::from_millis(250) => {
                inspect(&preview,"const p=[...document.querySelectorAll('pre[data-fastra-code]')].at(-1),c=p.querySelector('code'),b=document.getElementById('fastra-code-controls').lastElementChild,pr=p.getBoundingClientRect(),br=b.getBoundingClientRect();return JSON.stringify({x:br.x+16,y:br.y+16,text:c.textContent,visible:!b.hidden&&br.left>=0&&br.right<=innerWidth+1&&Math.abs(br.top-pr.top-8)<1,scrolled:scrollY>0&&(c.scrollLeft>0||p.scrollLeft>0)});",&reply);
                stage.set(29);
            }
            29 => {
                if reply.borrow().is_some()
                    && !git_view::try_capture(ui.window.upcast_ref(), "code-copy-scrolled")
                {
                    return glib::ControlFlow::Continue;
                }
                if let Some(value) = reply.borrow_mut().take() {
                    assert_eq!(value["visible"], true);
                    assert_eq!(value["scrolled"], true);
                    *expected.borrow_mut() = value["text"].as_str().unwrap().into();
                    input(
                        &preview.view,
                        value["x"].as_f64().unwrap(),
                        value["y"].as_f64().unwrap(),
                        None,
                    );
                    pause.set(Instant::now());
                    stage.set(30);
                }
            }
            30 if pause.get().elapsed() > Duration::from_millis(300) => {
                read(&preview, &reply);
                stage.set(31);
            }
            31 => {
                if let Some(value) = reply.borrow_mut().take() {
                    assert_eq!(value.as_str(), Some(expected.borrow().as_str()));
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert_eq!(doc.revision.get(), undo_revision.get());
                    assert!(doc.buffer.can_redo());
                    resize_width.set(ui.window.width());
                    ui.window
                        .set_default_size(ui.window.width() + 80, ui.window.height() + 30);
                    pause.set(Instant::now());
                    stage.set(32);
                }
            }
            32 if pause.get().elapsed() > Duration::from_millis(300) => {
                assert!(ui.window.width() > resize_width.get(), "real window resize");
                inspect(&preview,"const p=[...document.querySelectorAll('pre[data-fastra-code]')].at(-1),b=document.getElementById('fastra-code-controls').lastElementChild,pr=p.getBoundingClientRect(),br=b.getBoundingClientRect();return JSON.stringify({x:br.x+16,y:br.y+16,visible:!b.hidden&&br.left>=0&&br.right<=innerWidth+1&&Math.abs(br.top-pr.top-8)<1});",&reply);
                stage.set(33);
            }
            33 => {
                if let Some(value) = reply.borrow_mut().take() {
                    assert_eq!(value["visible"], true);
                    preview.view.clipboard().set_text("resize-sentinel");
                    input(
                        &preview.view,
                        value["x"].as_f64().unwrap(),
                        value["y"].as_f64().unwrap(),
                        None,
                    );
                    pause.set(Instant::now());
                    stage.set(34);
                }
            }
            34 if pause.get().elapsed() > Duration::from_millis(300) => {
                read(&preview, &reply);
                stage.set(35);
            }
            35 => {
                if let Some(value) = reply.borrow_mut().take() {
                    assert_eq!(value.as_str(), Some(expected.borrow().as_str()));
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert_eq!(doc.revision.get(), undo_revision.get());
                    assert!(doc.buffer.can_redo());
                    println!("PASS Codecopy native click+keyboard, Unicode/LF-or-CRLF/whitespace DOM equality, plain-only MIME replaces old HTML+RTF, unknown/stale/Tab-ABA/revision-ABA/mode-ABA sentinel preservation, Copy after SourceUndo retains Redo, actual Ctrl+C HTML+Plain cleanup with/without BLANK and source-marker-only paragraph, code inner bytes exact, real vertical+horizontal scroll and window resize with full long-code copy, actual native PDF generated, screencontrols remain visible; PDF print-CSS visually verified separately");
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
