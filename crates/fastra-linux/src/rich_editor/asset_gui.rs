use super::*;
use std::time::{Duration, Instant};
fn preview(lang: Language) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .iter()
        .filter_map(|widget| widget.clone().downcast::<gtk::Window>().ok())
        .find(|window| {
            window.is_visible()
                && window.title().as_deref()
                    == Some(lang.text("Bilder und Dateien einfügen", "Insert images and files"))
        })
}
fn click(window: &gtk::Window, label: &str) {
    let button = gui_test::button(window.child().unwrap().upcast_ref(), label).unwrap();
    gui_test::input(&button, true, &[]);
}
fn bookmark(editor: &Rc<RichEditor>, reply: &Rc<RefCell<Option<Value>>>) {
    let reply = reply.clone();
    editor.evaluate("const root=document.getElementById('fastra-visual'),range=document.createRange();range.selectNodeContents(root.lastElementChild);range.collapse(false);getSelection().removeAllRanges();getSelection().addRange(range);root.focus();await new Promise(r=>setTimeout(r,30));return JSON.stringify(fastraVisual.bookmarkClipboard());",move|value|*reply.borrow_mut()=value);
}
static STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(super) fn run(ui: Rc<Ui>) {
    if STARTED.swap(true, std::sync::atomic::Ordering::Relaxed) {
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("asset.md");
    let source = "Before **Bold**\n\nAfter untouched\n";
    let png = include_bytes!("../../tests/fixtures/pixel-1.png").to_vec();
    std::fs::write(&path, source).unwrap();
    ui.window.set_default_size(
        std::env::var("FASTRA_RICH_WIDTH")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(1180),
        850,
    );
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let start = Instant::now();
    let since = Cell::new(Instant::now());
    let editor = RefCell::new(None::<Rc<RichEditor>>);
    let reply = Rc::new(RefCell::new(None::<Value>));
    let saved = RefCell::new(String::new());
    let shots = RefCell::new(None);
    let selection_tested = Cell::new(false);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            start.elapsed() < Duration::from_secs(100),
            "asset phase {} status {:?}",
            phase.get(),
            editor.borrow().as_ref().map(|e| e.status.text())
        );
        if since.get().elapsed() < Duration::from_millis(150) {
            return glib::ControlFlow::Continue;
        }
        let next = |value| {
            eprintln!("Asset phase {value}");
            phase.set(value);
            since.set(Instant::now());
        };
        match phase.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                mode_toggle(&doc, ui.lang).set_active(true);
                next(1);
            }
            1 => {
                let Some(value) = ui
                    .active()
                    .and_then(|doc| doc.rich.borrow().clone())
                    .filter(|e| e.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!value.failed.get());
                let providers = [
                    gtk::gdk::ContentProvider::for_value(&"WRONG PLAIN".to_value()),
                    gtk::gdk::ContentProvider::for_bytes(
                        "image/png",
                        &glib::Bytes::from_owned(png.clone()),
                    ),
                ];
                value
                    .view
                    .clipboard()
                    .set_content(Some(&gtk::gdk::ContentProvider::new_union(&providers)))
                    .unwrap();
                assert_eq!(
                    transfer::preferred(&value.view.clipboard().formats(), false),
                    Some("image/png")
                );
                bookmark(&value, &reply);
                *editor.borrow_mut() = Some(value);
                next(2);
            }
            2 => {
                let Some(Value::String(key)) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                editor.borrow().as_ref().unwrap().paste(key, false);
                next(3);
            }
            3 => {
                let Some(window) = preview(ui.lang) else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!root.join("images").exists());
                click(&window, ui.lang.text("Abbrechen", "Cancel"));
                next(4);
            }
            4 => {
                if preview(ui.lang).is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!root.join("images").exists());
                let value = editor.borrow().clone().unwrap();
                assert_eq!(*value.expected.borrow(), source);
                bookmark(&value, &reply);
                next(5);
            }
            5 => {
                let Some(Value::String(key)) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                editor.borrow().as_ref().unwrap().paste(key, false);
                next(6);
            }
            6 => {
                let Some(window) = preview(ui.lang) else {
                    return glib::ControlFlow::Continue;
                };
                if !selection_tested.get() {
                    let response = reply.clone();
                    let value = editor.borrow().clone().unwrap();
                    value.evaluate("const root=document.getElementById('fastra-visual'),old=getSelection().getRangeAt(0).cloneRange(),next=document.createRange();next.selectNodeContents(root.firstElementChild);next.collapse(true);getSelection().removeAllRanges();getSelection().addRange(next);await new Promise(r=>setTimeout(r,30));getSelection().removeAllRanges();getSelection().addRange(old);await new Promise(r=>setTimeout(r,30));return JSON.stringify(true);",move|value|*response.borrow_mut()=value);
                    next(60);
                    return glib::ControlFlow::Continue;
                }
                if !gui_test::capture(&window, "asset-write-preview", &shots) {
                    return glib::ControlFlow::Continue;
                }
                click(
                    &window,
                    ui.lang
                        .text("Bilder speichern und einfügen", "Save images and insert"),
                );
                next(7);
            }
            60 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let window = preview(ui.lang).unwrap();
                click(
                    &window,
                    ui.lang
                        .text("Bilder speichern und einfügen", "Save images and insert"),
                );
                next(61);
            }
            61 => {
                assert!(
                    !root.join("images").exists(),
                    "Caret-only ABA must refuse before filesystem writes"
                );
                assert_eq!(*editor.borrow().as_ref().unwrap().expected.borrow(), source);
                click(
                    &preview(ui.lang).unwrap(),
                    ui.lang.text("Abbrechen", "Cancel"),
                );
                next(62);
            }
            62 => {
                if preview(ui.lang).is_some() {
                    return glib::ControlFlow::Continue;
                }
                selection_tested.set(true);
                bookmark(editor.borrow().as_ref().unwrap(), &reply);
                next(5);
            }
            7 => {
                let value = editor.borrow().clone().unwrap();
                if value.busy.get() || !value.expected.borrow().contains("images/1.png") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!value.failed.get(), "{}", value.status.text());
                assert_eq!(std::fs::read(root.join("images/1.png")).unwrap(), png);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
                assert!(!value.expected.borrow().contains("WRONG"));
                assert!(value.expected.borrow().starts_with("Before **Bold**\n\n"));
                *saved.borrow_mut() = value.expected.borrow().clone();
                let response = reply.clone();
                value.evaluate("const image=document.querySelector('#fastra-visual img');return JSON.stringify({url:image?.getAttribute('data-md-src'),width:image?.naturalWidth,transactions:fastraVisual.clipboardState().imageTransactions});",move|value|*response.borrow_mut()=value);
                next(8);
            }
            8 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["url"], "images/1.png");
                assert_eq!(value["width"], 1);
                assert_eq!(value["transactions"].as_array().unwrap().len(), 1);
                let value = editor.borrow().clone().unwrap();
                value.command("undo");
                next(9);
            }
            9 => {
                let value = editor.borrow().clone().unwrap();
                if value.busy.get() || *value.expected.borrow() != source {
                    return glib::ControlFlow::Continue;
                }
                assert!(!root.join("images/1.png").exists());
                let state = value.assets.borrow();
                assert_eq!(state.records.len(), 1);
                let record = state.records.values().next().unwrap();
                assert!(!record.visible);
                assert!(!record.receipt.is_applied());
                assert_eq!(
                    std::fs::read(&record.receipt.recovery_paths()[0].1).unwrap(),
                    png
                );
                drop(state);
                value.command("redo");
                next(10);
            }
            10 => {
                let value = editor.borrow().clone().unwrap();
                if value.busy.get() || *value.expected.borrow() != *saved.borrow() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!value.failed.get(), "{}", value.status.text());
                assert_eq!(std::fs::read(root.join("images/1.png")).unwrap(), png);
                crate::git_view::test_keys(&value.view, &["ctrl+s"]);
                next(11);
            }
            11 => {
                if std::fs::read_to_string(&path).unwrap() != *saved.borrow() {
                    return glib::ControlFlow::Continue;
                }
                if !gui_test::capture(&ui.window, "asset-saved", &shots) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(root.join("images/1.png")).unwrap(), png);
                println!(
                    "PASS native asset base flow: PNG MIME, Cancel/Apply/Save, full bytes, real WebKit, Undo/Redo"
                );
                asset_gui_transfer::run(ui.clone(), editor.borrow().clone().unwrap());
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
