use super::*;
use std::time::{Duration, Instant};
thread_local! { static STARTED: Cell<bool> = const { Cell::new(false) }; }
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
}

fn first(menu: &Menu) -> gtk::Button {
    menu.list.first_child().unwrap().downcast().unwrap()
}
fn entries() -> Vec<Entry> {
    Store::open(&config_root().unwrap())
        .unwrap()
        .load()
        .unwrap()
}
fn idle(menu: &Menu) -> bool {
    !menu.busy.get() && menu.queue.borrow().is_empty()
}
pub(super) fn run(ui: Rc<Ui>) {
    if STARTED.with(|started| started.replace(true)) {
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    assert!(
        entries().is_empty(),
        "Use a fresh private test configuration"
    );
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or_else(|_| "760".into())
        .parse::<i32>()
        .unwrap();
    ui.window.set_default_size(width, 950);
    let menu = ui.search_history.borrow().as_ref().unwrap().clone();
    let other: RefCell<Option<Rc<Ui>>> = RefCell::new(None);
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let generation = Cell::new(0);
    let invalidated = Rc::new(Cell::new(false));
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(55),
            "search history phase {}: {}",
            phase.get(),
            menu.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(400) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                super::super::chrome::show_search(&ui);
                ui.find.set_text("typing must not persist document text");
                ui.replace.set_text("unsolicited");
                assert!(entries().is_empty());
                ui.active().unwrap().buffer.set_text("alpha alpha");
                ui.find.set_text("alpha");
                ui.replace.set_text("first replacement");
                ui.scope.set_selected(0);
                ui.mode.set_selected(2);
                ui.case.set_active(true);
                ui.whole_word.set_active(true);
                ui.search();
                phase.set(1);
            }
            1 => {
                if !idle(&menu) || ui.pending.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    entries(),
                    [Entry {
                        find: "alpha".into(),
                        replace: "first replacement".into()
                    }]
                );
                generation.set(ui.generation.get());
                // Dasselbe Suchwort mit anderem Ersatz ist ein eigenständiges Paar.
                menu.remember("alpha".into(), "second replacement".into());
                phase.set(2);
            }
            2 => {
                if !idle(&menu) {
                    return glib::ControlFlow::Continue;
                }
                click(&menu.button, &[]);
                phase.set(3);
            }
            3 => {
                if !idle(&menu) || !menu.popover.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(entries().len(), 2);
                assert!(ui.pending.borrow().is_some());
                support::capture(ui.window.upcast_ref(), "history-pair-menu");
                capture_menu(&menu, "history-pair-menu");
                let observed = invalidated.clone();
                let owner = Rc::downgrade(&ui);
                let once = Cell::new(false);
                ui.replace.connect_changed(move |_| {
                    if !once.replace(true) {
                        let ui = owner.upgrade().unwrap();
                        assert!(ui.pending.borrow().is_none() && !ui.apply.is_sensitive());
                        observed.set(true);
                    }
                });
                first(&menu).grab_focus();
                // Echte Tastenzustellung aktiviert den fokussierten nativen Button.
                click(&menu.status, &["Return"]);
                phase.set(4);
            }
            4 => {
                if ui.replace.text() != "second replacement" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.find.text(), "alpha");
                assert_eq!(ui.mode.selected(), 2);
                assert_eq!(ui.scope.selected(), 0);
                assert!(ui.case.is_active() && ui.whole_word.is_active());
                assert!(
                    invalidated.get(),
                    "history field change invalidates synchronously before the live search"
                );
                assert!(ui.pending.borrow().as_ref().is_none_or(|p| p
                    .preview
                    .matches()
                    .iter()
                    .all(|m| m.replacement == "second replacement")));
                assert!(!ui.apply.is_sensitive());
                assert!(ui.generation.get() > generation.get());
                assert!(!menu.popover.is_visible());
                assert_eq!(entries().len(), 2, "Selection is not a search action");
                let second = super::super::build(&ui.window.application().unwrap());
                second.window.set_default_size(width, 950);
                let second_menu = second.search_history.borrow().as_ref().unwrap().clone();
                for n in 0..17 {
                    second_menu.remember(format!("pair-{n}\n雪$1"), format!("replace-{n}\t$2"));
                }
                second_menu.remember("alpha".into(), "first replacement".into());
                *other.borrow_mut() = Some(second);
                phase.set(5);
            }
            5 => {
                let second = other.borrow();
                let second = second.as_ref().unwrap();
                let second_menu = second.search_history.borrow().as_ref().unwrap().clone();
                if !idle(&second_menu) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(entries().len(), 15);
                assert_eq!(entries()[0].replace, "first replacement");
                second.window.set_visible(false);
                ui.window.present();
                click(&ui.find, &["alt+h"]);
                phase.set(6);
            }
            6 => {
                if !idle(&menu) || !menu.popover.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                let mut count = 0;
                let mut child = menu.list.first_child();
                while let Some(row) = child {
                    count += 1;
                    child = row.next_sibling();
                }
                assert_eq!(count, 15, "Opening reads changes from another window");
                assert_eq!(
                    ui.replace.text(),
                    "second replacement",
                    "Other window cannot change these fields"
                );
                capture_menu(&menu, "history-full");
                support::capture(ui.window.upcast_ref(), "history-full");
                click(&menu.clear, &[]);
                phase.set(7);
            }
            7 => {
                if !idle(&menu) {
                    return glib::ControlFlow::Continue;
                }
                assert!(entries().is_empty());
                assert!(!menu.clear.is_sensitive());
                assert_eq!(ui.find.text(), "alpha");
                assert_eq!(ui.replace.text(), "second replacement");
                capture_menu(&menu, "history-empty");
                menu.popover.popdown();
                // Ein längst geöffnetes zweites Fenster darf gelöschte Paare nicht zurückbringen.
                let second = other.borrow();
                let second = second.as_ref().unwrap();
                second
                    .search_history
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .remember("after clear".into(), "fresh".into());
                phase.set(8);
            }
            8 => {
                let second = other.borrow();
                let second = second.as_ref().unwrap();
                if !idle(second.search_history.borrow().as_ref().unwrap()) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    entries(),
                    [Entry {
                        find: "after clear".into(),
                        replace: "fresh".into()
                    }]
                );
                let file = config_root()
                    .unwrap()
                    .join("fastra-search-history/library.json");
                std::fs::write(file, b"broken history retained").unwrap();
                click(&menu.button, &[]);
                phase.set(9);
            }
            9 => {
                if !idle(&menu) || !menu.popover.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!menu.list.is_sensitive());
                assert!(!menu.clear.is_sensitive());
                assert!(menu
                    .status
                    .text()
                    .contains(ui.lang.text("konnte nicht", "could not")));
                capture_menu(&menu, "history-error");
                menu.popover.popdown();
                menu.remember("must not overwrite".into(), "".into());
                phase.set(10);
            }
            10 => {
                if !idle(&menu) {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui
                    .status
                    .text()
                    .contains(ui.lang.text("konnte nicht", "could not")));
                assert_eq!(
                    std::fs::read(
                        config_root()
                            .unwrap()
                            .join("fastra-search-history/library.json")
                    )
                    .unwrap(),
                    b"broken history retained"
                );
                println!("SEARCH_HISTORY_SELFTEST_OK native mouse open/clear, keyboard pair, flags/scope, invalidation, discrete record, two windows, MRU15, fresh reload, clear, visible retained errors");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
