use super::*;
use std::{path::Path, time::Instant};
fn click(widget: &gtk::Widget, label: &str) {
    let mut all = Vec::new();
    widgets(widget, &mut all);
    all.into_iter()
        .filter_map(|w| w.downcast::<gtk::Button>().ok())
        .find(|b| b.label().as_deref() == Some(label))
        .unwrap_or_else(|| panic!("Button missing: {label}"))
        .emit_clicked();
}
fn project_path(ui: &Rc<Ui>, path: &Path) {
    let window = gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| w.title().as_deref() == Some(ui.lang.text("Projektdateien", "Project files")))
        .unwrap();
    let mut all = Vec::new();
    widgets(window.upcast_ref(), &mut all);
    all.into_iter()
        .filter_map(|w| w.downcast::<gtk::Entry>().ok())
        .find(|e| e.placeholder_text().is_none())
        .unwrap()
        .set_text(path.to_str().unwrap());
}
fn tools(ui: &Rc<Ui>) {
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
            .text("4D-Diagnosen (tool4d) …", "4D diagnostics (tool4d) …"),
    );
}
fn live_runtime_processes() -> usize {
    std::fs::read_dir("/proc")
        .unwrap()
        .filter_map(std::result::Result::ok)
        .filter(|e| {
            e.file_name()
                .to_str()
                .is_some_and(|s| s.bytes().all(|b| b.is_ascii_digit()))
        })
        .filter(|e| {
            std::fs::read(e.path().join("cmdline"))
                .ok()
                .is_some_and(|data| data.starts_with(b"/runtime/tool4d\0"))
        })
        .count()
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("XDG_STATE_HOME").unwrap())
        .join(format!("4d-lsp-{}", glib::uuid_string_random()));
    let methods = root.join("Project/Sources/Methods");
    std::fs::create_dir_all(&methods).unwrap();
    std::fs::write(root.join("Project/Test.4DProject"), "{}").unwrap();
    let database_methods = root.join("Project/Sources/DatabaseMethods");
    std::fs::create_dir_all(&database_methods).unwrap();
    for method in ["onStartup.4dm", "onExit.4dm"] {
        std::fs::write(
            database_methods.join(method),
            "LOG EVENT(Into system standard outputs;\"FASTRA_LSP_SOURCE_EXECUTION_FORBIDDEN\")\n",
        )
        .unwrap();
    }
    let source="// Grüße 🚀\r\n#DECLARE($name : Text; $count : Integer)->$result : Boolean\r\n$result:=True\r\n";
    let method = methods.join("Probe.4dm");
    std::fs::write(&method, source).unwrap();
    let caller = methods.join("Caller.4dm");
    let caller_source = "// Unicode 🚀\r\nvar $ok : Boolean\r\n$ok:=Probe(\"🚀\"; 1)\r\n";
    std::fs::write(&caller, caller_source).unwrap();
    let snapshot = fastra_io::Snapshot::read(&method, &Cancellation::default()).unwrap();
    let decoded = fastra_core::encoding::decode(source.as_bytes(), None).unwrap();
    ui.add_loaded_text("Probe.4dm", std::sync::Arc::new(decoded), snapshot);
    let doc = ui.active().unwrap();
    let page = ui.tabs.current_page();
    let invalid = source.replace("$result:=True", "$result:=");
    doc.buffer.set_text(&invalid);
    assert!(doc.buffer.is_modified());
    project_view::open(&ui);
    project_path(&ui, &root);
    let state = open_for(&ui, &doc);
    git_view::test_size(&state.window);
    let phase = Cell::new(0);
    let started = Instant::now();
    let paint = Cell::new(None::<Instant>);
    let held = RefCell::new(None::<gtk::Button>);
    let runtime = PathBuf::from(std::env::var_os("FASTRA_4D_RUNTIME_PATH").unwrap());
    let fake = PathBuf::from(std::env::var_os("FASTRA_4D_FAKE_PATH").unwrap());
    let good_source = source.to_owned();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(70),
            "LSP phase {} {}",
            phase.get(),
            state.status.text()
        );
        match phase.get() {
            0 => {
                tools(&ui);
                let extra = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| w != &state.window && w.title() == state.window.title())
                    .unwrap();
                extra.close();
                state.set_path(runtime.clone());
                phase.set(1);
            }
            1 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                state.diagnose.emit_clicked();
                phase.set(2);
            }
            2 => {
                if state.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    !state.diagnostics.borrow().is_empty(),
                    "{}",
                    state.status.text()
                );
                assert!(doc.buffer.is_modified());
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
                assert_eq!(doc.buffer.text(&a, &b, true), "$result:=");
                *held.borrow_mut() = Some(row);
                paint.set(Some(Instant::now()));
                phase.set(3);
            }
            3 => {
                if paint.get().unwrap().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                git_view::capture(&state.window, "4d-lsp-diagnostics");
                assert_eq!(std::fs::read_to_string(&method).unwrap(), good_source);
                assert_eq!(buffer_text(&doc.buffer), invalid);
                ui.add_document("foreign.4dm", "foreign");
                held.borrow().as_ref().unwrap().emit_clicked();
                assert!(ui.active().unwrap().buffer.selection_bounds().is_none());
                ui.tabs.set_current_page(page);
                assert!(state.diagnostics.borrow().is_empty());
                doc.buffer.set_text(&good_source);
                state.diagnose.emit_clicked();
                phase.set(4);
            }
            4 => {
                if state.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.index.borrow().is_some(), "{}", state.status.text());
                assert!(state.diagnostics.borrow().is_empty());
                assert!(state
                    .status
                    .text()
                    .contains(ui.lang.text("Vollständige", "Complete")));
                project_path(&ui, &root.join("missing"));
                phase.set(5);
            }
            5 => {
                if !state
                    .project
                    .borrow()
                    .as_ref()
                    .is_some_and(|b| !b.is_current())
                {
                    return glib::ControlFlow::Continue;
                }
                if state.index.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                held.borrow().as_ref().unwrap().emit_clicked();
                assert!(state
                    .status
                    .text()
                    .contains(ui.lang.text("geändert", "changed")));
                project_path(&ui, &root);
                phase.set(6);
            }
            6 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                state.set_path(fake.clone());
                state.diagnose.emit_clicked();
                phase.set(7);
            }
            7 => {
                assert!(state.running.get(), "{}", state.status.text());
                if live_runtime_processes() < 2 {
                    return glib::ControlFlow::Continue;
                }
                state.cancel_button.emit_clicked();
                phase.set(8);
            }
            8 => {
                if state.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(live_runtime_processes(), 0);
                assert!(state
                    .status
                    .text()
                    .contains(ui.lang.text("Abgebrochen", "Cancelled")));
                assert!(state.index.borrow().is_none());
                assert_eq!(buffer_text(&doc.buffer), good_source);
                assert_eq!(std::fs::read_to_string(&method).unwrap(), good_source);
                let snap = fastra_io::Snapshot::read(&caller, &Cancellation::default()).unwrap();
                let decoded =
                    fastra_core::encoding::decode(caller_source.as_bytes(), None).unwrap();
                ui.add_loaded_text("Caller.4dm", std::sync::Arc::new(decoded), snap);
                state.window.close();
                let caller_doc = ui.active().unwrap();
                let signature_state = open_for(&ui, &caller_doc);
                git_view::test_size(&signature_state.window);
                signature_state.set_path(runtime.clone());
                let cursor = caller_source.find("; 1").unwrap() + 2;
                let chars = caller_source[..cursor].chars().count();
                caller_doc
                    .buffer
                    .place_cursor(&caller_doc.buffer.iter_at_offset(chars as i32));
                signature_state.signature.emit_clicked();
                let begin = Instant::now();
                let ui = ui.clone();
                let method = method.clone();
                let caller = caller.clone();
                let good = good_source.clone();
                let root = root.clone();
                let paint = Cell::new(None::<Instant>);
                glib::timeout_add_local(Duration::from_millis(50), move || {
                    assert!(
                        begin.elapsed() < Duration::from_secs(25),
                        "{}",
                        signature_state.status.text()
                    );
                    if signature_state.running.get() {
                        return glib::ControlFlow::Continue;
                    }
                    assert!(
                        buffer_text(&signature_state.details.buffer()).contains("count : Integer"),
                        "{} {}",
                        signature_state.status.text(),
                        buffer_text(&signature_state.details.buffer())
                    );
                    if paint.get().is_none() {
                        paint.set(Some(Instant::now()));
                        return glib::ControlFlow::Continue;
                    }
                    if paint.get().unwrap().elapsed() < Duration::from_millis(250) {
                        return glib::ControlFlow::Continue;
                    }
                    git_view::capture(&signature_state.window, "4d-lsp-signature");
                    caller_doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
                    assert!(caller_doc.source_edits_locked());
                    signature_state.run(Operation::Diagnostics);
                    assert!(!signature_state.running.get());
                    ui.window.set_visible(false);
                    assert!(!signature_state.window.is_visible());
                    assert_eq!(live_runtime_processes(), 0);
                    assert_eq!(std::fs::read_to_string(&method).unwrap(), good);
                    assert_eq!(std::fs::read_to_string(&caller).unwrap(), caller_source);
                    std::fs::remove_dir_all(&root).unwrap();
                    println!("FASTRA_4D_RUNTIME_UI_OK real-loopback-isolation/readonly/unsaved-diagnostics/UTF16-CRLF-goto/foreign-tab/root-stale/signature/active-cancel-fork-cleanup/Rich/parent-hide/no-source-writes");
                    std::process::exit(0);
                });
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
