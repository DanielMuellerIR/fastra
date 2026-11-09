use super::*;
use gtk::glib;
use std::{
    cell::RefCell,
    time::{Duration, Instant},
};
fn xid(widget: &impl IsA<gtk::Widget>) -> String {
    let native = widget.as_ref().native().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let get: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    unsafe { get(native.surface().unwrap().as_ptr().cast()) }.to_string()
}
fn drag(source: &gtk::Window, destination: &gtk::ApplicationWindow) {
    let source = xid(source);
    let destination = xid(destination);
    std::thread::spawn(move || {
        assert!(std::process::Command::new("xdotool")
            .args([
                "windowmove",
                &destination,
                "0",
                "0",
                "windowraise",
                &destination,
                "windowmove",
                &source,
                "1150",
                "40",
                "windowfocus",
                "--sync",
                &source,
                "mousemove",
                "--window",
                &source,
                "80",
                "65",
                "mousedown",
                "1",
                "sleep",
                "0.15",
                "mousemove",
                "--window",
                &source,
                "110",
                "85",
                "sleep",
                "0.2",
                "mousemove",
                "--window",
                &destination,
                "300",
                "500",
                "sleep",
                "0.5",
                "mouseup",
                "1",
            ])
            .status()
            .unwrap()
            .success());
    });
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    use std::os::unix::ffi::OsStringExt;
    let fixture = tempfile::tempdir_in(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).unwrap();
    let a = fixture.path().join("first #%.txt");
    let b = fixture
        .path()
        .join(std::ffi::OsString::from_vec(b"raw-\xff.txt".to_vec()));
    let folder = fixture.path().join("project");
    let other = fixture.path().join("other");
    std::fs::write(&a, b"first cat\r\n").unwrap();
    std::fs::write(&b, b"second cat\n").unwrap();
    std::fs::create_dir(&folder).unwrap();
    std::fs::create_dir(&other).unwrap();
    std::fs::write(folder.join("inside.txt"), b"project source\n").unwrap();
    let fixture_holder = RefCell::new(Some(fixture));
    let capture = RefCell::new(None);
    let original = ui.active().unwrap();
    original.buffer.insert_at_cursor("unsaved marker");
    let original_text = super::super::buffer_text(&original.buffer);
    let source = gtk::Window::builder()
        .title("Synthetic native file source")
        .default_width(240)
        .default_height(150)
        .build();
    let label = gtk::Label::new(Some("Drag local files / folder"));
    source.set_child(Some(&label));
    let provider = Rc::new(RefCell::new(gtk::gdk::ContentProvider::for_value(
        &gtk::gdk::FileList::from_array(&[
            gio::File::for_path(&a),
            gio::File::for_path(&b),
            gio::File::for_path(&a),
        ])
        .to_value(),
    )));
    let source_drag = gtk::DragSource::builder()
        .actions(gtk::gdk::DragAction::COPY)
        .build();
    let p = provider.clone();
    source_drag.connect_prepare(move |_, _, _| Some(p.borrow().clone()));
    label.add_controller(source_drag);
    source.present();
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or_else(|_| "760".into())
        .parse()
        .unwrap();
    ui.window.set_default_size(width, 850);
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let initial = ui.documents.borrow().len();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(40),
            "desktop open phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        let has = |path: &std::path::Path| {
            ui.documents.borrow().iter().any(|d| {
                d.snapshot
                    .borrow()
                    .as_ref()
                    .is_some_and(|s| s.path() == path)
            })
        };
        match phase.get() {
            0 if pause.get().elapsed() > Duration::from_millis(450) => {
                drag(&source, &ui.window);
                phase.set(1);
            }
            1 if has(&a) && has(&b) => {
                assert_eq!(ui.documents.borrow().len(), initial + 2);
                let raw = ui
                    .documents
                    .borrow()
                    .iter()
                    .find(|doc| {
                        doc.snapshot
                            .borrow()
                            .as_ref()
                            .is_some_and(|snapshot| snapshot.path() == b)
                    })
                    .unwrap()
                    .clone();
                assert_eq!(
                    raw.label.text().as_str(),
                    project_view::display(std::path::Path::new(b.file_name().unwrap()))
                );
                assert_eq!(super::super::buffer_text(&original.buffer), original_text);
                assert!(original.buffer.is_modified());
                *provider.borrow_mut() = gtk::gdk::ContentProvider::for_value(
                    &gtk::gdk::FileList::from_array(&[gio::File::for_path(&folder)]).to_value(),
                );
                drag(&source, &ui.window);
                phase.set(2);
            }
            2 if project_view::current_binding(&ui).is_some() => {
                assert_eq!(
                    project_view::current_binding(&ui).unwrap().root.path,
                    folder
                );
                if !git_view::try_capture_x11(&ui.window, "desktop-files-open", &capture) {
                    return glib::ControlFlow::Continue;
                }
                *provider.borrow_mut() = gtk::gdk::ContentProvider::for_value(
                    &gtk::gdk::FileList::from_array(&[
                        gio::File::for_path(&folder),
                        gio::File::for_path(&other),
                    ])
                    .to_value(),
                );
                drag(&source, &ui.window);
                pause.set(Instant::now());
                phase.set(3);
            }
            3 if pause.get().elapsed() > Duration::from_secs(2) => {
                assert_eq!(
                    project_view::current_binding(&ui).unwrap().root.path,
                    folder
                );
                assert_eq!(ui.documents.borrow().len(), initial + 2);
                assert!(ui
                    .status
                    .text()
                    .contains(ui.lang.text("Öffnen abgewiesen", "Open refused")));
                open_files(&ui, &[gio::File::for_uri("https://example.invalid/a.txt")]);
                assert!(ui
                    .status
                    .text()
                    .contains(ui.lang.text("Nur lokale", "Only local")));
                let request = state(&ui);
                assert!(request.request(&[gio::File::for_path(&a)]));
                request.cancel();
                pause.set(Instant::now());
                phase.set(4);
            }
            4 if pause.get().elapsed() > Duration::from_millis(500) => {
                assert_eq!(ui.documents.borrow().len(), initial + 2);
                assert_eq!(super::super::buffer_text(&original.buffer), original_text);
                assert_eq!(std::fs::read(&a).unwrap(), b"first cat\r\n");
                assert_eq!(std::fs::read(&b).unwrap(), b"second cat\n");
                fixture_holder.borrow_mut().take().unwrap().close().unwrap();
                source.close();
                ui.window.close();
                println!("FASTRA_DESKTOP_OPEN_OK native FileList drag, raw paths, deduplication, folder/project, whole invalid plan refusal, local-only, stale request, dirty source and disk unchanged");
                std::process::exit(0);
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
