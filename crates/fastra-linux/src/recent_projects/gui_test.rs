use super::*;
use std::{
    cell::Cell,
    os::unix::ffi::OsStringExt,
    time::{Duration, Instant},
};
fn click(widget: &impl IsA<gtk::Widget>, keys: &[&str]) {
    let widget = widget.as_ref();
    let native = widget.native().unwrap();
    let point = widget
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(widget.width() as f32 / 2., widget.height() as f32 / 2.),
        )
        .unwrap();
    let (x, y) = native.surface_transform();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(native.surface().unwrap().as_ptr().cast()) }.to_string();
    let keys: Vec<String> = keys.iter().map(|s| s.to_string()).collect();
    std::thread::spawn(move || {
        let mut c = std::process::Command::new("xdotool");
        c.args([
            "windowfocus",
            "--sync",
            &id,
            "mousemove",
            "--window",
            &id,
            &(point.x() as f64 - x).round().to_string(),
            &(point.y() as f64 - y).round().to_string(),
            "click",
            "1",
        ]);
        if !keys.is_empty() {
            c.arg("key").args(keys);
        }
        assert!(c.status().unwrap().success());
    });
}

fn capture_menu(menu: &Menu, name: &str) {
    let Some(directory) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS").map(PathBuf::from) else {
        return;
    };
    std::fs::create_dir_all(&directory).unwrap();
    let paintable = gtk::WidgetPaintable::new(Some(&menu.popover));
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(
        &snapshot,
        menu.popover.width() as f64,
        menu.popover.height() as f64,
    );
    let node = snapshot.to_node().unwrap();
    let texture = menu.popover.renderer().unwrap().render_texture(&node, None);
    texture
        .save_to_png(directory.join(format!("{name}-rendered.png")))
        .unwrap();

    let native = menu.popover.native().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(native.surface().unwrap().as_ptr().cast()) }.to_string();
    let file = directory.join(format!("{name}-popover.png"));
    std::thread::spawn(move || {
        assert!(std::process::Command::new("import")
            .args(["-silent", "-window", &id])
            .arg(file)
            .status()
            .unwrap()
            .success());
    });
}
fn first_action(menu: &Menu, index: usize) -> gtk::Button {
    let row = menu.list.first_child().unwrap();
    let mut widget = row.first_child().unwrap();
    for _ in 0..index {
        widget = widget.next_sibling().unwrap();
    }
    widget.downcast().unwrap()
}
fn count(menu: &Menu) -> usize {
    let mut n = 0;
    let mut child = menu.list.first_child();
    while let Some(row) = child {
        n += 1;
        child = row.next_sibling();
    }
    n
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let fixture = if let Some(path) = std::env::var_os("FASTRA_RECENT_FIXTURE") {
        PathBuf::from(path)
    } else {
        let fixture = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap())
            .join(format!("recent-fixture-{}", glib::uuid_string_random()));
        std::fs::create_dir(&fixture).unwrap();
        let store = Store::open(&config_root().unwrap()).unwrap();
        assert!(
            store.load().unwrap().is_empty(),
            "Use an empty private test configuration"
        );
        for n in (0..11).rev() {
            let path = fixture.join(format!("project-{n}"));
            std::fs::create_dir(&path).unwrap();
            store.apply(&Change::Remember(path)).unwrap();
        }
        let raw = fixture.join(std::ffi::OsString::from_vec(b"raw-\xff-project".to_vec()));
        std::fs::create_dir(&raw).unwrap();
        std::fs::write(raw.join("retained.txt"), b"retained\n").unwrap();
        store.apply(&Change::Remember(raw)).unwrap();
        std::fs::create_dir(fixture.join("normal")).unwrap();
        std::fs::write(fixture.join("normal/plain.txt"), b"normal\n").unwrap();
        fixture
    };
    let raw = fixture.join(std::ffi::OsString::from_vec(b"raw-\xff-project".to_vec()));
    let normal = fixture.join("normal");
    let project = super::super::open(&ui);
    support::test_size(&project.window);
    let menu = project.recent.borrow().as_ref().unwrap().clone();
    let phase = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    let initial_documents = ui.documents.borrow().len();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(45),
            "recent timeout phase{} {}",
            phase.get(),
            menu.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(350) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                assert!(project.selected.borrow().is_none());
                assert!(project.root_path.borrow().as_os_str().is_empty());
                click(&menu.button, &[]);
                phase.set(1);
                pause.set(Instant::now());
            }
            1 => {
                if menu.busy.get() || !menu.popover.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(count(&menu), 12);
                assert_eq!(ui.documents.borrow().len(), initial_documents);
                support::capture(&project.window, "recent-menu-full");
                capture_menu(&menu, "recent-menu-full");
                phase.set(101);
                pause.set(Instant::now());
            }
            101 => {
                click(&first_action(&menu, 1), &[]);
                phase.set(2);
                pause.set(Instant::now());
            }
            2 => {
                if project.busy.get() || project.selected.borrow().is_none() || menu.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(project.selected.borrow().as_ref().unwrap().path, raw);
                assert_eq!(ui.documents.borrow().len(), initial_documents);
                support::capture(&project.window, "recent-project-raw");
                click(&menu.button, &[]);
                phase.set(3);
                pause.set(Instant::now());
            }
            3 => {
                if menu.busy.get() || !menu.popover.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                click(&first_action(&menu, 2), &[]);
                phase.set(4);
                pause.set(Instant::now());
            }
            4 => {
                if menu.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(count(&menu), 11);
                assert!(!Store::open(&config_root().unwrap())
                    .unwrap()
                    .load()
                    .unwrap()
                    .contains(&raw));
                assert_eq!(project.selected.borrow().as_ref().unwrap().path, raw);
                support::capture(&project.window, "recent-menu-removed");
                capture_menu(&menu, "recent-menu-removed");
                phase.set(104);
                pause.set(Instant::now());
            }
            104 => {
                click(&menu.clear, &[]);
                phase.set(5);
                pause.set(Instant::now());
            }
            5 => {
                if menu.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(Store::open(&config_root().unwrap())
                    .unwrap()
                    .load()
                    .unwrap()
                    .is_empty());
                assert!(!menu.clear.is_sensitive());
                assert_eq!(project.selected.borrow().as_ref().unwrap().path, raw);
                menu.popover.popdown();
                project
                    .path
                    .set_text(fixture.join("missing").to_str().unwrap());
                phase.set(6);
                pause.set(Instant::now());
            }
            6 => {
                if project.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(project.selected.borrow().is_none());
                assert!(Store::open(&config_root().unwrap())
                    .unwrap()
                    .load()
                    .unwrap()
                    .is_empty());
                project.path.set_text(normal.to_str().unwrap());
                phase.set(7);
                pause.set(Instant::now());
            }
            7 => {
                if project.busy.get() || project.selected.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert!(Store::open(&config_root().unwrap())
                    .unwrap()
                    .load()
                    .unwrap()
                    .is_empty());
                click(&project.path, &["Return"]);
                phase.set(8);
                pause.set(Instant::now());
            }
            8 => {
                if project.busy.get() || menu.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                let paths = Store::open(&config_root().unwrap())
                    .unwrap()
                    .load()
                    .unwrap();
                if paths.is_empty() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(paths, vec![normal.clone()]);
                click(&menu.button, &[]);
                phase.set(9);
                pause.set(Instant::now());
            }
            9 => {
                if menu.busy.get() || !menu.popover.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(count(&menu), 1);
                assert_eq!(ui.documents.borrow().len(), initial_documents);
                support::capture(&project.window, "recent-menu-confirmed");
                capture_menu(&menu, "recent-menu-confirmed");
                assert_eq!(
                    std::fs::read(raw.join("retained.txt")).unwrap(),
                    b"retained\n"
                );
                println!("FASTRA recent projects PASS: native menu/open/remove/clear/Return, raw path preserved, no autostart/file tab, failed scan and unconfirmed typing not recorded, selected project and files retained");
                phase.set(10);
                pause.set(Instant::now());
            }
            10 => std::process::exit(0),
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
