use super::*;
use std::time::Instant;
fn button(root: &gtk::Widget, title: &str) -> Option<gtk::Button> {
    if let Some(button) = root.downcast_ref::<gtk::Button>().filter(|button| {
        button.is_mapped()
            && (button.label().as_deref() == Some(title)
                || button.tooltip_text().as_deref() == Some(title))
    }) {
        return Some(button.clone());
    }
    chrome::children(root)
        .iter()
        .find_map(|child| button(child, title))
}
fn list(root: &gtk::Widget) -> Option<gtk::ListView> {
    if let Some(list) = root.downcast_ref::<gtk::ListView>() {
        return Some(list.clone());
    }
    chrome::children(root).iter().find_map(list)
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(
        std::env::var("FASTRA_TOOL_WIDTH")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(1000),
        650,
    );
    let source = format!("{}🙂cat e\u{301}\r\n猫cat\n", "fixture line\n".repeat(200));
    let matches = source
        .match_indices("cat")
        .map(|(byte, _)| source[..byte].chars().count() as i32)
        .collect::<Vec<_>>();
    ui.add_document("source.txt", &source);
    let doc = ui.active().unwrap();
    let target = source_panes::capture(&doc).unwrap();
    target
        .buffer
        .select_range(&target.buffer.start_iter(), &target.buffer.end_iter());
    let selection = target.offsets();
    let modified = doc.buffer.is_modified();
    let undo = doc.buffer.can_undo();
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let preview = RefCell::new(None::<Arc<Preview>>);
    let tag = RefCell::new(None::<gtk::TextTag>);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 35,
            "source navigation phase{} status{}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(240) {
            return glib::ControlFlow::Continue;
        }
        let search = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
        match phase.get() {
            0 => {
                chrome::show_search(&ui);
                ui.scope.set_selected(4);
                ui.mode.set_selected(2);
                ui.find.set_text("cat|\\z");
                ui.replace.set_text("dog");
                ui.search();
            }
            1 => {
                if !ui.approval.is_ready() || ui.search_emphasis.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let emphasis = ui.search_emphasis.borrow();
                let emphasis = emphasis.as_ref().unwrap();
                assert_eq!(emphasis.range, (matches[0], matches[0] + 3));
                assert!(target
                    .buffer
                    .iter_at_offset(matches[0])
                    .has_tag(&emphasis.active));
                *tag.borrow_mut() = Some(emphasis.active.clone());
                *preview.borrow_mut() = Some(ui.pending.borrow().as_ref().unwrap().preview.clone());
                assert_eq!(
                    source_panes::capture(&doc).unwrap().offsets(),
                    (matches[0], matches[0] + 3)
                );
                assert_eq!(search_selection::range(&ui, &doc), Some(selection));
                git_view::test_click(
                    &button(
                        search.upcast_ref(),
                        ui.lang.text("Nächster Treffer", "Next match"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            2 => {
                if ui
                    .search_emphasis
                    .borrow()
                    .as_ref()
                    .map(|emphasis| emphasis.range)
                    != Some((matches[1], matches[1] + 3))
                {
                    return glib::ControlFlow::Continue;
                }
                let scroll = target
                    .view
                    .ancestor(gtk::ScrolledWindow::static_type())
                    .unwrap()
                    .downcast::<gtk::ScrolledWindow>()
                    .unwrap();
                if scroll.vadjustment().value() <= 0. {
                    return glib::ControlFlow::Continue;
                }
                assert!(Arc::ptr_eq(
                    preview.borrow().as_ref().unwrap(),
                    &ui.pending.borrow().as_ref().unwrap().preview
                ));
                assert_eq!(target.offsets(), (matches[1], matches[1] + 3));
                assert_eq!(search_selection::range(&ui, &doc), Some(selection));
                git_view::capture(ui.window.upcast_ref(), "search-source-highlight");
                assert!(list(ui.approval.root.upcast_ref()).unwrap().grab_focus());
                git_view::test_keys(&list(ui.approval.root.upcast_ref()).unwrap(), &["Down"]);
            }
            3 => {
                let end = source.chars().count() as i32;
                if ui
                    .search_emphasis
                    .borrow()
                    .as_ref()
                    .map(|emphasis| emphasis.range)
                    != Some((end, end))
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(target.offsets(), (end, end));
                assert_eq!(search_selection::range(&ui, &doc), Some(selection));
                assert_eq!(buffer_text(&doc.buffer), source);
                assert_eq!(doc.buffer.is_modified(), modified);
                assert_eq!(doc.buffer.can_undo(), undo);
                git_view::capture(ui.window.upcast_ref(), "search-source-zero-match");
                assert!(list(ui.approval.root.upcast_ref()).unwrap().grab_focus());
                git_view::test_keys(&list(ui.approval.root.upcast_ref()).unwrap(), &["Up"]);
            }
            4 => {
                if ui
                    .search_emphasis
                    .borrow()
                    .as_ref()
                    .map(|emphasis| emphasis.range)
                    != Some((matches[1], matches[1] + 3))
                {
                    return glib::ControlFlow::Continue;
                }
                *tag.borrow_mut() =
                    Some(ui.search_emphasis.borrow().as_ref().unwrap().active.clone());
                ui.find.set_text("new");
                assert!(ui.pending.borrow().is_none() && ui.search_emphasis.borrow().is_none());
            }
            5 => {
                if !ui
                    .pending
                    .borrow()
                    .as_ref()
                    .is_some_and(|pending| pending.preview.matches().is_empty())
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.search_emphasis.borrow().is_none());
                assert!(!target
                    .buffer
                    .iter_at_offset(matches[1])
                    .has_tag(tag.borrow().as_ref().unwrap()));
                assert_eq!(target.offsets(), (matches[1], matches[1] + 3));
                assert_eq!(search_selection::range(&ui, &doc), Some(selection));
                assert_eq!(buffer_text(&doc.buffer), source);
                assert_eq!(doc.buffer.is_modified(), modified);
                assert_eq!(doc.buffer.can_undo(), undo);
                println!("PASS native source search navigation: real Next/Down/Up, exact Unicode/CRLF character ranges, source scroll and painted zero-length marker, frozen selection-only preview identity with actual native match selections; unchanged content/Undo/modified state, highlight removal on invalidation");
                search.close();
                git_view::finish(ui.window.clone().upcast(), ui.clone(), "search-navigation");
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
