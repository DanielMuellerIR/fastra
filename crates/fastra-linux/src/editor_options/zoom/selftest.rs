use super::*;
use crate::{buffer_text, git_view as support};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
thread_local! { static RUNNING: Cell<bool> = const { Cell::new(false) }; }
const TEXT: &str = "Zoom café e\u{301} 😀\n\n![Image](zoom.png)\n";
fn widgets(root: &impl IsA<gtk::Widget>) -> Vec<gtk::Widget> {
    fn walk(widget: &gtk::Widget, result: &mut Vec<gtk::Widget>) {
        result.push(widget.clone());
        let mut child = widget.first_child();
        while let Some(widget) = child {
            walk(&widget, result);
            child = widget.next_sibling();
        }
    }
    let mut result = Vec::new();
    walk(root.as_ref(), &mut result);
    result
}
fn views(doc: &Document) -> Vec<sourceview5::View> {
    widgets(&doc.container)
        .into_iter()
        .filter_map(|widget| widget.downcast::<sourceview5::View>().ok())
        .collect()
}
fn split(doc: &Document) {
    widgets(&doc.container)
        .into_iter()
        .find_map(|widget| {
            widget
                .downcast::<gtk::CheckButton>()
                .ok()
                .filter(|button| button.widget_name() == "fastra-source-split")
        })
        .unwrap()
        .set_active(true);
}
fn size(widget: &impl IsA<gtk::Widget>) -> i32 {
    widget.create_pango_layout(Some("MMMMMMMMMM")).size().0
}
const MEASURE: &str = "const p=[...document.querySelectorAll('p')].find(p=>p.textContent.includes('Zoom'));const img=document.querySelector('img');if(!p||!img||!img.complete)return JSON.stringify(null);const r=document.createRange();r.selectNodeContents(p);return JSON.stringify({text:r.getBoundingClientRect().height,image:img.getBoundingClientRect().width});";
fn inspect(view: &webkit6::WebView, result: Rc<RefCell<Option<serde_json::Value>>>) {
    view.call_async_javascript_function(
        MEASURE,
        None,
        None,
        None,
        None::<&gio::Cancellable>,
        move |value| {
            *result.borrow_mut() = Some(
                value
                    .ok()
                    .and_then(|value| serde_json::from_str(&value.to_str()).ok())
                    .unwrap_or(serde_json::Value::Null),
            );
        },
    );
}
pub(super) fn run(ui: Rc<Ui>) {
    if RUNNING.with(|running| running.replace(true)) {
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let mode = std::env::var("FASTRA_ZOOM_SELFTEST").unwrap();
    let restore = std::env::var("FASTRA_ZOOM_PHASE").as_deref() == Ok("restore");
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("zoom.md");
    if !restore {
        std::fs::write(&path, TEXT).unwrap();
        gtk::gdk::MemoryTexture::new(
            120,
            50,
            gtk::gdk::MemoryFormat::R8g8b8a8,
            &glib::Bytes::from_owned([0u8, 100, 200, 255].repeat(120 * 50)),
            120 * 4,
        )
        .save_to_png(root.join("zoom.png"))
        .unwrap();
        if mode == "readonly" {
            std::fs::hard_link(&path, root.join("alias.md")).unwrap();
        }
    }
    ui.load_path(path.clone());
    support::test_size(ui.window.upcast_ref());
    let began = Instant::now();
    let paused = Cell::new(began);
    let phase = Cell::new(0);
    let inputs = RefCell::new(None::<std::sync::mpsc::Receiver<()>>);
    let other = RefCell::new(None::<Rc<Ui>>);
    let fonts = RefCell::new(Vec::<i32>::new());
    let ui_font = Cell::new(0);
    let revision = Cell::new(0);
    let selected = Cell::new((0, 0));
    let lock = RefCell::new(None);
    let web = RefCell::new(
        None::<(
            gtk::Window,
            Rc<crate::markdown::MarkdownView>,
            Rc<crate::rich_editor::RichEditor>,
        )>,
    );
    let measurements: [Rc<RefCell<Option<serde_json::Value>>>; 2] =
        std::array::from_fn(|_| Rc::default());
    let baseline = RefCell::new(Vec::<serde_json::Value>::new());
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            began.elapsed() < Duration::from_secs(45),
            "zoom phase {}",
            phase.get()
        );
        if inputs
            .borrow()
            .as_ref()
            .is_some_and(|input| input.try_recv().is_err())
        {
            return glib::ControlFlow::Continue;
        }
        inputs.borrow_mut().take();
        let Some(doc) = ui
            .active()
            .filter(|doc| doc.disk_path().as_ref() == Some(&path))
        else {
            return glib::ControlFlow::Continue;
        };
        let state = state();
        let app = ui.window.application().unwrap();
        if state.busy.get() || state.queued.get() {
            return glib::ControlFlow::Continue;
        }
        if !state.loaded.get() && mode != "corrupt" {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                assert_eq!(doc.is_read_only(), mode == "readonly");
                if mode == "corrupt" {
                    assert!(state.error.borrow().is_some());
                    controls::open(&app);
                    paused.set(Instant::now());
                    phase.set(90);
                    return glib::ControlFlow::Continue;
                }
                split(&doc);
                let window = crate::build(&app);
                window.add_document("Other", TEXT);
                split(&window.active().unwrap());
                *other.borrow_mut() = Some(window);
                revision.set(doc.revision.get());
                if restore {
                    assert_eq!(state.levels.get(), Levels { ui: 2, document: 3 });
                    controls::open(&app);
                    paused.set(Instant::now());
                    phase.set(91);
                } else {
                    assert_eq!(state.levels.get(), Levels::default());
                    ui.window.present();
                    paused.set(Instant::now());
                    phase.set(1);
                }
            }
            1 if paused.get().elapsed() > Duration::from_millis(350) => {
                *fonts.borrow_mut() = views(&doc).iter().map(size).collect();
                assert_eq!(fonts.borrow().len(), 2);
                ui_font.set(size(&ui.window));
                let source = views(&doc)[1].clone();
                *inputs.borrow_mut() = Some(support::test_input_completed(
                    &source,
                    &["ctrl+Home", "ctrl+shift+End"],
                    true,
                ));
                phase.set(2);
            }
            2 => {
                selected.set(crate::source_panes::capture(&doc).unwrap().offsets());
                assert_ne!(selected.get().0, selected.get().1);
                *inputs.borrow_mut() = Some(support::test_input_completed(
                    &views(&doc)[1],
                    &[
                        if std::env::var("FASTRA_ZOOM_KEYMAP").as_deref() == Ok("de") {
                            "ctrl+plus"
                        } else {
                            "ctrl+equal"
                        },
                    ],
                    false,
                ));
                paused.set(Instant::now());
                phase.set(3);
            }
            3 if paused.get().elapsed() > Duration::from_millis(350) => {
                assert_eq!(state.levels.get(), Levels { ui: 1, document: 0 });
                assert!(size(&ui.window) > ui_font.get());
                assert_eq!(
                    views(&doc).iter().map(size).collect::<Vec<_>>(),
                    *fonts.borrow()
                );
                *inputs.borrow_mut() = Some(support::test_input_completed(
                    &views(&doc)[1],
                    &[
                        if std::env::var("FASTRA_ZOOM_KEYMAP").as_deref() == Ok("de") {
                            "ctrl+shift+plus"
                        } else {
                            "ctrl+shift+equal"
                        },
                    ],
                    false,
                ));
                paused.set(Instant::now());
                phase.set(4);
            }
            4 if paused.get().elapsed() > Duration::from_millis(350) => {
                assert_eq!(state.levels.get(), Levels { ui: 1, document: 1 });
                for view in views(&doc) {
                    assert!(size(&view) > fonts.borrow()[0]);
                }
                for view in views(&other.borrow().as_ref().unwrap().active().unwrap()) {
                    assert_eq!(size(&view), size(&views(&doc)[0]));
                }
                assert_eq!(
                    crate::source_panes::capture(&doc).unwrap().offsets(),
                    selected.get()
                );
                *inputs.borrow_mut() = Some(support::test_input_completed(
                    &views(&doc)[1],
                    &["ctrl+comma"],
                    false,
                ));
                paused.set(Instant::now());
                phase.set(5);
            }
            5 if paused.get().elapsed() > Duration::from_millis(300) => {
                let window = state.window.borrow().upgrade().unwrap();
                assert!(window.is_visible());
                assert!(support::try_capture(&window, "zoom-settings"));
                let stepper = widgets(&window).into_iter().find_map(|widget| widget.downcast::<gtk::SpinButton>().ok().filter(|spin| spin.widget_name()=="fastra-document-zoom-stepper")).unwrap();
                let button = widgets(&stepper).into_iter().find_map(|widget| widget.downcast::<gtk::Button>().ok().filter(|button| button.has_css_class("up"))).unwrap();
                *inputs.borrow_mut() = Some(support::test_input_completed(&button, &[], true));
                paused.set(Instant::now());
                phase.set(6);
            }
            6 if paused.get().elapsed() > Duration::from_millis(300) => {
                assert_eq!(state.levels.get().document, 2);
                let window = state.window.borrow().upgrade().unwrap();
                *inputs.borrow_mut() =
                    Some(support::test_input_completed(&window, &["Escape"], false));
                paused.set(Instant::now());
                phase.set(7);
            }
            7 if paused.get().elapsed() > Duration::from_millis(350) => {
                assert!(state.window.borrow().upgrade().is_none());
                assert_eq!(
                    crate::source_panes::capture(&doc).unwrap().offsets(),
                    selected.get()
                );
                assert!(crate::source_panes::capture(&doc).unwrap().view.has_focus());
                for _ in 0..20 {
                    app.activate_action("ui-larger", None);
                    app.activate_action("document-larger", None);
                }
                paused.set(Instant::now());
                phase.set(8);
            }
            8 if paused.get().elapsed() > Duration::from_millis(350) => {
                assert_eq!(state.levels.get(), Levels { ui: 5, document: 8 });
                assert!(support::try_capture(
                    ui.window.upcast_ref(),
                    "zoom-source-maximum"
                ));
                controls::open(&app);
                paused.set(Instant::now());
                phase.set(9);
            }
            9 if paused.get().elapsed() > Duration::from_millis(300) => {
                assert!(support::try_capture(
                    &state.window.borrow().upgrade().unwrap(),
                    "zoom-settings-maximum"
                ));
                for _ in 0..24 {
                    app.activate_action("ui-smaller", None);
                    app.activate_action("document-smaller", None);
                }
                paused.set(Instant::now());
                phase.set(10);
            }
            10 if paused.get().elapsed() > Duration::from_millis(350) => {
                assert_eq!(
                    state.levels.get(),
                    Levels {
                        ui: -3,
                        document: -4
                    }
                );
                assert!(support::try_capture(
                    &state.window.borrow().upgrade().unwrap(),
                    "zoom-settings-minimum"
                ));
                state.window.borrow().upgrade().unwrap().close();
                app.activate_action("ui-original", None);
                app.activate_action("document-original", None);
                let preview = crate::markdown::MarkdownView::new();
                preview.visible.set(true);
                preview.schedule(&doc, ui.lang);
                let rich = crate::rich_editor::RichEditor::new(&ui, &doc).unwrap();
                let row = gtk::Box::new(gtk::Orientation::Horizontal, 4);
                row.append(&preview.widget);
                row.append(&rich.widget);
                preview.widget.set_hexpand(true);
                rich.widget.set_hexpand(true);
                let window = gtk::Window::builder()
                    .application(&app)
                    .default_width(1000)
                    .default_height(500)
                    .child(&row)
                    .build();
                crate::chrome::dialog::decorate(&window, "Web document zoom", ui.lang);
                window.present();
                *web.borrow_mut() = Some((window, preview, rich));
                paused.set(Instant::now());
                phase.set(11);
            }
            11 if paused.get().elapsed() > Duration::from_millis(750) => {
                let web = web.borrow();
                let (window, preview, rich) = web.as_ref().unwrap();
                inspect(&preview.view, measurements[0].clone());
                inspect(&rich.view, measurements[1].clone());
                assert!(support::try_capture(window, "zoom-web-before"));
                phase.set(12);
            }
            12 if measurements.iter().all(|value| value.borrow().is_some())
                && measurements
                    .iter()
                    .any(|value| value.borrow().as_ref().is_some_and(|value| value.is_null())) =>
            {
                for value in &measurements {
                    value.borrow_mut().take();
                }
                paused.set(Instant::now());
                phase.set(11);
            }
            12 if measurements.iter().all(|value| {
                value
                    .borrow()
                    .as_ref()
                    .is_some_and(|value| !value.is_null())
            }) =>
            {
                *baseline.borrow_mut() = measurements
                    .iter()
                    .map(|value| value.borrow_mut().take().unwrap())
                    .collect();
                eprintln!("ZOOM web baseline {:?}", baseline.borrow());
                state.choose(Levels { ui: 2, document: 3 });
                paused.set(Instant::now());
                phase.set(13);
            }
            13 if paused.get().elapsed() > Duration::from_millis(500) => {
                let web = web.borrow();
                let (_, preview, rich) = web.as_ref().unwrap();
                inspect(&preview.view, measurements[0].clone());
                inspect(&rich.view, measurements[1].clone());
                phase.set(14);
            }
            14 if measurements.iter().all(|value| value.borrow().is_some()) => {
                for (index, value) in measurements.iter().enumerate() {
                    let value = value.borrow();
                    let value = value.as_ref().unwrap();
                    let baseline = &baseline.borrow()[index];
                    eprintln!("ZOOM web scaled {index}: {value}");
                    assert!(
                        value["text"].as_f64().unwrap() > baseline["text"].as_f64().unwrap() * 1.2
                    );
                    assert!(
                        (value["image"].as_f64().unwrap() - baseline["image"].as_f64().unwrap())
                            .abs()
                            < 0.1
                    );
                }
                assert!(support::try_capture(
                    &web.borrow().as_ref().unwrap().0,
                    "zoom-web-text-only"
                ));
                if mode == "busy" {
                    *lock.borrow_mut() = Some(
                        super::super::store::Store::open(&config_root().unwrap())
                            .unwrap()
                            .lock()
                            .unwrap(),
                    );
                    state.choose(Levels { ui: 3, document: 4 });
                    phase.set(15);
                } else {
                    phase.set(20);
                }
            }
            15 if state.error.borrow().is_some() => {
                assert_eq!(
                    store::load(&config_root().unwrap()).unwrap(),
                    Levels { ui: 2, document: 3 }
                );
                lock.borrow_mut().take();
                state.save();
                phase.set(16);
            }
            16 => {
                assert!(state.error.borrow().is_none());
                state.choose(Levels { ui: 2, document: 3 });
                phase.set(20);
            }
            20 => {
                assert_eq!(buffer_text(&doc.buffer), TEXT);
                assert_eq!(doc.revision.get(), revision.get());
                assert!(!doc.buffer.can_undo());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), TEXT);
                assert_eq!(
                    store::load(&config_root().unwrap()).unwrap(),
                    Levels { ui: 2, document: 3 }
                );
                println!("FASTRA_TOOL_SELFTEST_OK zoom");
                app.quit();
                return glib::ControlFlow::Break;
            }
            90 if paused.get().elapsed() > Duration::from_millis(350) => {
                assert!(!app.lookup_action("ui-larger").unwrap().is_enabled());
                assert!(support::try_capture(
                    &state.window.borrow().upgrade().unwrap(),
                    "zoom-corrupt"
                ));
                assert_eq!(
                    std::fs::read_to_string(config_root().unwrap().join("fastra-editor/zoom.json"))
                        .unwrap(),
                    "corrupt preference"
                );
                println!("FASTRA_TOOL_SELFTEST_OK zoom-corrupt");
                app.quit();
                return glib::ControlFlow::Break;
            }
            91 if paused.get().elapsed() > Duration::from_millis(350) => {
                assert!(support::try_capture(
                    &state.window.borrow().upgrade().unwrap(),
                    "zoom-restored"
                ));
                println!("FASTRA_TOOL_SELFTEST_OK zoom-restored");
                app.quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
