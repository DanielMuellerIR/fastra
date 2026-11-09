use super::*;
use crate::{buffer_text, git_view as support};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
fn widgets(root: &impl IsA<gtk::Widget>) -> Vec<gtk::Widget> {
    let mut result = vec![root.as_ref().clone()];
    for child in crate::chrome::children(root.as_ref()) {
        result.extend(widgets(&child));
    }
    result
}
fn named<T: IsA<glib::Object> + glib::object::ObjectType>(
    root: &impl IsA<gtk::Widget>,
    name: &str,
) -> T {
    widgets(root)
        .into_iter()
        .find(|widget| widget.widget_name() == name)
        .unwrap()
        .dynamic_cast::<T>()
        .ok()
        .unwrap()
}
fn settings(ui: &Ui) -> gtk::Window {
    ui.window
        .application()
        .unwrap()
        .windows()
        .into_iter()
        .find(|window| window.widget_name() == "fastra-global-settings")
        .unwrap()
}
fn views(doc: &Document) -> Vec<sourceview5::View> {
    doc.editor_options
        .borrow()
        .as_ref()
        .unwrap()
        .views
        .iter()
        .filter_map(|view| view.upgrade())
        .collect()
}
fn check(doc: &Document, text: &str, redo: bool) {
    assert_eq!(buffer_text(&doc.buffer), text);
    assert!(!doc.buffer.is_modified());
    assert!(!doc.buffer.can_undo());
    assert_eq!(doc.buffer.can_redo(), redo);
}
fn geometry(window: &gtk::Window) {
    let mode_label: gtk::Label = named(window, "fastra-appearance-label");
    assert_eq!(
        mode_label.layout().line_count(),
        1,
        "appearance label stays on one line"
    );
    for row in widgets(window)
        .into_iter()
        .filter(|widget| widget.has_css_class("settings-row"))
    {
        for child in crate::chrome::children(&row)
            .into_iter()
            .filter(|child| child.is_visible())
        {
            let bounds = child.compute_bounds(&row).unwrap();
            assert!(
                bounds.x() >= -1. && bounds.x() + bounds.width() <= row.width() as f32 + 1.,
                "settings row child {} {bounds:?} row={}",
                child.type_().name(),
                row.width()
            );
            assert!(bounds.width() > 0. && bounds.height() > 0.);
        }
    }
    let scroll = window
        .child()
        .unwrap()
        .downcast::<gtk::ScrolledWindow>()
        .unwrap();
    assert!(
        scroll.hadjustment().upper() <= scroll.hadjustment().page_size() + 1.,
        "no clipped horizontal form content"
    );
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let mode = std::env::var("FASTRA_SETTINGS_FORM_SELFTEST").unwrap();
    let restore = std::env::var_os("FASTRA_SETTINGS_FORM_RESTORE").is_some();
    let home = mode == "home";
    let text = if home {
        ""
    } else {
        "fn main() { println!(\"café 😀\"); }\r\n"
    };
    if !home {
        ui.add_document("settings.rs", text);
    }
    let doc = ui.active().unwrap();
    if !home {
        doc.buffer.insert(&mut doc.buffer.end_iter(), "temporary");
        doc.buffer.undo();
    }
    let peer_text = "peer Ω\r\n";
    ui.add_document("peer.rs", peer_text);
    let peer = ui.active().unwrap();
    peer.buffer.insert(&mut peer.buffer.end_iter(), "temporary");
    peer.buffer.undo();
    if home {
        ui.tabs.set_current_page(Some(0));
    }
    let root = PathBuf::from(std::env::var_os("XDG_CONFIG_HOME").unwrap());
    let path = root.join("fastra-editor/profiles.json");
    let original = std::fs::read(&path).unwrap();
    let lock = RefCell::new(None::<std::fs::File>);
    let input = RefCell::new(None::<std::sync::mpsc::Receiver<()>>);
    let phase = Cell::new(0);
    let previous = Cell::new(u32::MAX);
    let began = Instant::now();
    let pause = Cell::new(began);
    let matrix = Cell::new(0);
    let target_motion = Cell::new((0., 0.));
    let actual_motion = Rc::new(Cell::new(None::<(f64, f64)>));
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            began.elapsed() < Duration::from_secs(65),
            "settings phase {}",
            phase.get()
        );
        if previous.replace(phase.get()) != phase.get() {
            eprintln!("SETTINGS_PHASE {}", phase.get());
        }
        check(&doc, text, !home);
        check(&peer, peer_text, true);
        match phase.get() {
            0 if began.elapsed() > Duration::from_millis(600) => {
                if home {
                    assert!(crate::chrome::is_pristine(&doc));
                    let gear = widgets(&ui.window)
                        .into_iter()
                        .find_map(|widget| {
                            widget.downcast::<gtk::Button>().ok().filter(|button| {
                                button.tooltip_text().as_deref()
                                    == Some(ui.lang.text("Einstellungen", "Settings"))
                            })
                        })
                        .unwrap();
                    support::test_click(&gear, &[]);
                } else {
                    ui.window
                        .application()
                        .unwrap()
                        .activate_action("settings", None);
                }
                phase.set(1);
            }
            1 => {
                if !ui
                    .window
                    .application()
                    .unwrap()
                    .windows()
                    .iter()
                    .any(|window| window.widget_name() == "fastra-global-settings")
                {
                    return glib::ControlFlow::Continue;
                }
                let window = settings(&ui);
                let toggle: gtk::Switch = named(&window, "fastra-global-guide-visible");
                if !window.is_mapped() || toggle.width() == 0 {
                    return glib::ControlFlow::Continue;
                }
                if mode == "corrupt" && !restore {
                    if toggle.is_sensitive() {
                        return glib::ControlFlow::Continue;
                    }
                    let retry: gtk::Button = named(&window, "fastra-global-guide-retry");
                    if !retry.is_visible() {
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(std::fs::read(&path).unwrap(), original);
                    assert!(support::try_capture(&window, "settings-corrupt"));
                    std::fs::write(
                        &path,
                        std::fs::read(root.join("valid-profiles.json")).unwrap(),
                    )
                    .unwrap();
                    support::test_click(&retry, &[]);
                    phase.set(2);
                    return glib::ControlFlow::Continue;
                }
                if !toggle.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                phase.set(2);
            }
            2 => {
                let window = settings(&ui);
                let toggle: gtk::Switch = named(&window, "fastra-global-guide-visible");
                if !toggle.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                let expected = if restore { 82 } else { 80 };
                for view in views(&doc).into_iter().chain(views(&peer)) {
                    assert_eq!(view.right_margin_position(), expected);
                    assert_eq!(view.shows_right_margin(), restore);
                }
                geometry(&window);
                if restore {
                    println!("PASS Settings fresh restore: global82/on, original format fields and source/Undo retained");
                    support::finish(window, ui.clone(), "settings-restored");
                    return glib::ControlFlow::Break;
                }
                assert!(support::try_capture(&window, "settings-default"));
                if mode == "busy" {
                    *lock.borrow_mut() = Some(
                        super::super::store::Store::open(&root)
                            .unwrap()
                            .lock()
                            .unwrap(),
                    );
                }
                support::test_click(&toggle, &[]);
                phase.set(3);
            }
            3 => {
                let window = settings(&ui);
                let toggle: gtk::Switch = named(&window, "fastra-global-guide-visible");
                if !toggle.is_active() {
                    return glib::ControlFlow::Continue;
                }
                for view in views(&doc).into_iter().chain(views(&peer)) {
                    assert!(view.shows_right_margin());
                }
                if mode == "busy" && lock.borrow().is_some() {
                    let retry: gtk::Button = named(&window, "fastra-global-guide-retry");
                    if !retry.is_visible() || !retry.is_sensitive() {
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(std::fs::read(&path).unwrap(), original);
                    assert!(super::super::profile::pending());
                    assert!(support::try_capture(&window, "settings-busy"));
                    lock.borrow_mut().take();
                    support::test_click(&retry, &[]);
                    return glib::ControlFlow::Continue;
                }
                if super::super::profile::pending() {
                    return glib::ControlFlow::Continue;
                }
                let spin: gtk::SpinButton = named(&window, "fastra-global-guide-column");
                let up = widgets(&spin)
                    .into_iter()
                    .find_map(|widget| {
                        widget
                            .downcast::<gtk::Button>()
                            .ok()
                            .filter(|button| button.has_css_class("up"))
                    })
                    .unwrap();
                let point = up
                    .compute_point(
                        &window,
                        &gtk::graphene::Point::new(up.width() as f32 / 2., up.height() as f32 / 2.),
                    )
                    .unwrap();
                target_motion.set((point.x() as f64, point.y() as f64));
                let motion = gtk::EventControllerMotion::new();
                motion.set_propagation_phase(gtk::PropagationPhase::Capture);
                let tracked = actual_motion.clone();
                motion.connect_motion(move |_, x, y| tracked.set(Some((x, y))));
                window.add_controller(motion);
                support::test_click(&up, &[]);
                pause.set(Instant::now());
                phase.set(4);
            }
            4 => {
                let spin: gtk::SpinButton = named(&settings(&ui), "fastra-global-guide-column");
                if spin.value_as_int() != 81 {
                    if pause.get().elapsed() > Duration::from_secs(2) {
                        support::try_capture(&settings(&ui), "settings-stepper-failure");
                        assert_eq!(spin.value_as_int(), 81, "actual native stepper click");
                    }
                    return glib::ControlFlow::Continue;
                }
                let actual = actual_motion.get().expect("real GTK pointer event");
                let target = target_motion.get();
                assert!(
                    (actual.0 - target.0).abs() <= 1. && (actual.1 - target.1).abs() <= 1.,
                    "native pointer {actual:?} must hit measured target {target:?}"
                );
                *input.borrow_mut() = Some(support::test_input_completed(&spin, &["Up"], false));
                phase.set(5);
            }
            5 => {
                if input
                    .borrow()
                    .as_ref()
                    .is_some_and(|rx| rx.try_recv().is_err())
                {
                    return glib::ControlFlow::Continue;
                }
                input.borrow_mut().take();
                let spin: gtk::SpinButton = named(&settings(&ui), "fastra-global-guide-column");
                if spin.value_as_int() != 82 || super::super::profile::pending() {
                    return glib::ControlFlow::Continue;
                }
                for view in views(&doc).into_iter().chain(views(&peer)) {
                    assert_eq!(view.right_margin_position(), 82);
                    assert!(view.shows_right_margin());
                }
                let stored: serde_json::Value =
                    serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
                assert_eq!(stored["formats"]["rust"]["tab"], 7);
                assert_eq!(stored["formats"]["rust"]["indent"], 3);
                assert_eq!(stored["formats"]["rust"]["spaces"], false);
                assert_eq!(stored["guide"]["column"], 82);
                assert_eq!(stored["guide"]["visible"], true);
                phase.set(6);
            }
            6 => {
                let app = ui.window.application().unwrap();
                app.activate_action("ui-original", None);
                let (level, width, height): (i32, f64, f64) = match matrix.get() {
                    0 => (0, 480., 380.),
                    1 => (0, 680., 720.),
                    2 => (5, 480., 380.),
                    _ => (-3, 480., 380.),
                };
                for _ in 0..level.abs() {
                    app.activate_action(if level > 0 { "ui-larger" } else { "ui-smaller" }, None);
                }
                let scale = 1. + f64::from(level) * 0.13;
                settings(&ui).set_default_size(
                    (width * scale).round() as i32,
                    (height * scale).round() as i32,
                );
                pause.set(Instant::now());
                phase.set(7);
            }
            7 if pause.get().elapsed() > Duration::from_millis(250) => {
                let window = settings(&ui);
                geometry(&window);
                if !support::try_capture(&window, &format!("settings-matrix-{}", matrix.get())) {
                    return glib::ControlFlow::Continue;
                }
                let scroll = window
                    .child()
                    .unwrap()
                    .downcast::<gtk::ScrolledWindow>()
                    .unwrap();
                let a = scroll.vadjustment();
                a.set_value((a.upper() - a.page_size()).max(0.));
                pause.set(Instant::now());
                phase.set(8);
            }
            8 if pause.get().elapsed() > Duration::from_millis(200) => {
                let window = settings(&ui);
                geometry(&window);
                if !support::try_capture(
                    &window,
                    &format!("settings-matrix-{}-bottom", matrix.get()),
                ) {
                    return glib::ControlFlow::Continue;
                }
                if matrix.get() < 3 {
                    matrix.set(matrix.get() + 1);
                    window
                        .child()
                        .unwrap()
                        .downcast::<gtk::ScrolledWindow>()
                        .unwrap()
                        .vadjustment()
                        .set_value(0.);
                    phase.set(6);
                } else {
                    ui.window
                        .application()
                        .unwrap()
                        .activate_action("ui-original", None);
                    println!("PASS Settings: actual global switch, native stepper mouse and keyboard, four source views unchanged/Undo retained, shared profile fields preserved, busy/corrupt retry, min/wide/min-maxUI row geometry and scroll");
                    support::finish(window, ui.clone(), "settings-form");
                    return glib::ControlFlow::Break;
                }
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
