use super::*;
use std::time::{Duration, Instant};
fn window(title: &str) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .iter()
        .filter_map(|v| v.clone().downcast::<gtk::Window>().ok())
        .find(|window| window.is_visible() && window.title().as_deref() == Some(title))
}
fn point(widget: &impl IsA<gtk::Widget>) -> (String, i32, i32) {
    let widget = widget.as_ref();
    let native = widget.native().unwrap();
    let point = widget
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(
                if widget.is::<webkit6::WebView>() {
                    60.
                } else {
                    widget.width() as f32 * 0.3
                },
                if widget.is::<webkit6::WebView>() {
                    35.
                } else {
                    widget.height() as f32 * 0.3
                },
            ),
        )
        .unwrap();
    let (x, y) = native.surface_transform();
    (
        gui_test::xid(widget),
        (point.x() as f64 - x) as i32,
        (point.y() as f64 - y) as i32,
    )
}
fn drag(from: &impl IsA<gtk::Widget>, to: &impl IsA<gtk::Widget>) {
    let (a, x, y) = point(from);
    let (b, tx, ty) = point(to);
    std::thread::spawn(move || {
        assert!(
            std::process::Command::new("timeout")
                .args([
                    "8s",
                    "xdotool",
                    "windowraise",
                    &a,
                    "windowmove",
                    &a,
                    "1400",
                    "100",
                    "mousemove",
                    "--window",
                    &a,
                    &x.to_string(),
                    &y.to_string(),
                    "mousedown",
                    "1",
                    "sleep",
                    "0.3",
                    "mousemove_relative",
                    "--",
                    "20",
                    "0",
                    "sleep",
                    "0.3",
                    "mousemove",
                    "--window",
                    &b,
                    &tx.to_string(),
                    &ty.to_string(),
                    "sleep",
                    "0.5",
                    "mouseup",
                    "1"
                ])
                .status()
                .unwrap()
                .success()
        );
    });
}
pub(super) fn run(a: Rc<Ui>, ui: Rc<Ui>, editor: Rc<RichEditor>) {
    if std::env::var_os("FASTRA_RICH_ASSET_TRACE_DROP").is_some() {
        glib::log_set_handler(
            Some("Gdk"),
            glib::LogLevels::LEVEL_CRITICAL,
            false,
            false,
            |domain, _, message| {
                eprintln!("DROP DIAG {domain:?}: {message}");
                unsafe {
                    let mut stack = [std::ptr::null_mut(); 32];
                    let count = libc::backtrace(stack.as_mut_ptr(), 32);
                    libc::backtrace_symbols_fd(stack.as_ptr(), count, 2);
                }
            },
        );
    }
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    let path = root.join("drop-source.png");
    let png = include_bytes!("../../tests/fixtures/pixel-1.png").to_vec();
    std::fs::write(&path, &png).unwrap();
    let source = gtk::Window::builder()
        .application(&ui.window.application().unwrap())
        .title("Isolated drag fixture")
        .default_width(230)
        .default_height(130)
        .build();
    let button = gtk::Button::with_label("Drag local image");
    let drag_source = gtk::DragSource::builder()
        .actions(gtk::gdk::DragAction::COPY)
        .build();
    let ended = Rc::new(Cell::new(0));
    let end_count = ended.clone();
    drag_source.connect_drag_end(move |_, _, delete_data| {
        assert!(!delete_data, "COPY must never request source deletion");
        end_count.set(end_count.get() + 1);
        eprintln!(
            "Native drag end {} delete_data={delete_data}",
            end_count.get()
        );
    });
    let cancelled = Cell::new(false);
    let note = root.join("dropped-note.txt");
    std::fs::write(&note, "Opened normally after image insertion").unwrap();
    let folder = root.join("normal-folder");
    std::fs::create_dir(&folder).unwrap();
    let files = gtk::gdk::FileList::from_array(&[
        gio::File::for_path(&path),
        gio::File::for_path(&note),
        gio::File::for_path(&folder),
    ]);
    drag_source.set_content(Some(&gtk::gdk::ContentProvider::new_union(&[
        gtk::gdk::ContentProvider::for_value(&"WRONG FILE TEXT".to_value()),
        gtk::gdk::ContentProvider::for_value(&files.to_value()),
    ])));
    button.add_controller(drag_source.clone());
    source.set_child(Some(&button));
    source.present();
    let phase = Cell::new(0);
    let started = Instant::now();
    let delay = Cell::new(Instant::now());
    let reply = Rc::new(RefCell::new(None::<Value>));
    let shots = RefCell::new(None);
    let before = editor.expected.borrow().clone();
    let before_bad = RefCell::new(String::new());
    let rtf = br"{\rtf1\ansi\uc1{\colortbl;\red255\green255\blue0;} Plain {\b Bold} \highlight1 Marked\highlight0  \u196?}".to_vec();
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "drop phase{} status{}",
            phase.get(),
            editor.status.text()
        );
        if delay.get().elapsed() < Duration::from_millis(200) {
            return glib::ControlFlow::Continue;
        }
        let next = |n| {
            eprintln!("Asset drop {n}");
            phase.set(n);
            delay.set(Instant::now());
        };
        match phase.get() {
            0 => {
                drag(&button, &editor.view);
                next(1);
            }
            1 => {
                let Some(preview) = window(
                    ui.lang
                        .text("Bilder und Dateien einfügen", "Insert images and files"),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(*editor.expected.borrow(), before);
                assert!(!root.join("receiver/images/3.png").exists());
                if !cancelled.get() {
                    let cancel = gui_test::button(
                        preview.child().unwrap().upcast_ref(),
                        ui.lang.text("Abbrechen", "Cancel"),
                    )
                    .unwrap();
                    if !cancel.is_mapped() || cancel.width() <= 0 || cancel.height() <= 0 {
                        return glib::ControlFlow::Continue;
                    }
                    gui_test::input(&cancel, true, &[]);
                    next(10);
                    return glib::ControlFlow::Continue;
                }
                if !gui_test::capture(&preview, "asset-real-drop-preview", &shots) {
                    return glib::ControlFlow::Continue;
                }
                let apply = gui_test::button(
                    preview.child().unwrap().upcast_ref(),
                    ui.lang
                        .text("Bilder speichern und einfügen", "Save images and insert"),
                )
                .unwrap();
                gui_test::input(&apply, true, &[]);
                next(2);
            }
            10 => {
                if window(
                    ui.lang
                        .text("Bilder und Dateien einfügen", "Insert images and files"),
                )
                .is_some()
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ended.get(), 1);
                assert_eq!(std::fs::read(&path).unwrap(), png);
                assert!(!root.join("receiver/images/3.png").exists());
                assert_eq!(*editor.expected.borrow(), before);
                assert!(ui.project.borrow().is_none());
                assert!(
                    !ui.documents
                        .borrow()
                        .iter()
                        .any(|doc| doc.disk_path().as_ref() == Some(&note))
                );
                cancelled.set(true);
                next(0);
            }
            2 => {
                if editor.busy.get() || !editor.expected.borrow().contains("images/3.png") {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    std::fs::read(root.join("receiver/images/3.png")).unwrap(),
                    png
                );
                assert!(!editor.expected.borrow().contains("WRONG FILE TEXT"));
                assert_eq!(std::fs::read(&path).unwrap(), png);
                if ui.project.borrow().is_none()
                    || !ui
                        .documents
                        .borrow()
                        .iter()
                        .any(|doc| doc.disk_path().as_ref() == Some(&note))
                {
                    return glib::ControlFlow::Continue;
                }
                let doc = editor.document.upgrade().unwrap();
                let index = ui
                    .documents
                    .borrow()
                    .iter()
                    .position(|other| Rc::ptr_eq(other, &doc))
                    .unwrap();
                ui.tabs.set_current_page(Some(index as u32));
                assert_eq!(
                    ended.get(),
                    2,
                    "exactly one native COPY completion per drag"
                );
                source.close();
                editor
                    .view
                    .clipboard()
                    .set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
                        "text/rtf",
                        &glib::Bytes::from_owned(rtf.clone()),
                    )))
                    .unwrap();
                let reply = reply.clone();
                editor.evaluate(
                    "return JSON.stringify(fastraVisual.bookmarkClipboard());",
                    move |value| *reply.borrow_mut() = value,
                );
                next(3);
            }
            3 => {
                let Some(Value::String(key)) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                editor.paste(key, false);
                next(4);
            }
            4 => {
                let Some(import) = window(ui.lang.text("Dokument importieren", "Import document"))
                else {
                    return glib::ControlFlow::Continue;
                };
                if std::env::var("FASTRA_RICH_WIDTH")
                    .ok()
                    .and_then(|width| width.parse::<i32>().ok())
                    .is_some_and(|width| width <= 700)
                {
                    import.set_default_size(640, 760);
                }
                next(41);
            }
            41 => {
                let import =
                    window(ui.lang.text("Dokument importieren", "Import document")).unwrap();
                if !gui_test::capture(&import, "asset-rtf-loss-boundary", &shots) {
                    return glib::ControlFlow::Continue;
                }
                if std::env::var_os("FASTRA_RTF_REAL_IMPORT").is_some() {
                    crate::import_view::test_real_rtf(ui.clone());
                    return glib::ControlFlow::Break;
                }
                import.close();
                next(5);
            }
            5 => {
                *before_bad.borrow_mut() = editor.expected.borrow().clone();
                editor
                    .view
                    .clipboard()
                    .set_content(Some(&gtk::gdk::ContentProvider::new_union(&[
                        gtk::gdk::ContentProvider::for_value(&"WRONG LOSSY FALLBACK".to_value()),
                        gtk::gdk::ContentProvider::for_bytes(
                            "image/png",
                            &glib::Bytes::from_static(b"not a PNG"),
                        ),
                    ])))
                    .unwrap();
                let response = reply.clone();
                editor.evaluate(
                    "return JSON.stringify(fastraVisual.bookmarkClipboard());",
                    move |value| *response.borrow_mut() = value,
                );
                next(6);
            }
            6 => {
                let Some(Value::String(key)) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                editor.paste(key, false);
                next(7);
            }
            7 => {
                if editor.busy.get() || editor.clipboard_busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(*editor.expected.borrow(), *before_bad.borrow());
                assert!(!root.join("receiver/images/4.png").exists());
                assert!(
                    window(
                        ui.lang
                            .text("Bilder und Dateien einfügen", "Insert images and files")
                    )
                    .is_none()
                );
                assert!(
                    editor
                        .status
                        .text()
                        .contains(ui.lang.text("Einfügen angehalten", "Paste held"))
                );
                println!(
                    "PASS native asset drop/RTF: real X11 mixed-file/folder drag, real GDK FileList+String priority, preview before writes, exact copied bytes with source intact, RTF-only actual GDK MIME enters explicit PMT loss-preview dialog"
                );
                ui.window.close();
                a.window.close();
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
