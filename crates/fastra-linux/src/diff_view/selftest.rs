use super::*;
use std::time::{Duration, Instant};
pub(super) fn wrap_control(widget: &gtk::Widget) -> Option<gtk::CheckButton> {
    if widget.has_css_class("soft-wrap") {
        return widget.clone().downcast().ok();
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(found) = wrap_control(&widget) {
            return Some(found);
        }
        child = widget.next_sibling();
    }
    None
}
fn aligned(view: &view::View, row: i32) -> bool {
    let positions = view
        .texts
        .each_ref()
        .map(|text| text.line_yrange(&text.buffer().iter_at_line(row).unwrap()));
    (positions[0].0 - positions[1].0).abs() <= 1
}
pub(super) fn run(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_DIFF_PALETTE_SELFTEST").is_some() {
        super::palette_selftest::run(ui);
        return;
    }
    if let Ok(mode) = std::env::var("FASTRA_DIFF_ENTRYPOINTS_SELFTEST") {
        super::entrypoints_selftest::run(ui, &mode);
        return;
    }
    if std::env::var_os("FASTRA_DIFF_INTERACTION_SELFTEST").is_some() {
        super::interaction_selftest::run(ui);
        return;
    }
    if std::env::var_os("FASTRA_DIFF_LARGE_SELFTEST").is_some() {
        super::large_selftest::run(ui);
        return;
    }
    if std::env::var_os("FASTRA_DIFF_DROP_SELFTEST").is_some() {
        super::drop_selftest::run(ui);
        return;
    }
    if std::env::var_os("FASTRA_DIFF_EXPORT_SELFTEST").is_some() {
        super::export_selftest::run(ui);
        return;
    }
    if std::env::var_os("FASTRA_DIFF_GUARDS_SELFTEST").is_some() {
        super::guards_selftest::run(ui);
        return;
    }
    if std::env::var_os("FASTRA_DIFF_STATES_SELFTEST").is_some() {
        super::states_selftest::run(ui);
        return;
    }
    if std::env::var_os("FASTRA_DIFF_RICH_SELFTEST").is_some() {
        super::rich_selftest::run(ui);
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let left = root.join("left.txt");
    let right = root.join("right.txt");
    let original = "start\r\nold café\r\nend\r\n";
    let external = "start\nnew café\nend\n";
    let output = "start\r\nnew café\nend\r\n";
    std::fs::write(&left, original).unwrap();
    std::fs::write(&right, external).unwrap();
    ui.load_path(left.clone());
    let state = RefCell::new(None::<Rc<State>>);
    let source = RefCell::new(None::<Rc<crate::Document>>);
    let copied = Rc::new(RefCell::new(None::<String>));
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    ui.window.set_default_size(1100, 780);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(45),
            "comparison phase{}",
            phase.get()
        );
        if pause.get().elapsed() < Duration::from_millis(300) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&left))
                else {
                    return glib::ControlFlow::Continue;
                };
                *source.borrow_mut() = Some(doc);
                let picker = open(&ui);
                picker.choose(1, sources::Choice::File(right.clone()));
                *state.borrow_mut() = Some(picker);
            }
            1 => {
                let state = state.borrow().clone().unwrap();
                if !state.picker.compare.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(&state.picker.window, "compare-picker") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.picker.compare, &[]);
            }
            2 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || state.model.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.active().unwrap().is_read_only());
                assert_eq!(ui.documents.borrow().len(), 2);
                assert_eq!(
                    state
                        .model
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .comparison
                        .blocks()
                        .len(),
                    1
                );
                assert!(state.view.transfer[0].is_sensitive());
                assert!(!state.view.transfer[1].is_sensitive());
                if !support::try_capture(ui.window.upcast_ref(), "compare-result") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.view.texts[0], &["ctrl+a", "ctrl+c"]);
            }
            3 => {
                let state = state.borrow().clone().unwrap();
                let clipboard = state.view.texts[0].clipboard();
                let copied = copied.clone();
                glib::spawn_future_local(async move {
                    *copied.borrow_mut() = Some(
                        clipboard
                            .read_text_future()
                            .await
                            .unwrap()
                            .unwrap()
                            .to_string(),
                    );
                });
            }
            4 => {
                let Some(text) = copied.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    text,
                    original.replace("\r\n", "\n"),
                    "native copy has no line numbers or alignment gaps"
                );
                let state = state.borrow().clone().unwrap();
                support::test_click(&state.view.transfer[0], &[]);
            }
            5 => {
                let Some(preview) = transfer::test_preview().filter(|p| p.apply.is_sensitive())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(preview.plan.output(), output);
                assert_eq!(
                    buffer_text(&source.borrow().as_ref().unwrap().buffer),
                    original
                );
                assert_eq!(std::fs::read(&left).unwrap(), original.as_bytes());
                if !support::try_capture(&preview.window, "compare-transfer-preview") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&preview.apply, &[]);
            }
            6 => {
                let state = state.borrow().clone().unwrap();
                let doc = source.borrow().clone().unwrap();
                if state.busy.get()
                    || buffer_text(&doc.buffer) != output
                    || transfer::test_preview().is_some()
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(doc.buffer.can_undo());
                assert_eq!(std::fs::read(&left).unwrap(), original.as_bytes());
                assert_eq!(std::fs::read(&right).unwrap(), external.as_bytes());
                support::test_click(&crate::chrome::tab_header(&ui, &doc), &[]);
            }
            7 => {
                let doc = source.borrow().clone().unwrap();
                if !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc)) {
                    return glib::ControlFlow::Continue;
                }
                let Some(target) = crate::source_panes::capture(&doc) else {
                    return glib::ControlFlow::Continue;
                };
                support::test_click(&target.view, &["ctrl+z"]);
            }
            8 => {
                let doc = source.borrow().clone().unwrap();
                if buffer_text(&doc.buffer) != original {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    !doc.buffer.can_undo(),
                    "one native Undo restores the source baseline"
                );
                assert_eq!(std::fs::read(&left).unwrap(), original.as_bytes());
                let comparison = state
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .document
                    .borrow()
                    .upgrade()
                    .unwrap();
                support::test_click(&crate::chrome::tab_header(&ui, &comparison), &[]);
            }
            9 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get()
                    || !state.active()
                    || !state.current()
                    || state
                        .model
                        .borrow()
                        .as_ref()
                        .is_none_or(|model| model.comparison.blocks().len() != 1)
                {
                    return glib::ControlFlow::Continue;
                }
                let doc = source.borrow().clone().unwrap();
                crate::source_panes::replace_result(
                    &doc.buffer,
                    &format!("start\n{} old café\nend\n", "👩‍💻 中文 e\u{301} ".repeat(40)),
                );
                support::test_click(&state.view.refresh, &[]);
            }
            10 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                if !aligned(&state.view, 2) {
                    assert!(
                        pause.get().elapsed() < Duration::from_secs(4),
                        "wrapped native columns did not align: {:?}",
                        state.view.texts.each_ref().map(|text| {
                            let buffer = text.buffer();
                            let a = buffer.iter_at_line(1).unwrap();
                            let mut b = a;
                            b.forward_to_line_end();
                            (
                                text.line_yrange(&a),
                                text.line_yrange(&buffer.iter_at_line(2).unwrap()),
                                text.iter_location(&a),
                                text.iter_location(&b),
                            )
                        })
                    );
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state.view.texts[0]
                        .line_yrange(&state.view.texts[0].buffer().iter_at_line(1).unwrap())
                        .1
                        > 44,
                    "fixture really wraps over several visual lines"
                );
                if !support::try_capture(ui.window.upcast_ref(), "compare-wrap-aligned") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&wrap_control(ui.window.upcast_ref()).unwrap(), &[]);
            }
            11 => {
                let state = state.borrow().clone().unwrap();
                if state.view.texts[0].wrap_mode() != gtk::WrapMode::None
                    || !aligned(&state.view, 2)
                {
                    return glib::ControlFlow::Continue;
                }
                let mut next = state.view.texts[0].buffer().iter_at_line(1).unwrap();
                state.view.texts[0].forward_display_line(&mut next);
                assert_eq!(
                    next.line(),
                    2,
                    "Soft Wrap off displays the long row on one visual line"
                );
                ui.window.set_default_size(760, 650);
            }
            12 => {
                if ui.window.width() > 760 {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&wrap_control(ui.window.upcast_ref()).unwrap(), &[]);
            }
            13 => {
                let state = state.borrow().clone().unwrap();
                if state.view.texts[0].wrap_mode() == gtk::WrapMode::None
                    || !aligned(&state.view, 2)
                {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(ui.window.upcast_ref(), "compare-wrap-narrow") {
                    return glib::ControlFlow::Continue;
                }
                let mut lines = (0..40)
                    .map(|index| format!("line{index}"))
                    .collect::<Vec<_>>();
                lines[20] = "old".into();
                crate::source_panes::replace_result(
                    &source.borrow().as_ref().unwrap().buffer,
                    &lines.join("\n"),
                );
                lines[20] = "new".into();
                std::fs::write(&right, lines.join("\n")).unwrap();
                support::test_click(&state.view.refresh, &[]);
            }
            14 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || state.view.folding.test_button(0).is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(state.view.data.borrow().as_ref().unwrap().folds.len(), 2);
                if !support::try_capture(ui.window.upcast_ref(), "compare-folded") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.view.texts[0], &["ctrl+a", "ctrl+c"]);
            }
            15 | 18 => {
                let state = state.borrow().clone().unwrap();
                let clipboard = state.view.texts[0].clipboard();
                let copied = copied.clone();
                glib::spawn_future_local(async move {
                    *copied.borrow_mut() = Some(
                        clipboard
                            .read_text_future()
                            .await
                            .unwrap()
                            .unwrap()
                            .to_string(),
                    );
                });
            }
            16 => {
                let Some(text) = copied.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    text, "line17\nline18\nline19\nold\nline21\nline22\nline23",
                    "native copy excludes hidden rows and fold controls"
                );
                let state = state.borrow().clone().unwrap();
                support::test_click(&state.view.folding.test_button(0).unwrap(), &[]);
            }
            17 => {
                let state = state.borrow().clone().unwrap();
                if state
                    .view
                    .folding
                    .hidden(state.view.data.borrow().as_ref().unwrap())
                    .len()
                    != 1
                {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(ui.window.upcast_ref(), "compare-unfolded") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.view.texts[0], &["ctrl+a", "ctrl+c"]);
            }
            19 => {
                let Some(text) = copied.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    text,
                    (0..24)
                        .map(|index| if index == 20 {
                            "old".into()
                        } else {
                            format!("line{index}")
                        })
                        .collect::<Vec<_>>()
                        .join("\n")
                );
                let state = state.borrow().clone().unwrap();
                support::test_keys(&state.view.texts[0], &["ctrl+Home"]);
            }
            20 => {
                let state = state.borrow().clone().unwrap();
                let Some(button) = state
                    .view
                    .folding
                    .test_button(0)
                    .filter(|button| button.is_visible())
                else {
                    return glib::ControlFlow::Continue;
                };
                support::test_click(&button, &[]);
            }
            21 => {
                let state = state.borrow().clone().unwrap();
                if state
                    .view
                    .folding
                    .hidden(state.view.data.borrow().as_ref().unwrap())
                    .len()
                    != 2
                {
                    return glib::ControlFlow::Continue;
                }
                eprintln!("DIFF_PICKER_SELFTEST PASS native picker/Compare, separate readonly result, no extra source tab, native copy without gutters, complete native transfer preview/apply, one native Undo, no disk writes, automatic refresh after returning, long Unicode row alignment at wide/narrow sizes and native Soft Wrap off/on; native context-fold expand/collapse and copy excludes hidden rows/control labels");
                crate::source_appearance::cleanup_schemes();
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        eprintln!("comparison phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
