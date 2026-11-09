use super::*;
use std::{
    os::unix::ffi::OsStringExt,
    time::{Duration, Instant},
};

fn text(view: &gtk::TextView) -> String {
    let b = view.buffer();
    b.text(&b.start_iter(), &b.end_iter(), true).to_string()
}
pub(super) fn click(widget: &impl IsA<gtk::Widget>, keys: &[&str]) {
    support::test_click(widget, keys);
}

fn button(widget: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(b) = widget.downcast_ref::<gtk::Button>() {
        if b.label().as_deref() == Some(label) {
            return Some(b.clone());
        }
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
fn dialog_button(label: &str) -> Option<gtk::Button> {
    gtk::Window::list_toplevels()
        .iter()
        .find_map(|w| button(w, label))
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join(std::ffi::OsString::from_vec(b"hex-\xff.bin".to_vec()));
    let original: Vec<u8> = (0..8195).map(|n| (n % 256) as u8).collect();
    std::fs::write(&path, &original).unwrap();
    ui.load_path(path.clone());
    let state: RefCell<Option<Rc<Editor>>> = RefCell::new(None);
    let stage = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(65),
            "hex stage {}: {}",
            stage.get(),
            state.borrow().as_ref().map_or_else(
                || ui.status.text().to_string(),
                |s| s.status.text().to_string()
            )
        );
        if stage.get() == 0 {
            let doc = ui.active().unwrap();
            let Some(view) = doc.section_view.borrow().clone() else {
                return glib::ControlFlow::Continue;
            };
            if view.source().path() != path {
                return glib::ControlFlow::Continue;
            }
            let editor = open(&ui, &doc, view.source());
            editor.window.set_default_size(
                std::env::var("FASTRA_TOOL_WIDTH")
                    .unwrap_or_else(|_| "760".into())
                    .parse()
                    .unwrap(),
                950,
            );
            editor.cancel_button.emit_clicked();
            assert!(!editor.busy.get());
            *state.borrow_mut() = Some(editor);
            pause.set(Instant::now());
            stage.set(1);
            return glib::ControlFlow::Continue;
        }
        let s = state.borrow().as_ref().unwrap().clone();
        match stage.get() {
            1 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.session.borrow().is_none());
                assert!(!s.row.is_sensitive());
                assert!(!s.navigation.is_sensitive());
                s.row.set_text("AA");
                assert!(prevent_close(&ui));
                s.row.set_text("");
                s.load(false);
                stage.set(2);
            }
            2 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(s.session.borrow().as_ref().unwrap().source(), original);
                s.row.set_text("GG");
                s.row_commands[0].emit_clicked();
                assert!(!s.session.borrow().as_ref().unwrap().dirty());
                assert!(s.dirty());
                assert!(!s.can_print());
                assert!(prevent_close(&ui));
                s.navigate(4096);
                assert_eq!(s.row_offset.get(), 0);
                s.row_commands[1].emit_clicked();
                assert!(!s.dirty());
                pause.set(Instant::now());
                stage.set(3);
            }
            3 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                click(
                    &s.row,
                    &["ctrl+Home", "shift+Right", "shift+Right", "F", "F"],
                );
                stage.set(4);
            }
            4 => {
                if !s.row.text().starts_with("FF ") {
                    return glib::ControlFlow::Continue;
                }
                click(&s.row_commands[0], &[]);
                stage.set(5);
            }
            5 => {
                if !s.session.borrow().as_ref().unwrap().dirty() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&path).unwrap(), original);
                assert!(s.can_print());
                let doc = s.doc.upgrade().unwrap();
                let count = ui.documents.borrow().len();
                super::super::tab_close::request(&ui, &doc);
                assert_eq!(ui.documents.borrow().len(), count);
                assert!(s.dirty() && !doc.close_pending.get());
                let other = ui
                    .documents
                    .borrow()
                    .iter()
                    .find(|d| !Rc::ptr_eq(d, &doc))
                    .unwrap()
                    .clone();
                assert!(
                    !prevent_document_close(&ui, &other),
                    "Another document's hex draft does not block this tab"
                );
                s.undo.emit_clicked();
                assert!(!s.dirty());
                s.redo.emit_clicked();
                assert!(s.dirty());
                s.navigate(8192);
                assert_eq!(s.row.text().as_str(), "00 01 02");
                s.row.set_text("00 01 AA");
                s.row_commands[0].emit_clicked();
                assert_eq!(s.session.borrow().as_ref().unwrap().changes().len(), 2);
                s.navigate(0);
                s.prepare.emit_clicked();
                stage.set(6);
            }
            6 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.pending.borrow().is_some());
                assert!(!s.consent.is_active());
                assert!(!s.save.is_sensitive());
                assert!(text(&s.preview).contains("000000000000     00 → FF"));
                assert!(text(&s.preview).contains("000000002002     02 → AA"));
                assert!(text(&s.preview).contains("hex-\\xff.bin"));
                assert_eq!(std::fs::read(&path).unwrap(), original);
                let doc = s.doc.upgrade().unwrap();
                if doc
                    .section_view
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .print_text()
                    .is_none()
                {
                    return glib::ControlFlow::Continue;
                }
                let (printed, _, hex) = doc
                    .section_view
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .print_text()
                    .unwrap();
                assert!(hex);
                assert!(printed.contains("FF 01 02"));
                pause.set(Instant::now());
                stage.set(7);
            }
            7 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                support::capture(&s.window, "hex-complete-preview");
                let mut external = original.clone();
                external[123] = 77;
                std::fs::write(&path, &external).unwrap();
                s.consent.set_active(true);
                s.save.emit_clicked();
                stage.set(8);
            }
            8 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.dirty());
                assert!(!s.consent.is_active());
                assert_eq!(std::fs::read(&path).unwrap()[123], 77);
                assert_eq!(std::fs::read(&path).unwrap()[0], 0);
                assert!(s.recovery.borrow().is_none());
                s.window.close();
                assert!(!s.window.is_visible());
                assert!(s.dirty());
                let doc = s.doc.upgrade().unwrap();
                open(&ui, &doc, s.initial.clone());
                assert!(s.window.is_visible());
                assert!(s.dirty());
                s.discard_reload();
                pause.set(Instant::now());
                stage.set(80);
            }
            80 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let Some(b) = dialog_button(ui.lang.text("Behalten", "Keep")) else {
                    return glib::ControlFlow::Continue;
                };
                click(&b, &[]);
                pause.set(Instant::now());
                stage.set(81);
            }
            81 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.dirty());
                assert!(!s.busy.get());
                s.discard_reload();
                pause.set(Instant::now());
                stage.set(82);
            }
            82 => {
                if pause.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                let Some(b) = dialog_button(
                    ui.lang
                        .text("Verwerfen und neu laden", "Discard and reload"),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                click(&b, &[]);
                stage.set(83);
            }
            83 => {
                if s.dirty() || s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                stage.set(9);
            }
            9 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.dirty());
                assert!(!s.session.borrow().as_ref().unwrap().can_undo());
                s.row
                    .set_text("EE 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F");
                s.row_commands[0].emit_clicked();
                s.prepare.emit_clicked();
                stage.set(10);
            }
            10 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.pending.borrow().is_some());
                click(&s.consent, &[]);
                stage.set(11);
            }
            11 => {
                if !s.consent.is_active() {
                    return glib::ControlFlow::Continue;
                }
                click(&s.save, &[]);
                stage.set(12);
            }
            12 => {
                if !s.busy.get() && s.dirty() {
                    return glib::ControlFlow::Continue;
                }
                if s.busy.get() {
                    assert!(prevent_close(&ui));
                    return glib::ControlFlow::Continue;
                }
                let mut expected = original.clone();
                expected[123] = 77;
                expected[0] = 0xEE;
                assert_eq!(std::fs::read(&path).unwrap(), expected);
                assert_eq!(s.session.borrow().as_ref().unwrap().source(), expected);
                assert!(!s.session.borrow().as_ref().unwrap().can_undo());
                assert!(s.pending.borrow().is_none());
                assert!(!s.consent.is_active());
                assert!(!prevent_close(&ui));
                pause.set(Instant::now());
                stage.set(13);
            }
            13 => {
                if pause.get().elapsed() < Duration::from_millis(400) {
                    return glib::ControlFlow::Continue;
                }
                support::capture(&s.window, "hex-saved-rebased");
                println!("FASTRA hex selftest PASS: native row/stage/consent/save, cancelled initial load, invalid input retained, close/print guards, fixed-length cross-page draft and Undo/Redo, complete raw-path preview, stale write rejected, hidden draft retained, atomic save and fresh baseline");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
