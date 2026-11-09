use super::*;
use std::time::{Duration, Instant};
fn chooser(ui: &Ui) -> Option<gtk::Window> {
    chooser_for(ui.window.upcast_ref(), ui.lang)
}
pub(super) fn chooser_for(parent: &gtk::Window, lang: Language) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Window>().ok())
        .find(|window| {
            window.is_visible()
                && window != parent
                && window.title().as_deref()
                    == Some(lang.text("Vergleich exportieren", "Export comparison"))
        })
}
pub(super) fn accept(window: &gtk::Window) -> gtk::Widget {
    button(window.upcast_ref(), &["Save", "Speichern"])
        .expect("native Save button")
        .upcast()
}
pub(super) fn button(widget: &gtk::Widget, labels: &[&str]) -> Option<gtk::Button> {
    if let Some(button) = widget
        .downcast_ref::<gtk::Button>()
        .filter(|button| button.is_visible() && button.is_sensitive())
    {
        if button
            .label()
            .is_some_and(|label| labels.contains(&label.replace('_', "").as_str()))
        {
            return Some(button.clone());
        }
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(found) = button(&widget, labels) {
            return Some(found);
        }
        child = widget.next_sibling();
    }
    None
}
pub(super) fn typing_finished(slot: &RefCell<Option<std::sync::mpsc::Receiver<()>>>) -> bool {
    let reply = slot
        .borrow()
        .as_ref()
        .map(std::sync::mpsc::Receiver::try_recv);
    match reply {
        None => true,
        Some(Ok(())) => {
            slot.borrow_mut().take();
            true
        }
        Some(Err(std::sync::mpsc::TryRecvError::Empty)) => false,
        Some(Err(std::sync::mpsc::TryRecvError::Disconnected)) => panic!("native typing stopped"),
    }
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let left = root.join("export-left.txt");
    let right = root.join("export-right.txt");
    let report = root.join("exported.txt");
    let renamed = [
        root.join("renamed-left.txt"),
        root.join("renamed-right.txt"),
    ];
    let protected_side = Cell::new(0);
    std::fs::write(&left, "old café\n").unwrap();
    std::fs::write(&right, "new café\n").unwrap();
    ui.load_path(left.clone());
    let state = RefCell::new(None::<Rc<State>>);
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let typed = RefCell::new(None::<std::sync::mpsc::Receiver<()>>);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(40),
            "comparison export phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(300) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                if !ui
                    .active()
                    .is_some_and(|doc| doc.disk_path().as_ref() == Some(&left))
                {
                    return glib::ControlFlow::Continue;
                }
                let picker = open(&ui);
                picker.choose(1, sources::Choice::File(right.clone()));
                *state.borrow_mut() = Some(picker);
            }
            1 => {
                let state = state.borrow().clone().unwrap();
                if !state.picker.compare.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.picker.compare, &[]);
            }
            2 | 10 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || !state.view.export.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.view.export, &[]);
            }
            3 => {
                let Some(window) = chooser(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                if !support::try_capture(&window, "compare-export-chooser") {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&window, &["ctrl+l", "ctrl+a"]);
            }
            4 => {
                let window = chooser(&ui).unwrap();
                *typed.borrow_mut() = Some(support::test_type(&window, report.to_str().unwrap()));
            }
            5 => {
                if !typing_finished(&typed) {
                    return glib::ControlFlow::Continue;
                }
                let window = chooser(&ui).unwrap();
                if !support::try_capture(&window, "compare-export-location") {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&window, &["Return"]);
            }
            6 => {
                if let Some(window) = chooser(&ui) {
                    support::test_click(&accept(&window), &[]);
                }
            }
            7 => {
                if !report.exists() {
                    return glib::ControlFlow::Continue;
                }
                let text = std::fs::read_to_string(&report).unwrap();
                assert!(text.contains("- 1 | old café"));
                assert!(text.contains("+ 1 | new café"));
                assert!(text.contains(ui.lang.text("Differenzen-Liste", "Difference list")));
                assert!(text.contains(ui.lang.text("Editorinhalt", "Editor content")));
                assert_eq!(std::fs::read_to_string(&left).unwrap(), "old café\n");
                let state = state.borrow().clone().unwrap();
                support::test_click(&state.view.export, &[]);
            }
            8 => {
                let Some(window) = chooser(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                support::test_keys(&window, &["Escape"]);
            }
            9 => {
                if chooser(&ui).is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&left).unwrap(), "old café\n");
            }
            11 => {
                let Some(window) = chooser(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                let source = if protected_side.get() == 0 {
                    &left
                } else {
                    &right
                };
                std::fs::rename(source, &renamed[protected_side.get()]).unwrap();
                support::test_keys(&window, &["ctrl+l", "ctrl+a"]);
            }
            12 => {
                let window = chooser(&ui).unwrap();
                *typed.borrow_mut() = Some(support::test_type(
                    &window,
                    renamed[protected_side.get()].to_str().unwrap(),
                ));
            }
            13 => {
                if !typing_finished(&typed) {
                    return glib::ControlFlow::Continue;
                }
                let window = chooser(&ui).unwrap();
                if !support::try_capture(&window, "compare-export-location") {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&window, &["Return"]);
            }
            14 => {
                let confirmation = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|widget| widget.downcast::<gtk::Window>().ok())
                    .any(|window| {
                        window.is_visible()
                            && window != ui.window
                            && chooser(&ui).as_ref() != Some(&window)
                    });
                if !confirmation {
                    if let Some(window) = chooser(&ui) {
                        support::test_click(&accept(&window), &[]);
                    }
                }
            }
            15 => {
                let confirmation = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|widget| widget.downcast::<gtk::Window>().ok())
                    .find(|window| {
                        window.is_visible()
                            && window != &ui.window
                            && chooser(&ui).as_ref() != Some(window)
                    });
                if let Some(window) = confirmation {
                    let button = button(window.upcast_ref(), &["Replace", "Ersetzen"])
                        .expect("native overwrite confirmation");
                    support::test_click(&button, &[]);
                } else if !ui.status.text().contains(ui.lang.text(
                    "Vergleichsquelle überschreiben",
                    "overwrite a comparison source",
                )) {
                    return glib::ControlFlow::Continue;
                }
            }
            _ => {
                if !ui.status.text().contains(ui.lang.text(
                    "Vergleichsquelle überschreiben",
                    "overwrite a comparison source",
                )) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&renamed[0]).unwrap(), "old café\n");
                if protected_side.get() == 0 {
                    assert_eq!(std::fs::read_to_string(&right).unwrap(), "new café\n");
                    protected_side.set(1);
                    ui.status.set_text("");
                    phase.set(10);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&renamed[1]).unwrap(), "new café\n");
                eprintln!("DIFF_PICKER_SELFTEST PASS native report Save with exact localized snapshot, native Cancel, native overwrite confirmations rejected for renamed memory and file sources; both input files unchanged");
                crate::source_appearance::cleanup_schemes();
                std::process::exit(0);
            }
        }
        eprintln!("comparison export phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
