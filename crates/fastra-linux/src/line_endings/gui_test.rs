use super::*;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
fn text_label(widget: &gtk::Widget, value: &str) -> Option<gtk::Widget> {
    if widget.is_mapped()
        && widget
            .downcast_ref::<gtk::Label>()
            .is_some_and(|label| label.text() == value)
    {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(found) = text_label(&widget, value) {
            return Some(found);
        }
        child = widget.next_sibling();
    }
    None
}
fn source_view(widget: &gtk::Widget) -> Option<sourceview5::View> {
    if let Some(view) = widget.downcast_ref::<sourceview5::View>() {
        return Some(view.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(view) = source_view(&widget) {
            return Some(view);
        }
        child = widget.next_sibling();
    }
    None
}
fn bytes(text: &str) -> Vec<u8> {
    [
        vec![0xff, 0xfe],
        text.encode_utf16().flat_map(u16::to_le_bytes).collect(),
    ]
    .concat()
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("line-ending-utf16.txt");
    let source = "é🙂\r\n二\rthree\nlast";
    let original = bytes(source);
    std::fs::write(&path, &original).unwrap();
    let snapshot = fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default()).unwrap();
    let decoded = std::sync::Arc::new(fastra_core::encoding::decode(&original, None).unwrap());
    crate::git_view::test_size(ui.window.upcast_ref());
    let doc = ui.add_loaded_text("line-ending-utf16.txt", decoded, snapshot);
    let choice = doc.line_endings.choice.upgrade().unwrap();
    let revision = doc.revision.get();
    let lf = LineEnding::Lf.convert(source);
    let crlf = LineEnding::CrLf.convert(source);
    let empty = std::cell::RefCell::new(None::<Rc<Document>>);
    let stage = Cell::new(0);
    let started = Instant::now();
    let changed = Cell::new(started);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "EOL native stage {} status={}",
            stage.get(),
            ui.status.text()
        );
        if changed.get().elapsed() < Duration::from_millis(350) {
            return glib::ControlFlow::Continue;
        }
        eprintln!("EOL native stage {}", stage.get());
        match stage.get() {
            0 => {
                assert_eq!(choice.selected(), 1);
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                crate::git_view::test_click(&choice, &[]);
            }
            1 => {
                let row = text_label(ui.window.upcast_ref(), "CR").unwrap();
                crate::git_view::test_click(&row, &[]);
            }
            2 => {
                assert_eq!(choice.selected(), 2);
                assert_eq!(doc.line_endings.pending(), Some(LineEnding::Cr));
                assert_eq!(buffer_text(&doc.buffer), source);
                assert_eq!(std::fs::read(&path).unwrap(), original);
                assert!(doc.buffer.is_modified());
                assert_eq!(doc.revision.get(), revision + 1);
                assert!(!doc.buffer.can_undo());
                crate::git_view::capture(ui.window.upcast_ref(), "line-ending-pending");
                choice.set_selected(1);
            }
            3 => {
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(doc.line_endings.pending().is_none());
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                doc.buffer.begin_user_action();
                doc.buffer.insert(&mut doc.buffer.end_iter(), "temporary");
                doc.buffer.end_user_action();
                choice.set_selected(0);
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), source);
                assert_eq!(doc.line_endings.pending(), Some(LineEnding::Lf));
                assert!(
                    doc.buffer.is_modified(),
                    "pending EOL choice must remain dirty after text Undo reaches old saved text"
                );
                assert!(!doc.buffer.can_undo());
                assert!(source_view(doc.container.upcast_ref())
                    .unwrap()
                    .grab_focus());
                doc.buffer
                    .select_range(&doc.buffer.iter_at_offset(8), &doc.buffer.iter_at_offset(2));
                crate::git_view::test_keys(&source_view(doc.container.upcast_ref()).unwrap(), &["ctrl+s"]);
            }
            4 => {
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&path).unwrap(), bytes(&lf));
                assert_eq!(buffer_text(&doc.buffer), lf);
                assert!(doc.line_endings.pending().is_none());
                assert!(!doc.buffer.is_modified());
                assert_eq!(
                    doc.buffer.iter_at_mark(&doc.buffer.get_insert()).offset(),
                    7
                );
                assert_eq!(
                    doc.buffer
                        .iter_at_mark(&doc.buffer.selection_bound())
                        .offset(),
                    2
                );
                crate::git_view::test_keys(&source_view(doc.container.upcast_ref()).unwrap(), &["ctrl+z"]);
            }
            5 => {
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(doc.buffer.is_modified());
                assert_eq!(std::fs::read(&path).unwrap(), bytes(&lf));
                crate::git_view::test_keys(&source_view(doc.container.upcast_ref()).unwrap(), &["ctrl+shift+z"]);
            }
            6 => {
                assert_eq!(buffer_text(&doc.buffer), lf);
                assert!(!doc.buffer.is_modified());
                choice.set_selected(1);
                ui.save_document();
                doc.buffer.begin_user_action();
                doc.buffer.insert(&mut doc.buffer.end_iter(), "!");
                doc.buffer.end_user_action();
            }
            7 => {
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&path).unwrap(), bytes(&crlf));
                assert_eq!(buffer_text(&doc.buffer), format!("{lf}!"));
                assert_eq!(doc.line_endings.pending(), Some(LineEnding::CrLf));
                assert!(doc.buffer.is_modified());
                ui.save_document();
            }
            8 => {
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&path).unwrap(), bytes(&format!("{crlf}!")));
                assert_eq!(buffer_text(&doc.buffer), format!("{crlf}!"));
                assert!(doc.line_endings.pending().is_none());
                assert!(!doc.buffer.is_modified());
                std::fs::write(&path, b"foreign replacement").unwrap();
                choice.set_selected(2);
                ui.save_document();
            }
            9 => {
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&path).unwrap(), b"foreign replacement");
                assert_eq!(buffer_text(&doc.buffer), format!("{crlf}!"));
                assert_eq!(doc.line_endings.pending(), Some(LineEnding::Cr));
                assert!(doc.buffer.is_modified());
                ui.add_document("empty-eol.txt", "");
                let new = ui.active().unwrap();
                choose(&ui, &new, LineEnding::CrLf);
                ui.save_to(
                    new.clone(),
                    crate::SaveTarget::New(root.join("empty-eol.txt")),
                );
                *empty.borrow_mut() = Some(new);
            }
            10 => {
                let new = empty.borrow().clone().unwrap();
                if new.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(root.join("empty-eol.txt")).unwrap(), b"");
                assert_eq!(new.line_endings.current(), LineEnding::CrLf);
                assert!(new.line_endings.pending().is_none());
                assert!(!new.buffer.is_modified());
                choose(&ui, &new, LineEnding::Cr);
                assert!(new.buffer.is_modified());
                choose(&ui, &new, LineEnding::CrLf);
                assert!(!new.buffer.is_modified());
                assert_eq!(buffer_text(&new.buffer), "");
                assert!(!new.buffer.can_undo());
                new.buffer.place_cursor(&new.buffer.start_iter());
                ui.window.clipboard().set_text("A\nB");
                new.rectangles.borrow()[0].paste();
            }
            11 => {
                let new = empty.borrow().clone().unwrap();
                assert_eq!(buffer_text(&new.buffer), "A\r\nB", "column paste honors an explicit saved convention even in an originally empty document");
                new.buffer.undo();
                assert_eq!(buffer_text(&new.buffer), "");
                assert!(!new.buffer.is_modified());
                println!("PASS EOL native dropdown no immediate source/disk/Undo change; cancel-to-baseline; UTF16 BOM mixed-to-LF actual Save with mapped selection and one Undo/Redo; newer input retained with pending choice and retry; external conflict retains source/intent; saved empty document retains explicit convention");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        changed.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
