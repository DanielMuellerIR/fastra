use super::*;
use std::time::Instant;
pub(super) fn views(root: &gtk::Widget, out: &mut Vec<sourceview5::View>) {
    if let Some(v) = root.downcast_ref::<sourceview5::View>() {
        out.push(v.clone());
    }
    let mut child = root.first_child();
    while let Some(c) = child {
        views(&c, out);
        child = c.next_sibling();
    }
}
pub(super) fn named<T: IsA<gtk::Widget> + glib::object::ObjectType>(
    root: &gtk::Widget,
    name: &str,
) -> Option<T> {
    if let Ok(w) = root.clone().downcast::<T>() {
        let label = root
            .downcast_ref::<gtk::Button>()
            .and_then(|b| b.label())
            .or_else(|| {
                root.downcast_ref::<gtk::CheckButton>()
                    .and_then(|b| b.label())
            })
            .or_else(|| {
                root.downcast_ref::<gtk::MenuButton>()
                    .and_then(|b| b.label())
            });
        if label.as_deref() == Some(name) {
            return Some(w);
        }
    }
    let mut child = root.first_child();
    while let Some(c) = child {
        if let Some(w) = named(&c, name) {
            return Some(w);
        }
        child = c.next_sibling();
    }
    None
}
pub(super) fn same(doc: &Document, views: &[sourceview5::View], tag: &str) {
    let a = buffer_text(&views[0].buffer());
    let b = buffer_text(&views[1].buffer());
    assert_eq!(a, b, "SPLIT NOGO {tag}");
    assert_eq!(
        doc.buffer.upcast_ref::<gtk::TextBuffer>(),
        &views[0].buffer()
    );
    eprintln!(
        "SPLIT {tag} chars={} rev={} undo={}/{} redo={}/{} sel={:?}/{:?}",
        a.chars().count(),
        doc.revision.get(),
        views[0].buffer().can_undo(),
        views[1].buffer().can_undo(),
        views[0].buffer().can_redo(),
        views[1].buffer().can_redo(),
        views[0]
            .buffer()
            .selection_bounds()
            .map(|(a, b)| (a.offset(), b.offset())),
        views[1]
            .buffer()
            .selection_bounds()
            .map(|(a, b)| (a.offset(), b.offset()))
    );
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(1100, 1000);
    ui.add_document(
        "split-gate.rs",
        "abcdefghijklmnopqrstuvwxyz\ncafé🙂\tsecond\r\n",
    );
    let doc = ui.active().unwrap();
    let mut all = Vec::new();
    views(doc.container.upcast_ref(), &mut all);
    assert_eq!(all.len(), 2);
    assert_ne!(all[0].buffer(), all[1].buffer());
    named::<gtk::CheckButton>(
        doc.container.upcast_ref(),
        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
    )
    .unwrap()
    .set_active(true);
    eprintln!(
        "SPLIT RESOURCE maxUndo={}/{}",
        all[0].buffer().max_undo_levels(),
        all[1].buffer().max_undo_levels()
    );
    let stage = Cell::new(0);
    let pause = Cell::new(Instant::now());
    let start = Instant::now();
    let counts = Rc::new([Cell::new(0u64), Cell::new(0u64)]);
    for (i, v) in all.iter().enumerate() {
        let counts = counts.clone();
        v.buffer()
            .connect_changed(move |_| counts[i].set(counts[i].get() + 1));
    }
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(start.elapsed().as_secs() < 40, "stage {}", stage.get());
        if pause.get().elapsed() < Duration::from_millis(350) {
            return glib::ControlFlow::Continue;
        }
        same(&doc, &all, &format!("stage{}", stage.get()));
        assert_eq!(
            counts[0].get(),
            counts[1].get(),
            "canonical/mirror changed mismatch"
        );
        assert_eq!(
            doc.revision.get(),
            counts[0].get(),
            "canonical revision duplication"
        );
        match stage.get() {
            0 => crate::git_view::test_click(
                &all[0],
                &[
                    "ctrl+Home",
                    "Right",
                    "Right",
                    "shift+Right",
                    "shift+Right",
                    "shift+Right",
                ],
            ),
            1 => crate::git_view::test_click(
                &all[1],
                &[
                    "ctrl+Home",
                    "Right",
                    "Right",
                    "Right",
                    "Right",
                    "Right",
                    "Right",
                    "Right",
                    "Right",
                    "Right",
                    "Right",
                    "shift+Right",
                    "shift+Right",
                    "shift+Right",
                ],
            ),
            2 => {
                assert_eq!(
                    all[0]
                        .buffer()
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((2, 5))
                );
                assert_eq!(
                    all[1]
                        .buffer()
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((10, 13))
                );
                crate::git_view::capture(ui.window.upcast_ref(), "independent-selection");
                crate::git_view::test_click(
                    &all[1],
                    &["ctrl+Home", "End", "a", "b", "c", "Tab", "d", "e", "f"],
                );
            }
            3 => crate::git_view::test_click(&all[0], &["ctrl+End", "x", "y", "z"]),
            4 => crate::git_view::test_click(&all[1], &["ctrl+z"]),
            5 => crate::git_view::test_click(&all[1], &["ctrl+z"]),
            6 => crate::git_view::test_click(&all[0], &["ctrl+shift+z"]),
            7 => crate::git_view::test_click(
                &named::<gtk::Button>(ui.window.upcast_ref(), ui.lang.text("Rückgängig", "Undo"))
                    .unwrap(),
                &[],
            ),
            8 => crate::git_view::test_click(
                &named::<gtk::Button>(ui.window.upcast_ref(), ui.lang.text("Wiederholen", "Redo"))
                    .unwrap(),
                &[],
            ),
            9 => {
                let b = all[1].buffer();
                b.begin_user_action();
                b.insert(&mut b.start_iter(), "é🙂\t");
                b.insert(&mut b.end_iter(), "\nEND");
                b.end_user_action();
            }
            10 => crate::git_view::test_click(&all[1], &["ctrl+z"]),
            11 => crate::git_view::test_click(&all[1], &["ctrl+shift+z"]),
            12 => {
                source_panes::reset(&doc, true);
                doc.buffer.begin_irreversible_action();
                doc.buffer.set_text("Reload café🙂\t\r\n");
                doc.buffer.end_irreversible_action();
                source_panes::reset(&doc, false);
                assert!(!all[0].buffer().can_undo() && !all[1].buffer().can_undo());
            }
            13 => {
                doc.buffer.set_enable_undo(false);
                doc.buffer.set_text("SaveAs reset\r\n");
                doc.buffer.set_enable_undo(true);
                assert!(!all[0].buffer().can_undo() && !all[1].buffer().can_undo());
            }
            _ => {
                println!("SPLIT FIRST_GATE PASS independent native selections, alternating native typing/tab, keyboard+toolbar undo/redo, multipart actions, single canonical Changed/revision; no full port Go");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
        }
        stage.set(stage.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
