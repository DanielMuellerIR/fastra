use super::*;
use crate::{git_view as support, project_view, Ui};
use std::{
    ffi::OsString,
    os::unix::ffi::OsStringExt,
    time::{Duration, Instant},
};

fn button(widget: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(button) = widget
        .downcast_ref::<gtk::Button>()
        .filter(|b| b.label().as_deref() == Some(label))
    {
        return Some(button.clone());
    }
    let mut child = widget.first_child();
    while let Some(node) = child {
        if let Some(button) = button(&node, label) {
            return Some(button);
        }
        child = node.next_sibling();
    }
    None
}
fn project_window(ui: &Ui) -> gtk::Window {
    gtk::Window::list_toplevels()
        .iter()
        .filter_map(|w| w.downcast_ref::<gtk::Window>())
        .find(|w| w.title().as_deref() == Some(ui.lang.text("Projektdateien", "Project files")))
        .unwrap()
        .clone()
}
fn contains_label(widget: &gtk::Widget, value: &str) -> bool {
    if widget
        .downcast_ref::<gtk::Label>()
        .is_some_and(|label| label.text().contains(value))
    {
        return true;
    }
    let mut child = widget.first_child();
    while let Some(node) = child {
        if contains_label(&node, value) {
            return true;
        }
        child = node.next_sibling();
    }
    false
}
// Derselbe XTest-Pfad wie im vorhandenen Tabkontextmenütest.
fn click(widget: &gtk::Widget, mouse: &str) {
    let mouse = mouse.to_owned();
    let native = widget.native().unwrap();
    let surface = native.surface().unwrap();
    let sym = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!sym.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(sym) };
    let id = unsafe { xid(surface.as_ptr().cast()) }.to_string();
    let p = widget
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(widget.width() as f32 / 2., widget.height() as f32 / 2.),
        )
        .unwrap();
    let (x, y) = native.surface_transform();
    let popup = native.is::<gtk::Popover>();
    std::thread::spawn(move || {
        let mut command = std::process::Command::new("xdotool");
        if !popup {
            command.args(["windowraise", &id, "windowfocus", "--sync", &id]);
        }
        assert!(command
            .args([
                "mousemove",
                "--window",
                &id,
                &(p.x() as f64 - x).round().to_string(),
                &(p.y() as f64 - y).round().to_string(),
                "click",
                &mouse
            ])
            .status()
            .unwrap()
            .success());
    });
}
fn capture(widget: &gtk::Widget, name: &str) {
    let Some(directory) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS") else {
        return;
    };
    let native = widget.native().unwrap();
    let target = native.clone().dynamic_cast::<gtk::Widget>().unwrap();
    let paintable = gtk::WidgetPaintable::new(Some(&target));
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(
        &snapshot,
        f64::from(target.width()),
        f64::from(target.height()),
    );
    let node = snapshot.to_node().unwrap();
    let renderer = gtk::gsk::Renderer::for_surface(&native.surface().unwrap()).unwrap();
    let texture = renderer.render_texture(&node, None);
    std::fs::create_dir_all(&directory).unwrap();
    texture
        .save_to_png(std::path::Path::new(&directory).join(format!("{name}.png")))
        .unwrap();
    renderer.unrealize();
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    assert_eq!(
        std::env::var("FASTRA_PRIVATE_DBUS_TEST").as_deref(),
        Ok("1")
    );
    let connection = ui.window.application().unwrap().dbus_connection().unwrap();
    let next = connection.clone();
    connection.call(
        Some("org.freedesktop.DBus"),
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "RequestName",
        Some(&(SERVICE, 4u32).to_variant()),
        None,
        gio::DBusCallFlags::NONE,
        2000,
        gio::Cancellable::NONE,
        move |result| {
            assert_eq!(
                result.unwrap().get::<(u32,)>(),
                Some((1,)),
                "fresh private D-Bus name required"
            );
            run_owned(ui, &next);
        },
    );
}
fn run_owned(ui: Rc<Ui>, connection: &gio::DBusConnection) {
    let fixture = tempfile::tempdir_in(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).unwrap();
    let root = fixture.path().join("project space % # ä🙂");
    let other = fixture.path().join("other");
    std::fs::create_dir(&root).unwrap();
    std::fs::create_dir(&other).unwrap();
    let raw = root.join(OsString::from_vec(b"document-\xff.txt".to_vec()));
    std::fs::write(&raw, b"preserved\r\n").unwrap();
    let calls = Rc::new(RefCell::new(Vec::<String>::new()));
    let held = Rc::new(RefCell::new(None::<gio::DBusMethodInvocation>));
    let info=gio::DBusNodeInfo::for_xml("<node><interface name='org.freedesktop.FileManager1'><method name='ShowItems'><arg type='as' direction='in'/><arg type='s' direction='in'/></method></interface></node>").unwrap();
    let received = calls.clone();
    let pending = held.clone();
    let registration = connection
        .register_object(OBJECT, &info.interfaces()[0])
        .method_call(move |_, _, _, _, method, args, invocation| {
            assert_eq!(method, "ShowItems");
            let (uris, startup) = args.get::<(Vec<String>, String)>().unwrap();
            assert_eq!(uris.len(), 1);
            assert_eq!(startup, "");
            let at = received.borrow().len();
            received.borrow_mut().push(uris[0].clone());
            match at {
                0 => invocation.return_value(Some(&().to_variant())),
                1 => invocation.return_dbus_error(
                    "org.freedesktop.FileManager1.TestFailure",
                    "synthetic visible failure",
                ),
                _ => {
                    assert!(pending.borrow().is_none());
                    *pending.borrow_mut() = Some(invocation);
                }
            }
        })
        .build()
        .unwrap();
    project_view::open_path(&ui, root.clone());
    ui.load_path(raw.clone());
    let window = project_window(&ui);
    support::test_size(&window);
    support::test_size(ui.window.upcast_ref());
    let phase = Cell::new(0u8);
    let started = Instant::now();
    let pause = Cell::new(Instant::now());
    let connection = connection.clone();
    let registration = RefCell::new(Some(registration));
    let fixture_holder = RefCell::new(Some(fixture));
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            started.elapsed() < Duration::from_secs(25),
            "filemanager native phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        let label = ui
            .lang
            .text("Im Dateimanager zeigen", "Show in file manager");
        let reveal = button(window.upcast_ref(), label).unwrap();
        let document = ui
            .documents
            .borrow()
            .iter()
            .find(|d| d.disk_path().as_ref() == Some(&raw))
            .cloned();
        match phase.get() {
            0 if reveal.is_sensitive()
                && document.is_some()
                && pause.get().elapsed() > Duration::from_millis(500) =>
            {
                capture(reveal.upcast_ref(), "filemanager-project");
                click(reveal.upcast_ref(), "1");
                phase.set(1);
            }
            1 if calls.borrow().len() == 1 => {
                assert_eq!(calls.borrow()[0], gio::File::for_path(&root).uri());
                let doc = document.unwrap();
                let row = crate::chrome::tab_header(&ui, &doc);
                click(row.first_child().unwrap().upcast_ref(), "3");
                phase.set(2);
            }
            2 => {
                let doc = document.unwrap();
                let row = crate::chrome::tab_header(&ui, &doc);
                if let Some(action) = button(&row, label).filter(|b| b.is_mapped()) {
                    assert!(action.is_sensitive());
                    capture(action.upcast_ref(), "filemanager-tab");
                    click(action.upcast_ref(), "1");
                    phase.set(3);
                }
            }
            3 if calls.borrow().len() == 2
                && ui.status.text().contains("synthetic visible failure") =>
            {
                assert_eq!(calls.borrow()[1], gio::File::for_path(&raw).uri());
                let doc = document.unwrap();
                let row = crate::chrome::tab_header(&ui, &doc);
                click(row.first_child().unwrap().upcast_ref(), "3");
                phase.set(4);
            }
            4 => {
                let doc = document.unwrap();
                let row = crate::chrome::tab_header(&ui, &doc);
                if let Some(action) = button(&row, label).filter(|b| b.is_mapped()) {
                    click(action.upcast_ref(), "1");
                    phase.set(5);
                }
            }
            5 if held.borrow().is_some() => {
                ui.add_document("Fresh owner", "fresh");
                ui.status.set_text("fresh owner status");
                held.borrow_mut().take().unwrap().return_dbus_error(
                    "org.freedesktop.FileManager1.TestFailure",
                    "must not overwrite fresh tab",
                );
                pause.set(Instant::now());
                phase.set(6);
            }
            6 if pause.get().elapsed() > Duration::from_millis(250) => {
                assert_eq!(ui.status.text(), "fresh owner status");
                assert!(reveal.is_sensitive());
                click(reveal.upcast_ref(), "1");
                phase.set(7);
            }
            7 if held.borrow().is_some() => {
                assert!(!reveal.is_sensitive());
                reveal.emit_clicked();
                assert_eq!(calls.borrow().len(), 4);
                project_view::open_path(&ui, other.clone());
                held.borrow_mut().take().unwrap().return_dbus_error(
                    "org.freedesktop.FileManager1.TestFailure",
                    "must not overwrite changed project",
                );
                pause.set(Instant::now());
                phase.set(8);
            }
            8 if reveal.is_sensitive() && pause.get().elapsed() > Duration::from_millis(300) => {
                assert!(!contains_label(window.upcast_ref(), "must not overwrite"));
                assert_eq!(calls.borrow().len(), 4);
                assert_eq!(std::fs::read(&raw).unwrap(), b"preserved\r\n");
                connection
                    .unregister_object(registration.borrow_mut().take().unwrap())
                    .unwrap();
                fixture_holder.borrow_mut().take();
                println!("PASS native filemanager: actual project/header and tab-menu mouse actions, exact raw URIs, visible real D-Bus error, late tab/project receipts suppressed, double-click gate, unchanged bytes");
                std::process::exit(0);
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
