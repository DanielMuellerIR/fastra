use super::*;
use std::time::{Duration, Instant};
fn preview(lang: Language) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .iter()
        .filter_map(|v| v.clone().downcast::<gtk::Window>().ok())
        .find(|window| {
            window.is_visible()
                && window.title().as_deref()
                    == Some(lang.text("Bilder und Dateien einfügen", "Insert images and files"))
        })
}
fn apply(window: &gtk::Window, lang: Language) {
    let button = gui_test::button(
        window.child().unwrap().upcast_ref(),
        lang.text("Bilder speichern und einfügen", "Save images and insert"),
    )
    .unwrap();
    gui_test::input(&button, true, &[]);
}
fn bookmark(editor: &Rc<RichEditor>, reply: &Rc<RefCell<Option<Value>>>) {
    let reply = reply.clone();
    editor.evaluate("const root=document.getElementById('fastra-visual'),range=document.createRange();range.selectNodeContents(root.lastElementChild);range.collapse(false);getSelection().removeAllRanges();getSelection().addRange(range);root.focus();await new Promise(r=>setTimeout(r,30));return JSON.stringify(fastraVisual.bookmarkClipboard());",move|value|*reply.borrow_mut()=value);
}
pub(super) fn run(a: Rc<Ui>, ea: Rc<RichEditor>) {
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    let path = root.join("receiver/receiver.md");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, "==Receiver== and **Bold&nbsp;**\n").unwrap();
    let b = crate::build(&a.window.application().unwrap());
    b.window.set_default_size(a.window.width(), 850);
    let png = include_bytes!("../../tests/fixtures/pixel-1.png").to_vec();
    let phase = Cell::new(0);
    let started = Instant::now();
    let delay = Cell::new(Instant::now());
    let reply = Rc::new(RefCell::new(None::<Value>));
    let eb = RefCell::new(None::<Rc<RichEditor>>);
    let shots = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            started.elapsed() < Duration::from_secs(90),
            "asset transfer {} A={} B={:?}",
            phase.get(),
            ea.status.text(),
            eb.borrow().as_ref().map(|e| e.status.text())
        );
        if delay.get().elapsed() < Duration::from_millis(150) {
            return glib::ControlFlow::Continue;
        }
        let next = |n| {
            eprintln!("Asset transfer {n}");
            phase.set(n);
            delay.set(Instant::now());
        };
        match phase.get() {
            0 => {
                ea.view.clipboard().set_text("OLD");
                let response = reply.clone();
                ea.evaluate("const range=document.createRange();range.selectNode(document.querySelector('#fastra-visual img'));getSelection().removeAllRanges();getSelection().addRange(range);document.getElementById('fastra-visual').focus();await new Promise(r=>setTimeout(r,30));return JSON.stringify(true);",move|v|*response.borrow_mut()=v);
                next(1);
            }
            1 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(&ea.view, false, &["ctrl+c"]);
                next(2);
            }
            2 => {
                if !ea
                    .view
                    .clipboard()
                    .formats()
                    .contain_mime_type(clipboard::MIME)
                {
                    return glib::ControlFlow::Continue;
                }
                let clipboard = ea.view.clipboard();
                let response = reply.clone();
                let expected = png.clone();
                glib::spawn_future_local(async move {
                    let (stream, mime) = clipboard
                        .read_future(&["text/html"], glib::Priority::DEFAULT)
                        .await
                        .unwrap();
                    let transfer::Transfer::Html(html) =
                        transfer::stream(stream, &mime).await.unwrap()
                    else {
                        panic!()
                    };
                    assert!(html.contains("data:image/png;base64,"));
                    assert!(!html.contains(images::PREFIX));
                    assert!(!html.contains("data-md-"));
                    let clipboard::Incoming::Assets(transfer::Transfer::Markdown {
                        images, ..
                    }) = clipboard::read(clipboard, false).await.unwrap()
                    else {
                        panic!("No actual image package")
                    };
                    assert_eq!(images.len(), 1);
                    assert_eq!(*images[0].bytes, expected);
                    *response.borrow_mut() = Some(Value::Bool(true));
                });
                next(3);
            }
            3 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                ea.command("undo");
                next(30);
            }
            30 => {
                if ea.busy.get() || ea.expected.borrow().contains("images/1.png") {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    root.join("images/1.png").exists(),
                    "Saved document still protects the asset"
                );
                crate::git_view::test_keys(&ea.view, &["ctrl+s"]);
                next(31);
            }
            31 => {
                if ea.busy.get() || root.join("images/1.png").exists() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    ea.assets
                        .borrow()
                        .records
                        .values()
                        .next()
                        .unwrap()
                        .receipt
                        .recovery_paths()
                        .len(),
                    1
                );
                b.window.present();
                b.load_path(path.clone());
                next(4);
            }
            4 => {
                let Some(doc) = b
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                mode_toggle(&doc, b.lang).set_active(true);
                next(5);
            }
            5 => {
                let Some(editor) = b
                    .active()
                    .and_then(|doc| doc.rich.borrow().clone())
                    .filter(|e| e.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                bookmark(&editor, &reply);
                *eb.borrow_mut() = Some(editor);
                next(6);
            }
            6 => {
                let Some(Value::String(key)) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                eb.borrow().as_ref().unwrap().paste(key, false);
                next(7);
            }
            7 => {
                let Some(window) = preview(b.lang) else {
                    return glib::ControlFlow::Continue;
                };
                apply(&window, b.lang);
                next(8);
            }
            8 => {
                let editor = eb.borrow().clone().unwrap();
                if editor.busy.get() || !editor.expected.borrow().contains("images/1.png") {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    std::fs::read(root.join("receiver/images/1.png")).unwrap(),
                    png
                );
                assert!(
                    editor
                        .expected
                        .borrow()
                        .starts_with("==Receiver== and **Bold&nbsp;**")
                );
                let html = format!(
                    "<p><mark>Marked</mark><img src=\"data:image/png;base64,{}\" alt=\"Copied\"></p>",
                    glib::base64_encode(&png)
                );
                editor
                    .view
                    .clipboard()
                    .set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
                        "text/html",
                        &glib::Bytes::from_owned(html.into_bytes()),
                    )))
                    .unwrap();
                bookmark(&editor, &reply);
                next(9);
            }
            9 => {
                let Some(Value::String(key)) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                eb.borrow().as_ref().unwrap().paste(key, false);
                next(10);
            }
            10 => {
                let Some(window) = preview(b.lang) else {
                    return glib::ControlFlow::Continue;
                };
                if !gui_test::capture(&window, "asset-html-preview", &shots) {
                    return glib::ControlFlow::Continue;
                }
                apply(&window, b.lang);
                next(11);
            }
            11 => {
                let editor = eb.borrow().clone().unwrap();
                if editor.busy.get() || !editor.expected.borrow().contains("images/2.png") {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    std::fs::read(root.join("receiver/images/2.png")).unwrap(),
                    png
                );
                assert!(editor.expected.borrow().contains("==Marked=="));
                assert!(!editor.failed.get(), "{}", editor.status.text());
                if !gui_test::capture(&b.window, "asset-cross-window-html", &shots) {
                    return glib::ControlFlow::Continue;
                }
                println!(
                    "PASS native assets transfer: actual Ctrl+C/private package/HTML data image, cross-window target materialization, Mark and NBSP, full image bytes; first flow already proved Cancel/Apply/Save/Undo/Redo"
                );
                editor.command("undo");
                next(40);
            }
            40 => {
                let editor = eb.borrow().clone().unwrap();
                if editor.busy.get() || editor.expected.borrow().contains("images/2.png") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!root.join("receiver/images/2.png").exists());
                let doc = editor.document.upgrade().unwrap();
                gui_test::input(&mode_toggle(&doc, b.lang), true, &[]);
                next(41);
            }
            41 => {
                let doc = b.active().unwrap();
                if doc.rich.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    std::fs::read(root.join("receiver/images/2.png")).unwrap(),
                    png,
                    "source Undo keeps approved image names available"
                );
                let source = crate::source_panes::capture(&doc).unwrap().view;
                source.grab_focus();
                crate::git_view::test_keys(&source, &["ctrl+z"]);
                next(42);
            }
            42 => {
                let doc = b.active().unwrap();
                if !buffer_text(&doc.buffer).contains("images/2.png") {
                    return glib::ControlFlow::Continue;
                }
                gui_test::input(&mode_toggle(&doc, b.lang), true, &[]);
                next(43);
            }
            43 => {
                let Some(editor) = b
                    .active()
                    .and_then(|doc| doc.rich.borrow().clone())
                    .filter(|e| e.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!editor.failed.get(), "{}", editor.status.text());
                let response = reply.clone();
                editor.evaluate("return JSON.stringify(Array.from(document.querySelectorAll('#fastra-visual img'),image=>image.naturalWidth));",move|value|*response.borrow_mut()=value);
                *eb.borrow_mut() = Some(editor);
                next(44);
            }
            44 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value, json!([1, 1]));
                println!(
                    "PASS saved-reference protection/deferred cleanup and Rich→Source Undo→Rich image availability"
                );
                asset_gui_drop::run(a.clone(), b.clone(), eb.borrow().clone().unwrap());
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
