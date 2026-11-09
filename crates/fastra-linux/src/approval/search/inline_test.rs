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
fn action(ui: &Ui, de: &'static str, en: &'static str) -> gtk::Button {
    widgets::<gtk::Button>(window(ui).upcast_ref())
        .into_iter()
        .find(|b| b.is_mapped() && b.label().as_deref() == Some(ui.lang.text(de, en)))
        .unwrap()
}
fn strip(ui: &Ui) -> gtk::Box {
    widgets::<gtk::Box>(window(ui).upcast_ref())
        .into_iter()
        .find(|b| b.widget_name() == "fastra-inline-preview")
        .unwrap()
}
fn labels(ui: &Ui) -> Vec<String> {
    widgets::<gtk::Label>(strip(ui).upcast_ref())
        .iter()
        .map(|l| l.text().to_string())
        .collect()
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let open = std::env::var("FASTRA_INLINE_PREVIEW_SELFTEST").as_deref() == Ok("open");
    let first_text = "FIRST cat\r\ncat cat\r\ncat\ncat\ncat";
    ui.add_document("same.txt", first_text);
    let first = ui.active().unwrap();
    ui.add_document("same.txt", "SECOND cat");
    let second = ui.active().unwrap();
    let first_index = ui
        .documents
        .borrow()
        .iter()
        .position(|d| Rc::ptr_eq(d, &first))
        .unwrap() as u32;
    ui.tabs.set_current_page(Some(first_index));
    ui.scope.set_selected(if open { 1 } else { 0 });
    ui.mode.set_selected(0);
    ui.find.set_text("cat");
    ui.replace.set_text("犬");
    let capture_pending = RefCell::new(None);
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 30,
            "inline phase{} labels={:?}",
            phase.get(),
            if phase.get() > 0 { labels(&ui) } else { vec![] }
        );
        if pause.get().elapsed() < Duration::from_millis(240) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => chrome::show_search(&ui),
            1 => {
                if !action(&ui, "Alle", "All").is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!strip(&ui).is_visible());
                git_view::test_click(&action(&ui, "Alle", "All"), &[]);
            }
            2 => {
                if !strip(&ui).is_visible() {
                    return glib::ControlFlow::Continue;
                }
                let text = labels(&ui);
                assert!(text.iter().any(|s| s == "FIRST cat"));
                assert!(text.iter().any(|s| s == "FIRST 犬"));
                assert!(text.iter().any(|s| s.starts_with("… 2 ")));
                assert_eq!(text.iter().filter(|s| s.as_str() == "→").count(), 3);
                assert!(!text.iter().any(|s| s.contains("SECOND")));
                if !git_view::try_capture_x11(
                    &window(&ui),
                    "search-inline-approved",
                    &capture_pending,
                ) {
                    return glib::ControlFlow::Continue;
                }
                if open {
                    let index = ui
                        .documents
                        .borrow()
                        .iter()
                        .position(|d| Rc::ptr_eq(d, &second))
                        .unwrap() as u32;
                    ui.tabs.set_current_page(Some(index));
                } else {
                    git_view::test_click(&action(&ui, "Keine", "None"), &[]);
                }
            }
            3 => {
                if open {
                    if !strip(&ui).is_visible() || !labels(&ui).iter().any(|s| s == "SECOND 犬") {
                        return glib::ControlFlow::Continue;
                    }
                    assert!(!labels(&ui).iter().any(|s| s.contains("FIRST")));
                    if !git_view::try_capture_x11(
                        &window(&ui),
                        "search-inline-active-tab",
                        &capture_pending,
                    ) {
                        return glib::ControlFlow::Continue;
                    }
                    git_view::test_click(&action(&ui, "Keine", "None"), &[]);
                } else {
                    if strip(&ui).is_visible() {
                        return glib::ControlFlow::Continue;
                    }
                    let checks = widgets::<gtk::CheckButton>(window(&ui).upcast_ref())
                        .into_iter()
                        .filter(|c| {
                            c.is_mapped() && c.ancestor(gtk::ListView::static_type()).is_some()
                        })
                        .collect::<Vec<_>>();
                    assert!(checks.len() >= 2);
                    git_view::test_click(&checks[1], &[]);
                }
            }
            4 => {
                if open {
                    if strip(&ui).is_visible() {
                        return glib::ControlFlow::Continue;
                    }
                    git_view::test_click(&action(&ui, "Alle", "All"), &[]);
                } else {
                    if !strip(&ui).is_visible() {
                        return glib::ControlFlow::Continue;
                    }
                    let text = labels(&ui);
                    assert_eq!(text.iter().filter(|s| s.as_str() == "→").count(), 1);
                    assert!(text.iter().any(|s| s == "FIRST 犬"));
                    assert!(!text.iter().any(|s| s.starts_with("…")));
                    if !git_view::try_capture_x11(
                        &window(&ui),
                        "search-inline-one-approved",
                        &capture_pending,
                    ) {
                        return glib::ControlFlow::Continue;
                    }
                    ui.replace.set_text("cat");
                    assert!(!strip(&ui).is_visible());
                }
            }
            5 => {
                if open {
                    if !strip(&ui).is_visible() {
                        return glib::ControlFlow::Continue;
                    }
                    ui.replace.set_text("cat");
                    assert!(!strip(&ui).is_visible());
                } else {
                    if !action(&ui, "Alle", "All").is_sensitive() {
                        return glib::ControlFlow::Continue;
                    }
                    git_view::test_click(&action(&ui, "Alle", "All"), &[]);
                }
            }
            6 => {
                if open {
                    if !action(&ui, "Alle", "All").is_sensitive() {
                        return glib::ControlFlow::Continue;
                    }
                    git_view::test_click(&action(&ui, "Alle", "All"), &[]);
                }
            }
            7 => {
                assert!(!strip(&ui).is_visible(), "no-op must hide inline preview");
                assert_eq!(buffer_text(&first.buffer), first_text);
                assert_eq!(buffer_text(&second.buffer), "SECOND cat");
                assert!(!first.buffer.can_undo() && !second.buffer.can_undo());
                println!("PASS native inline preview: approved-only active document identity with duplicate names, three row limit and honest remainder, no approvals/no-op/changed input hide immediately, no source/Undo changes, open={open}");
                window(&ui).close();
                git_view::finish(
                    ui.window.clone().upcast(),
                    ui.clone(),
                    "search-inline-preview",
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
