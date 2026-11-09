use super::*;
mod footer;
mod guards;
use std::time::Instant;
fn widgets<T: IsA<gtk::Widget> + glib::object::ObjectType>(root: &gtk::Widget) -> Vec<T> {
    let mut found = root
        .clone()
        .downcast::<T>()
        .ok()
        .into_iter()
        .collect::<Vec<_>>();
    for child in chrome::children(root) {
        found.extend(widgets::<T>(&child));
    }
    found
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
fn replace(ui: &Ui) -> gtk::Button {
    widgets::<gtk::Button>(window(ui).upcast_ref())
        .into_iter()
        .find(|b| {
            b.is_mapped() && b.label().as_deref() == Some(ui.lang.text("Ersetzen", "Replace"))
        })
        .unwrap()
}
fn next(ui: &Ui) -> gtk::Button {
    widgets::<gtk::Button>(window(ui).upcast_ref())
        .into_iter()
        .find(|b| {
            b.is_mapped()
                && b.tooltip_text().as_deref()
                    == Some(ui.lang.text("Nächster Treffer", "Next match"))
        })
        .unwrap()
}
fn count(ui: &Ui, n: usize) -> bool {
    widgets::<gtk::Label>(window(ui).upcast_ref())
        .iter()
        .any(|label| label.text() == format!("{} ({n})", ui.lang.text("Treffer", "Matches")))
}
fn undo(doc: &Document) {
    let target = source_panes::capture(doc).unwrap();
    target.view.grab_focus();
    git_view::test_keys(&target.view, &["ctrl+z"]);
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    if std::env::var("FASTRA_SINGLE_REPLACE_SELFTEST").is_ok_and(|case| case.starts_with("footer"))
    {
        footer::run(ui);
        return;
    }
    if std::env::var("FASTRA_SINGLE_REPLACE_SELFTEST").is_ok_and(|case| case.starts_with("guards"))
    {
        guards::run(ui);
        return;
    }
    if std::env::var("FASTRA_SINGLE_REPLACE_SELFTEST").as_deref() == Ok("open") {
        open(ui);
        return;
    }
    ui.window.set_default_size(1100, 650);
    let baseline = "🙂cat\r\ncat cat\r\noutside cat";
    let longer = std::env::var("FASTRA_SINGLE_REPLACE_SELFTEST").as_deref() == Ok("longer");
    let replacement = if longer { "犬犬犬犬" } else { "犬" };
    let delta = replacement.chars().count() as i32 - 3;
    let once = format!("🙂cat\r\n{replacement} cat\r\noutside cat");
    let twice = format!("🙂cat\r\n{replacement} {replacement}\r\noutside cat");
    ui.add_document("single.txt", baseline);
    let doc = ui.active().unwrap();
    ui.find.set_text("");
    ui.replace.set_text(replacement);
    ui.mode.set_selected(0);
    ui.case.set_active(true);
    let secondary = std::env::var("FASTRA_SINGLE_REPLACE_SELFTEST").as_deref() == Ok("secondary");
    if secondary {
        widgets::<gtk::CheckButton>(doc.container.upcast_ref())
            .into_iter()
            .find(|b| {
                b.label().as_deref()
                    == Some(
                        ui.lang
                            .text("Quelltextansicht teilen", "Split source editor"),
                    )
            })
            .unwrap()
            .set_active(true);
    }
    let phase = Cell::new(if secondary { -2 } else { 0 });
    let began = Instant::now();
    let pause = Cell::new(began);
    let noop = RefCell::new(None::<Rc<Document>>);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 35,
            "single file phase{}: {} source={:?}",
            phase.get(),
            ui.status.text(),
            buffer_text(&doc.buffer)
        );
        if pause.get().elapsed() < Duration::from_millis(240) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            -2 => {
                let views = widgets::<sourceview5::View>(doc.container.upcast_ref());
                assert_eq!(views.len(), 2);
                views[1].grab_focus();
                git_view::test_keys(&views[1], &[]);
            }
            -1 => {
                if source_panes::capture(&doc).is_none_or(|target| target.buffer == doc.buffer) {
                    return glib::ControlFlow::Continue;
                }
            }
            0 => {
                let buffer = source_panes::buffer(&doc);
                buffer.select_range(&buffer.iter_at_offset(13), &buffer.iter_at_offset(6));
                ui.scope.set_selected(4);
                chrome::show_search(&ui);
                ui.find.grab_focus();
                git_view::test_keys(&ui.find, &["c", "a", "t"]);
            }
            1 => {
                if !replace(&ui).is_sensitive() || !count(&ui, 2) {
                    return glib::ControlFlow::Continue;
                }
                assert!(!ui.approval.has_approvals());
                git_view::test_click(&replace(&ui), &[]);
            }
            2 => {
                if buffer_text(&doc.buffer) != once || !replace(&ui).is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(count(&ui, 1));
                assert_eq!(search_selection::range(&ui, &doc), Some((6, 13 + delta)));
                assert_eq!(selected_offsets(&doc), Some((10 + delta, 13 + delta)));
                assert!(doc.buffer.can_undo() && doc.buffer.is_modified());
                assert_eq!(
                    ui.search_emphasis.borrow().as_ref().map(|e| e.test_range()),
                    Some((10 + delta, 13 + delta))
                );
                git_view::test_click(&replace(&ui), &[]);
            }
            3 => {
                if buffer_text(&doc.buffer) != twice
                    || !ui
                        .pending
                        .borrow()
                        .as_ref()
                        .is_some_and(|p| p.preview.matches().is_empty())
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(!replace(&ui).is_sensitive());
                assert_eq!(
                    search_selection::range(&ui, &doc),
                    Some((6, 13 + 2 * delta))
                );
                git_view::test_keys(&window(&ui), &["Escape"]);
            }
            4 => {
                if ui
                    .chrome
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .search_window
                    .is_visible()
                {
                    return glib::ControlFlow::Continue;
                }
                undo(&doc);
            }
            5 => {
                if buffer_text(&doc.buffer) != once {
                    return glib::ControlFlow::Continue;
                }
                assert!(doc.buffer.can_undo());
                undo(&doc);
            }
            6 => {
                if buffer_text(&doc.buffer) != baseline {
                    return glib::ControlFlow::Continue;
                }
                assert!(!doc.buffer.can_undo());
                ui.add_document("no-op.txt", "cat");
                *noop.borrow_mut() = ui.active();
                ui.scope.set_selected(0);
                ui.replace.set_text("cat");
                chrome::show_search(&ui);
            }
            7 => {
                if !replace(&ui).is_sensitive() || !count(&ui, 1) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&replace(&ui), &[]);
            }
            8 => {
                let no_op = noop.borrow().clone().unwrap();
                assert_eq!(buffer_text(&no_op.buffer), "cat");
                assert!(!no_op.buffer.can_undo() && !no_op.buffer.is_modified());
                assert_eq!(buffer_text(&doc.buffer), baseline);
                println!(
                    "PASS native single file: real typed query and Replace clicks without approvals, Unicode/CRLF selection scope, exact range adjustment, successor highlight, zero-result disabled state, two independent native Undo steps, no-op creates no history or dirty state"
                );
                window(&ui).close();
                git_view::finish(ui.window.clone().upcast(), ui.clone(), "single-replace");
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
fn open(ui: Rc<Ui>) {
    ui.add_document("duplicate.txt", "cat cat");
    let first = ui.active().unwrap();
    ui.add_document("duplicate.txt", "cat");
    let second = ui.active().unwrap();
    ui.scope.set_selected(1);
    ui.mode.set_selected(0);
    ui.case.set_active(true);
    ui.find.set_text("cat");
    ui.replace.set_text("犬");
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 35,
            "single open phase{} first={:?} second={:?}",
            phase.get(),
            buffer_text(&first.buffer),
            buffer_text(&second.buffer)
        );
        if pause.get().elapsed() < Duration::from_millis(240) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => chrome::show_search(&ui),
            1 => {
                if !replace(&ui).is_sensitive() || !count(&ui, 3) {
                    return glib::ControlFlow::Continue;
                }
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &second));
                git_view::test_click(&replace(&ui), &[]);
            }
            2 => {
                if buffer_text(&first.buffer) != "犬 cat" || !replace(&ui).is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&second.buffer), "cat");
                assert!(count(&ui, 2));
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &first));
                git_view::test_click(&next(&ui), &[]);
            }
            3 => {
                if !Rc::ptr_eq(&ui.active().unwrap(), &second) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&replace(&ui), &[]);
            }
            4 => {
                if buffer_text(&second.buffer) != "犬" || !replace(&ui).is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&first.buffer), "犬 cat");
                assert!(count(&ui, 1));
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &first));
                git_view::test_keys(&window(&ui), &["Escape"]);
            }
            5 => {
                if gtk::Window::list_toplevels().iter().any(|w| {
                    w.downcast_ref::<gtk::Window>().is_some_and(|w| {
                        w.is_mapped()
                            && w.title().as_deref()
                                == Some(ui.lang.text("Suchen & Ersetzen", "Search & Replace"))
                    })
                }) {
                    return glib::ControlFlow::Continue;
                }
                undo(&first);
            }
            6 => {
                if buffer_text(&first.buffer) != "cat cat" {
                    return glib::ControlFlow::Continue;
                }
                assert!(!first.buffer.can_undo());
                assert_eq!(buffer_text(&second.buffer), "犬");
                let index = ui
                    .documents
                    .borrow()
                    .iter()
                    .position(|doc| Rc::ptr_eq(doc, &second))
                    .unwrap();
                ui.tabs.set_current_page(Some(index as u32));
            }
            7 => undo(&second),
            8 => {
                if buffer_text(&second.buffer) != "cat" {
                    return glib::ControlFlow::Continue;
                }
                assert!(!second.buffer.can_undo());
                assert_eq!(buffer_text(&first.buffer), "cat cat");
                println!(
                    "PASS native single open: duplicate names and zero-match input, initially offscreen target by document identity, only active hit changed, explicit Next, successor ordinal clamping, independent native Undo in each document"
                );
                git_view::finish(
                    ui.window.clone().upcast(),
                    ui.clone(),
                    "single-replace-open",
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
