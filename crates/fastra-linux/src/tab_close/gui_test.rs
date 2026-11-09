use super::super::git_view;
use super::*;
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    time::{Instant,Duration},
};

fn button(widget: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(b) = widget
        .downcast_ref::<gtk::Button>()
        .filter(|b| b.label().as_deref() == Some(label))
    {
        return Some(b.clone());
    }
    let mut child = widget.first_child();
    while let Some(w) = child {
        if let Some(b) = button(&w, label) {
            return Some(b);
        }
        child = w.next_sibling();
    }
    None
}
fn dialog(label: &str) -> Option<gtk::Button> {
    gtk::Window::list_toplevels()
        .iter()
        .find_map(|w| button(w, label))
}
fn close(ui: &Ui, doc: &Document) {
    let row = crate::chrome::tab_header(ui, doc);
    let close = row.last_child().unwrap().downcast::<gtk::Button>().unwrap();
    assert!(close.is_mapped());
    let bounds = row.compute_bounds(&ui.window).unwrap();
    assert!(bounds.y() >= 0. && bounds.y() + bounds.height() <= ui.window.height() as f32);
    let bounds = close.compute_bounds(&row).unwrap();
    assert!(
        bounds.width() >= 18. && bounds.height() >= 22.,
        "Reachable close control: {bounds:?}"
    );
    git_view::test_click(&close, &[]);
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("close-save.txt");
    std::fs::write(&path, "original\n").unwrap();
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or_else(|_| "760".into())
        .parse()
        .unwrap();
    ui.window.set_default_size(width, 950);
    let response = Rc::new(RefCell::new(None::<serde_json::Value>));
    let phase = Cell::new(0);
    let last_close_requested = Cell::new(false);
    let docs = RefCell::new(Vec::<Rc<Document>>::new());
    let started = Instant::now();
    let pause = Cell::new(started);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            started.elapsed() < Duration::from_secs(65),
            "tab close phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(400) {
            return glib::ControlFlow::Continue;
        }
        let cancel = ui.lang.text("Abbrechen", "Cancel");
        let discard = ui
            .lang
            .text("Ohne Speichern schließen", "Close without saving");
        let save = ui.lang.text("Speichern und schließen", "Save and close");
        match phase.get() {
            0 => {
                ui.add_document("A.txt", "original\n");
                let a = ui.active().unwrap();
                *a.snapshot.borrow_mut() = Some(
                    fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default())
                        .unwrap(),
                );
                ui.add_document("B.txt", "clean B");
                let b = ui.active().unwrap();
                ui.add_document("C.txt", "clean C");
                let c = ui.active().unwrap();
                *docs.borrow_mut() = vec![a, b, c];
            }
            1 => close(&ui, &docs.borrow()[1]),
            2 => {
                assert!(position(&ui, &docs.borrow()[1]).is_none(), "remaining={:?}", ui.documents.borrow().iter().map(|doc|doc.name.clone()).collect::<Vec<_>>());
                assert!(
                    Rc::ptr_eq(&ui.active().unwrap(), &docs.borrow()[2]),
                    "Closing inactive tab preserves active tab"
                );
                git_view::test_click(&ui.active().unwrap().container, &["ctrl+w"]);
            }
            3 => {
                if position(&ui, &docs.borrow()[2]).is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    Rc::ptr_eq(&ui.active().unwrap(), &docs.borrow()[0]),
                    "MRU fallback"
                );
                docs.borrow()[0].buffer.set_text("edited\n");
                git_view::test_click(&ui.active().unwrap().container, &["ctrl+w"]);
            }
            4 => {
                let Some(b) = dialog(cancel) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::capture(ui.window.upcast_ref(), "tab-close-dirty");
                git_view::capture(
                    &b.root().unwrap().downcast::<gtk::Window>().unwrap(),
                    "tab-close-dialog",
                );
                git_view::test_click(&b, &[]);
            }
            5 => {
                let a = docs.borrow()[0].clone();
                if a.close_pending.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(current(&ui, &a) && a.buffer.is_modified());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), "original\n");
                close(&ui, &a);
            }
            6 => {
                let Some(b) = dialog(discard) else {
                    return glib::ControlFlow::Continue;
                };
                docs.borrow()[0].buffer.set_text("later unsaved\n");
                git_view::test_click(&b, &[]);
            }
            7 => {
                let a = docs.borrow()[0].clone();
                if a.close_pending.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    current(&ui, &a) && a.buffer.is_modified(),
                    "Stale discard retains later input"
                );
                close(&ui, &a);
            }
            8 => {
                let Some(b) = dialog(save) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&b, &[]);
            }
            9 => {
                if position(&ui, &docs.borrow()[0]).is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&path).unwrap(), "later unsaved\n");
                assert_eq!(ui.documents.borrow().len(), 1);
                ui.add_document("save-failure.txt", "later unsaved\n");
                let a = ui.active().unwrap();
                *a.snapshot.borrow_mut() = Some(
                    fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default())
                        .unwrap(),
                );
                a.buffer.set_text("must remain in editor\n");
                std::fs::write(&path, "external change\n").unwrap();
                docs.borrow_mut().push(a);
            }
            10 => close(&ui, &docs.borrow()[3]),
            11 => {
                let Some(b) = dialog(save) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&b, &[]);
            }
            12 => {
                let a = docs.borrow()[3].clone();
                if a.close_pending.get() || a.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    current(&ui, &a) && a.buffer.is_modified(),
                    "Failed save retains dirty tab"
                );
                assert_eq!(std::fs::read_to_string(&path).unwrap(), "external change\n");
                git_view::capture(ui.window.upcast_ref(), "tab-close-save-failure");
                close(&ui, &a);
            }
            13 => {
                let Some(b) = dialog(discard) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&b, &[]);
            }
            14 => {
                if position(&ui, &docs.borrow()[3]).is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), 1);
                ui.active().unwrap().buffer.set_text("last tab unsaved");
            }
            15 => {
                if !last_close_requested.replace(true) { close(&ui, &ui.active().unwrap()); return glib::ControlFlow::Continue; }
                let Some(b) = dialog(cancel) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&b, &[]);
            }
            16 => {
                if ui.window_close_dialog.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.window.is_visible() && ui.active().unwrap().buffer.is_modified());
                close(&ui, &ui.active().unwrap());
            }
            17 => {
                let Some(b) = dialog(discard) else {
                    return glib::ControlFlow::Continue;
                };
                ui.active().unwrap().buffer.set_text("new last tab input");
                git_view::test_click(&b, &[]);
            }
            18 => {
                if ui.window_close_dialog.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.window.is_visible() && ui.active().unwrap().buffer.is_modified());
                assert_eq!(ui.documents.borrow().len(), 1);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), "external change\n");
                git_view::capture(ui.window.upcast_ref(), "tab-close-last-preserved");
                ui.add_document("rich-close.md", "# Heading\n\nAlpha\n");
                let doc = ui.active().unwrap();
                doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
                docs.borrow_mut().push(doc);
            }
            19 => {
                let Some(editor) = docs.borrow()[4].rich.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                let reply = response.clone();
                editor.evaluate("if(typeof fastraVisual==='undefined')return JSON.stringify(false); const p=document.querySelector('#fastra-visual p');const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('bold');return JSON.stringify(true);", move |value| *reply.borrow_mut() = value);
            }
            20 => {
                let Some(value) = response.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                if value != true {
                    phase.set(19);
                    return glib::ControlFlow::Continue;
                }
                let doc = docs.borrow()[4].clone();
                if !super::super::buffer_text(&doc.buffer).contains("**Alpha**") {
                    phase.set(19);
                    return glib::ControlFlow::Continue;
                }
                close(&ui, &doc);
            }
            21 => {
                let Some(b) = dialog(cancel) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&b, &[]);
            }
            22 => {
                let doc = docs.borrow()[4].clone();
                if doc.close_pending.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(current(&ui, &doc) && doc.buffer.is_modified() && doc.is_rich_active());
                git_view::capture(ui.window.upcast_ref(), "tab-close-rich-retained");
                close(&ui, &doc);
            }
            23 => {
                let Some(b) = dialog(discard) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&b, &[]);
            }
            24 => {
                if position(&ui, &docs.borrow()[4]).is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!docs.borrow()[4].is_rich_active());
                ui.add_document("saving-close.txt", "external change\n");
                let doc = ui.active().unwrap();
                *doc.snapshot.borrow_mut() = Some(
                    fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default())
                        .unwrap(),
                );
                doc.buffer.set_text("saving guard\n");
                ui.save_document_ready(doc.clone());
                assert!(doc.saving.get());
                request(&ui, &doc);
                assert!(
                    current(&ui, &doc) && !doc.close_pending.get(),
                    "Saving tab cannot close before receipt"
                );
                docs.borrow_mut().push(doc);
            }
            25 => {
                let doc = docs.borrow()[5].clone();
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!doc.buffer.is_modified());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), "saving guard\n");
                close(&ui, &doc);
            }
            26 => {
                if position(&ui, &docs.borrow()[5]).is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), 1);
                println!("FASTRA_TAB_CLOSE_SELFTEST=PASS inactive-x keyboard-mru cancel stale-tab save failure discard last-cancel stale-window rich-sync-cancel-discard saving-guard");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
