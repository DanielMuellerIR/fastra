use super::*;
use serde_json::Value;
fn query(editor: &crate::rich_editor::RichEditor, reply: &Rc<RefCell<Option<Value>>>, code: &str) {
    let target = reply.clone();
    editor.evaluate(code, move |v| *target.borrow_mut() = v);
}
pub(super) fn start(ui: Rc<Ui>) {
    seed(true);
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("snippet-rich.md");
    let source = "# Heading\n\n😀 target end\n\n";
    std::fs::write(&path, source).unwrap();
    let pixel = include_bytes!("../../../../tests/fixtures/pixel-1.png");
    std::fs::write(root.join("pixel.png"), pixel).unwrap();
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let pause = Cell::new(Instant::now());
    let began = Instant::now();
    let reply = Rc::new(RefCell::new(None));
    let shots = RefCell::new(None);
    let bound = RefCell::new(None::<Rc<Document>>);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            began.elapsed() < Duration::from_secs(65),
            "Rich snippet phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(350) {
            return glib::ControlFlow::Continue;
        }
        let Some(doc) = bound.borrow().clone().or_else(|| {
            ui.active()
                .filter(|d| d.disk_path().as_ref() == Some(&path))
        }) else {
            return glib::ControlFlow::Continue;
        };
        if bound.borrow().is_none() {
            *bound.borrow_mut() = Some(doc.clone());
        }
        let rich = doc.rich.borrow().clone();
        match phase.get() {
            0 => {
                crate::git_view::test_click(doc.rich_toggle.borrow().as_ref().unwrap(), &[]);
            }
            1 => {
                let Some(e) = rich.filter(|e| e.outline_stamp().is_some()) else {
                    return glib::ControlFlow::Continue;
                };
                query(&e,&reply,"const root=document.getElementById('fastra-visual'),p=[...root.querySelectorAll('p')].find(p=>p.textContent==='😀 target end'),r=document.createRange();r.setStart(p.firstChild,3);r.setEnd(p.firstChild,9);root.focus();getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(getSelection().toString());");
            }
            2 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value, "target");
                let e = rich.unwrap();
                let b = button(
                    e.widget.upcast_ref(),
                    ui.lang.text("Textbausteine…", "Text snippets…"),
                )
                .unwrap();
                crate::git_view::test_click(&b, &[]);
            }
            3 => {
                let Some(v) = view().filter(|v| !v.busy.get() && v.snapshot.borrow().is_some())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!v.dirty.get());
                assert!(matches!(v.snippet_target, Some(Target::Rich(_))));
                let width = std::env::var("FASTRA_TOOL_WIDTH")
                    .unwrap_or("760".into())
                    .parse::<i32>()
                    .unwrap();
                v.window
                    .set_default_size(width, if width == 760 { 650 } else { 740 });
                v.values.borrow()[0].1.buffer().set_text("bold");
                v.values.borrow()[1].1.buffer().set_text("x");
            }
            4 => {
                let v = view().unwrap();
                assert_eq!(
                    super::super::super::selftest::text(&v.after),
                    "**bold** / x / **bold**"
                );
                assert!(
                    v.apply.is_sensitive(),
                    "{}",
                    v.snippet_layout.as_ref().unwrap().stale.text()
                );
                if !crate::git_view::try_capture_x11(
                    &v.window,
                    "snippet-rich-dialog-native",
                    &shots,
                ) {
                    return glib::ControlFlow::Continue;
                }
                crate::git_view::test_click(&v.apply, &[]);
            }
            5 => {
                if view().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let e = rich.unwrap();
                assert!(
                    buffer_text(&doc.buffer).contains("**bold** / x / **bold**"),
                    "{}",
                    buffer_text(&doc.buffer)
                );
                query(&e,&reply,"return JSON.stringify({text:document.getElementById('fastra-visual').textContent,strong:document.querySelectorAll('#fastra-visual strong').length,active:document.activeElement.id,editable:document.getElementById('fastra-visual').isContentEditable});");
            }
            6 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(value["text"]
                    .as_str()
                    .unwrap()
                    .replace('\u{a0}', " ")
                    .contains("😀 bold / x / bold end"));
                assert_eq!(value["strong"], 2);
                assert_eq!(value["active"], "fastra-visual");
                assert_eq!(value["editable"], true);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
                if !crate::git_view::try_capture_x11(
                    &ui.window,
                    "snippet-rich-insert-native",
                    &shots,
                ) {
                    *reply.borrow_mut() = Some(value);
                    return glib::ControlFlow::Continue;
                }
                crate::git_view::test_keys(&rich.unwrap().view, &["ctrl+z"]);
            }
            7 => {
                let e = rich.unwrap();
                e.synchronize(false, Box::new(|ok| assert!(ok)));
            }
            8 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    source,
                    "one native WebKit Undo preserves original bytes"
                );
                let e = rich.unwrap();
                crate::git_view::test_keys(&e.view, &["ctrl+shift+z"]);
            }
            9 => {
                let e = rich.unwrap();
                e.synchronize(false, Box::new(|ok| assert!(ok)));
            }
            10 => {
                assert!(buffer_text(&doc.buffer).contains("**bold** / x / **bold**"));
                crate::git_view::test_keys(&rich.unwrap().view, &["ctrl+z"]);
            }
            11 => {
                let e = rich.unwrap();
                e.synchronize(false, Box::new(|ok| assert!(ok)));
            }
            12 => {
                assert_eq!(buffer_text(&doc.buffer), source);
                let e = rich.unwrap();
                query(&e,&reply,"const root=document.getElementById('fastra-visual'),p=root.querySelector('p'),r=document.createRange();r.selectNodeContents(p);root.focus();getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);");
            }
            13 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let e = rich.unwrap();
                crate::git_view::test_click(
                    &button(
                        e.widget.upcast_ref(),
                        ui.lang.text("Textbausteine…", "Text snippets…"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            14 => {
                let Some(v) = view().filter(|v| !v.busy.get() && v.snapshot.borrow().is_some())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(v.apply.is_sensitive());
                ui.add_document("other.md", "# Other");
            }
            15 => {
                let v = view().unwrap();
                assert!(!v.apply.is_sensitive());
                insert(&v);
                assert_eq!(buffer_text(&doc.buffer), source);
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "# Other");
                v.window.close();
            }
            16 => {
                assert!(view().is_none());
                let index = ui
                    .documents
                    .borrow()
                    .iter()
                    .position(|d| Rc::ptr_eq(d, &doc))
                    .unwrap();
                ui.tabs.set_current_page(Some(index as u32));
            }
            17 => {
                let e = rich.unwrap();
                query(&e,&reply,"const root=document.getElementById('fastra-visual'),p=root.querySelector('p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);root.focus();getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);");
            }
            18 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let e = rich.unwrap();
                crate::git_view::test_click(
                    &button(
                        e.widget.upcast_ref(),
                        ui.lang.text("Textbausteine…", "Text snippets…"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            19 => {
                let Some(v) = view().filter(|v| !v.busy.get() && v.snapshot.borrow().is_some())
                else {
                    return glib::ControlFlow::Continue;
                };
                v.template
                    .buffer()
                    .set_text("![pixel](pixel.png)\n\n{{Name}}");
                v.values.borrow()[0].1.buffer().set_text("picture");
            }
            20 => {
                let v = view().unwrap();
                crate::git_view::test_click(&v.save, &[]);
            }
            21 => {
                let v = view().unwrap();
                if v.busy.get() || v.dirty.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    super::super::super::selftest::text(&v.values.borrow()[0].1),
                    "picture"
                );
                assert!(v.apply.is_sensitive(), "{}", v.status.text());
                crate::git_view::test_click(&v.apply, &[]);
            }
            22 => {
                if view().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let e = rich.unwrap();
                query(&e,&reply,"const i=document.querySelector('#fastra-visual img');return JSON.stringify({loaded:i?.complete,width:i?.naturalWidth,alt:i?.alt,src:i?.getAttribute('src')});");
            }
            23 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                if value["loaded"] != true || value["width"] != 1 {
                    phase.set(22);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(value["alt"], "pixel");
                assert!(value["src"]
                    .as_str()
                    .unwrap()
                    .starts_with("fastra-rich://image/"));
                let events = crate::markdown::syntax::events(
                    &buffer_text(&doc.buffer),
                    &Cancellation::default(),
                )
                .unwrap();
                assert!(events.into_iter().any(|(e,_,_)|matches!(e,pulldown_cmark::Event::Start(pulldown_cmark::Tag::Image{dest_url,..}) if dest_url.as_ref()=="pixel.png")));
                if !crate::git_view::try_capture_x11(
                    &ui.window,
                    "snippet-rich-image-native",
                    &shots,
                ) {
                    *reply.borrow_mut() = Some(value);
                    return glib::ControlFlow::Continue;
                }
                crate::git_view::test_keys(&rich.unwrap().view, &["ctrl+z"]);
            }
            24 => {
                rich.unwrap().synchronize(false, Box::new(|ok| assert!(ok)));
            }
            25 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    source,
                    "one image/text insertion Undo"
                );
                assert_eq!(std::fs::read(root.join("pixel.png")).unwrap(), pixel);
            }
            _ => {
                assert!(view().is_none());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
                println!("FASTRA_SNIPPET_RICH_SELFTEST_OK actual-bookmark/native-toolbar/native-insert/formatted-markdown/captured-selection/native-undo-redo/relative-local-image/one-image-text-undo/source-bytes/stale-tab/no-disk-write");
                std::process::exit(0);
            }
        }
        eprintln!("Rich snippet phase{}", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
