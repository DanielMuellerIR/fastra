use super::*;
use std::time::Instant;
fn widgets<T: IsA<gtk::Widget> + glib::object::ObjectType>(root: &gtk::Widget) -> Vec<T> {
    let mut result = root
        .clone()
        .downcast::<T>()
        .ok()
        .into_iter()
        .collect::<Vec<_>>();
    for child in chrome::children(root) {
        result.extend(widgets::<T>(&child));
    }
    result
}
fn window(ui: &Ui) -> gtk::Window {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| {
            w.is_mapped()
                && w.title().as_deref()
                    == Some(ui.lang.text("Suchen & Ersetzen", "Search & Replace"))
        })
        .unwrap()
}
fn button(ui: &Ui, title: &str) -> gtk::Button {
    widgets::<gtk::Button>(window(ui).upcast_ref())
        .into_iter()
        .find(|b| b.is_mapped() && b.label().as_deref() == Some(title))
        .unwrap()
}
fn literal(ui: &Ui) -> gtk::CheckButton {
    widgets::<gtk::CheckButton>(window(ui).upcast_ref())
        .into_iter()
        .find(|b| {
            b.is_mapped() && b.label().as_deref() == Some(ui.lang.text("∗ wörtlich", "Literal ∗"))
        })
        .unwrap()
}
fn open_from_source(ui: &Ui, doc: &Document) {
    let target = source_panes::capture(doc).unwrap();
    target.view.grab_focus();
    git_view::test_keys(&target.view, &["ctrl+f"]);
    assert!(ui.window.is_visible());
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let source = "🙂cat\r\ncat cat\r\noutside cat";
    ui.add_document("selection-open.txt", source);
    let doc = ui.active().unwrap();
    ui.scope.set_selected(0);
    ui.mode.set_selected(1);
    ui.find.set_text("cat");
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 30,
            "selection entry phase{} scope{} find{}",
            phase.get(),
            ui.scope.selected(),
            ui.find.text()
        );
        if pause.get().elapsed() < Duration::from_millis(240) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let b = source_panes::buffer(&doc);
                b.select_range(&b.iter_at_offset(1), &b.iter_at_offset(13));
                open_from_source(&ui, &doc);
            }
            1 => {
                if !ui.approval.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.scope.selected(), 4);
                assert_eq!(range(&ui, &doc), Some((1, 13)));
                assert_eq!(
                    ui.pending
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .preview
                        .matches()
                        .len(),
                    3
                );
                let b = source_panes::buffer(&doc);
                b.select_range(&b.iter_at_offset(1), &b.iter_at_offset(4));
                open_from_source(&ui, &doc);
            }
            2 => {
                assert_eq!(range(&ui, &doc), Some((1, 13)));
                git_view::test_click(&button(&ui, ui.lang.text("Geöffnet", "Open")), &[]);
            }
            3 => {
                if ui.scope.selected() != 1 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(range(&ui, &doc), Some((1, 13)));
                git_view::test_click(&button(&ui, ui.lang.text("Datei", "File")), &[]);
            }
            4 => {
                if ui.scope.selected() != 4 || !ui.approval.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(range(&ui, &doc), Some((1, 13)));
                assert_eq!(
                    ui.pending
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .preview
                        .matches()
                        .len(),
                    3
                );
                window(&ui).close();
                ui.find.set_text("no-match");
                let b = source_panes::buffer(&doc);
                b.place_cursor(&b.end_iter());
                open_from_source(&ui, &doc);
            }
            5 => {
                if ui.scope.selected() != 0
                    || !ui
                        .pending
                        .borrow()
                        .as_ref()
                        .is_some_and(|p| p.preview.matches().is_empty())
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.search_selection.borrow().is_none());
                assert!(!ui.selection_control.upgrade().unwrap().is_sensitive());
                ui.find.set_text("*");
            }
            6 => {
                if !literal(&ui).is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&literal(&ui), &[]);
            }
            7 => {
                if !literal(&ui).is_active() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.mode.selected(), 0);
                ui.find.grab_focus();
                git_view::test_keys(&ui.find, &["ctrl+a", "c", "a", "t"]);
            }
            8 => {
                if ui.find.text() != "cat" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.mode.selected(), 1);
                assert!(!literal(&ui).is_sensitive() && !literal(&ui).is_active());
                ui.find.set_text("*");
            }
            9 => {
                assert_eq!(ui.mode.selected(), 1);
                assert!(!literal(&ui).is_active());
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                println!("PASS native search opening: real Ctrl+F captures multiline range, preserves a filled visible search, survives Open/File roundtrip, resets on a fresh empty selection, disabled empty selection control; literal-star reset persists after removing and re-adding star; source and Undo unchanged");
                window(&ui).close();
                git_view::finish(
                    ui.window.clone().upcast(),
                    ui.clone(),
                    "search-selection-entry",
                );
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
