use super::*;
use std::sync::atomic::Ordering::SeqCst;
fn views(root: &gtk::Widget) -> Vec<sourceview5::View> {
    let mut out = root
        .clone()
        .downcast::<sourceview5::View>()
        .ok()
        .into_iter()
        .collect::<Vec<_>>();
    for child in chrome::children(root) {
        out.extend(views(&child));
    }
    out
}
fn split(root: &gtk::Widget) -> Option<gtk::CheckButton> {
    if root.widget_name() == "fastra-source-split" {
        return root.clone().downcast().ok();
    }
    chrome::children(root).iter().find_map(split)
}
fn row(root: &gtk::Widget, name: &str) -> Option<gtk::Widget> {
    let mut widget = labels(root)
        .into_iter()
        .find(|l| l.is_mapped() && l.text() == name)?
        .upcast::<gtk::Widget>();
    while !widget.has_css_class("document-outline-row") {
        widget = widget.parent()?;
    }
    Some(widget)
}
fn drag(ui: &Rc<Ui>, doc: &Document) {
    let rect = doc.rectangles.borrow()[1].clone();
    let a = rect.test_point(&ui.window, 1, 1);
    let b = rect.test_point(&ui.window, 3, 6);
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(ui.window.surface().unwrap().as_ptr().cast()) }.to_string();
    std::thread::spawn(move || {
        assert!(std::process::Command::new("xdotool")
            .args([
                "windowactivate",
                "--sync",
                &id,
                "keydown",
                "Alt_L",
                "mousemove",
                "--window",
                &id,
                &a.0.to_string(),
                &a.1.to_string(),
                "mousedown",
                "1",
                "sleep",
                "0.1",
                "mousemove",
                "--window",
                &id,
                &b.0.to_string(),
                &b.1.to_string(),
                "sleep",
                "0.1",
                "mouseup",
                "1",
                "keyup",
                "Alt_L"
            ])
            .status()
            .unwrap()
            .success());
    });
}
pub(super) fn start(ui: Rc<Ui>) {
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let methods = root.join("Project/Sources/Methods");
    std::fs::create_dir_all(&methods).unwrap();
    let path = methods.join("Guard.4dm");
    let source="// 🙂\r\n$this.target()\r\n$this.first()\r\nTarget Method()\r\n\r\nFunction first()\r\n return 1\r\n\r\nFunction target($x)\r\n return $x\r\n";
    std::fs::write(&path, source).unwrap();
    std::fs::write(methods.join("Target Method.4dm"), "ALERT(\"fixture\")\n").unwrap();
    git_view::test_size(ui.window.upcast_ref());
    ui.load_path(path.clone());
    let document = RefCell::new(None::<Rc<Document>>);
    let right = RefCell::new(None::<sourceview5::View>);
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(Instant::now());
    let ready = Cell::new(0);
    let returned = Cell::new(0);
    let capture = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            began.elapsed() < Duration::from_secs(55),
            "target guard phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(160) {
            return glib::ControlFlow::Continue;
        }
        let Some(doc) = document.borrow().clone().or_else(|| {
            ui.active()
                .filter(|d| d.disk_path().as_ref() == Some(&path))
        }) else {
            return glib::ControlFlow::Continue;
        };
        if document.borrow().is_none() {
            *document.borrow_mut() = Some(doc.clone());
        }
        let at = |word: &str| source[..source.find(word).unwrap() + 1].chars().count() as i32;
        match phase.get() {
            0 => {
                if !doc.outline.borrow().as_ref().unwrap().valid() {
                    return glib::ControlFlow::Continue;
                }
                let button = split(doc.container.upcast_ref()).unwrap();
                git_view::test_click(&button, &[]);
            }
            1 => {
                let mut all = views(doc.container.upcast_ref())
                    .into_iter()
                    .filter(|v| v.is_mapped() && v.width() > 0)
                    .collect::<Vec<_>>();
                if all.len() != 2 {
                    return glib::ControlFlow::Continue;
                }
                all.sort_by_key(|v| {
                    v.compute_point(&ui.window, &gtk::graphene::Point::new(0., 0.))
                        .unwrap()
                        .x() as i32
                });
                doc.buffer
                    .select_range(&doc.buffer.iter_at_offset(3), &doc.buffer.start_iter());
                if !git_view::try_capture_x11(&ui.window, "target-split-owner-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                *right.borrow_mut() = Some(all[1].clone());
                pointer(&all[1], at("target()"), "1", true, "2");
            }
            2 => {
                if !selected(&doc).contains("Function target") {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    doc.buffer
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((0, 3))
                );
                git_view::test_click(&doc.outline.borrow().as_ref().unwrap().menu, &[]);
            }
            3 => {
                let outline = doc.outline.borrow().clone().unwrap();
                let Some(current) = row(outline.popup.upcast_ref(), "target") else {
                    return glib::ControlFlow::Continue;
                };
                assert!(current.has_css_class("current"));
                if !git_view::try_capture_x11(
                    &outline.popup,
                    "target-split-current-native",
                    &capture,
                ) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&row(outline.popup.upcast_ref(), "first").unwrap(), &[]);
            }
            4 => {
                if !selected(&doc).contains("Function first") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&doc.outline.borrow().as_ref().unwrap().back, &[]);
            }
            5 => {
                if !selected(&doc).contains("Function target") {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    doc.buffer
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((0, 3))
                );
                REPLY_DELAY.store(1000, SeqCst);
                ready.set(READY.load(SeqCst));
                returned.set(RETURNED.load(SeqCst));
                pointer(
                    right.borrow().as_ref().unwrap(),
                    at("target()"),
                    "1",
                    true,
                    "2",
                );
            }
            6 => {
                if READY.load(SeqCst) <= ready.get() || POINTER_BUSY.load(SeqCst) {
                    return glib::ControlFlow::Continue;
                }
                let page = ui.tabs.current_page().unwrap();
                ui.add_document("other.4dm", "Function wrong()\n");
                ui.tabs.set_current_page(Some(page));
                let view = right.borrow().clone().unwrap();
                view.grab_focus();
                view.buffer().place_cursor(&view.buffer().start_iter());
            }
            7 => {
                if RETURNED.load(SeqCst) <= returned.get() {
                    return glib::ControlFlow::Continue;
                }
                let view = right.borrow().clone().unwrap();
                assert_eq!(view.buffer().cursor_position(), 0);
                assert!(doc
                    .outline
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .forward
                    .is_sensitive());
                assert!(!doc.buffer.can_undo());
                ready.set(READY.load(SeqCst));
                returned.set(RETURNED.load(SeqCst));
                pointer(&view, at("target()"), "1", true, "2");
            }
            8 => {
                if READY.load(SeqCst) <= ready.get() || POINTER_BUSY.load(SeqCst) {
                    return glib::ControlFlow::Continue;
                }
                let view = right.borrow().clone().unwrap();
                view.grab_focus();
                git_view::test_keys(&view, &["--clearmodifiers", "x"]);
            }
            9 => {
                if buffer_text(&doc.buffer) == source {
                    if pause.get().elapsed() > Duration::from_secs(3) {
                        if !git_view::try_capture_x11(&ui.window, "target-typing-pending", &capture)
                        {
                            return glib::ControlFlow::Continue;
                        }
                        let view = right.borrow().clone().unwrap();
                        let focus = gtk::prelude::RootExt::focus(&ui.window)
                            .map(|w| w.type_().name().to_owned());
                        panic!("native input missing: focus={focus:?} right_focus={} editable={} sensitive={} mapped={} right_text={:?}",view.has_focus(),view.is_editable(),view.is_sensitive(),view.is_mapped(),buffer_text(&view.buffer()));
                    }
                    return glib::ControlFlow::Continue;
                }
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), source);
                let view = right.borrow().clone().unwrap();
                view.buffer().place_cursor(&view.buffer().start_iter());
                assert!(doc.buffer.can_redo());
            }
            10 => {
                if RETURNED.load(SeqCst) <= returned.get() {
                    return glib::ControlFlow::Continue;
                }
                let view = right.borrow().clone().unwrap();
                assert_eq!(view.buffer().cursor_position(), 0);
                assert!(doc.buffer.can_redo());
                ready.set(READY.load(SeqCst));
                returned.set(RETURNED.load(SeqCst));
                pointer(&view, at("target()"), "1", true, "2");
            }
            11 => {
                if READY.load(SeqCst) <= ready.get() || POINTER_BUSY.load(SeqCst) {
                    return glib::ControlFlow::Continue;
                }
                REPLY_DELAY.store(0, SeqCst);
                pointer(
                    right.borrow().as_ref().unwrap(),
                    at("first()"),
                    "1",
                    true,
                    "2",
                );
            }
            12 => {
                if RETURNED.load(SeqCst) < returned.get() + 2
                    || !selected(&doc).contains("Function first")
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(doc.buffer.can_redo());
                ready.set(READY.load(SeqCst));
                drag(&ui, &doc);
            }
            13 => {
                if !doc.rectangles.borrow()[1].is_selected() {
                    return glib::ControlFlow::Continue;
                }
                if pause.get().elapsed() < Duration::from_millis(500) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(READY.load(SeqCst), ready.get());
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                assert!(doc.buffer.can_redo());
                if !git_view::try_capture_x11(&ui.window, "target-alt-drag-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                for rectangle in doc.rectangles.borrow().iter() {
                    rectangle.clear();
                }
                REPLY_DELAY.store(1000, SeqCst);
                ready.set(READY.load(SeqCst));
                returned.set(RETURNED.load(SeqCst));
                pointer(
                    right.borrow().as_ref().unwrap(),
                    at("Target Method"),
                    "1",
                    true,
                    "2",
                );
            }
            14 => {
                if READY.load(SeqCst) <= ready.get() || POINTER_BUSY.load(SeqCst) {
                    return glib::ControlFlow::Continue;
                }
                let view = right.borrow().clone().unwrap();
                view.grab_focus();
                git_view::test_keys(&view, &["ctrl+w"]);
            }
            15 => {
                if ui.documents.borrow().iter().any(|d| Rc::ptr_eq(d, &doc))
                    || RETURNED.load(SeqCst) <= returned.get()
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), 1);
                assert_eq!(ui.active().unwrap().name, "other.4dm");
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
                assert_eq!(buffer_text(&doc.buffer), source);
                println!("FASTRA_TOOL_SELFTEST_OK target-guards native-second-pane peer-selection current-outline-and-back held-ready-tab-ABA revision-ABA no-late-selection latest-wins native-Alt-single-drag preserved-redo pending-source-closed-no-file-open unchanged-file");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        eprintln!("target guard phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
