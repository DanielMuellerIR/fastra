use super::*;
use std::{
    cell::RefCell,
    path::PathBuf,
    time::{Duration, Instant},
};
fn contains(widget: &gtk::Widget, text: &str) -> bool {
    if widget
        .downcast_ref::<gtk::Label>()
        .is_some_and(|label| label.text().contains(text))
    {
        return true;
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if contains(&widget, text) {
            return true;
        }
        child = widget.next_sibling();
    }
    false
}
fn modal(ui: &Ui, text: &str) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|object| object.downcast::<gtk::Window>().ok())
        .find(|window| {
            window.is_visible()
                && window.as_ptr() != ui.window.as_ptr().cast()
                && contains(window.upcast_ref(), text)
        })
}
fn label(widget: &gtk::Widget, text: &str) -> Option<gtk::Widget> {
    if widget.is_mapped()
        && widget
            .downcast_ref::<gtk::Label>()
            .is_some_and(|label| label.text() == text)
    {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(found) = label(&widget, text) {
            return Some(found);
        }
        child = widget.next_sibling();
    }
    None
}
pub(super) fn run(ui: Rc<Ui>) {
    if let Ok(scope) = std::env::var("FASTRA_EOL_CLOSE_SCOPE") {
        run_scope(ui, scope);
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let path = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join("noop-eol.md");
    std::fs::write(&path, b"").unwrap();
    let snapshot = fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default()).unwrap();
    let doc = ui.add_loaded_text(
        "noop-eol.md",
        std::sync::Arc::new(fastra_core::encoding::decode(b"", None).unwrap()),
        snapshot,
    );
    choose(&ui, &doc, LineEnding::CrLf);
    doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
    let editor = RefCell::new(None::<Rc<crate::rich_editor::RichEditor>>);
    let reply = Rc::new(RefCell::new(None::<serde_json::Value>));
    let stage = Cell::new(0);
    let start = Instant::now();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            start.elapsed() < Duration::from_secs(35),
            "noop close stage {} {}",
            stage.get(),
            ui.status.text()
        );
        match stage.get() {
            0 => {
                let Some(ed) = doc
                    .rich
                    .borrow()
                    .clone()
                    .filter(|ed| ed.ready_for_saved_source())
                else {
                    return glib::ControlFlow::Continue;
                };
                *editor.borrow_mut() = Some(ed);
                ui.add_document("second-eol.txt", "B");
                let second = ui.active().unwrap();
                second.buffer.insert(&mut second.buffer.end_iter(), "!");
                ui.window.close();
            }
            1 => {
                let Some(window) = modal(&ui, "noop-eol.md") else {
                    return glib::ControlFlow::Continue;
                };
                let save = label(
                    window.upcast_ref(),
                    ui.lang.text("Speichern und schließen", "Save and close"),
                )
                .unwrap();
                crate::git_view::test_click(&save, &[]);
            }
            2 => {
                if modal(&ui, "second-eol.txt").is_none() {
                    return glib::ControlFlow::Continue;
                }
                let answer = reply.clone();
                editor.borrow().as_ref().unwrap().evaluate("return JSON.stringify({editable:document.getElementById('fastra-visual').isContentEditable});",move|value|*answer.borrow_mut()=value);
            }
            3 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["editable"],false,"no-op EOL Save must not release the prepared Rich fence while another tab decision is pending");
                assert_eq!(std::fs::read(&path).unwrap(), b"");
                assert_eq!(doc.line_endings.current(), LineEnding::CrLf);
                assert!(doc.line_endings.pending().is_none());
                let window = modal(&ui, "second-eol.txt").unwrap();
                crate::git_view::test_click(
                    &label(window.upcast_ref(), ui.lang.text("Abbrechen", "Cancel")).unwrap(),
                    &[],
                );
            }
            4 => {
                if crate::close_protocol::active(&ui) {
                    return glib::ControlFlow::Continue;
                }
                let answer = reply.clone();
                editor.borrow().as_ref().unwrap().evaluate("return JSON.stringify({editable:document.getElementById('fastra-visual').isContentEditable});",move|value|*answer.borrow_mut()=value);
            }
            5 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    value["editable"], true,
                    "late Cancel releases exactly the retained current Rich view"
                );
                assert!(ui.window.is_visible());
                assert_eq!(ui.documents.borrow().len(), 3);
                assert_eq!(buffer_text(&ui.documents.borrow()[2].buffer), "B!");
                println!("PASS no-op Rich EOL Save retains prepared ticket fence through second-tab decision and releases after late Cancel; empty file and convention retained, every tab preserved");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        glib::ControlFlow::Continue
    });
}

fn run_scope(ui: Rc<Ui>, scope: String) {
    assert!(["single", "others", "window", "quit"].contains(&scope.as_str()));
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let rich = std::env::var_os("FASTRA_EOL_CLOSE_RICH").is_some();
    let path =
        PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join("closing-eol.md");
    let source = "# Closing\r\n\r\nsource café 🙂\r\n";
    let expected = LineEnding::Lf.convert(source);
    std::fs::write(&path, source).unwrap();
    ui.add_document("keep-eol.txt", "Keep");
    let keep = ui.active().unwrap();
    let snapshot = fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default()).unwrap();
    let doc = ui.add_loaded_text(
        "closing-eol.md",
        std::sync::Arc::new(fastra_core::encoding::decode(source.as_bytes(), None).unwrap()),
        snapshot,
    );
    choose(&ui, &doc, LineEnding::Lf);
    if rich {
        doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
    }
    crate::git_view::test_size(ui.window.upcast_ref());
    if scope == "window" || scope == "quit" {
        let doc = doc.clone();
        let path = path.clone();
        let expected = expected.clone();
        let scope = scope.clone();
        ui.window.application().unwrap().connect_shutdown(move |_|{
            assert_eq!(std::fs::read(&path).unwrap(),expected.as_bytes());
            assert_eq!(buffer_text(&doc.buffer),expected);
            assert!(!doc.buffer.is_modified());assert!(doc.line_endings.pending().is_none());
            println!("PASS EOL {scope} rich={rich}: application shutdown observes owned normalized source, no pending intent and exact file bytes");
        });
    }
    let stage = Cell::new(0);
    let start = Instant::now();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            start.elapsed() < Duration::from_secs(35),
            "EOL close {scope} stage {} {}",
            stage.get(),
            ui.status.text()
        );
        match stage.get() {
            0 => {
                if rich
                    && doc
                        .rich
                        .borrow()
                        .as_ref()
                        .is_none_or(|ed| !ed.ready_for_saved_source())
                {
                    return glib::ControlFlow::Continue;
                }
                match scope.as_str() {
                    "single" => {
                        let header = doc.label.parent().unwrap();
                        let x = header
                            .last_child()
                            .unwrap()
                            .downcast::<gtk::Button>()
                            .unwrap();
                        crate::git_view::test_click(&x, &[]);
                    }
                    "others" => crate::tab_close_others::request(&ui, &keep),
                    "window" => ui.window.close(),
                    "quit" => crate::application_lifecycle::request_quit(),
                    _ => unreachable!(),
                }
            }
            1 => {
                let Some(window) = modal(&ui, "closing-eol.md") else {
                    return glib::ControlFlow::Continue;
                };
                crate::git_view::test_click(
                    &label(
                        window.upcast_ref(),
                        ui.lang.text("Speichern und schließen", "Save and close"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            2 => {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|item| Rc::ptr_eq(item, &doc))
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&path).unwrap(), expected.as_bytes());
                assert_eq!(buffer_text(&doc.buffer), expected);
                assert!(!doc.buffer.is_modified());
                assert!(doc.line_endings.pending().is_none());
                assert!(ui.window.is_visible());
                assert!(ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|item| Rc::ptr_eq(item, &keep)));
                println!("PASS EOL {scope} rich={rich}: actual Save-and-close accepts only owned normalization revision, keep tab retained, source/file exact");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        glib::ControlFlow::Continue
    });
}
