use super::*;
use std::time::{Duration, Instant};
fn labels(root: &gtk::Widget) -> Vec<gtk::Label> {
    let mut out = root
        .clone()
        .downcast::<gtk::Label>()
        .ok()
        .into_iter()
        .collect::<Vec<_>>();
    for child in chrome::children(root) {
        out.extend(labels(&child));
    }
    out
}
fn row(root: &gtk::Widget, title: &str) -> Option<gtk::Widget> {
    let mut widget = labels(root)
        .into_iter()
        .find(|l| l.is_mapped() && l.text() == title)?
        .upcast::<gtk::Widget>();
    while !widget.has_css_class("document-outline-row") {
        widget = widget.parent()?;
    }
    Some(widget)
}
fn query(editor: &Rc<RichEditor>, result: &Rc<RefCell<Option<Value>>>) {
    let target = result.clone();
    editor.evaluate("const n=getSelection().anchorNode,h=(n?.nodeType===1?n:n?.parentElement)?.closest('h1,h2,h3');return JSON.stringify({index:fastraVisual.outlinePosition(),title:h?.textContent,y:scrollY,count:fastraVisual.outlineSnapshot().headings.length});",move|v|*target.borrow_mut()=v);
}
pub(crate) fn start(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("rich-outline.md");
    let source=format!("# First &amp; **bold**\n\n{}\n## Second `code`\n\n{}\n<div><h1>Hidden HTML</h1></div>\n\n```md\n# Hidden code\n```\n\n{}", "paragraph\n\n".repeat(30),"middle\n\n".repeat(20),(1..=205).map(|i|format!("### Item {i}\n\n")).collect::<String>());
    std::fs::write(&path, &source).unwrap();
    git_view::test_size(ui.window.upcast_ref());
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(Instant::now());
    let result = Rc::new(RefCell::new(None::<Value>));
    let capture = RefCell::new(None);
    let original = RefCell::new(None::<Rc<Document>>);
    let paragraph = Cell::new(0);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            began.elapsed() < Duration::from_secs(60),
            "rich outline phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(120) {
            return glib::ControlFlow::Continue;
        }
        let Some(doc) = original.borrow().clone().or_else(|| {
            ui.active()
                .filter(|d| d.disk_path().as_ref() == Some(&path))
        }) else {
            return glib::ControlFlow::Continue;
        };
        if original.borrow().is_none() {
            *original.borrow_mut() = Some(doc.clone());
        }
        let editor = doc.rich.borrow().clone();
        let outline = editor.as_ref().and_then(|e| e.outline.borrow().clone());
        match phase.get() {
            0 => {
                super::super::mode_toggle(&doc, ui.lang).set_active(true);
            }
            1 => {
                let Some(outline) = outline.filter(|v| v.menu.is_mapped() && v.menu.is_sensitive())
                else {
                    return glib::ControlFlow::Continue;
                };
                if !editor.as_ref().unwrap().ready.get() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&outline.menu, &[]);
            }
            2 => {
                let outline = outline.unwrap();
                if row(outline.popup.upcast_ref(), "Second code").is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(outline.popup.child().unwrap().width() + 28, 320);
                assert!(!labels(outline.popup.upcast_ref())
                    .iter()
                    .any(|l| l.text().contains("Hidden")));
                if !git_view::try_capture_x11(&outline.popup, "rich-outline-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(
                    &row(outline.popup.upcast_ref(), "Second code").unwrap(),
                    &[],
                );
            }
            3 => {
                let outline = outline.unwrap();
                if outline.popup.is_visible() || !outline.back.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                query(editor.as_ref().unwrap(), &result);
            }
            4 => {
                if !git_view::try_capture_x11(&ui.window, "rich-outline-owner-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                let Some(value) = result.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["index"], 1);
                assert_eq!(value["count"], 207);
                assert_eq!(value["title"], "Second code");
                assert!(value["y"].as_f64().unwrap() > 0.);
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                git_view::test_click(&outline.unwrap().back, &[]);
            }
            5 => query(editor.as_ref().unwrap(), &result),
            6 => {
                let Some(value) = result.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["index"], 0);
                assert!(doc.is_rich_active());
                git_view::test_click(&outline.unwrap().forward, &[]);
            }
            7 => query(editor.as_ref().unwrap(), &result),
            8 => {
                let Some(value) = result.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["index"], 1);
                let editor = editor.unwrap();
                editor.view.grab_focus();
                git_view::test_keys(
                    &editor.view,
                    &[
                        "--clearmodifiers",
                        "--delay",
                        "30",
                        "C",
                        "h",
                        "a",
                        "n",
                        "g",
                        "e",
                        "d",
                        "space",
                    ],
                );
            }
            9 => {
                if !buffer_text(&doc.buffer).contains("Changed Second") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&outline.unwrap().menu, &[]);
            }
            10 => {
                let outline = outline.unwrap();
                if row(outline.popup.upcast_ref(), "Changed Second code").is_none() {
                    return glib::ControlFlow::Continue;
                }
                if result.borrow().is_none() {
                    query(editor.as_ref().unwrap(), &result);
                    return glib::ControlFlow::Continue;
                }
                let observed = result.borrow_mut().take().unwrap();
                assert!(
                    row(outline.popup.upcast_ref(), "Changed Second code")
                        .unwrap()
                        .has_css_class("current"),
                    "current Rich row missing: DOM={observed} focus={}",
                    editor.as_ref().unwrap().view.has_focus()
                );
                if !git_view::try_capture_x11(
                    &outline.popup,
                    "rich-outline-changed-native",
                    &capture,
                ) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(
                    &row(outline.popup.upcast_ref(), "First & bold").unwrap(),
                    &[],
                );
            }
            11 => {
                if outline.as_ref().unwrap().popup.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&outline.unwrap().back, &[]);
            }
            12 => query(editor.as_ref().unwrap(), &result),
            13 => {
                let Some(value) = result.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["index"], 1);
                assert_eq!(value["title"], "Changed Second code");
                let target = result.clone();
                editor
                    .as_ref()
                    .unwrap()
                    .outline_snapshot(move |v| *target.borrow_mut() = Some(json!(v.is_none())));
                let page = ui.tabs.current_page().unwrap();
                ui.add_document("other.md", "# Other\n");
                ui.tabs.set_current_page(Some(page));
            }
            14 => {
                let Some(value) = result.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value, true);
                super::super::mode_toggle(&doc, ui.lang).set_active(false);
            }
            15 => {
                if doc.is_rich_active() {
                    return glib::ControlFlow::Continue;
                }
                let offset = buffer_text(&doc.buffer).find("paragraph").unwrap() as i32;
                paragraph.set(offset);
                doc.buffer.place_cursor(&doc.buffer.iter_at_offset(offset));
                let outline = doc.outline.borrow().clone().unwrap();
                git_view::test_click(&outline.menu, &[]);
            }
            16 => {
                let outline = doc.outline.borrow().clone().unwrap();
                let Some(row) = row(outline.popup.upcast_ref(), "First & bold") else {
                    return glib::ControlFlow::Continue;
                };
                if !outline.valid() || row.width() <= 0 || row.height() <= 0 {
                    return glib::ControlFlow::Continue;
                }
                if !git_view::try_capture_x11(
                    &outline.popup,
                    "rich-outline-source-native",
                    &capture,
                ) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&row, &[]);
            }
            17 => {
                let outline = doc.outline.borrow().clone().unwrap();
                if outline.popup.is_visible() || doc.buffer.cursor_position() != 0 {
                    return glib::ControlFlow::Continue;
                }
                super::super::mode_toggle(&doc, ui.lang).set_active(true);
            }
            18 => {
                let Some(editor) = editor.filter(|e| e.outline_stamp().is_some()) else {
                    return glib::ControlFlow::Continue;
                };
                let outline = editor.outline.borrow().clone().unwrap();
                if !outline.back.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&outline.back, &[]);
            }
            19 => {
                if doc.is_rich_active() || doc.buffer.cursor_position() != paragraph.get() {
                    return glib::ControlFlow::Continue;
                }
                let edited = buffer_text(&doc.buffer);
                assert!(edited.contains("Changed Second"));
                let mut steps = 0;
                while doc.buffer.can_undo() {
                    steps += 1;
                    assert!(steps <= 16);
                    doc.buffer.undo();
                }
                assert_eq!(buffer_text(&doc.buffer), source);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
            }
            20 => {
                if !git_view::try_capture_x11(&ui.window, "rich-outline-source-history", &capture) {
                    return glib::ControlFlow::Continue;
                }
                println!("FASTRA_RICH_OUTLINE_SELFTEST=PASS native-popup shared-renderer automatic-refresh native-typing real-DOM-heading-scroll back-forward rich-source-history tab-ABA no-navigation-undo unchanged-file");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        eprintln!("rich outline phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
