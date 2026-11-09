use super::*;
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    time::{Duration, Instant},
};

pub(super) fn handle(ui: &Ui, doc: &Document) -> gtk::Widget {
    let row = crate::chrome::tab_header(ui, doc);
    let mut child = row.first_child();
    while let Some(node) = child {
        if node.widget_name() == "fastra-tab-file-handle" { return node; }
        child = node.next_sibling();
    }
    panic!("missing native file drag icon")
}
fn xid(widget: &gtk::Widget) -> String {
    let surface = widget.native().unwrap().surface().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let get: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    unsafe { get(surface.as_ptr().cast()) }.to_string()
}
pub(super) fn native_drag(source: &gtk::Widget, to: String, tx: String, ty: String, width: i32) {
    assert!(source.is_mapped());
    let native = source.native().unwrap();
    let start = source
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(source.width() as f32 / 2., source.height() as f32 / 2.),
        )
        .unwrap();
    let (a, b) = native.surface_transform();
    let sx = (start.x() as f64 - a).round().to_string();
    let sy = (start.y() as f64 - b).round().to_string();
    let step = (start.x() as f64 - a + 16.).round().to_string();
    let from = xid(source);
    let target_x = (width + 30).to_string();
    std::thread::spawn(move || {
        assert!(std::process::Command::new("xdotool")
            .args([
                "windowmove",
                &from,
                "0",
                "0",
                "windowmove",
                &to,
                &target_x,
                "250",
                "windowraise",
                &to,
                "windowraise",
                &from,
                "windowfocus",
                "--sync",
                &from,
                "mousemove",
                "--window",
                &from,
                &sx,
                &sy,
                "mousedown",
                "1",
                "sleep",
                "0.15",
                "mousemove",
                "--window",
                &from,
                &step,
                &sy,
                "sleep",
                "0.15",
                "mousemove",
                "--window",
                &to,
                &tx,
                &ty,
                "sleep",
                "0.35",
                "mouseup",
                "1",
            ])
            .status()
            .unwrap()
            .success());
    });
}
fn drag(source: &gtk::Widget, target: &gtk::Widget, width: i32) {
    assert!(target.is_mapped());
    let native = target.native().unwrap();
    let end = target
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(target.width() as f32 / 2., target.height() as f32 / 2.),
        )
        .unwrap();
    let (a, b) = native.surface_transform();
    native_drag(
        source,
        xid(target),
        (end.x() as f64 - a).round().to_string(),
        (end.y() as f64 - b).round().to_string(),
        width,
    );
}
struct Receiver(Option<std::process::Child>);
impl Drop for Receiver {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
pub(super) fn run(ui: Rc<Ui>) {
    use std::os::unix::{ffi::OsStringExt, fs::symlink};
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let fixture = tempfile::tempdir_in(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).unwrap();
    let source = fixture.path().join(std::ffi::OsString::from_vec(
        "Bericht % # ä🙂 "
            .as_bytes()
            .iter()
            .copied()
            .chain([0xff])
            .chain(b".txt".iter().copied())
            .collect(),
    ));
    let target_file = fixture.path().join("saved-target.txt");
    std::fs::write(&source, b"Saved\r\n").unwrap();
    std::fs::write(&target_file, b"Linked saved bytes\n").unwrap();
    ui.add_document("unsaved.txt", "Unsaved\n");
    let unsaved = ui.active().unwrap();
    ui.add_document("Saved.txt", "Saved\r\n");
    let doc = ui.active().unwrap();
    *doc.snapshot.borrow_mut() =
        Some(fastra_io::Snapshot::read(&source, &fastra_core::Cancellation::default()).unwrap());
    doc.buffer.begin_user_action();
    doc.buffer.insert_at_cursor("Dirty ");
    doc.buffer.end_user_action();
    doc.update_label();
    let dirty = crate::buffer_text(&doc.buffer);
    let revision = Cell::new(doc.revision.get());
    let received = Rc::new(RefCell::new(Vec::<(PathBuf, Vec<u8>)>::new()));
    let target = gtk::Window::builder()
        .title("Synthetic native file receiver")
        .default_width(350)
        .default_height(150)
        .transient_for(&ui.window)
        .build();
    let area = gtk::Label::new(Some("Native file drop receiver"));
    area.set_hexpand(true);
    area.set_vexpand(true);
    target.set_child(Some(&area));
    let drop = gtk::DropTarget::new(
        gtk::gdk::FileList::static_type(),
        gtk::gdk::DragAction::COPY,
    );
    let output = received.clone();
    drop.connect_drop(move |_, value, _, _| {
        let Ok(list) = value.get::<gtk::gdk::FileList>() else {
            return false;
        };
        let files = list.files();
        assert_eq!(files.len(), 1);
        let path = files[0].path().unwrap();
        let bytes = std::fs::read(&path).unwrap();
        output.borrow_mut().push((path, bytes));
        true
    });
    area.add_controller(drop);
    target.present();
    super::super::git_view::test_size(ui.window.upcast_ref());
    let phase = Cell::new(0u8);
    let started = Instant::now();
    let pause = Cell::new(Instant::now());
    let ready = fixture.path().join("receiver-ready");
    let result = fixture.path().join("receiver-result");
    let receiver = RefCell::new(Receiver(None));
    let fixture = RefCell::new(Some(fixture));
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(20),
            "native tab-file drag phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        assert_eq!(crate::buffer_text(&doc.buffer), dirty);
        if phase.get() > 0 {
            assert_eq!(doc.revision.get(), revision.get());
        }
        assert!(doc.buffer.is_modified() && doc.buffer.can_undo());
        match phase.get() {
            0 if pause.get().elapsed() > Duration::from_millis(500) => {
                revision.set(doc.revision.get());
                let icon = handle(&ui, &doc);
                assert!(icon.is_mapped() && icon.width() >= 16 && icon.height() >= 22);
                assert!(!handle(&ui, &unsaved).is_visible());
                assert!(icon
                    .tooltip_text()
                    .unwrap()
                    .contains(ui.lang.text("letzte gespeicherte", "last saved")));
                super::super::git_view::capture(ui.window.upcast_ref(), "tab-file-drag-source");
                super::super::git_view::capture(&target, "tab-file-drag-target");
                drag(icon.upcast_ref(), area.upcast_ref(), ui.window.width());
                phase.set(1);
            }
            1 if received.borrow().len() == 1 => {
                assert_eq!(
                    received.borrow()[0],
                    (source.clone(), b"Saved\r\n".to_vec())
                );
                assert_eq!(std::fs::read(&source).unwrap(), b"Saved\r\n");
                std::fs::remove_file(&source).unwrap();
                ui.status.set_text("");
                drag(
                    handle(&ui, &doc).upcast_ref(),
                    area.upcast_ref(),
                    ui.window.width(),
                );
                pause.set(Instant::now());
                phase.set(2);
            }
            2 if pause.get().elapsed() > Duration::from_millis(850) => {
                assert_eq!(received.borrow().len(), 1);
                assert!(ui.status.text().starts_with(ui.lang.text(
                    "Die gespeicherte Datei ist zum Ziehen nicht verfügbar",
                    "The saved file is unavailable for dragging"
                )));
                symlink(&target_file, &source).unwrap();
                drag(
                    handle(&ui, &doc).upcast_ref(),
                    area.upcast_ref(),
                    ui.window.width(),
                );
                phase.set(3);
            }
            3 if received.borrow().len() == 2 => {
                assert_eq!(
                    received.borrow()[1],
                    (source.clone(), b"Linked saved bytes\n".to_vec())
                );
                assert_eq!(
                    std::fs::read(&target_file).unwrap(),
                    b"Linked saved bytes\n"
                );
                std::fs::remove_file(&target_file).unwrap();
                ui.status.set_text("");
                drag(
                    handle(&ui, &doc).upcast_ref(),
                    area.upcast_ref(),
                    ui.window.width(),
                );
                pause.set(Instant::now());
                phase.set(4);
            }
            4 if pause.get().elapsed() > Duration::from_millis(850) => {
                assert_eq!(received.borrow().len(), 2);
                assert!(!ui.status.text().is_empty());
                std::fs::remove_file(&source).unwrap();
                std::fs::create_dir(&source).unwrap();
                ui.status.set_text("");
                drag(
                    handle(&ui, &doc).upcast_ref(),
                    area.upcast_ref(),
                    ui.window.width(),
                );
                pause.set(Instant::now());
                phase.set(5);
            }
            5 if pause.get().elapsed() > Duration::from_millis(850) => {
                assert_eq!(received.borrow().len(), 2);
                assert!(ui
                    .status
                    .text()
                    .contains(ui.lang.text("keine reguläre Datei", "not a regular file")));
                std::fs::remove_dir(&source).unwrap();
                std::fs::write(&source, b"Cross-process saved bytes\n").unwrap();
                receiver.borrow_mut().0 = Some(
                    std::process::Command::new(
                        std::env::var_os("FASTRA_TAB_FILE_DRAG_RECEIVER")
                            .expect("native receiver fixture path"),
                    )
                    .arg(&ready)
                    .arg(&result)
                    .spawn()
                    .unwrap(),
                );
                phase.set(6);
            }
            6 if ready.is_file() => {
                let target_id = std::fs::read_to_string(&ready).unwrap();
                target_id.trim().parse::<u64>().unwrap();
                native_drag(
                    handle(&ui, &doc).upcast_ref(),
                    target_id.trim().to_owned(),
                    "175".into(),
                    "75".into(),
                    ui.window.width(),
                );
                phase.set(7);
            }
            7 if result.is_file() => {
                let receipt = gtk::glib::KeyFile::new();
                receipt
                    .load_from_file(&result, gtk::glib::KeyFileFlags::NONE)
                    .unwrap();
                assert_eq!(
                    receipt.string("drop", "uri").unwrap(),
                    gio::File::for_path(&source).uri()
                );
                assert_eq!(
                    gtk::glib::base64_decode(receipt.string("drop", "bytes").unwrap().as_str()),
                    b"Cross-process saved bytes\n"
                );
                assert_eq!(
                    std::fs::read(&source).unwrap(),
                    b"Cross-process saved bytes\n"
                );
                phase.set(8);
            }
            8 => {
                let finished = receiver
                    .borrow_mut()
                    .0
                    .as_mut()
                    .unwrap()
                    .try_wait()
                    .unwrap();
                if let Some(status) = finished {
                    assert!(status.success());
                    receiver.borrow_mut().0.take();
                    doc.buffer.undo();
                    assert_eq!(crate::buffer_text(&doc.buffer), "Saved\r\n");
                    target.close();
                    fixture.borrow_mut().take();
                    println!("PASS native tab-file drag: actual XTest drag to separate GTK window and independent GTK process, raw URI with space/percent/hash/Unicode/invalidUTF8, only disk bytes despite dirty buffer, live symlink and removed/broken/directory refusal, no unsaved handle, untouched buffer/revision/Undo");
                    std::process::exit(0);
                }
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
