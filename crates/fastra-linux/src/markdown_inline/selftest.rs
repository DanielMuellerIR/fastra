use super::*;
use std::time::Instant;
use webkit6::prelude::*;
pub(super) fn find<T: IsA<gtk::Widget> + glib::object::ObjectType>(
    root: &gtk::Widget,
    label: &str,
) -> Option<T> {
    if let Ok(widget) = root.clone().downcast::<T>() {
        let text = root
            .downcast_ref::<gtk::Button>()
            .and_then(|b| b.label().or_else(|| b.tooltip_text()))
            .or_else(|| {
                root.downcast_ref::<gtk::CheckButton>()
                    .and_then(|b| b.label().or_else(|| b.tooltip_text()))
            });
        if text.as_deref() == Some(label) {
            return Some(widget);
        }
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        if let Some(found) = find(&widget, label) {
            return Some(found);
        }
        child = widget.next_sibling();
    }
    None
}
pub(super) fn views(root: &gtk::Widget, out: &mut Vec<sourceview5::View>) {
    if let Some(view) = root.downcast_ref::<sourceview5::View>() {
        out.push(view.clone());
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        views(&widget, out);
        child = widget.next_sibling();
    }
}
pub(super) fn bar(root: &gtk::Widget) -> Option<gtk::Widget> {
    if root.widget_name() == "fastra-markdown-inline" {
        return Some(root.clone());
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        if let Some(found) = bar(&widget) {
            return Some(found);
        }
        child = widget.next_sibling();
    }
    None
}
pub(super) fn reset(doc: &Document, source: &str) {
    source_panes::reset(doc, true);
    doc.buffer.begin_irreversible_action();
    doc.buffer.set_text(source);
    doc.buffer.end_irreversible_action();
    source_panes::reset(doc, false);
}
pub(super) fn same(doc: &Document, expected: &str) {
    let panes = doc.source_panes.borrow();
    for buffer in &panes.as_ref().unwrap().buffers {
        assert_eq!(buffer_text(buffer), expected);
    }
}
pub(crate) fn run(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_MARKDOWN_FORMATTING_SELFTEST").is_some() {
        super::formatting_test::run(ui);
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(
        std::env::var("FASTRA_TOOL_WIDTH")
            .unwrap_or("1100".into())
            .parse()
            .unwrap(),
        950,
    );
    let source = "A\r\n雪🙂e\u{301} and word\r\nZ\n";
    ui.add_document("inline.md", source);
    let doc = ui.active().unwrap();
    let native = fastra_process::host::is_active().unwrap();
    println!(
        "INLINE_RUNTIME native={native} commit_hook={} buffer_type={}",
        source_panes::native_preflight_ready(),
        doc.buffer.type_().name()
    );
    if std::env::var_os("FASTRA_NATIVE_RUNTIME").is_some() {
        assert!(native && source_panes::native_preflight_ready());
        assert_eq!(doc.buffer.type_().name(), "FastraCountedSourceBuffer");
    }

    let mut all = Vec::new();
    views(doc.container.upcast_ref(), &mut all);
    assert_eq!(all.len(), 2);
    find::<gtk::CheckButton>(
        doc.container.upcast_ref(),
        ui.lang
            .text("Quelltextansicht teilen", "Split source editor"),
    )
    .unwrap()
    .set_active(true);
    let index: usize = std::env::var("FASTRA_INLINE_PANE")
        .unwrap_or("1".into())
        .parse()
        .unwrap();
    assert!(index < 2);
    let other = 1 - index;
    let toolbar = bar(doc.container.upcast_ref()).unwrap();
    let styles = [
        (Style::Bold, "Fett", "Bold"),
        (Style::Italic, "Kursiv", "Italic"),
        (Style::Highlight, "Markierung", "Highlight"),
        (Style::Code, "Inlinecode", "Inline code"),
    ];
    let state = Cell::new(0);
    let which = Cell::new(0usize);
    let start = Instant::now();
    let pause = Cell::new(start);
    let held = RefCell::new(None::<source_panes::Target>);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            start.elapsed() < Duration::from_secs(65),
            "inline stage{} style{} status{}",
            state.get(),
            which.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(200) {
            return glib::ControlFlow::Continue;
        }
        match state.get() {
            0 => {
                assert!(toolbar.is_mapped());
                git_view::test_click(&all[other], &[]);
                state.set(1);
            }
            1 => {
                if !all[other].has_focus() {
                    return glib::ControlFlow::Continue;
                }
                all[other].buffer().select_range(
                    &all[other].buffer().iter_at_offset(1),
                    &all[other].buffer().iter_at_offset(0),
                );
                git_view::test_click(&all[index], &[]);
                state.set(2);
            }
            2 => {
                let target = source_panes::capture(&doc).unwrap();
                if target.view != all[index] {
                    return glib::ControlFlow::Continue;
                }
                all[other].buffer().select_range(
                    &all[other].buffer().iter_at_offset(6),
                    &all[other].buffer().iter_at_offset(4),
                );
                target.buffer.select_range(
                    &target.buffer.iter_at_offset(7),
                    &target.buffer.iter_at_offset(3),
                );
                assert_eq!(source_panes::capture(&doc).unwrap().offsets(), (3, 7));
                let (_, de, en) = styles[which.get()];
                let button = find::<gtk::Button>(&toolbar, ui.lang.text(de, en)).unwrap();
                assert!(button.is_mapped());
                let bounds = button.compute_bounds(&toolbar).unwrap();
                assert!(
                    bounds.width() >= 26. && bounds.height() >= 22.,
                    "button bounds {bounds:?}"
                );
                git_view::test_click(&button, &[]);
                state.set(3);
            }
            3 => {
                let marker = styles[which.get()].0.marker();
                let expected = format!("A\r\n{marker}雪🙂e\u{301}{marker} and word\r\nZ\n");
                if buffer_text(&doc.buffer) != expected {
                    return glib::ControlFlow::Continue;
                }
                same(&doc, &expected);
                let target = source_panes::capture(&doc).unwrap();
                assert_eq!(target.view, all[index]);
                let m = marker.len() as i32;
                assert_eq!(target.offsets(), (3 + m, 7 + m));
                assert_eq!(
                    all[other]
                        .buffer()
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((4 + m, 6 + m))
                );
                assert!(target.buffer.can_undo());
                target.buffer.undo();
                same(&doc, source);
                assert!(
                    !target.buffer.can_undo(),
                    "one action must undo the complete toggle"
                );
                target.buffer.redo();
                same(&doc, &expected);
                target.buffer.select_range(
                    &target.buffer.iter_at_offset(7 + m),
                    &target.buffer.iter_at_offset(3 + m),
                );
                let (_, de, en) = styles[which.get()];
                git_view::test_click(
                    &find::<gtk::Button>(&toolbar, ui.lang.text(de, en)).unwrap(),
                    &[],
                );
                state.set(4);
            }
            4 => {
                if buffer_text(&doc.buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                same(&doc, source);
                let marker = styles[which.get()].0.marker();
                let wrapped = format!("A\r\n{marker}雪🙂e\u{301}{marker} and word\r\nZ\n");
                assert_eq!(
                    all[other]
                        .buffer()
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((4, 6))
                );
                let buffer = source_panes::buffer(&doc);
                buffer.undo();
                same(&doc, &wrapped);
                buffer.redo();
                same(&doc, source);
                let next = which.get() + 1;
                if next < styles.len() {
                    which.set(next);
                    reset(&doc, source);
                    git_view::test_click(&all[index], &[]);
                    state.set(2);
                } else {
                    reset(&doc, "abc");
                    all[index]
                        .buffer()
                        .place_cursor(&all[index].buffer().end_iter());
                    git_view::test_click(
                        &find::<gtk::Button>(&toolbar, ui.lang.text("Kursiv", "Italic")).unwrap(),
                        &[],
                    );
                    state.set(5);
                }
            }
            5 => {
                if buffer_text(&doc.buffer) != "abc**" {
                    return glib::ControlFlow::Continue;
                }
                same(&doc, "abc**");
                let target = source_panes::capture(&doc).unwrap();
                assert_eq!(target.offsets(), (4, 4));
                target.buffer.undo();
                same(&doc, "abc");
                assert!(!target.buffer.can_undo());
                target.buffer.redo();
                same(&doc, "abc**");
                target.buffer.select_range(
                    &target.buffer.iter_at_offset(5),
                    &target.buffer.iter_at_offset(3),
                );
                git_view::test_click(
                    &find::<gtk::Button>(&toolbar, ui.lang.text("Kursiv", "Italic")).unwrap(),
                    &[],
                );
                state.set(6);
            }
            6 => {
                if buffer_text(&doc.buffer) != "abc" {
                    return glib::ControlFlow::Continue;
                }
                same(&doc, "abc");
                let buffer = source_panes::buffer(&doc);
                buffer.undo();
                same(&doc, "abc**");
                buffer.redo();
                same(&doc, "abc");
                reset(&doc, source);
                let target = source_panes::capture(&doc).unwrap();
                *held.borrow_mut() = Some(target.clone());
                target.buffer.place_cursor(&target.buffer.end_iter());
                assert!(!apply(&ui, &doc, &target, Style::Bold));
                same(&doc, source);
                let target = source_panes::capture(&doc).unwrap();
                target.buffer.place_cursor(&target.buffer.start_iter());
                let target = source_panes::capture(&doc).unwrap();
                let at = target.buffer.char_count();
                target
                    .buffer
                    .insert(&mut target.buffer.iter_at_offset(at), "_");
                assert!(!apply(&ui, &doc, &target, Style::Bold));
                same(&doc, &format!("{source}_"));
                target.buffer.undo();
                same(&doc, source);
                let target = source_panes::capture(&doc).unwrap();
                let original_buffer = target.buffer.clone();
                let foreign = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
                foreign.set_text("foreign");
                source_panes::bind_view(&target.view, &foreign);
                assert!(!apply(&ui, &doc, &target, Style::Bold));
                assert_eq!(buffer_text(&foreign), "foreign");
                same(&doc, source);
                source_panes::bind_view(&target.view, &original_buffer);
                let target = source_panes::capture(&doc).unwrap();
                target.view.set_editable(false);
                assert!(!apply(&ui, &doc, &target, Style::Bold));
                target.view.set_editable(true);
                doc.close_pending.set(true);
                assert!(!apply(
                    &ui,
                    &doc,
                    &source_panes::capture(&doc).unwrap(),
                    Style::Bold
                ));
                doc.close_pending.set(false);
                doc.rectangles.borrow()[index].select((0, 0), (0, 1));
                assert!(!apply(
                    &ui,
                    &doc,
                    &source_panes::capture(&doc).unwrap(),
                    Style::Bold
                ));
                doc.rectangles.borrow()[index].clear();
                same(&doc, source);
                assert!(!doc.buffer.can_undo());
                *held.borrow_mut() = source_panes::capture(&doc);
                git_view::test_click(&all[other], &[]);
                state.set(7);
            }
            7 => {
                if source_panes::capture(&doc).unwrap().view != all[other] {
                    return glib::ControlFlow::Continue;
                }
                assert!(!apply(
                    &ui,
                    &doc,
                    held.borrow().as_ref().unwrap(),
                    Style::Bold
                ));
                same(&doc, source);
                let target = source_panes::capture(&doc).unwrap();
                let lang = doc.buffer.language();
                doc.buffer.set_language(None::<&sourceview5::Language>);
                assert!(!toolbar.is_visible());
                assert!(!apply(&ui, &doc, &target, Style::Bold));
                doc.buffer.set_language(lang.as_ref());
                assert!(toolbar.is_visible());
                *held.borrow_mut() = source_panes::capture(&doc);
                doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
                state.set(8);
            }
            8 => {
                let ready = doc.rich.borrow().as_ref().is_some_and(|e| e.active.get());
                if !ready
                    || pause.get().elapsed() < Duration::from_millis(1200)
                    || doc
                        .rich
                        .borrow()
                        .as_ref()
                        .is_some_and(|editor| editor.view.is_loading())
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(!toolbar.is_visible());
                assert!(!apply(
                    &ui,
                    &doc,
                    held.borrow().as_ref().unwrap(),
                    Style::Bold
                ));
                same(&doc, source);
                doc.rich_toggle.borrow().as_ref().unwrap().set_active(false);
                state.set(9);
            }
            9 => {
                if doc.is_rich_active() {
                    return glib::ControlFlow::Continue;
                }
                assert!(toolbar.is_visible());
                same(&doc, source);
                git_view::test_click(&all[index], &[]);
                state.set(10);
            }
            10 => {
                reset(&doc, &"x".repeat(65536));
                let target = source_panes::capture(&doc).unwrap();
                target.buffer.place_cursor(&target.buffer.end_iter());
                let target = source_panes::capture(&doc).unwrap();
                target.buffer.insert(&mut target.buffer.end_iter(), "_");
                target.buffer.undo();
                assert!(target.buffer.can_redo());
                let target = source_panes::capture(&doc).unwrap();
                assert!(!apply(&ui, &doc, &target, Style::Bold));
                assert!(
                    target.buffer.can_redo(),
                    "rejected limit must preserve Redo"
                );
                same(&doc, &"x".repeat(65536));
                assert!(!target.buffer.can_undo());
                reset(&doc, source);
                let target = source_panes::capture(&doc).unwrap();
                *held.borrow_mut() = Some(target);
                ui.add_document("other.txt", "untouched");
                state.set(11);
            }
            11 => {
                assert!(!apply(
                    &ui,
                    &doc,
                    held.borrow().as_ref().unwrap(),
                    Style::Bold
                ));
                same(&doc, source);
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "untouched");
                assert!(!bar(ui.active().unwrap().container.upcast_ref())
                    .unwrap()
                    .is_visible());
                ui.tabs.set_current_page(Some(1));
                state.set(12);
            }
            _ => {
                if !ui.active().is_some_and(|a| Rc::ptr_eq(&a, &doc)) {
                    return glib::ControlFlow::Continue;
                }
                assert!(toolbar.is_mapped());
                println!(
                    "INLINE_UI actual_window={}x{} toolbar={}x{} pane={index} de={}",
                    ui.window.width(),
                    ui.window.height(),
                    toolbar.width(),
                    toolbar.height(),
                    ui.lang.0
                );
                if !git_view::try_capture(ui.window.upcast_ref(), "markdown-inline-source") {
                    return glib::ControlFlow::Continue;
                }
                println!("PASS Markdown inline native GTK: actual buttons all four markers, bound source pane and independent peer selection, exact Unicode/CRLF/outside bytes, one Undo/Redo, included/surrounding/empty marker cases, stale selection/pane/tab/language/readonly/close/rectangle/Rich guards, pre-mutation line limit, DE/EN source-only toolbar");
                git_view::finish(ui.window.clone().upcast(), ui.clone(), "markdown-inline");
                return glib::ControlFlow::Break;
            }
        }
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
