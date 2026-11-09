use super::super::git_view as support;
use super::*;
use std::time::{Duration, Instant};
fn button(widget: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(b) = widget.downcast_ref::<gtk::Button>().filter(|b| {
        b.label()
            .is_some_and(|value| value.replace('_', "") == label)
    }) {
        return Some(b.clone());
    }
    let mut child = widget.first_child();
    while let Some(node) = child {
        if let Some(b) = button(&node, label) {
            return Some(b);
        }
        child = node.next_sibling();
    }
    None
}
fn dialog(label: &str) -> Option<gtk::Button> {
    gtk::Window::list_toplevels()
        .iter()
        .find_map(|w| button(w, label))
}
fn click(widget: &gtk::Widget, mouse: &str) {
    match mouse {
        "1" => support::test_click(widget, &[]),
        "3" => support::test_context_click(widget),
        _ => panic!("unsupported native test pointer button"),
    }
}
fn menu(ui: &Ui, keep: &Document) {
    let row = crate::chrome::tab_header(ui, keep);
    let mut child = row.first_child();
    while let Some(widget) = child {
        if widget.has_css_class("tab-select") {
            click(&widget, "3");
            return;
        }
        child = widget.next_sibling();
    }
    panic!("missing visible tab selection button");
}
fn others(ui: &Ui, keep: &Document) -> Option<gtk::Button> {
    let row = crate::chrome::tab_header(ui, keep);
    button(
        &row,
        ui.lang.text("Andere Tabs schließen", "Close other tabs"),
    )
    .filter(|b| b.is_mapped())
}
fn capture_popup(action: &gtk::Button, name: &str) -> bool {
    let native = action.native().unwrap();
    let widget = native.clone().dynamic_cast::<gtk::Widget>().unwrap();
    let paintable = gtk::WidgetPaintable::new(Some(&widget));
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(
        &snapshot,
        f64::from(widget.width()),
        f64::from(widget.height()),
    );
    let Some(node) = snapshot.to_node() else {
        widget.queue_draw();
        return false;
    };
    let texture = native.renderer().unwrap().render_texture(&node, None);
    let directory = std::path::PathBuf::from(std::env::var_os("FASTRA_TOOL_SCREENSHOTS").unwrap());
    std::fs::create_dir_all(&directory).unwrap();
    texture
        .save_to_png(directory.join(format!("{name}.png")))
        .unwrap();
    true
}
fn same(ui: &Ui, docs: &[Rc<Document>]) {
    let now = ui.documents.borrow();
    assert_eq!(now.len(), docs.len());
    assert!(now.iter().zip(docs).all(|(a, b)| Rc::ptr_eq(a, b)));
}
mod asset;
mod chooser;
mod folder;
mod hex;
mod rich;
mod safety;
pub(super) fn run(ui: Rc<Ui>) {
    let case = std::env::var("FASTRA_TAB_CLOSE_OTHERS_SELFTEST").unwrap();
    if case == "asset" {
        asset::run(ui);
        return;
    }
    if case.starts_with("chooser") {
        chooser::run(ui, case);
        return;
    }
    if case == "folder" {
        folder::run(ui);
        return;
    }
    if case.starts_with("rich") {
        rich::run(ui, case);
        return;
    }
    if case.starts_with("hex") {
        hex::run(ui, case);
        return;
    }
    if let Some(case) = std::env::var("FASTRA_TAB_CLOSE_OTHERS_SELFTEST")
        .ok()
        .and_then(|value| value.strip_prefix("safety-").map(str::to_owned))
    {
        safety::run(ui, case);
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("A.txt");
    std::fs::write(&path, "A original\n").unwrap();
    ui.add_document("A.txt", "A original\n");
    let a = ui.active().unwrap();
    *a.snapshot.borrow_mut() =
        Some(fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default()).unwrap());
    a.buffer.set_text("A dirty\n");
    a.buffer.set_modified(true);
    ui.add_document("B.txt", "B original\n");
    let b = ui.active().unwrap();
    b.buffer.set_text("B dirty\n");
    b.buffer.set_modified(true);
    ui.add_document("Keep.txt", "keep");
    let keep = ui.active().unwrap();
    ui.add_document("Previous.txt", "previous");
    let previous = ui.active().unwrap();
    let docs = ui.documents.borrow().clone();
    let states = docs
        .iter()
        .map(|doc| (doc.revision.get(), super::super::buffer_text(&doc.buffer)))
        .collect::<Vec<_>>();
    let stage = Cell::new(0);
    let logged = Cell::new(u32::MAX);
    let round = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or_else(|_| "760".into())
        .parse()
        .unwrap();
    ui.window.set_default_size(width, 900);
    glib::timeout_add_local(Duration::from_millis(70), move || {
        assert!(
            began.elapsed() < Duration::from_secs(80),
            "close others stage{}: {}",
            stage.get(),
            ui.status.text()
        );
        let cancel = ui.lang.text("Abbrechen", "Cancel");
        let discard = ui
            .lang
            .text("Ohne Speichern schließen", "Close without saving");
        let save = ui.lang.text("Speichern und schließen", "Save and close");
        if logged.replace(stage.get()) != stage.get() {
            eprintln!(
                "close others stage={} active={} status={}",
                stage.get(),
                ui.active().unwrap().label.text(),
                ui.status.text()
            );
        }
        match stage.get() {
            0 if pause.get().elapsed() > Duration::from_millis(500) => {
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                println!(
                    "layout requested={width} actual={}x{}",
                    ui.window.width(),
                    ui.window.height()
                );
                menu(&ui, &keep);
                stage.set(1);
            }
            1 => {
                if let Some(action) = others(&ui, &keep) {
                    assert!(
                        Rc::ptr_eq(&ui.active().unwrap(), &previous),
                        "inactive keep remains inactive on context menu"
                    );
                    if !support::try_capture(ui.window.upcast_ref(), "others-context") {
                        return glib::ControlFlow::Continue;
                    }
                    if !capture_popup(&action, "others-context-menu") {
                        return glib::ControlFlow::Continue;
                    }
                    click(action.upcast_ref(), "1");
                    stage.set(2);
                }
            }
            2 => {
                if let Some(action) = dialog(if round.get() == 0 { discard } else { save }) {
                    assert!(Rc::ptr_eq(&ui.active().unwrap(), &a));
                    same(&ui, &docs);
                    click(action.upcast_ref(), "1");
                    stage.set(3);
                }
            }
            3 => {
                if let Some(action) = dialog(if round.get() == 0 { cancel } else { save }) {
                    if !Rc::ptr_eq(&ui.active().unwrap(), &b) {
                        return glib::ControlFlow::Continue;
                    }
                    same(&ui, &docs);
                    if !support::try_capture(ui.window.upcast_ref(), "others-before-late-cancel") {
                        return glib::ControlFlow::Continue;
                    }
                    let window = action.root().unwrap().downcast::<gtk::Window>().unwrap();
                    if !support::try_capture(&window, "others-decision") {
                        return glib::ControlFlow::Continue;
                    }
                    click(action.upcast_ref(), "1");
                    stage.set(if round.get() == 0 { 4 } else { 5 });
                }
            }
            4 => {
                if !close_protocol::active(&ui) {
                    same(&ui, &docs);
                    assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                    assert_eq!(std::fs::read_to_string(&path).unwrap(), "A original\n");
                    assert!(docs.iter().zip(&states).all(|(doc, (revision, text))| doc
                        .revision
                        .get()
                        == *revision
                        && super::super::buffer_text(&doc.buffer) == *text));
                    round.set(1);
                    menu(&ui, &keep);
                    stage.set(1);
                }
            }
            5 => {
                let title = ui
                    .lang
                    .text("Neues Dokument speichern", "Save new document");
                let chooser = gtk::Window::list_toplevels()
                    .iter()
                    .filter_map(|w| w.clone().downcast::<gtk::Window>().ok())
                    .find(|w| w.is_visible() && w.title().as_deref() == Some(title));
                if let Some(chooser) = chooser {
                    if let Some(action) = button(chooser.upcast_ref(), cancel)
                        .or_else(|| button(chooser.upcast_ref(), "Cancel"))
                    {
                        same(&ui, &docs);
                        if !support::try_capture(&chooser, "others-save-as") {
                            return glib::ControlFlow::Continue;
                        }
                        click(action.upcast_ref(), "1");
                        stage.set(6);
                    }
                }
            }
            6 => {
                if !close_protocol::active(&ui) {
                    same(&ui, &docs);
                    assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                    assert_eq!(std::fs::read_to_string(&path).unwrap(), "A dirty\n");
                    assert!(!a.buffer.is_modified());
                    assert!(b.buffer.is_modified());
                    menu(&ui, &keep);
                    stage.set(7);
                }
            }
            7 => {
                if let Some(action) = others(&ui, &keep) {
                    click(action.upcast_ref(), "1");
                    stage.set(8);
                }
            }
            8 => {
                if let Some(action) = dialog(discard) {
                    assert!(Rc::ptr_eq(&ui.active().unwrap(), &b));
                    same(&ui, &docs);
                    click(action.upcast_ref(), "1");
                    stage.set(9);
                }
            }
            9 if !close_protocol::active(&ui) => {
                assert_eq!(ui.documents.borrow().len(), 1);
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &keep));
                assert!(ui.window.is_visible());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), "A dirty\n");
                assert_eq!(super::super::buffer_text(&keep.buffer), "keep");
                if !support::try_capture(ui.window.upcast_ref(), "others-kept") {
                    return glib::ControlFlow::Continue;
                }
                println!("PASS close others minimal: actual inactive-tab context action, all decisions before removal, late Cancel retains every tab and prior activation, earlier explicit Save retained after SaveAs Cancel, successful Discard closes only complete bound set and activates Keep");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
