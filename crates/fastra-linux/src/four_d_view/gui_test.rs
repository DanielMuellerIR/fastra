use super::*;
use std::time::{Duration, Instant};
fn click(widget: &gtk::Widget, label: &str) {
    let mut all = Vec::new();
    widgets(widget, &mut all);
    let b = all
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Button>().ok())
        .find(|b| b.label().as_deref() == Some(label))
        .unwrap_or_else(|| panic!("Button missing: {label}"));
    b.emit_clicked();
}
fn project_window(ui: &Rc<Ui>) -> gtk::Window {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| w.title().as_deref() == Some(ui.lang.text("Projektdateien", "Project files")))
        .unwrap()
}
fn project_path(ui: &Rc<Ui>, path: &str) {
    let w = project_window(ui);
    let mut all = Vec::new();
    widgets(w.upcast_ref(), &mut all);
    all.into_iter()
        .filter_map(|w| w.downcast::<gtk::Entry>().ok())
        .find(|e| e.placeholder_text().is_none())
        .unwrap()
        .set_text(path);
}
fn color(buffer: &sourceview5::Buffer, byte: usize, source: &str) -> Option<gtk::gdk::RGBA> {
    let iter = buffer.iter_at_offset(source[..byte].chars().count() as i32);
    iter.tags().iter().find_map(|t| {
        if t.property::<bool>("foreground-set") {
            t.property::<Option<gtk::gdk::RGBA>>("foreground-rgba")
        } else {
            None
        }
    })
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = std::path::PathBuf::from(std::env::var_os("XDG_STATE_HOME").unwrap())
        .join(format!("4d-fixture-{}", glib::uuid_string_random()));
    let methods = root.join("Project/Sources/Methods");
    std::fs::create_dir_all(&methods).unwrap();
    std::fs::write(
        methods.join("Me\u{301}thode longue.4dm"),
        "// Grüße vom Test.\r\n#DECLARE($name : Text; $count : Integer)->$result : Boolean",
    )
    .unwrap();
    let source="// Function hidden()\r\n// Grüße 🙂\r\nFunction get Grüße($name : Text)\r\nIf ($name=\"x\")\r\nALERT(\"ok\")\r\nEnd if\r\nMéthode longue(\"a;b\"; ";
    ui.add_document("fixture.4dm", source);
    let doc = ui.active().unwrap();
    let page = ui.tabs.current_page();
    let initial_pages = ui.tabs.n_pages();
    assert_eq!(doc.buffer.language().unwrap().id(), "fastra-4d");
    doc.buffer
        .ensure_highlight(&doc.buffer.start_iter(), &doc.buffer.end_iter());
    assert!(color(&doc.buffer, source.find("// Grüße").unwrap(), source).is_some());
    assert!(color(&doc.buffer, source.find("Function get").unwrap(), source).is_some());
    assert!(color(&doc.buffer, source.find("ALERT").unwrap(), source).is_some());
    assert!(color(&doc.buffer, source.find("\"x\"").unwrap(), source).is_some());
    let corpus: Vec<String> =
        serde_json::from_str(include_str!("../../resources/four-d-symbols-test.json")).unwrap();
    assert_eq!(corpus.len(), 3576);
    let corpus_source = corpus.join("\n");
    let corpus_buffer = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
    corpus_buffer.set_text(&corpus_source);
    corpus_buffer.set_language(doc.buffer.language().as_ref());
    let highlight_start = Instant::now();
    corpus_buffer.ensure_highlight(&corpus_buffer.start_iter(), &corpus_buffer.end_iter());
    let mut offset = 0;
    for symbol in &corpus {
        let last = symbol.char_indices().next_back().unwrap().0;
        assert!(
            color(&corpus_buffer, offset + last, &corpus_source).is_some(),
            "Uncolored symbol: {symbol}"
        );
        offset += symbol.len() + 1;
    }
    println!(
        "4D_CORPUS_OK symbols={} elapsed_ms={}",
        corpus.len(),
        highlight_start.elapsed().as_millis()
    );
    project_view::open(&ui);
    project_path(&ui, root.to_str().unwrap());
    let state = open_for(&ui, &doc);
    if let Ok(width) = std::env::var("FASTRA_TOOL_WIDTH") {
        state.window.set_default_size(width.parse().unwrap(), 760);
    }
    let phase = Cell::new(0);
    let started = Instant::now();
    let held = RefCell::new(None::<gtk::Button>);
    let original = source.to_owned();
    let paint_wait = Cell::new(None::<Instant>);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(50),
            "4D phase {} {}",
            phase.get(),
            state.status.text()
        );
        if state.running.get() {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let mut all = Vec::new();
                widgets(ui.window.upcast_ref(), &mut all);
                let menu = all
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::MenuButton>().ok())
                    .find(|b| b.label().as_deref() == Some(ui.lang.text("Werkzeuge", "Tools")))
                    .unwrap();
                menu.popup();
                click(
                    menu.popover().unwrap().upcast_ref(),
                    ui.lang
                        .text("4D-Methoden und Parameter …", "4D methods and parameters …"),
                );
                let opened = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| w != &state.window && w.title() == state.window.title())
                    .unwrap();
                opened.close();
                let Some(analysis) = state.analysis.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(analysis.definitions.len(), 1);
                let row = state
                    .list
                    .row_at_index(0)
                    .unwrap()
                    .child()
                    .unwrap()
                    .downcast::<gtk::Button>()
                    .unwrap();
                row.emit_clicked();
                let (a, b) = doc.buffer.selection_bounds().unwrap();
                assert_eq!(doc.buffer.text(&a, &b, true), "Function get Grüße");
                *held.borrow_mut() = Some(row);
                ui.add_document("foreign.4dm", "Function foreign()");
                phase.set(1);
            }
            1 => {
                held.borrow().as_ref().unwrap().emit_clicked();
                assert!(ui.active().unwrap().buffer.selection_bounds().is_none());
                ui.tabs.set_current_page(page);
                doc.buffer.insert_at_cursor("x");
                held.borrow().as_ref().unwrap().emit_clicked();
                assert!(state
                    .status
                    .text()
                    .contains(ui.lang.text("geändert", "changed")));
                doc.buffer.set_text(&original);
                state.build(false);
                phase.set(2);
            }
            2 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                click(
                    state.window.upcast_ref(),
                    ui.lang
                        .text("Projektmethoden lesen", "Read project methods"),
                );
                phase.set(3);
            }
            3 => {
                assert_eq!(state.index.borrow().as_ref().unwrap().entries.len(), 1);
                state
                    .list
                    .row_at_index(0)
                    .unwrap()
                    .child()
                    .unwrap()
                    .downcast::<gtk::Button>()
                    .unwrap()
                    .emit_clicked();
                assert!(buffer_text(&state.details.buffer()).contains("$count : Integer"));
                doc.buffer.place_cursor(&doc.buffer.end_iter());
                click(
                    state.window.upcast_ref(),
                    ui.lang.text("Parameter am Cursor", "Parameters at cursor"),
                );
                phase.set(32);
            }
            32 => {
                assert!(buffer_text(&state.details.buffer()).contains("▶ $count"));
                paint_wait.set(Some(Instant::now()));
                phase.set(30);
            }
            30 => {
                if paint_wait.get().unwrap().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                git_view::capture(&state.window, "4d-parameters");
                let w = project_window(&ui);
                let mut all = Vec::new();
                widgets(w.upcast_ref(), &mut all);
                all.into_iter()
                    .filter_map(|w| w.downcast::<gtk::Entry>().ok())
                    .find(|e| e.placeholder_text().is_some())
                    .unwrap()
                    .set_text("none");
                assert!(state.project.borrow().as_ref().unwrap().is_current());
                project_path(&ui, root.join("other").to_str().unwrap());
                state.method(0, state.generation.get());
                assert!(state
                    .status
                    .text()
                    .contains(ui.lang.text("geändert", "changed")));
                project_path(&ui, root.to_str().unwrap());
                phase.set(4);
            }
            4 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                state.build(true);
                phase.set(5);
            }
            5 => {
                state
                    .list
                    .row_at_index(0)
                    .unwrap()
                    .child()
                    .unwrap()
                    .downcast::<gtk::Button>()
                    .unwrap()
                    .emit_clicked();
                std::fs::write(methods.join("Me\u{301}thode longue.4dm"), "changed").unwrap();
                state.open_method();
                phase.set(6);
            }
            6 => {
                assert!(state.status.text().contains("changed"));
                assert_eq!(ui.tabs.n_pages(), initial_pages + 1);
                std::fs::write(
                    methods.join("Me\u{301}thode longue.4dm"),
                    "// Fresh reopen\r\n#DECLARE($name : Text)",
                )
                .unwrap();
                state.build(true);
                phase.set(60);
            }
            60 => {
                state
                    .list
                    .row_at_index(0)
                    .unwrap()
                    .child()
                    .unwrap()
                    .downcast::<gtk::Button>()
                    .unwrap()
                    .emit_clicked();
                state.open_method();
                phase.set(61);
            }
            61 => {
                if ui.tabs.n_pages() < initial_pages + 2 {
                    return glib::ControlFlow::Continue;
                }
                let opened = ui.active().unwrap();
                assert_eq!(
                    buffer_text(&opened.buffer),
                    "// Fresh reopen\r\n#DECLARE($name : Text)"
                );
                assert_eq!(
                    opened.snapshot.borrow().as_ref().unwrap().path(),
                    methods.join("Me\u{301}thode longue.4dm")
                );
                ui.tabs.set_current_page(page);
                state.build(false);
                click(
                    state.window.upcast_ref(),
                    ui.lang.text("Abbrechen", "Cancel"),
                );
                phase.set(7);
            }
            7 => {
                assert!(state.analysis.borrow().is_none());
                assert!(state
                    .status
                    .text()
                    .contains(ui.lang.text("Abgebrochen", "Cancelled")));
                assert_eq!(buffer_text(&doc.buffer), original);
                state.build(false);
                phase.set(8);
            }
            8 => {
                doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
                assert!(doc.source_edits_locked());
                state.definition(0, state.generation.get());
                assert!(state
                    .status
                    .text()
                    .contains(ui.lang.text("geändert", "changed")));

                ui.window.set_visible(false);
                assert!(!state.window.is_visible());
                println!("4D_UI_OK language={} definitions offsets colors parameters project_filter root_stale source_stale cancellation owner_hide",if ui.lang.0{"de"}else{"en"});
                std::fs::remove_dir_all(&root).unwrap();
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
