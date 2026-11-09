use super::gui_test::{checkbox, click, spins};
use super::*;
use std::time::{Duration, Instant};
fn state(doc: &Document) -> Rc<Options> {
    doc.editor_options.borrow().as_ref().unwrap().clone()
}
fn values(state: &Options, tab: u32, indent: i32, spaces: bool, wrap: bool) -> bool {
    state.views.iter().filter_map(|v| v.upgrade()).all(|v| {
        v.tab_width() == tab
            && v.indent_width() == indent
            && v.is_insert_spaces_instead_of_tabs() == spaces
            && (v.wrap_mode() != gtk::WrapMode::None) == wrap
    })
}
fn spin(state: &Options, index: usize, value: &str) {
    eprintln!(
        "PROFILE spin index={index} value={value} window={} key={}",
        state.window.borrow().is_some(),
        state.profile_key.borrow()
    );
    let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
    let mut widgets = Vec::new();
    spins(window.upcast_ref(), &mut widgets);
    assert_eq!(widgets.len(), 3 + usize::from(super::soft_wrap::capable()));
    click(
        &window,
        &widgets[index],
        vec!["ctrl+a".into(), value.into(), "Return".into()],
    );
}
fn unchanged(doc: &Document, text: &str) {
    assert_eq!(super::super::buffer_text(&doc.buffer), text);
    assert!(!doc.buffer.is_modified());
    assert!(!doc.buffer.can_undo());
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap()
        .parse::<i32>()
        .unwrap();
    ui.window.set_default_size(width, 950);
    let text = "\tfn main() { println!(\"café 🙂\"); }\r\n";
    ui.add_document("first.rs", text);
    let first = ui.active().unwrap();
    let options = state(&first);
    first.buffer.begin_user_action();
    first
        .buffer
        .insert(&mut first.buffer.end_iter(), "temporary");
    first.buffer.end_user_action();
    first.buffer.undo();
    assert!(first.buffer.can_redo());
    first.buffer.select_range(
        &first.buffer.iter_at_offset(2),
        &first.buffer.iter_at_offset(8),
    );
    options.show();
    let peer_ui = super::super::build(&ui.window.application().unwrap());
    peer_ui.window.set_default_size(width, 950);
    peer_ui.add_document("second.rs", text);
    let peer = peer_ui.active().unwrap();
    let peer_options = state(&peer);
    let stage = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    let stale = RefCell::new(None);
    let generation = Cell::new(0);
    let third = RefCell::new(None::<Rc<Document>>);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(50),
            "profile stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        assert!(
            peer_ui.window.is_visible(),
            "second real window owner retained"
        );
        match stage.get() {
            0 => {
                if pause.get().elapsed() < Duration::from_millis(400) {
                    return glib::ControlFlow::Continue;
                }
                assert!(values(&options, 4, 4, true, false));
                assert!(values(&peer_options, 4, 4, true, false));
                let selected = || {
                    first
                        .buffer
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset()))
                };
                assert_eq!(selected(), Some((2, 8)));
                options.change_profile(profile::Patch {
                    tab: Some(8),
                    indent: Some(2),
                    spaces: Some(false),
                    wrap: Some(true),
                    wrap_target: Some(super::soft_wrap::Target::Window),
                    wrap_column: Some(80),
                    wrap_indentation: Some(super::soft_wrap::Indentation::FirstLine),
                });
                assert_eq!(
                    selected(),
                    Some((2, 8)),
                    "direct profile application preserves Source selection"
                );
                options.change_profile(profile::Patch {
                    tab: Some(4),
                    indent: Some(4),
                    spaces: Some(true),
                    wrap: Some(false),
                    ..Default::default()
                });
                assert_eq!(selected(), Some((2, 8)));
                assert_eq!(first.buffer.cursor_position(), 2);
                first.buffer.place_cursor(&first.buffer.iter_at_offset(6));
                options.change_profile(profile::Patch {
                    tab: Some(8),
                    indent: Some(2),
                    spaces: Some(false),
                    wrap: Some(true),
                    wrap_target: Some(super::soft_wrap::Target::Window),
                    wrap_column: Some(80),
                    wrap_indentation: Some(super::soft_wrap::Indentation::FirstLine),
                });
                assert_eq!(first.buffer.cursor_position(), 6);
                assert!(first.buffer.selection_bounds().is_none());
                options.change_profile(profile::Patch {
                    tab: Some(4),
                    indent: Some(4),
                    spaces: Some(true),
                    wrap: Some(false),
                    ..Default::default()
                });
                assert_eq!(first.buffer.cursor_position(), 6);
                assert!(first.buffer.selection_bounds().is_none());
                first.buffer.select_range(
                    &first.buffer.iter_at_offset(2),
                    &first.buffer.iter_at_offset(8),
                );
                assert!(first.buffer.can_redo());
                generation.set(options.profile_generation.get());
                *stale.borrow_mut() = Some(profile::get(&config_root().unwrap(), "rust").unwrap());
                spin(&options, 0, "2");
                stage.set(1);
            }
            1 => {
                if !values(&options, 2, 4, true, false) || !values(&peer_options, 2, 4, true, false)
                {
                    return glib::ControlFlow::Continue;
                }
                spin(&options, 1, "8");
                stage.set(2);
            }
            2 => {
                if !values(&options, 2, 8, true, false) || !values(&peer_options, 2, 8, true, false)
                {
                    return glib::ControlFlow::Continue;
                }
                first.buffer.select_range(
                    &first.buffer.iter_at_offset(2),
                    &first.buffer.iter_at_offset(8),
                );
                assert!(
                    options
                        .finish_profile(generation.get(), Ok(stale.borrow_mut().take().unwrap()))
                );
                assert!(values(&options, 2, 8, true, false));
                assert_eq!(
                    first
                        .buffer
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((2, 8)),
                    "delayed profile reply preserves Source selection"
                );
                assert_eq!(first.buffer.cursor_position(), 2);
                assert!(first.buffer.can_redo());
                eprintln!(
                    "PROFILE direct application and delayed actual-read reply preserve Source selection2..8, caret, text and existing redo"
                );
                let window = options.window.borrow().as_ref().unwrap().upgrade().unwrap();
                click(
                    &window,
                    &checkbox(
                        window.upcast_ref(),
                        ui.lang
                            .text("Mit Leerzeichen einrücken", "Indent with spaces"),
                    )
                    .unwrap(),
                    vec![],
                );
                stage.set(3);
            }
            3 => {
                if !values(&options, 2, 8, false, false)
                    || !values(&peer_options, 2, 8, false, false)
                {
                    return glib::ControlFlow::Continue;
                }
                click(
                    ui.window.upcast_ref(),
                    &checkbox(
                        first.container.upcast_ref(),
                        ui.lang.text("Zeilenumbruch", "Wrap lines"),
                    )
                    .unwrap(),
                    vec![],
                );
                stage.set(4);
            }
            4 => {
                if !values(&options, 2, 8, false, true) || !values(&peer_options, 2, 8, false, true)
                {
                    return glib::ControlFlow::Continue;
                }
                click(
                    ui.window.upcast_ref(),
                    &checkbox(
                        first.container.upcast_ref(),
                        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
                    )
                    .unwrap(),
                    vec![],
                );
                pause.set(Instant::now());
                stage.set(5);
            }
            5 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    options
                        .views
                        .iter()
                        .filter_map(|v| v.upgrade())
                        .all(|v| v.is_mapped() && v.width() > 30)
                );
                unchanged(&first, text);
                unchanged(&peer, text);
                let before = options.profile_generation.get();
                first.buffer.set_language(None);
                let plain_generation = options.profile_generation.get();
                assert_ne!(before, plain_generation);
                first.buffer.set_language(
                    sourceview5::LanguageManager::default()
                        .language("rust")
                        .as_ref(),
                );
                assert!(!options.finish_profile(
                    before,
                    Ok(profile::Patch {
                        tab: Some(16),
                        indent: Some(16),
                        spaces: Some(true),
                        wrap: Some(false),
                        ..Default::default()
                    })
                ));
                // Der fremde aktive Tab darf durch die ausstehende Antwort keine Werte erhalten.
                ui.add_document("unrelated.txt", "other🙂\r\n");
                *third.borrow_mut() = ui.active();
                pause.set(Instant::now());
                stage.set(6);
            }
            6 => {
                if pause.get().elapsed() < Duration::from_millis(350) {
                    return glib::ControlFlow::Continue;
                }
                assert!(values(&options, 2, 8, false, true));
                assert!(values(
                    &state(third.borrow().as_ref().unwrap()),
                    4,
                    4,
                    true,
                    true
                ));
                peer_options.show();
                stage.set(60);
            }
            60 => {
                let window = peer_options
                    .window
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .upgrade()
                    .unwrap();
                let mut widgets = Vec::new();
                spins(window.upcast_ref(), &mut widgets);
                if !window.is_mapped()
                    || widgets
                        .iter()
                        .any(|w| !w.is_mapped() || w.width() <= 0 || w.height() <= 0)
                {
                    return glib::ControlFlow::Continue;
                }
                spin(&peer_options, 0, "8");
                stage.set(7);
            }
            7 => {
                if !values(&options, 8, 8, false, true) || !values(&peer_options, 8, 8, false, true)
                {
                    return glib::ControlFlow::Continue;
                }
                // Zweites Fenster schreibt nur seine Feldänderung; Einrückung bleibt davon unabhängig.
                let index = ui
                    .documents
                    .borrow()
                    .iter()
                    .position(|d| Rc::ptr_eq(d, &first))
                    .unwrap();
                ui.tabs.set_current_page(Some(index as u32));
                options
                    .window
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .upgrade()
                    .unwrap()
                    .present();
                let window = options.window.borrow().as_ref().unwrap().upgrade().unwrap();
                click(
                    &window,
                    &checkbox(
                        window.upcast_ref(),
                        ui.lang
                            .text("Mit Leerzeichen einrücken", "Indent with spaces"),
                    )
                    .unwrap(),
                    vec![],
                );
                stage.set(71);
            }
            71 => {
                if !values(&options, 8, 8, true, true) || !values(&peer_options, 8, 8, true, true) {
                    return glib::ControlFlow::Continue;
                }
                spin(&options, 1, "2");
                stage.set(8);
            }
            8 => {
                if !values(&options, 8, 2, true, true) || !values(&peer_options, 8, 2, true, true) {
                    return glib::ControlFlow::Continue;
                }
                if profile::get(&config_root().unwrap(), "rust").unwrap()
                    != (profile::Patch {
                        tab: Some(8),
                        indent: Some(2),
                        spaces: Some(true),
                        wrap: Some(true),
                    wrap_target: Some(super::soft_wrap::Target::Window),
                    wrap_column: Some(80),
                    wrap_indentation: Some(super::soft_wrap::Indentation::FirstLine),
                    })
                {
                    return glib::ControlFlow::Continue;
                }
                // Ein neuer Tab lädt den gespeicherten Stand und nicht eine alte Instanzkopie.
                ui.add_document("fresh.rs", text);
                *third.borrow_mut() = ui.active();
                pause.set(Instant::now());
                stage.set(9);
            }
            9 => {
                let fresh = third.borrow().as_ref().unwrap().clone();
                if !values(&state(&fresh), 8, 2, true, true) {
                    return glib::ControlFlow::Continue;
                }
                unchanged(&first, text);
                unchanged(&peer, text);
                unchanged(&fresh, text);
                let index = ui
                    .documents
                    .borrow()
                    .iter()
                    .position(|d| Rc::ptr_eq(d, &first))
                    .unwrap();
                ui.tabs.set_current_page(Some(index as u32));
                options
                    .window
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .upgrade()
                    .unwrap()
                    .present();
                pause.set(Instant::now());
                stage.set(10);
            }
            10 => {
                if pause.get().elapsed() < Duration::from_millis(350) {
                    return glib::ControlFlow::Continue;
                }
                let window = options.window.borrow().as_ref().unwrap().upgrade().unwrap();
                assert!(
                    first.buffer.can_redo(),
                    "profile preserves an existing redo action"
                );
                first.buffer.redo();
                assert_eq!(
                    super::super::buffer_text(&first.buffer),
                    format!("{text}temporary")
                );
                first.buffer.undo();
                unchanged(&first, text);
                window.set_default_size(if width <= 760 { 640 } else { 800 }, 660);
                pause.set(Instant::now());
                stage.set(11);
            }
            11 => {
                if pause.get().elapsed() < Duration::from_millis(350) {
                    return glib::ControlFlow::Continue;
                }
                let window = options.window.borrow().as_ref().unwrap().upgrade().unwrap();
                super::super::git_view::capture(&window, "editor-profiles-options");
                super::super::git_view::capture(ui.window.upcast_ref(), "editor-profiles-split");
                println!(
                    "FASTRA format profiles PASS: XTest independent2/8 and8/2, real two-window field merge/sync, delayed real-read reply preserves explicit edits, format ABA rejects stale reply, tab owner isolation, fresh-tab persistence, both mapped SourceViews, window wrap, unchanged bytes/dirty/undo"
                );
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

pub(super) fn readiness(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let first_path = root.join("delayed.rs");
    let second_path = root.join("explicit.rs");
    let text = "fn main() { println!(\"café 🙂\"); }\r\n";
    for path in [&first_path, &second_path] {
        std::fs::write(path, text).unwrap();
        store::set(&config_root().unwrap(), path, Some("markdown")).unwrap();
    }
    ui.load_path(first_path.clone());
    let stage = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    let first = RefCell::new(None::<Rc<Document>>);
    glib::timeout_add_local(Duration::from_millis(25), move || {
        assert!(
            start.elapsed() < Duration::from_secs(25),
            "profile readiness stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        let doc = ui.active().unwrap();
        let options = state(&doc);
        match stage.get() {
            0 => {
                if doc
                    .snapshot
                    .borrow()
                    .as_ref()
                    .is_none_or(|s| s.path() != first_path)
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(options.language_pending.get());
                options.show();
                pause.set(Instant::now());
                *first.borrow_mut() = Some(doc.clone());
                stage.set(1);
            }
            1 => {
                let window = options.window.borrow().as_ref().unwrap().upgrade().unwrap();
                let mut widgets = Vec::new();
                spins(window.upcast_ref(), &mut widgets);
                if !window.is_mapped() || widgets.iter().any(|w| w.width() <= 0 || w.height() <= 0)
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(options.language_pending.get());
                assert!(widgets.iter().take(2).all(|w| !w.is_sensitive()));
                assert!(
                    widgets.iter().find(|w|w.widget_name()=="fastra-page-guide-column").unwrap().is_sensitive(),
                    "app-wide guide is independent of the pending format key"
                );
                assert!(
                    options
                        .language_widget
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .0
                        .upgrade()
                        .unwrap()
                        .is_sensitive()
                );
                assert!(
                    !options
                        .spaces_widget
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .upgrade()
                        .unwrap()
                        .is_sensitive()
                );
                assert!(
                    !options
                        .wrap_widget
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .upgrade()
                        .unwrap()
                        .is_sensitive()
                );
                assert!(
                    options
                        .profile_status
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .upgrade()
                        .unwrap()
                        .is_visible()
                );
                super::super::git_view::capture(&window, "editor-profiles-loading");
                click(&window, &widgets[0], vec![]);
                pause.set(Instant::now());
                stage.set(2);
            }
            2 => {
                if pause.get().elapsed() < Duration::from_millis(100) {
                    return glib::ControlFlow::Continue;
                }
                assert!(options.language_pending.get());
                assert!(options.profile_key.borrow().is_empty());
                assert!(
                    options
                        .views
                        .iter()
                        .filter_map(|v| v.upgrade())
                        .all(|v| v.tab_width() == 4)
                );
                let file = config_root().unwrap().join("fastra-editor/profiles.json");
                assert!(
                    !file.exists()
                        || serde_json::from_slice::<serde_json::Value>(
                            &std::fs::read(&file).unwrap()
                        )
                        .unwrap()["formats"]
                            .get("rust")
                            .is_none(),
                    "disabled input cannot create an intermediate Rust profile"
                );
                unchanged(&doc, text);
                stage.set(3);
            }
            3 => {
                if options.language_pending.get()
                    || doc.buffer.language().as_ref().map(|l| l.id()).as_deref() != Some("markdown")
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(&*options.profile_key.borrow(), "markdown");
                assert!(
                    !options
                        .profile_status
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .upgrade()
                        .unwrap()
                        .is_visible()
                );
                pause.set(Instant::now());
                stage.set(31);
            }
            31 => {
                if pause.get().elapsed() < Duration::from_millis(180) {
                    return glib::ControlFlow::Continue;
                }
                spin(&options, 0, "2");
                stage.set(4);
            }
            4 => {
                if !values(&options, 2, 4, true, true) {
                    return glib::ControlFlow::Continue;
                }
                spin(&options, 1, "8");
                stage.set(5);
            }
            5 => {
                if !values(&options, 2, 8, true, true) {
                    return glib::ControlFlow::Continue;
                }
                if !config_root()
                    .unwrap()
                    .join("fastra-editor/profiles.json")
                    .exists()
                {
                    return glib::ControlFlow::Continue;
                }
                let value: serde_json::Value = serde_json::from_slice(
                    &std::fs::read(config_root().unwrap().join("fastra-editor/profiles.json"))
                        .unwrap(),
                )
                .unwrap();
                if value["formats"]["markdown"]["indent"] != 8 {
                    return glib::ControlFlow::Continue;
                }
                assert!(value["formats"].get("rust").is_none());
                assert_eq!(
                    store::get(&config_root().unwrap(), &first_path)
                        .unwrap()
                        .as_deref(),
                    Some("markdown")
                );
                unchanged(&doc, text);
                let window = options.window.borrow().as_ref().unwrap().upgrade().unwrap();
                window.close();
                ui.load_path(second_path.clone());
                stage.set(6);
            }
            6 => {
                if doc
                    .snapshot
                    .borrow()
                    .as_ref()
                    .is_none_or(|s| s.path() != second_path)
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(options.language_pending.get());
                options.show();
                pause.set(Instant::now());
                stage.set(7);
            }
            7 => {
                let window = options.window.borrow().as_ref().unwrap().upgrade().unwrap();
                let mut widgets = Vec::new();
                spins(window.upcast_ref(), &mut widgets);
                if !window.is_mapped() || widgets.iter().any(|w| w.width() <= 0 || w.height() <= 0)
                {
                    return glib::ControlFlow::Continue;
                }
                let (widget, choices) = options.language_widget.borrow().as_ref().unwrap().clone();
                let index = choices
                    .iter()
                    .position(|c| c.as_deref() == Some("rust"))
                    .unwrap();
                widget.upgrade().unwrap().set_selected(index as u32);
                assert!(!options.language_pending.get());
                assert_eq!(&*options.profile_key.borrow(), "rust");
                assert!(widgets[0].is_sensitive());
                pause.set(Instant::now());
                stage.set(71);
            }
            71 => {
                if pause.get().elapsed() < Duration::from_millis(180) {
                    return glib::ControlFlow::Continue;
                }
                spin(&options, 0, "2");
                stage.set(8);
            }
            8 => {
                if !values(&options, 2, 4, true, false) {
                    return glib::ControlFlow::Continue;
                }
                spin(&options, 1, "8");
                stage.set(9);
            }
            9 => {
                if !values(&options, 2, 8, true, false)
                    || pause.get().elapsed() < Duration::from_millis(1100)
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    doc.buffer.language().as_ref().map(|l| l.id()).as_deref(),
                    Some("rust")
                );
                assert_eq!(
                    store::get(&config_root().unwrap(), &second_path)
                        .unwrap()
                        .as_deref(),
                    Some("rust")
                );
                assert_eq!(
                    store::get(&config_root().unwrap(), &first_path)
                        .unwrap()
                        .as_deref(),
                    Some("markdown")
                );
                unchanged(&doc, text);
                unchanged(first.borrow().as_ref().unwrap(), text);
                println!(
                    "FASTRA profile readiness PASS: actual delayed language read, disabled native width click cannot create provisional Rust profile, stored Markdown retained and2/8 applies to Markdown, explicit syntax choice remains enabled and invalidates old Markdown reply, post-choice2/8 Rust persists, bytes/dirty/undo unchanged"
                );
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
