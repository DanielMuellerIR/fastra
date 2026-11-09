use super::*;
use std::time::Instant;
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
static POINTER_BUSY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
fn pointer(view: &sourceview5::View, offset: i32, button: &str, alt: bool, count: &str) -> i32 {
    let iter = view.buffer().iter_at_offset(offset);
    let rect = view.iter_location(&iter);
    let (x, y) = view.buffer_to_window_coords(
        gtk::TextWindowType::Widget,
        rect.x() + rect.width().max(2) / 2,
        rect.y() + rect.height() / 2,
    );
    let (bx, by) = view.window_to_buffer_coords(gtk::TextWindowType::Widget, x, y);
    let expected = view.iter_at_position(bx, by).unwrap().0.offset();
    let native = view.native().unwrap();
    let point = view
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(x as f32, y as f32),
        )
        .unwrap();
    let (dx, dy) = native.surface_transform();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(native.surface().unwrap().as_ptr().cast()) }.to_string();
    let button = button.to_owned();
    let count = count.to_owned();
    POINTER_BUSY.store(true, std::sync::atomic::Ordering::SeqCst);
    std::thread::spawn(move || {
        let mut cmd = std::process::Command::new("xdotool");
        cmd.args(["windowactivate", "--sync", &id]);
        if alt {
            cmd.args(["keydown", "Alt_L"]);
        }
        cmd.args([
            "mousemove",
            "--window",
            &id,
            &(point.x() as f64 - dx).round().to_string(),
            &(point.y() as f64 - dy).round().to_string(),
            "click",
            &button,
        ]);
        if count == "2" {
            cmd.args(["sleep", "0.08", "click", &button]);
        } else {
            assert_eq!(count, "1");
        }
        if alt {
            cmd.args(["keyup", "Alt_L"]);
        }
        assert!(cmd.status().unwrap().success());
        POINTER_BUSY.store(false, std::sync::atomic::Ordering::SeqCst);
    });
    expected
}
fn selected(doc: &Document) -> String {
    let buffer = source_panes::buffer(doc);
    buffer
        .selection_bounds()
        .map(|(a, b)| buffer.text(&a, &b, true).to_string())
        .unwrap_or_default()
}
fn widgets<T: IsA<gtk::Widget> + glib::object::ObjectType>(root: &gtk::Widget) -> Vec<T> {
    let mut out = root
        .clone()
        .downcast::<T>()
        .ok()
        .into_iter()
        .collect::<Vec<_>>();
    for child in chrome::children(root) {
        out.extend(widgets::<T>(&child));
    }
    out
}
fn search_window(ui: &Ui) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| {
            w.is_visible()
                && w.has_css_class("fastra-search")
                && w.transient_for().as_ref() == Some(ui.window.upcast_ref())
        })
}
mod guards;
mod markdown;
pub(crate) fn start(ui: Rc<Ui>) {
    match std::env::var("FASTRA_TARGET_SELFTEST").as_deref() {
        Ok("markdown") => {
            markdown::start(ui);
            return;
        }
        Ok("guards") => {
            guards::start(ui);
            return;
        }
        _ => {}
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let methods = root.join("Project/Sources/Methods");
    std::fs::create_dir_all(&methods).unwrap();
    let path = methods.join("Caller.4dm");
    let other = methods.join("Ziel Methode.4dm");
    let source="// 🙂\r\nZiel Methode($p)\r\n$this.zwei()\r\nMissingMethod($p)\r\nALERT(\"x\")\r\n\r\nFunction eins()\r\n return 1\r\n\r\nexposed Function zwei($x)\r\n return $x\r\n";
    std::fs::write(&path, source).unwrap();
    std::fs::write(&other, "#DECLARE($x : Text)\r\nALERT($x)\r\n").unwrap();
    git_view::test_size(ui.window.upcast_ref());
    ui.load_path(path.clone());
    let source_doc = RefCell::new(None::<Rc<Document>>);
    let target_doc = RefCell::new(None::<Rc<Document>>);
    let began = Instant::now();
    let phase = Cell::new(0);
    let pause = Cell::new(Instant::now());
    let clicked = Cell::new(0);
    let capture = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            began.elapsed() < Duration::from_secs(35),
            "target phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(160) {
            return glib::ControlFlow::Continue;
        }
        let Some(doc) = source_doc.borrow().clone().or_else(|| {
            ui.active()
                .filter(|d| d.disk_path().as_ref() == Some(&path))
        }) else {
            return glib::ControlFlow::Continue;
        };
        if source_doc.borrow().is_none() {
            *source_doc.borrow_mut() = Some(doc.clone());
        }
        match phase.get() {
            0 => {
                let outline = doc.outline.borrow().clone().unwrap();
                if !outline.valid() {
                    return glib::ControlFlow::Continue;
                }
                let target = source_panes::capture(&doc).unwrap();
                let offset = source[..source.find("zwei()").unwrap() + 1].chars().count() as i32;
                clicked.set(pointer(&target.view, offset, "1", true, "2"));
            }
            1 => {
                if !selected(&doc).contains("Function zwei") {
                    return glib::ControlFlow::Continue;
                }
                let outline = doc.outline.borrow().clone().unwrap();
                assert!(outline.back.is_sensitive());
                assert!(!doc.buffer.can_undo());
                assert_eq!(buffer_text(&doc.buffer), source);
                if !git_view::try_capture_x11(&ui.window, "target-local-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&outline.back, &[]);
            }
            2 => {
                if source_panes::buffer(&doc).cursor_position() != clicked.get() {
                    return glib::ControlFlow::Continue;
                }
                let target = source_panes::capture(&doc).unwrap();
                let offset = source[..source.find("Methode").unwrap() + 2]
                    .chars()
                    .count() as i32;
                clicked.set(pointer(&target.view, offset, "1", true, "2"));
            }
            3 => {
                let Some(target) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&other))
                else {
                    return glib::ControlFlow::Continue;
                };
                let outline = target.outline.borrow().clone().unwrap();
                if !outline.back.is_mapped() || !outline.back.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(source_panes::buffer(&target).cursor_position(), 0);
                assert!(!target.buffer.can_undo());
                *target_doc.borrow_mut() = Some(target);
                if !git_view::try_capture_x11(&ui.window, "target-file-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&outline.back, &[]);
            }
            4 => {
                if !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
                    || source_panes::buffer(&doc).cursor_position() != clicked.get()
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), 2);
                git_view::test_click(&doc.outline.borrow().as_ref().unwrap().forward, &[]);
            }
            5 => {
                let target = target_doc.borrow().clone().unwrap();
                if !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &target)) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), 2);
                git_view::test_click(&target.outline.borrow().as_ref().unwrap().back, &[]);
            }
            6 => {
                if !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc)) {
                    return glib::ControlFlow::Continue;
                }
                let target = source_panes::capture(&doc).unwrap();
                let offset = source[..source.find("zwei()").unwrap() + 1].chars().count() as i32;
                target
                    .buffer
                    .place_cursor(&target.buffer.iter_at_offset(offset));
                pointer(&target.view, offset, "3", false, "1");
            }
            7 => {
                let Some(label) = labels(ui.window.upcast_ref()).into_iter().find(|l| {
                    l.is_mapped()
                        && l.text()
                            == ui
                                .lang
                                .text("Gehe zum Ziel an der Einfügemarke", "Go to target at caret")
                }) else {
                    return glib::ControlFlow::Continue;
                };
                if !git_view::try_capture_x11(&label, "target-context-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&label, &[]);
            }
            8 => {
                if !selected(&doc).contains("Function zwei") {
                    return glib::ControlFlow::Continue;
                }
                ui.replace.set_text("keep replacement");
                ui.mode.set_selected(2);
                let target = source_panes::capture(&doc).unwrap();
                let offset = source[..source.find("MissingMethod").unwrap() + 2]
                    .chars()
                    .count() as i32;
                pointer(&target.view, offset, "1", true, "2");
            }
            9 => {
                if ui.scope.selected() != 2 || search_window(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.find.text(), "MissingMethod");
                assert_eq!(ui.mode.selected(), 0);
                assert_eq!(ui.replace.text(), "keep replacement");
                folder::test_root(&ui, root.clone());
            }
            10 => {
                if folder::test_matches(&ui) != Some(0) {
                    return glib::ControlFlow::Continue;
                }
                let sources = folder::test_sources(&ui);
                let menu = widgets::<gtk::MenuButton>(sources.root.upcast_ref())
                    .into_iter()
                    .find(|m| m.widget_name() == "fastra-folder-file-types")
                    .unwrap();
                git_view::test_click(&menu, &[]);
            }
            11 => {
                let sources = folder::test_sources(&ui);
                let menu = widgets::<gtk::MenuButton>(sources.root.upcast_ref())
                    .into_iter()
                    .find(|m| m.widget_name() == "fastra-folder-file-types")
                    .unwrap();
                let popup = menu.popover().unwrap();
                let Some(all) = widgets::<gtk::CheckButton>(popup.upcast_ref())
                    .into_iter()
                    .find(|c| {
                        c.is_mapped()
                            && c.label().as_deref()
                                == Some(ui.lang.text("Alle Dateien", "All files"))
                    })
                else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&all, &[]);
            }
            12 => {
                if folder::test_matches(&ui) != Some(1) {
                    return glib::ControlFlow::Continue;
                }
                let window = search_window(&ui).unwrap();
                if !git_view::try_capture_x11(&window, "target-folder-fallback-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                window.close();
                if window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                project_view::open_path(&ui, root.clone());
            }
            13 => {
                if !project_view::current_binding(&ui).is_some_and(|p| p.root.path == root) {
                    return glib::ControlFlow::Continue;
                }
                if !git_view::try_capture_x11(&ui.window, "target-project-owner-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                let target = source_panes::capture(&doc).unwrap();
                let offset = source[..source.find("MissingMethod").unwrap() + 2]
                    .chars()
                    .count() as i32;
                ui.mode.set_selected(2);
                pointer(&target.view, offset, "1", true, "2");
            }
            14 => {
                if ui.scope.selected() != 3 || folder::test_matches(&ui) != Some(0) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.find.text(), "MissingMethod");
                assert_eq!(ui.mode.selected(), 0);
                assert_eq!(ui.replace.text(), "keep replacement");
                let filter = widgets::<gtk::DropDown>(search_window(&ui).unwrap().upcast_ref())
                    .into_iter()
                    .find(|d| {
                        d.model()
                            .and_then(|m| m.item(0))
                            .and_downcast::<gtk::StringObject>()
                            .is_some_and(|s| {
                                s.string()
                                    == ui.lang.text("Bekannte Textformate", "Known text formats")
                            })
                    })
                    .unwrap();
                assert_eq!(filter.selected(), 0);
                filter.set_selected(1);
            }
            15 => {
                if folder::test_matches(&ui) != Some(1) {
                    return glib::ControlFlow::Continue;
                }
                let window = search_window(&ui).unwrap();
                if !git_view::try_capture_x11(&window, "target-project-fallback-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                window.close();
                if window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
            }
            16 => {
                let target = source_panes::capture(&doc).unwrap();
                let offset = source[..source.find("ALERT").unwrap() + 1].chars().count() as i32;
                target
                    .buffer
                    .place_cursor(&target.buffer.iter_at_offset(offset));
                target
                    .view
                    .activate_action("fastra-navigation.target", None)
                    .unwrap();
            }
            17 => {
                if !labels(ui.window.upcast_ref()).iter().any(|l| {
                    l.is_mapped()
                        && l.text()
                            == ui.lang.text(
                                "An der Einfügemarke gibt es kein Sprungziel.",
                                "There is no navigation target at the caret.",
                            )
                }) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                println!("FASTRA_TOOL_SELFTEST_OK target actual-alt-double-click native-window-capture local-four-d Unicode-CRLF shared-history local-file-open back-forward no-duplicate-tabs native-context-entry literal-folder-and-project-fallback preserved-known-filter explicit-all-files-searches-four-d unchanged-files-no-undo");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        eprintln!("target phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
