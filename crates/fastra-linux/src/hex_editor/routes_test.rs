use super::*;
use std::time::{Duration, Instant};

fn button(root: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(b) = root.downcast_ref::<gtk::Button>() {
        if b.label().as_deref() == Some(label) {
            return Some(b.clone());
        }
    }
    let mut child = root.first_child();
    while let Some(w) = child {
        if let Some(b) = button(&w, label) {
            return Some(b);
        }
        child = w.next_sibling();
    }
    None
}
fn menu(root: &gtk::Widget, label: &str) -> Option<gtk::MenuButton> {
    if let Some(b) = root.downcast_ref::<gtk::MenuButton>() {
        if b.label().as_deref() == Some(label) {
            return Some(b.clone());
        }
    }
    let mut child = root.first_child();
    while let Some(w) = child {
        if let Some(b) = menu(&w, label) {
            return Some(b);
        }
        child = w.next_sibling();
    }
    None
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("latin1.txt");
    std::fs::write(&path, [0xC3, 0xA9, 13, 10]).unwrap();
    ui.load_path_as(path.clone(), Some(fastra_core::encoding::Encoding::Latin1));
    let owner = RefCell::<Option<Rc<Document>>>::new(None);
    let editor = RefCell::<Option<Rc<Editor>>>::new(None);
    let stage = Cell::new(0);
    let initial = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(40),
            "hex routing stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        match stage.get() {
            0 => {
                let doc = ui.active().unwrap();
                if doc
                    .snapshot
                    .borrow()
                    .as_ref()
                    .is_none_or(|s| s.path() != path)
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(crate::buffer_text(&doc.buffer), "Ã©\r\n");
                assert_eq!(
                    doc.format.borrow().encoding(),
                    fastra_core::encoding::Encoding::Latin1
                );
                *owner.borrow_mut() = Some(doc);
                initial.set(ui.documents.borrow().len());
                crate::hex_routes::open(&ui);
                ui.add_document("other", "retain this context");
                pause.set(Instant::now());
                stage.set(1);
            }
            1 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), initial.get() + 1);
                let doc = owner.borrow().as_ref().unwrap().clone();
                let page = ui
                    .documents
                    .borrow()
                    .iter()
                    .position(|d| Rc::ptr_eq(&doc, d))
                    .unwrap();
                ui.tabs.set_current_page(Some(page as u32));
                doc.buffer.insert(&mut doc.buffer.end_iter(), " unsaved");
                let tools =
                    menu(ui.window.upcast_ref(), ui.lang.text("Werkzeuge", "Tools")).unwrap();
                tools.popup();
                pause.set(Instant::now());
                stage.set(10);
            }
            10 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let tools =
                    menu(ui.window.upcast_ref(), ui.lang.text("Werkzeuge", "Tools")).unwrap();
                let button = button(
                    tools.popover().unwrap().upcast_ref(),
                    ui.lang.text(
                        "Dateibytes in neuem Hex-Tab …",
                        "Disk bytes in new hex tab …",
                    ),
                )
                .unwrap();
                super::gui_test::click(&button, &[]);
                stage.set(2);
            }
            2 => {
                let doc = ui.active().unwrap();
                let Some(view) = doc.section_view.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(ui.documents.borrow().len(), initial.get() + 2);
                assert_eq!(
                    crate::buffer_text(&owner.borrow().as_ref().unwrap().buffer),
                    "Ã©\r\n unsaved"
                );
                let state = open(&ui, &doc, view.source());
                state.window.set_default_size(
                    std::env::var("FASTRA_TOOL_WIDTH")
                        .unwrap_or_else(|_| "760".into())
                        .parse()
                        .unwrap(),
                    850,
                );
                *editor.borrow_mut() = Some(state);
                stage.set(3);
            }
            3 => {
                let s = editor.borrow().as_ref().unwrap().clone();
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(s.row.text().as_str(), "C3 A9 0D 0A");
                s.row.set_text("C2 A9 0D 0A");
                s.row_commands[0].emit_clicked();
                s.prepare.emit_clicked();
                stage.set(4);
            }
            4 => {
                let s = editor.borrow().as_ref().unwrap().clone();
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.pending.borrow().is_some());
                s.consent.set_active(true);
                s.save.emit_clicked();
                assert!(!s.busy.get());
                assert!(s.pending.borrow().is_some());
                assert!(s.dirty());
                assert_eq!(std::fs::read(&path).unwrap(), [0xC3, 0xA9, 13, 10]);
                let doc = owner.borrow().as_ref().unwrap().clone();
                doc.buffer.undo();
                assert_eq!(crate::buffer_text(&doc.buffer), "Ã©\r\n");
                assert!(!doc.buffer.is_modified());
                s.save.emit_clicked();
                stage.set(5);
            }
            5 => {
                let s = editor.borrow().as_ref().unwrap().clone();
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.dirty(), "{}", s.status.text());
                assert_eq!(std::fs::read(&path).unwrap(), [0xC2, 0xA9, 13, 10]);
                let doc = owner.borrow().as_ref().unwrap().clone();
                assert_eq!(crate::buffer_text(&doc.buffer), "Â©\r\n");
                assert_eq!(
                    doc.format.borrow().encoding(),
                    fastra_core::encoding::Encoding::Latin1
                );
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                assert_eq!(
                    doc.snapshot.borrow().as_ref().unwrap().bytes(),
                    [0xC2, 0xA9, 13, 10]
                );
                pause.set(Instant::now());
                stage.set(6);
            }
            6 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let s = editor.borrow().as_ref().unwrap().clone();
                support::capture(&s.window, "text-file-hex-rebased");
                s.window.close();
                ui.add_document("unsaved", "untouched 🙂");
                let count = ui.documents.borrow().len();
                crate::hex_routes::open(&ui);
                assert_eq!(ui.documents.borrow().len(), count);
                assert_eq!(
                    crate::buffer_text(&ui.active().unwrap().buffer),
                    "untouched 🙂"
                );
                println!("FASTRA hex routing selftest PASS: saved text via visible menu, original dirty source retained, foreign tab owner refused, dirty duplicate blocks save, explicit codec retained on clean refresh, new unsaved document refused");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
