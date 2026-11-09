use super::*;
use std::time::{Duration, Instant};
pub(super) fn click(window: &gtk::Window, widget: &impl IsA<gtk::Widget>, keys: Vec<String>) {
    let widget = widget.as_ref();
    assert!(
        widget.is_mapped() && widget.width() > 0 && widget.height() > 0,
        "mapped native input target"
    );
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
    let surface = native.surface().unwrap();
    let scale = f64::from(surface.scale_factor());
    let id = unsafe { xid(surface.as_ptr().cast()) }.to_string();
    let title = window.title().unwrap().to_string();
    std::thread::spawn(move || {
        let mut command = std::process::Command::new("xdotool");
        command.args([
            "windowraise",
            &id,
            "windowfocus",
            "--sync",
            &id,
            "mousemove",
            "--window",
            &id,
            &((point.x() as f64 - x) * scale).round().to_string(),
            &((point.y() as f64 - y) * scale).round().to_string(),
            "click",
            "1",
        ]);
        if !keys.is_empty() {
            command.arg("key").args(keys);
        }
        assert!(command.status().unwrap().success(), "XTest {title}");
    });
}
pub(super) fn find<T: IsA<gtk::Widget> + glib::object::ObjectType>(
    root: &gtk::Widget,
) -> Option<T> {
    if let Ok(widget) = root.clone().dynamic_cast::<T>() {
        return Some(widget);
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        if let Some(result) = find(&widget) {
            return Some(result);
        }
        child = widget.next_sibling();
    }
    None
}
pub(super) fn spins(root: &gtk::Widget, found: &mut Vec<gtk::SpinButton>) {
    if let Some(spin) = root.downcast_ref::<gtk::SpinButton>() {
        found.push(spin.clone());
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        spins(&widget, found);
        child = widget.next_sibling();
    }
}
pub(super) fn checkbox(root: &gtk::Widget, label: &str) -> Option<gtk::CheckButton> {
    if let Some(button) = root.downcast_ref::<gtk::CheckButton>() {
        if button.label().as_deref() == Some(label) {
            return Some(button.clone());
        }
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        if let Some(result) = checkbox(&widget, label) {
            return Some(result);
        }
        child = widget.next_sibling();
    }
    None
}
thread_local! { static STARTED: Cell<bool> = const {Cell::new(false)}; }
pub(super) fn run(ui: Rc<Ui>) {
    if STARTED.with(|v| v.replace(true)) {
        return;
    }
    if std::env::var_os("FASTRA_PAGE_GUIDE_SELFTEST").is_some() {
        super::page_guide_gui_test::run(ui);
        return;
    }
    if std::env::var_os("FASTRA_OPTIONS_FOCUS_SELFTEST").is_some() {
        if std::env::var_os("FASTRA_OPTIONS_FOCUS_GUARDS_SELFTEST").is_some() {
            focus_guards(ui);
        } else {
            focus(ui);
        }
        return;
    }
    if std::env::var_os("FASTRA_PROFILE_READINESS_SELFTEST").is_some() {
        super::profile_gui_test::readiness(ui);
        return;
    }
    if std::env::var_os("FASTRA_PROFILE_SELFTEST").is_some() {
        super::profile_gui_test::run(ui);
        return;
    }

    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("source-no-extension");
    let text = "fn main() { println!(\"café 🙂\"); }\r\n";
    std::fs::write(&path, text).unwrap();
    ui.load_path(path.clone());
    let stage = Cell::new(
        if std::env::var_os("FASTRA_PROFILE_RESTART_SELFTEST").is_some() {
            100
        } else {
            0
        },
    );
    let start = Instant::now();
    let pause = Cell::new(start);
    let initial = ui.documents.borrow().len().saturating_sub(1);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(35),
            "options stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        let doc = ui.active().unwrap();
        match stage.get() {
            100 => {
                if doc
                    .snapshot
                    .borrow()
                    .as_ref()
                    .is_none_or(|s| s.path() != path)
                    || doc.buffer.language().as_ref().map(|l| l.id()).as_deref() != Some("rust")
                {
                    return glib::ControlFlow::Continue;
                }
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                if state
                    .views
                    .iter()
                    .filter_map(|v| v.upgrade())
                    .any(|v| v.indent_width() != 8)
                {
                    return glib::ControlFlow::Continue;
                }
                for view in state.views.iter().filter_map(|v| v.upgrade()) {
                    assert_eq!(view.tab_width(), 2);
                    assert!(!view.is_insert_spaces_instead_of_tabs());
                    assert!(view.shows_line_numbers());
                    assert!(view.is_auto_indent());
                }
                assert_eq!(super::super::buffer_text(&doc.buffer), text);
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                println!(
                    "FASTRA profile restart PASS: old language choice, independent tab2/indent8, spaces policy, local gutter/autoindent, unchanged bytes/undo"
                );
                std::process::exit(0);
            }
            0 => {
                if doc
                    .snapshot
                    .borrow()
                    .as_ref()
                    .is_none_or(|s| s.path() != path)
                {
                    return glib::ControlFlow::Continue;
                }
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                state.show();
                if let Ok(width) = std::env::var("FASTRA_TOOL_WIDTH")
                    .unwrap_or_default()
                    .parse::<i32>()
                {
                    state
                        .window
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .upgrade()
                        .unwrap()
                        .set_default_size(width, 550);
                }
                pause.set(Instant::now());
                stage.set(1);
            }
            1 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                let (widget, choices) = state.language_widget.borrow().as_ref().unwrap().clone();
                let index = choices
                    .iter()
                    .position(|c| c.as_deref() == Some("rust"))
                    .unwrap();
                widget.upgrade().unwrap().set_selected(index as u32);
                stage.set(2);
            }
            2 => {
                if doc.buffer.language().as_ref().map(|l| l.id()).as_deref() != Some("rust") {
                    return glib::ControlFlow::Continue;
                }
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                let button = checkbox(
                    window.upcast_ref(),
                    ui.lang.text("Zeilennummern", "Line numbers"),
                )
                .unwrap();
                click(&window, &button, vec![]);
                stage.set(3);
            }
            3 => {
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                if state.numbers.get() {
                    return glib::ControlFlow::Continue;
                }
                let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                let spin = find::<gtk::SpinButton>(window.upcast_ref()).unwrap();
                click(
                    &window,
                    &spin,
                    vec!["ctrl+a".into(), "2".into(), "Return".into()],
                );
                stage.set(30);
            }
            30 => {
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                if state
                    .views
                    .iter()
                    .filter_map(|v| v.upgrade())
                    .any(|v| v.tab_width() != 2)
                {
                    return glib::ControlFlow::Continue;
                }
                let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                let mut widgets = Vec::new();
                spins(window.upcast_ref(), &mut widgets);
                assert_eq!(widgets.len(), 3 + usize::from(super::soft_wrap::capable()));
                click(
                    &window,
                    &widgets[1],
                    vec!["ctrl+a".into(), "8".into(), "Return".into()],
                );
                stage.set(4);
            }
            4 => {
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                if state.writing.get()
                    || state
                        .views
                        .iter()
                        .filter_map(|v| v.upgrade())
                        .any(|v| v.tab_width() != 2 || v.indent_width() != 8)
                {
                    return glib::ControlFlow::Continue;
                }
                let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                let button = checkbox(
                    window.upcast_ref(),
                    ui.lang
                        .text("Mit Leerzeichen einrücken", "Indent with spaces"),
                )
                .unwrap();
                if button.is_active() {
                    click(&window, &button, vec![]);
                }
                pause.set(Instant::now());
                stage.set(5);
            }
            5 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                for view in state.views.iter().filter_map(|v| v.upgrade()) {
                    assert_eq!(view.tab_width(), 2);
                    assert!(!view.shows_line_numbers());
                    assert_eq!(view.indent_width(), 8);
                    assert!(!view.is_insert_spaces_instead_of_tabs());
                }
                assert_eq!(super::super::buffer_text(&doc.buffer), text);
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                super::super::git_view::capture(&window, "editor-options");
                window.close();
                ui.load_path(path.clone());
                stage.set(6);
            }
            6 => {
                if ui.documents.borrow().len() <= initial + 1
                    || doc.buffer.language().as_ref().map(|l| l.id()).as_deref() != Some("rust")
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(super::super::buffer_text(&doc.buffer), text);
                assert!(!doc.buffer.is_modified());
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                if state
                    .views
                    .iter()
                    .filter_map(|v| v.upgrade())
                    .any(|v| v.indent_width() != 8)
                {
                    return glib::ControlFlow::Continue;
                }
                for view in state.views.iter().filter_map(|v| v.upgrade()) {
                    assert_eq!(view.tab_width(), 2);
                    assert_eq!(view.indent_width(), 8);
                    assert!(!view.is_insert_spaces_instead_of_tabs());
                    assert!(view.shows_line_numbers());
                }
                store::set(
                    &config_root().unwrap(),
                    &path,
                    Some("missing-fastra-format"),
                )
                .unwrap();
                restore(&ui, &doc);
                stage.set(7);
            }
            7 => {
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                if state.choice.borrow().as_deref() != Some("missing-fastra-format") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!state.language_pending.get());
                assert!(
                    ui.status
                        .text()
                        .contains(ui.lang.text("nicht installiert", "not installed"))
                );
                state.show();
                assert!(
                    state.profile_spins.borrow()[0]
                        .0
                        .upgrade()
                        .unwrap()
                        .is_sensitive()
                );
                saved(&doc);
                stage.set(8);
            }
            8 => {
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                if state.writing.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    store::get(&config_root().unwrap(), &path)
                        .unwrap()
                        .as_deref(),
                    Some("missing-fastra-format")
                );
                let (widget, choices) = state.language_widget.borrow().as_ref().unwrap().clone();
                let widget = widget.upgrade().unwrap();
                assert_eq!(
                    choices[widget.selected() as usize].as_deref(),
                    Some("missing-fastra-format")
                );
                widget.set_selected(0);
                stage.set(9);
            }
            9 => {
                let state = doc.editor_options.borrow().as_ref().unwrap().clone();
                if state.writing.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(store::get(&config_root().unwrap(), &path).unwrap(), None);
                assert_eq!(super::super::buffer_text(&doc.buffer), text);
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                store::set(&config_root().unwrap(), &path, Some("rust")).unwrap();
                println!(
                    "FASTRA editor options selftest PASS: native syntax notification, XTest indentation, both views, private path persistence, missing format preserved and explicit Auto reset, unchanged bytes/undo"
                );
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

pub(super) fn named_button(root: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(button) = root.downcast_ref::<gtk::Button>() {
        if button.label().as_deref() == Some(label) {
            return Some(button.clone());
        }
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        if let Some(button) = named_button(&widget, label) {
            return Some(button);
        }
        child = widget.next_sibling();
    }
    None
}
fn focus(ui: Rc<Ui>) {
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap()
        .parse::<i32>()
        .unwrap();
    ui.window.set_default_size(width, 950);
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let text = "fn main() { café🙂 }\r\nsecond line\r\n";
    ui.add_document("focus.rs", text);
    let doc = ui.active().unwrap();
    let state = doc.editor_options.borrow().as_ref().unwrap().clone();
    let stage = Cell::new(0);
    let round = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            start.elapsed() < Duration::from_secs(30),
            "options focus stage={} round={} cursor={} selection={:?}",
            stage.get(),
            round.get(),
            doc.buffer.cursor_position(),
            doc.buffer
                .selection_bounds()
                .map(|(a, b)| (a.offset(), b.offset()))
        );
        match stage.get() {
            0 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                if round.get() == 1 {
                    ui.scope.set_selected(4);
                }
                state.views[0].upgrade().unwrap().grab_focus();
                let (head, anchor) = match round.get() {
                    0 => (2, 8),
                    1 => (8, 2),
                    _ => (6, 6),
                };
                doc.buffer.select_range(
                    &doc.buffer.iter_at_offset(head),
                    &doc.buffer.iter_at_offset(anchor),
                );
                // Hier Auswahl/Fokus prüfen; der sichtbare Menüweg besitzt eine eigene GUI-Probe.
                state.show();
                pause.set(Instant::now());
                stage.set(1);
            }
            1 => {
                let Some(window) = state.window.borrow().as_ref().and_then(|w| w.upgrade()) else {
                    return glib::ControlFlow::Continue;
                };
                if pause.get().elapsed() < Duration::from_millis(300) || !window.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state.dialog_selection.borrow().is_some(),
                    "snapshot captured before native input"
                );
                let spin = find::<gtk::SpinButton>(window.upcast_ref()).unwrap();
                click(
                    &window,
                    &spin,
                    vec!["ctrl+a".into(), "8".into(), "Return".into()],
                );
                stage.set(2);
            }
            2 => {
                if state.views[0].upgrade().unwrap().tab_width() != 8 {
                    return glib::ControlFlow::Continue;
                }
                let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                eprintln!(
                    "OPTIONS before close round={} active={} snapshot={} interaction={}",
                    round.get(),
                    window.is_active(),
                    state.dialog_selection.borrow().is_some(),
                    state.source_interaction.get()
                );
                let close =
                    named_button(window.upcast_ref(), ui.lang.text("Schließen", "Close")).unwrap();
                click(&window, &close, vec![]);
                pause.set(Instant::now());
                stage.set(3);
            }
            3 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let (head, anchor) = match round.get() {
                    0 => (2, 8),
                    1 => (8, 2),
                    _ => (6, 6),
                };
                assert_eq!(
                    doc.buffer.cursor_position(),
                    head,
                    "active caret side restored"
                );
                assert_eq!(
                    doc.buffer
                        .iter_at_mark(&doc.buffer.selection_bound())
                        .offset(),
                    anchor,
                    "anchor restored"
                );
                assert!(
                    state.views[0].upgrade().unwrap().has_focus(),
                    "source input focus restored"
                );
                assert_eq!(super::super::buffer_text(&doc.buffer), text);
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                eprintln!(
                    "OPTIONS focus round {} PASS head={head} anchor={anchor}",
                    round.get()
                );
                super::super::git_view::capture(
                    ui.window.upcast_ref(),
                    &format!("options-focus-round-{}", round.get()),
                );
                if round.get() == 2 {
                    super::super::git_view::capture(ui.window.upcast_ref(), "options-focus-source");
                    println!(
                        "FASTRA options focus GATE PASS native Spin/CtrlA/value8/Close, both selection directions2..8 and collapsed caret6, source focus, unchanged bytes/dirty/undo"
                    );
                    std::process::exit(0);
                }
                round.set(round.get() + 1);
                pause.set(Instant::now());
                stage.set(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

fn focus_guards(ui: Rc<Ui>) {
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap()
        .parse::<i32>()
        .unwrap();
    ui.window.set_default_size(width, 950);
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let text = "fn main() { café🙂 }\r\nsecond line\r\n";
    let doc = RefCell::new(None::<Rc<Document>>);
    let foreign = RefCell::new(None::<Rc<Ui>>);
    let replacement = RefCell::new(None::<Rc<Document>>);
    let round = Cell::new(0);
    let before_close=Cell::new((0,0));
    let stage = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    let pane = Cell::new(0usize);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            start.elapsed() < Duration::from_secs(75),
            "focus guard round={} stage={}",
            round.get(),
            stage.get()
        );
        match stage.get() {
            0 => {
                ui.window.present();
                ui.add_document(&format!("guard-{}.rs", round.get()), text);
                *doc.borrow_mut() = ui.active();
                pane.set(if round.get() == 8 { 1 } else { 0 });
                pause.set(Instant::now());
                stage.set(1);
            }
            1 => {
                if pause.get().elapsed() < Duration::from_millis(200) {
                    return glib::ControlFlow::Continue;
                }
                let document = doc.borrow().as_ref().unwrap().clone();
                if round.get() == 8 {
                    let button = checkbox(
                        document.container.upcast_ref(),
                        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
                    )
                    .unwrap();
                    click(ui.window.upcast_ref(), &button, vec![]);
                    pause.set(Instant::now());
                    stage.set(11);
                } else {
                    stage.set(2);
                }
            }
            11 => {
                let document = doc.borrow().as_ref().unwrap().clone();
                let state = document.editor_options.borrow().as_ref().unwrap().clone();
                if pause.get().elapsed() < Duration::from_millis(200)
                    || !state.views[1].upgrade().unwrap().is_mapped()
                {
                    return glib::ControlFlow::Continue;
                }
                stage.set(2);
            }
            2 => {
                let document = doc.borrow().as_ref().unwrap().clone();
                let state = document.editor_options.borrow().as_ref().unwrap().clone();
                let view=state.views[pane.get()].upgrade().unwrap();view.grab_focus();
                let buffer=view.buffer();buffer.select_range(&buffer.iter_at_offset(2),&buffer.iter_at_offset(8));
                let button = named_button(
                    document.container.upcast_ref(),
                    ui.lang.text("Editoroptionen …", "Editor options …"),
                )
                .unwrap();
                click(ui.window.upcast_ref(), &button, vec![]);
                pause.set(Instant::now());
                stage.set(3);
            }
            3 => {
                let document = doc.borrow().as_ref().unwrap().clone();
                let state = document.editor_options.borrow().as_ref().unwrap().clone();
                let Some(window) = state.window.borrow().as_ref().and_then(|w| w.upgrade()) else {
                    return glib::ControlFlow::Continue;
                };
                if pause.get().elapsed() < Duration::from_millis(200) || !window.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.dialog_selection.borrow().is_some());
                assert_eq!(state.source_pane.get(), pane.get());
                let spin = find::<gtk::SpinButton>(window.upcast_ref()).unwrap();
                click(
                    &window,
                    &spin,
                    vec!["ctrl+a".into(), "8".into(), "Return".into()],
                );
                pause.set(Instant::now());
                stage.set(4);
            }
            4 => {
                let document = doc.borrow().as_ref().unwrap().clone();
                let state = document.editor_options.borrow().as_ref().unwrap().clone();
                if pause.get().elapsed() < Duration::from_millis(180)
                    || state.views[pane.get()].upgrade().unwrap().tab_width() != 8
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.dialog_selection.borrow().is_some());
                match round.get() {
                    0 => {
                        document.buffer.begin_user_action();
                        document
                            .buffer
                            .insert(&mut document.buffer.end_iter(), "changed");
                        document.buffer.end_user_action();
                        stage.set(5);
                    }
                    1 => {
                        document
                            .buffer
                            .place_cursor(&document.buffer.iter_at_offset(2));
                        assert!(state.dialog_selection.borrow().is_none());
                        stage.set(5);
                    }
                    2 | 3 => {
                        ui.add_document("other-tab.rs", "other");
                        let other = ui.active().unwrap();
                        other.buffer.place_cursor(&other.buffer.iter_at_offset(3));
                        *replacement.borrow_mut() = Some(other);
                        if round.get() == 3 {
                            let index = ui
                                .documents
                                .borrow()
                                .iter()
                                .position(|d| Rc::ptr_eq(d, &document))
                                .unwrap();
                            ui.tabs.set_current_page(Some(index as u32));
                        }
                        assert!(state.dialog_selection.borrow().is_none());
                        stage.set(5);
                    }
                    4 => {
                        let peer = super::super::build(&ui.window.application().unwrap());
                        peer.add_document("foreign.rs", "foreign");
                        peer.active()
                            .unwrap()
                            .buffer
                            .place_cursor(&peer.active().unwrap().buffer.iter_at_offset(4));
                        *foreign.borrow_mut() = Some(peer);
                        pause.set(Instant::now());
                        stage.set(40);
                    }
                    5 => {
                        let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                        window.close();
                        ui.add_document("replacement.rs", "new-document");
                        let new = ui.active().unwrap();
                        new.buffer.place_cursor(&new.buffer.iter_at_offset(3));
                        *replacement.borrow_mut() = Some(new);
                        pause.set(Instant::now());
                        stage.set(6);
                    }
                    6 => {
                        let other = sourceview5::Buffer::new(None);
                        other.set_text("different buffer");
                        super::super::source_panes::bind_view(&state.views[0].upgrade().unwrap(),&other);
                        super::super::source_panes::bind_view(&state.views[0].upgrade().unwrap(),&document.buffer);
                        assert!(
                            state.dialog_selection.borrow().is_none(),
                            "buffer ABA invalidates old context"
                        );
                        stage.set(5);
                    }
                    7 => {
                        ui.window.set_visible(false);
                        let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                        window.close();
                        pause.set(Instant::now());
                        stage.set(6);
                    }
                    8 => {
                        stage.set(5);
                    }
                    9 => {
                        let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                        // Native Ctrl+W removes the owner while its options remain a separate toplevel.
                        let source = state.views[0].upgrade().unwrap();
                        click(ui.window.upcast_ref(), &source, vec!["ctrl+w".into()]);
                        drop(window);
                        pause.set(Instant::now());
                        stage.set(42);
                    }
                    _ => unreachable!(),
                }
            }
            40 => {
                let peer = foreign.borrow().as_ref().unwrap().clone();
                let view = peer
                    .active()
                    .unwrap()
                    .editor_options
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .views[0]
                    .upgrade()
                    .unwrap();
                if pause.get().elapsed() < Duration::from_millis(150)
                    || !view.is_mapped()
                    || view.width() <= 0
                    || view.height() <= 0
                {
                    return glib::ControlFlow::Continue;
                }
                click(peer.window.upcast_ref(), &view, vec![]);
                pause.set(Instant::now());
                stage.set(41);
            }
            41 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let peer = foreign.borrow().as_ref().unwrap().clone();
                assert!(peer.window.is_active());
                let document = doc.borrow().as_ref().unwrap().clone();
                let state = document.editor_options.borrow().as_ref().unwrap().clone();
                assert!(state.dialog_selection.borrow().is_none());
                let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                assert!(!window.is_active());
                window.close();
                pause.set(Instant::now());
                stage.set(6);
            }
            42 => {
                let document = doc.borrow().as_ref().unwrap().clone();
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, &document))
                {
                    return glib::ControlFlow::Continue;
                }
                let other = ui.active().unwrap();
                other.buffer.place_cursor(&other.buffer.iter_at_offset(3));
                *replacement.borrow_mut() = Some(other);
                let state = document.editor_options.borrow().as_ref().unwrap().clone();
                let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                window.close();
                pause.set(Instant::now());
                stage.set(6);
            }
            5 => {
                let document = doc.borrow().as_ref().unwrap().clone();
                let state = document.editor_options.borrow().as_ref().unwrap().clone();
                let window = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
                before_close.set((document.buffer.cursor_position(),document.buffer.iter_at_mark(&document.buffer.selection_bound()).offset()));
                let button =
                    named_button(window.upcast_ref(), ui.lang.text("Schließen", "Close")).unwrap();
                click(&window, &button, vec![]);
                pause.set(Instant::now());
                stage.set(6);
            }
            6 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                let document = doc.borrow().as_ref().unwrap().clone();
                let state = document.editor_options.borrow().as_ref().unwrap().clone();
                assert!(state.window.borrow().is_none());
                if round.get()==8 {
                    let buffer=state.views[1].upgrade().unwrap().buffer();
                    assert_eq!(buffer.cursor_position(),2);
                    assert_eq!(buffer.iter_at_mark(&buffer.selection_bound()).offset(),8);
                    assert!(state.views[1].upgrade().unwrap().has_focus());
                } else {
                    assert!(state.dialog_selection.borrow().is_none(),"invalid context remains cancelled");
                    if matches!(round.get(),0|1){assert_eq!((document.buffer.cursor_position(),document.buffer.iter_at_mark(&document.buffer.selection_bound()).offset()),before_close.get(),"close must retain the actual post-invalidation native state");}
                }
                if round.get() == 0 {
                    assert_eq!(
                        super::super::buffer_text(&document.buffer),
                        format!("{text}changed")
                    );
                    assert!(document.buffer.can_undo());
                    document.buffer.undo();
                    assert_eq!(super::super::buffer_text(&document.buffer), text);
                } else {
                    assert_eq!(super::super::buffer_text(&document.buffer), text);
                    assert!(!document.buffer.is_modified());
                    assert!(!document.buffer.can_undo());
                }
                if matches!(round.get(), 2 | 5 | 9) {
                    let other = replacement.borrow().as_ref().unwrap().clone();
                    assert!(ui.active().is_some_and(|d| Rc::ptr_eq(&d, &other)));
                    assert_eq!(other.buffer.cursor_position(), 3);
                }
                if round.get() == 4 {
                    let peer = foreign.borrow().as_ref().unwrap().clone();
                    assert!(
                        peer.window.is_active(),
                        "late close cannot steal foreign window focus"
                    );
                    assert!(!ui.window.is_active());
                    peer.window.close();
                }
                if round.get() == 6 {
                    super::super::source_panes::bind_view(&state.views[0].upgrade().unwrap(),&document.buffer);
                }
                if round.get() == 7 {
                    assert!(
                        !ui.window.is_visible(),
                        "late close never resurrects hidden parent"
                    );
                }
                eprintln!("OPTIONS guard round {} PASS", round.get());
                if round.get() == 9 {
                    println!(
                        "FASTRA options focus GUARDS PASS actual Spin/CtrlA/Close, source edit/undo, same-head navigation, foreign tab and tabABA, other active window/late close, new document before idle callback, rebound buffer, hidden parent, second source pane, owner tab removal"
                    );
                    std::process::exit(0);
                }
                round.set(round.get() + 1);
                pause.set(Instant::now());
                stage.set(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
