use super::*;
use std::{path::PathBuf, time::Instant};
fn widgets(widget: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
    all.push(widget.clone());
    let mut child = widget.first_child();
    while let Some(item) = child {
        widgets(&item, all);
        child = item.next_sibling();
    }
}
fn active(ui: &Rc<Ui>) -> Rc<State> {
    STATES.with(|all| {
        all.borrow()
            .iter()
            .filter_map(Weak::upgrade)
            .find(|state| {
                state
                    .ui
                    .upgrade()
                    .is_some_and(|bound| Rc::ptr_eq(&bound, ui))
                    && state.owner().is_some()
            })
            .unwrap()
    })
}
fn keys(state: &State, keys: &[&str]) {
    state.view.upgrade().unwrap().grab_focus();
    let keys: Vec<String> = keys.iter().map(|key| key.to_string()).collect();
    std::thread::spawn(move || {
        assert!(std::process::Command::new("xdotool")
            .args(["key", "--clearmodifiers"])
            .args(keys)
            .status()
            .unwrap()
            .success());
    });
}
fn ready(state: &State) -> bool {
    state.popup.is_visible() && state.pending.borrow().is_some()
}
fn reset(state: &State, text: &str) {
    state.close();
    let doc = state.doc.upgrade().unwrap();
    doc.buffer.set_text(text);
    doc.buffer.place_cursor(&doc.buffer.end_iter());
    state.view.upgrade().unwrap().grab_focus();
}
fn capture(state: &State, name: &str) -> bool {
    let Some(directory) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS") else {
        return true;
    };
    if !state.popup.is_mapped() {
        return false;
    }
    let paintable = gtk::WidgetPaintable::new(Some(&state.popup));
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(
        &snapshot,
        state.popup.width() as f64,
        state.popup.height() as f64,
    );
    let Some(node) = snapshot.to_node() else {
        state.popup.queue_draw();
        return false;
    };
    let ui = state.ui.upgrade().unwrap();
    let texture = ui.window.renderer().unwrap().render_texture(&node, None);
    std::fs::create_dir_all(&directory).unwrap();
    texture
        .save_to_png(PathBuf::from(directory).join(format!("{name}.png")))
        .unwrap();
    true
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root =
        PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join("completion-project");
    let methods = root.join("Project/Sources/Methods");
    std::fs::create_dir_all(&methods).unwrap();
    std::fs::write(methods.join("ZZProject.4dm"), "#DECLARE($value : Text)").unwrap();
    let shared = root.join("Components/Shared.4dbase/Sources/Methods");
    std::fs::create_dir_all(&shared).unwrap();
    std::fs::write(
        shared.join("ZZComponent.4dm"),
        "//%attributes={\"shared\":true}\n#DECLARE($count : Integer)",
    )
    .unwrap();
    std::fs::write(
        shared.join("ZZProject.4dm"),
        "//%attributes={\"shared\":true}",
    )
    .unwrap();
    ui.add_document("completion.4dm", "");
    let doc = ui.active().unwrap();
    let page = ui.tabs.current_page();
    if let Ok(width) = std::env::var("FASTRA_TOOL_WIDTH") {
        ui.window.set_default_size(width.parse().unwrap(), 900);
    }
    let start = Instant::now();
    let pause = Cell::new(start);
    let stage = Cell::new(0);
    let held: RefCell<Option<Rc<State>>> = RefCell::new(None);
    let picked = RefCell::new(String::new());
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(65),
            "completion stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        match stage.get() {
            0 => {
                if !ui.window.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                let state = active(&ui);
                assert_eq!(doc.buffer.language().unwrap().id(), "fastra-4d");
                git_view::test_click(&state.view.upgrade().unwrap(), &["o", "b"]);
                *held.borrow_mut() = Some(state);
                stage.set(1);
            }
            1 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "ob");
                assert!(
                    state.pending.borrow().as_ref().unwrap().suggestions.items[0]
                        .name
                        .to_lowercase()
                        .starts_with("ob")
                );
                pause.set(Instant::now());
                stage.set(2);
            }
            2 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                if !capture(&state, "completion-auto") {
                    return glib::ControlFlow::Continue;
                }
                *picked.borrow_mut() = state.pending.borrow().as_ref().unwrap().suggestions.items
                    [10]
                .name
                .clone();
                let mut arrows = vec!["Down"; 11];
                arrows.push("Up");
                keys(&state, &arrows);
                stage.set(21);
            }
            21 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if state.list.selected_row().map(|row| row.index()) != Some(10) {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state.scroll.vadjustment().value() > 0.,
                    "selected row scrolled into view"
                );
                if !capture(&state, "completion-scrolled") {
                    return glib::ControlFlow::Continue;
                }
                keys(&state, &["Return"]);
                stage.set(3);
            }
            3 => {
                let text = buffer_text(&doc.buffer);
                if text == "ob" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(text, *picked.borrow());
                assert!(!held.borrow().as_ref().unwrap().popup.is_visible());
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), "ob");
                let state = held.borrow().as_ref().unwrap().clone();
                reset(&state, "OBJECT SET C");
                state.request(true);
                stage.set(4);
            }
            4 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                let name = state.pending.borrow().as_ref().unwrap().suggestions.items[0]
                    .name
                    .clone();
                *picked.borrow_mut() = name;
                keys(&state, &["Tab"]);
                stage.set(5);
            }
            5 => {
                if buffer_text(&doc.buffer) == "OBJECT SET C" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), *picked.borrow());
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), "OBJECT SET C");
                let state = held.borrow().as_ref().unwrap().clone();
                reset(&state, "A");
                pause.set(Instant::now());
                stage.set(6);
            }
            6 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert!(!state.popup.is_visible());
                let mut all = Vec::new();
                widgets(ui.window.upcast_ref(), &mut all);
                all.into_iter()
                    .filter_map(|w| w.downcast::<gtk::MenuButton>().ok())
                    .find(|b| b.label().as_deref() == Some(ui.lang.text("Werkzeuge", "Tools")))
                    .unwrap()
                    .popup();
                pause.set(Instant::now());
                stage.set(61);
            }
            61 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let mut all = Vec::new();
                widgets(ui.window.upcast_ref(), &mut all);
                let menu = all
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::MenuButton>().ok())
                    .find(|b| b.label().as_deref() == Some(ui.lang.text("Werkzeuge", "Tools")))
                    .unwrap();
                let mut all = Vec::new();
                widgets(menu.popover().unwrap().upcast_ref(), &mut all);
                let button = all
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Button>().ok())
                    .find(|b| {
                        b.label().as_deref()
                            == Some(ui.lang.text("4D-Vervollständigung …", "4D completion …"))
                    })
                    .unwrap();
                git_view::test_click(&button, &[]);
                stage.set(7);
            }
            7 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    state.scroll.vadjustment().value(),
                    state.scroll.vadjustment().lower(),
                    "new manual suggestions start at the first complete row"
                );
                if !capture(&state, "completion-manual-one") {
                    return glib::ControlFlow::Continue;
                }
                keys(&state, &["Escape"]);
                pause.set(Instant::now());
                stage.set(8);
            }
            8 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert!(!state.popup.is_visible());
                assert_eq!(buffer_text(&doc.buffer), "A");
                keys(&state, &["Escape"]);
                stage.set(81);
            }
            81 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                keys(&state, &["Escape"]);
                pause.set(Instant::now());
                stage.set(82);
            }
            82 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert!(!state.popup.is_visible());
                reset(&state, "AL");
                keys(&state, &["ctrl+space"]);
                stage.set(9);
            }
            9 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                let row = state.list.row_at_index(0).unwrap();
                *picked.borrow_mut() = state.pending.borrow().as_ref().unwrap().suggestions.items
                    [0]
                .name
                .clone();
                git_view::test_click(&row, &[]);
                stage.set(10);
            }
            10 => {
                if buffer_text(&doc.buffer) == "AL" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), *picked.borrow());
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), "AL");
                let state = held.borrow().as_ref().unwrap().clone();
                reset(&state, "// AL");
                state.request(true);
                pause.set(Instant::now());
                stage.set(11);
            }
            11 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert!(!state.popup.is_visible());
                reset(&state, "\"AL");
                state.request(true);
                pause.set(Instant::now());
                stage.set(12);
            }
            12 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert!(!state.popup.is_visible());
                reset(&state, "AL");
                let a = doc.buffer.start_iter();
                let b = doc.buffer.end_iter();
                doc.buffer.select_range(&a, &b);
                state.request(true);
                pause.set(Instant::now());
                stage.set(13);
            }
            13 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert!(!state.popup.is_visible());
                doc.buffer.place_cursor(&doc.buffer.end_iter());
                reset(&state, "ZZ");
                project_view::open_path(&ui, root.clone());
                pause.set(Instant::now());
                stage.set(14);
            }
            14 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                for window in gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .filter(|w| {
                        w.title().as_deref()
                            == Some(ui.lang.text("Projektdateien", "Project files"))
                    })
                {
                    window.set_visible(false);
                }
                ui.window.present();
                let state = held.borrow().as_ref().unwrap().clone();
                state.view.upgrade().unwrap().grab_focus();
                let mut all = Vec::new();
                widgets(ui.window.upcast_ref(), &mut all);
                all.into_iter()
                    .filter_map(|w| w.downcast::<gtk::MenuButton>().ok())
                    .find(|b| b.label().as_deref() == Some(ui.lang.text("Werkzeuge", "Tools")))
                    .unwrap()
                    .popup();
                pause.set(Instant::now());
                stage.set(141);
            }
            141 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let mut all = Vec::new();
                widgets(ui.window.upcast_ref(), &mut all);
                let menu = all
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::MenuButton>().ok())
                    .find(|b| b.label().as_deref() == Some(ui.lang.text("Werkzeuge", "Tools")))
                    .unwrap();
                let mut all = Vec::new();
                widgets(menu.popover().unwrap().upcast_ref(), &mut all);
                let button = all
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Button>().ok())
                    .find(|b| {
                        b.label().as_deref()
                            == Some(ui.lang.text(
                                "4D-Projekt-/Komponentenindex aktualisieren",
                                "Refresh 4D project/component index",
                            ))
                    })
                    .unwrap();
                git_view::test_click(&button, &[]);
                stage.set(15);
            }
            15 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if !ready(&state) || !state.cache.current(&ui) {
                    return glib::ControlFlow::Continue;
                }
                let pending = state.pending.borrow();
                let names = pending
                    .as_ref()
                    .unwrap()
                    .suggestions
                    .items
                    .iter()
                    .map(|m| m.name.clone())
                    .collect::<Vec<_>>();
                assert_eq!(names, vec!["ZZProject", "ZZComponent"]);
                drop(pending);
                if !capture(&state, "completion-project-component") {
                    return glib::ControlFlow::Continue;
                }
                keys(&state, &["Escape"]);
                pause.set(Instant::now());
                stage.set(16);
            }
            16 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                reset(&state, "AL");
                state.request(true);
                ui.add_document("other.4dm", "foreign");
                pause.set(Instant::now());
                stage.set(17);
            }
            17 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                state.apply();
                assert_eq!(buffer_text(&doc.buffer), "AL");
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "foreign");
                assert!(!state.popup.is_visible());
                ui.tabs.set_current_page(page);
                stage.set(18);
            }
            18 => {
                let state = held.borrow().as_ref().unwrap().clone();
                state.view.upgrade().unwrap().grab_focus();
                reset(&state, "AL");
                state.request(true);
                doc.buffer.insert_at_cursor("x");
                pause.set(Instant::now());
                stage.set(19);
            }
            19 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                state.apply();
                assert_eq!(buffer_text(&doc.buffer), "ALx");
                reset(&state, "AL");
                state.request(true);
                stage.set(200);
            }
            200 => {
                let state = held.borrow().as_ref().unwrap().clone();
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                ui.window.set_visible(false);
                state.apply();
                assert_eq!(buffer_text(&doc.buffer), "AL");
                ui.window.present();
                doc.buffer.set_language(None);
                state.view.upgrade().unwrap().grab_focus();
                state.request(true);
                pause.set(Instant::now());
                stage.set(201);
            }
            201 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert!(!state.popup.is_visible());
                doc.buffer.set_language(
                    sourceview5::LanguageManager::default()
                        .language("fastra-4d")
                        .as_ref(),
                );
                state.view.upgrade().unwrap().set_editable(false);
                state.request(true);
                pause.set(Instant::now());
                stage.set(202);
            }
            202 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let state = held.borrow().as_ref().unwrap().clone();
                assert!(!state.popup.is_visible());
                assert_eq!(buffer_text(&doc.buffer), "AL");
                state.view.upgrade().unwrap().set_editable(true);
                state.close();
                println!("FASTRA_TOOL_SELFTEST_OK four-d-completion");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
