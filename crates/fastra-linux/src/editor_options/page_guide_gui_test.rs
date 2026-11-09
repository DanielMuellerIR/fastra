use super::gui_test::{checkbox, click, find, named_button, spins};
use super::*;
use std::time::{Duration, Instant};
fn options(doc: &Document) -> Rc<Options> {
    doc.editor_options.borrow().as_ref().unwrap().clone()
}
fn window(state: &Options) -> gtk::Window {
    state.window.borrow().as_ref().unwrap().upgrade().unwrap()
}
fn field(state: &Options) -> gtk::SpinButton {
    let mut found = Vec::new();
    spins(window(state).upcast_ref(), &mut found);
    found.into_iter().find(|spin|spin.widget_name()=="fastra-page-guide-column").unwrap()
}
fn native_value(state: &Options, value: &str) {
    let mut keys = vec!["ctrl+a".to_owned()];
    keys.extend(value.chars().map(|c| c.to_string()));
    keys.push("Return".into());
    let text = find::<gtk::Text>(field(state).upcast_ref()).unwrap();
    click(&window(state), &text, keys);
}

fn matches(state: &Options, column: u32, visible: bool) -> bool {
    state
        .views
        .iter()
        .filter_map(|v| v.upgrade())
        .all(|v| v.right_margin_position() == column && v.shows_right_margin() == visible)
}
fn unchanged(doc: &Document, text: &str) {
    assert_eq!(super::super::buffer_text(&doc.buffer), text);
    assert!(!doc.buffer.is_modified());
    assert!(!doc.buffer.can_undo());
    assert!(doc.buffer.can_redo());
}
fn bottom(state: &Options) {
    let w = window(state);
    let scroll = find::<gtk::ScrolledWindow>(w.upcast_ref()).unwrap();
    let a = scroll.vadjustment();
    a.set_value((a.upper() - a.page_size()).max(0.));
}
fn capture_view(ui: &Ui, view: &sourceview5::View, name: &str) {
    let paintable = gtk::WidgetPaintable::new(Some(view));
    let snap = gtk::Snapshot::new();
    paintable.snapshot(&snap, f64::from(view.width()), f64::from(view.height()));
    let node = snap.to_node().unwrap();
    let texture = ui.window.renderer().unwrap().render_texture(&node, None);
    texture
        .save_to_png(
            PathBuf::from(std::env::var_os("FASTRA_TOOL_SCREENSHOTS").unwrap())
                .join(format!("{name}.png")),
        )
        .unwrap();
    let x = view
        .buffer_to_window_coords(
            gtk::TextWindowType::Widget,
            view.left_margin() + 20 * view.create_pango_layout(Some(" ")).pixel_size().0,
            0,
        )
        .0;
    eprintln!(
        "GUIDE_PIXELS {name} expected20={x} width={} height={}",
        view.width(),
        view.height()
    );
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap()
        .parse::<i32>()
        .unwrap();
    ui.window.set_default_size(width, 950);
    let text = "fn main() { println!(\"café 🙂 e\u{301}\"); }\r\n\tsecond line\r\n";
    ui.add_document("guide.rs", text);
    let doc = ui.active().unwrap();
    let state = options(&doc);
    doc.buffer.begin_user_action();
    doc.buffer.insert(&mut doc.buffer.end_iter(), "temporary");
    doc.buffer.end_user_action();
    doc.buffer.undo();
    let restart = std::env::var_os("FASTRA_GUIDE_RESTART_SELFTEST").is_some();
    let stage = Cell::new(0);
    let loading_observed = Cell::new(false);
    let start = Instant::now();
    let pause = Cell::new(start);
    let peer = RefCell::new(None::<Rc<Ui>>);
    let peer_doc = RefCell::new(None::<Rc<Document>>);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            start.elapsed() < Duration::from_secs(45),
            "guide stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        match stage.get() {
            0 => {
                if pause.get().elapsed() < Duration::from_millis(180) {
                    return glib::ControlFlow::Continue;
                }
                if restart {
                    if !matches(&state, 60, false) {
                        return glib::ControlFlow::Continue;
                    }
                    unchanged(&doc, text);
                    println!("FASTRA PAGE_GUIDE_RESTART PASS app-wide60/off, source/undo retained");
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
                click(
                    ui.window.upcast_ref(),
                    &checkbox(
                        doc.container.upcast_ref(),
                        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
                    )
                    .unwrap(),
                    vec![],
                );
                stage.set(1);
                pause.set(Instant::now());
            }
            1 => {
                if pause.get().elapsed() < Duration::from_millis(150)
                    || !state.views[1].upgrade().unwrap().is_mapped()
                {
                    return glib::ControlFlow::Continue;
                }
                state.views[1].upgrade().unwrap().grab_focus();
                let buffer=state.views[1].upgrade().unwrap().buffer();
                buffer.select_range(&buffer.iter_at_offset(2),&buffer.iter_at_offset(8));
                click(
                    ui.window.upcast_ref(),
                    &named_button(
                        doc.container.upcast_ref(),
                        ui.lang.text("Editoroptionen …", "Editor options …"),
                    )
                    .unwrap(),
                    vec![],
                );
                stage.set(2);
                pause.set(Instant::now());
            }
            2 => {
                let Some(w) = state.window.borrow().as_ref().and_then(|v| v.upgrade()) else {
                    return glib::ControlFlow::Continue;
                };
                if !w.is_mapped() || pause.get().elapsed() < Duration::from_millis(120) {
                    return glib::ControlFlow::Continue;
                }
                if !super::page_guide::ready() {
                    assert!(!field(&state).is_sensitive());
                    assert!(
                        !checkbox(
                            w.upcast_ref(),
                            ui.lang.text("Seitenlinie anzeigen", "Show page guide")
                        )
                        .unwrap()
                        .is_sensitive()
                    );
                    if !loading_observed.get() {
                        super::super::git_view::capture(&w, "page-guide-loading");
                    }
                    loading_observed.set(true);
                    return glib::ControlFlow::Continue;
                }
                if std::env::var_os("FASTRA_GUIDE_DELAY_SELFTEST").is_some() {
                    assert!(
                        loading_observed.get(),
                        "native initial Guide loading state observed"
                    );
                    assert!(matches(&state, 120, false));
                }
                bottom(&state);
                stage.set(3);
                pause.set(Instant::now());
            }
            3 => {
                if pause.get().elapsed() < Duration::from_millis(120) {
                    return glib::ControlFlow::Continue;
                }
                click(
                    &window(&state),
                    &checkbox(
                        window(&state).upcast_ref(),
                        ui.lang.text("Seitenlinie anzeigen", "Show page guide"),
                    )
                    .unwrap(),
                    vec![],
                );
                stage.set(4);
                pause.set(Instant::now());
            }
            4 => {
                if !state.views[0].upgrade().unwrap().shows_right_margin() {
                    return glib::ControlFlow::Continue;
                }
                native_value(&state, "20");
                stage.set(5);
                pause.set(Instant::now());
            }
            5 => {
                if !super::page_guide::ready()
                    || !matches(&state, 20, true)
                    || pause.get().elapsed() < Duration::from_millis(1000)
                    || profile::pending()
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state
                        .views
                        .iter()
                        .filter_map(|v| v.upgrade())
                        .all(|v| v.wrap_mode() == gtk::WrapMode::None)
                );
                super::super::git_view::capture(&window(&state), "page-guide-options");
                let close = named_button(
                    window(&state).upcast_ref(),
                    ui.lang.text("Schließen", "Close"),
                )
                .unwrap();
                click(&window(&state), &close, vec![]);
                stage.set(6);
                pause.set(Instant::now());
            }
            6 => {
                if pause.get().elapsed() < Duration::from_millis(150)
                    || state.window.borrow().is_some()
                {
                    return glib::ControlFlow::Continue;
                }
                let buffer=state.views[1].upgrade().unwrap().buffer();
                assert_eq!(buffer.cursor_position(),2);
                assert_eq!(buffer.iter_at_mark(&buffer.selection_bound()).offset(),8);
                assert!(state.views[1].upgrade().unwrap().has_focus());
                unchanged(&doc, text);
                for (i, v) in state.views.iter().enumerate() {
                    capture_view(&ui, &v.upgrade().unwrap(), &format!("page-guide-pane-{i}"));
                }
                super::super::git_view::capture(ui.window.upcast_ref(), "page-guide-source");
                ui.window
                    .set_default_size(if width < 1000 { 1280 } else { 760 }, 950);
                stage.set(7);
                pause.set(Instant::now());
            }
            7 => {
                if pause.get().elapsed() < Duration::from_millis(200) {
                    return glib::ControlFlow::Continue;
                }
                assert!(matches(&state, 20, true));
                unchanged(&doc, text);
                for (i, v) in state.views.iter().enumerate() {
                    capture_view(
                        &ui,
                        &v.upgrade().unwrap(),
                        &format!("page-guide-resize-pane-{i}"),
                    );
                }
                let other = super::super::build(&ui.window.application().unwrap());
                other.window.set_default_size(width, 950);
                other.add_document("peer.json", text);
                let d = other.active().unwrap();
                assert!(matches(&options(&d), 20, true));
                *peer_doc.borrow_mut() = Some(d);
                *peer.borrow_mut() = Some(other);
                stage.set(8);
                pause.set(Instant::now());
            }
            8 => {
                if pause.get().elapsed() < Duration::from_millis(180) {
                    return glib::ControlFlow::Continue;
                }
                let other = peer.borrow().as_ref().unwrap().clone();
                let d = peer_doc.borrow().as_ref().unwrap().clone();
                click(
                    other.window.upcast_ref(),
                    &named_button(
                        d.container.upcast_ref(),
                        other.lang.text("Editoroptionen …", "Editor options …"),
                    )
                    .unwrap(),
                    vec![],
                );
                stage.set(9);
                pause.set(Instant::now());
            }
            9 => {
                let d = peer_doc.borrow().as_ref().unwrap().clone();
                let s = options(&d);
                let Some(w) = s.window.borrow().as_ref().and_then(|v| v.upgrade()) else {
                    return glib::ControlFlow::Continue;
                };
                if !w.is_mapped() || pause.get().elapsed() < Duration::from_millis(150) {
                    return glib::ControlFlow::Continue;
                }
                bottom(&s);
                stage.set(10);
                pause.set(Instant::now());
            }
            10 => {
                if pause.get().elapsed() < Duration::from_millis(120) {
                    return glib::ControlFlow::Continue;
                }
                let s = options(peer_doc.borrow().as_ref().unwrap());
                super::super::git_view::capture(&window(&s), "page-guide-peer-before");
                let f = field(&s);
                eprintln!(
                    "GUIDE_PEER before field={} val={} point={:?} window={}x{}",
                    f.text(),
                    f.value(),
                    f.compute_point(&window(&s), &gtk::graphene::Point::new(0., 0.)),
                    window(&s).width(),
                    window(&s).height()
                );
                native_value(&s, "500");
                stage.set(11);
                pause.set(Instant::now());
            }
            11 => {
                if !matches(&state, 500, true) {
                    if pause.get().elapsed() > Duration::from_secs(5) {
                        let s = options(peer_doc.borrow().as_ref().unwrap());
                        let f = field(&s);
                        super::super::git_view::capture(&window(&s), "page-guide-peer-after");
                        panic!(
                            "peer field={} val={} updating={} focus={:?}",
                            f.text(),
                            f.value(),
                            s.updating.get(),
                            gtk::prelude::RootExt::focus(&window(&s))
                                .map(|w| w.type_().name().to_string())
                        );
                    }
                    return glib::ControlFlow::Continue;
                }
                let s = options(peer_doc.borrow().as_ref().unwrap());
                native_value(&s, "60");
                stage.set(12);
                pause.set(Instant::now());
            }
            12 => {
                if !matches(&state, 60, true) {
                    return glib::ControlFlow::Continue;
                }
                let s = options(peer_doc.borrow().as_ref().unwrap());
                click(
                    &window(&s),
                    &checkbox(
                        window(&s).upcast_ref(),
                        ui.lang.text("Seitenlinie anzeigen", "Show page guide"),
                    )
                    .unwrap(),
                    vec![],
                );
                stage.set(13);
                pause.set(Instant::now());
            }
            13 => {
                if !matches(&state, 60, false) || profile::pending() {
                    return glib::ControlFlow::Continue;
                }
                unchanged(&doc, text);
                assert!(
                    state
                        .views
                        .iter()
                        .filter_map(|v| v.upgrade())
                        .all(|v| v.wrap_mode() == gtk::WrapMode::None)
                );
                assert!(
                    options(peer_doc.borrow().as_ref().unwrap())
                        .views
                        .iter()
                        .filter_map(|v| v.upgrade())
                        .all(|v| v.wrap_mode() == gtk::WrapMode::WordChar)
                );
                let p = profile::get_guide(&config_root().unwrap()).unwrap();
                assert_eq!(p.column, Some(60));
                assert_eq!(p.visible, Some(false));
                state.change_profile(profile::Patch {
                    tab: Some(2),
                    indent: Some(8),
                    ..profile::Patch::default()
                });
                stage.set(14);
            }
            14 => {
                if profile::pending() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    profile::get_guide(&config_root().unwrap()).unwrap().column,
                    Some(60)
                );
                let old = doc.buffer.iter_at_mark(&doc.buffer.get_insert()).offset();
                let anchor = doc
                    .buffer
                    .iter_at_mark(&doc.buffer.selection_bound())
                    .offset();
                super::page_guide::apply(
                    &state,
                    super::page_guide::Patch {
                        column: Some(120),
                        visible: Some(true),
                    },
                );
                assert_eq!(
                    doc.buffer.iter_at_mark(&doc.buffer.get_insert()).offset(),
                    old
                );
                assert_eq!(
                    doc.buffer
                        .iter_at_mark(&doc.buffer.selection_bound())
                        .offset(),
                    anchor
                );
                unchanged(&doc, text);
                super::page_guide::apply(
                    &state,
                    super::page_guide::Patch {
                        column: Some(60),
                        visible: Some(false),
                    },
                );
                ui.add_document("fresh.md", text);
                assert!(matches(&options(&ui.active().unwrap()), 60, false));
                println!(
                    "FASTRA PAGE_GUIDE PASS native20/500/60, shared windows/panes, resize, own Source selection/caret focus, exact bytes/dirty/undo, fresh tab and fieldwise persistent merge"
                );
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
