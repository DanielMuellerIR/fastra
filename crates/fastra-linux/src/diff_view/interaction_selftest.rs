use super::*;
use std::time::{Duration, Instant};
fn fraction(view: &view::View) -> f64 {
    let pane = &view.columns.widget;
    f64::from(pane.start_child().unwrap().width())
        / f64::from(pane.start_child().unwrap().width() + pane.end_child().unwrap().width())
}
fn check_wrap_geometry(view: &view::View, wrapped: bool) {
    let data = view.data.borrow();
    let data = data.as_ref().unwrap();
    let index = data.columns[1]
        .lines
        .iter()
        .position(|line| line.number == Some(3811))
        .unwrap();
    let heights: [i32; 2] = std::array::from_fn(|side| {
        let line = &data.columns[side].lines[index];
        let text = &view.texts[side];
        let mut iter = text.buffer().iter_at_offset(line.display.start as i32);
        let logical = iter.line();
        // Offscreen liefert line_yrange zunächst eine Schätzung. Wie im
        // Produktlayout zuerst die tatsächlichen Textfragmente anfordern.
        let _ = text.iter_location(&iter);
        let (top, height) = text.line_yrange(&iter);
        let mut count = 0;
        let mut bottom = top;
        loop {
            let rect = text.iter_location(&iter);
            assert!(rect.height() > 0 && rect.y() >= bottom,
                "display fragments must occupy distinct vertical space: side={side} fragment={count} rect={rect:?} previous-bottom={bottom}");
            bottom = rect.y() + rect.height();
            assert!(bottom <= top + height, "wrapped fragment clipped by logical row: side={side} bottom={bottom} row={top}+{height}");
            count += 1;
            assert!(count < 1024);
            if !text.forward_display_line(&mut iter)
                || iter.line() != logical
                || iter.offset() >= line.display.end as i32
            {
                break;
            }
        }
        if side == 1 {
            assert!(
                if wrapped { count > 2 } else { count == 1 },
                "fixture must really change display-line count: wrapped={wrapped} count={count}"
            );
        }
        let next = &data.columns[side].lines[index + 1];
        let next = text.buffer().iter_at_offset(next.display.start as i32);
        assert!(
            text.line_yrange(&next).0 >= bottom,
            "next logical row overlaps wrapped text"
        );
        height
    });
    assert!(
        (heights[0] - heights[1]).abs() <= 1,
        "comparison sides keep the same complete row height: {heights:?}"
    );
    eprintln!("PASS native diff fragment geometry wrapped={wrapped} heights={heights:?}");
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
fn first_visible_number(view: &view::View) -> Option<usize> {
    let text = &view.texts[0];
    let rect = text.visible_rect();
    let (mut iter, _) = text.line_at_y(rect.y());
    let data = view.data.borrow();
    let data = data.as_ref()?;
    loop {
        let (y, height) = text.line_yrange(&iter);
        if y >= rect.y() + rect.height() {
            return None;
        }
        if height > 0 {
            if let Some(number) = data.columns[0]
                .lines
                .get(iter.line().max(0) as usize)?
                .number
            {
                return Some(number);
            }
        }
        if !iter.forward_visible_line() {
            return None;
        }
    }
}
fn visible_list_label(widget: &gtk::Widget, root: &gtk::Widget, needle: &str) -> bool {
    if let Some(label) = widget
        .downcast_ref::<gtk::Label>()
        .filter(|label| label.is_mapped() && label.text().contains(needle))
    {
        if label.compute_bounds(root).is_some_and(|bounds| {
            bounds.y() < root.height() as f32
                && bounds.y() + bounds.height() > 0.
                && bounds.x() < root.width() as f32
                && bounds.x() + bounds.width() > 0.
        }) {
            return true;
        }
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if visible_list_label(&widget, root, needle) {
            return true;
        }
        child = widget.next_sibling();
    }
    false
}
fn tab_button(widget: &gtk::Widget, title: &str) -> Option<gtk::Button> {
    if let Some(button) = widget.downcast_ref::<gtk::Button>().filter(|button| {
        button.is_mapped()
            && button.width() > 0
            && button.has_css_class("tab-select")
            && button
                .child()
                .and_downcast::<gtk::Label>()
                .is_some_and(|label| label.text() == title)
    }) {
        return Some(button.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(button) = tab_button(&widget, title) {
            return Some(button);
        }
        child = widget.next_sibling();
    }
    None
}
fn stored_ratio() -> Option<u16> {
    let root = PathBuf::from(std::env::var_os("XDG_CONFIG_HOME")?);
    fastra_workflow::comparison_preferences::Store::open(&root)
        .ok()?
        .load()
        .ok()
        .map(|settings| settings.split_ratio)
}
fn stored_wrap() -> Option<bool> {
    let root = PathBuf::from(std::env::var_os("XDG_CONFIG_HOME")?);
    let data = std::fs::read(root.join("fastra-editor/profiles.json")).ok()?;
    serde_json::from_slice::<serde_json::Value>(&data).ok()?["formats"]["file-comparison"]["wrap"]
        .as_bool()
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let restoring = std::env::var("FASTRA_DIFF_INTERACTION_PHASE").as_deref() == Ok("restore");
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let left = root.join("interaction-left.txt");
    let right = root.join("interaction-right.txt");
    let mut source = String::new();
    let mut other = String::new();
    for line in 0..4000 {
        if line > 0 {
            source.push('\n');
            other.push('\n');
        }
        source.push_str(&format!("source line {line}"));
        other.push_str(&if line % 200 == 10 {
            if line == 3810 {
                format!("changed line {line} {}", "unwrapped ".repeat(80))
            } else {
                format!("changed line {line}")
            }
        } else {
            format!("source line {line}")
        });
    }
    std::fs::write(&left, &source).unwrap();
    std::fs::write(&right, &other).unwrap();
    ui.window.set_default_size(1100, 780);
    ui.load_path(left.clone());
    let original = RefCell::new(None::<Rc<crate::Document>>);
    let states = RefCell::new(Vec::<Rc<State>>::new());
    let preview = RefCell::new(None::<Rc<transfer::Preview>>);
    let drag_fraction = Cell::new(0.);
    let phase = Cell::new(0);
    let overview_phase = Cell::new(0);
    let zoom_phase = Cell::new(0);
    let original_font_width = Cell::new(0);
    let preview_resized = Cell::new(false);
    let started = Instant::now();
    let pause = Cell::new(started);
    glib::timeout_add_local(Duration::from_millis(25), move || {
        assert!(
            started.elapsed() < Duration::from_secs(40)
                && (![7, 12, 17].contains(&phase.get())
                    || pause.get().elapsed() < Duration::from_secs(3)),
            "comparison interaction phase{} overview{}: (fraction,selected,visible,rect)={:?}",
            phase.get(),
            overview_phase.get(),
            states
                .borrow()
                .iter()
                .map(|state| (
                    fraction(&state.view),
                    state.view.selection.selected(),
                    first_visible_number(&state.view),
                    state.view.texts[0].visible_rect()
                ))
                .collect::<Vec<_>>()
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
                *original.borrow_mut() = Some(doc);
                let state = open(&ui);
                state.choose(1, sources::Choice::File(right.clone()));
                states.borrow_mut().push(state);
            }
            1 => {
                let state = states.borrow()[0].clone();
                if !state.picker.compare.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.picker.compare, &[]);
            }
            2 => {
                let state = states.borrow()[0].clone();
                if state.busy.get()
                    || state.view.alignment.test_pending()
                    || !state.view.ready.get()
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    state
                        .model
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .comparison
                        .blocks()
                        .len(),
                    20
                );
                assert!(
                    buffer_text(&original.borrow().as_ref().unwrap().buffer) == source,
                    "original source remains unchanged"
                );
                if restoring {
                    if state.view.texts[0].wrap_mode() != gtk::WrapMode::None {
                        return glib::ControlFlow::Continue;
                    }
                    if (fraction(&state.view) - 0.65).abs() >= 0.01 {
                        assert!(pause.get().elapsed() < Duration::from_secs(3), "restore split did not settle: fraction={}, stored={:?}, width={}, position={}", fraction(&state.view), stored_ratio(), state.view.columns.widget.width(), state.view.columns.widget.position());
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(
                        source_view(original.borrow().as_ref().unwrap().container.upcast_ref())
                            .unwrap()
                            .wrap_mode(),
                        gtk::WrapMode::WordChar
                    );
                    eprintln!("DIFF_INTERACTION_SELFTEST PASS fresh process restores65% split and independent comparison wrap; source text and normal source wrap retained");
                    crate::source_appearance::cleanup_schemes();
                    std::process::exit(0);
                }
                check_wrap_geometry(&state.view, true);
                assert!((fraction(&state.view) - 0.5).abs() < 0.01);
                let pane = &state.view.columns.widget;
                support::test_drag_at(pane, pane.position() as f32 + 3., 80., 220, 0);
            }
            3 => {
                let state = states.borrow()[0].clone();
                if fraction(&state.view) < 0.68 {
                    return glib::ControlFlow::Continue;
                }
                drag_fraction.set(fraction(&state.view));
                if stored_ratio().is_none_or(|ratio| {
                    (f64::from(ratio) / 10000. - drag_fraction.get()).abs() > 0.01
                }) {
                    return glib::ControlFlow::Continue;
                }
                ui.window.set_default_size(760, 780);
            }
            4 => {
                let state = states.borrow()[0].clone();
                if ui.window.width() > 780 || state.view.alignment.test_pending() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    (fraction(&state.view) - drag_fraction.get()).abs() < 0.01,
                    "resize preserves ratio"
                );
                check_wrap_geometry(&state.view, true);
                if zoom_phase.get() == 0 {
                    original_font_width.set(
                        state.view.texts[0]
                            .create_pango_layout(Some("MMMMMMMMMM"))
                            .size()
                            .0,
                    );
                    let app = ui.window.application().unwrap();
                    app.activate_action("ui-larger", None);
                    app.activate_action("ui-larger", None);
                    zoom_phase.set(1);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                if zoom_phase.get() == 1 {
                    assert!(
                        state.view.texts[0]
                            .create_pango_layout(Some("MMMMMMMMMM"))
                            .size()
                            .0
                            > original_font_width.get()
                    );
                    assert!(support::try_capture(
                        ui.window.upcast_ref(),
                        "compare-ui-zoom-wrap"
                    ));
                    ui.window
                        .application()
                        .unwrap()
                        .activate_action("ui-original", None);
                    zoom_phase.set(2);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    state.view.texts[0]
                        .create_pango_layout(Some("MMMMMMMMMM"))
                        .size()
                        .0,
                    original_font_width.get()
                );
                if !support::try_capture(ui.window.upcast_ref(), "compare-divider-narrow") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.view.transfer[0], &[]);
            }
            5 => {
                let Some(value) = transfer::test_preview() else {
                    return glib::ControlFlow::Continue;
                };
                if !value.view.ready.get() || value.view.alignment.test_pending() {
                    return glib::ControlFlow::Continue;
                }
                if !preview_resized.replace(true) {
                    value.window.set_default_size(620, 440);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                if value.window.width() > 640 || value.window.height() > 460 {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    value.view.viewport.height() >= 120,
                    "minimum preview retains a usable comparison viewport"
                );
                assert!((fraction(&value.view) - drag_fraction.get()).abs() < 0.01);
                if !support::try_capture(&value.window, "compare-preview-minimum") {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&value.window, &["Escape"]);
                *preview.borrow_mut() = Some(value);
            }
            6 => {
                if preview.borrow().as_ref().unwrap().window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                preview.borrow_mut().take();
                let state = states.borrow()[0].clone();
                let pane = &state.view.columns.widget;
                support::test_double_click_at(pane, pane.position() as f32, 80.);
            }
            7 => {
                let state = states.borrow()[0].clone();
                if (fraction(&state.view) - 0.5).abs() > 0.01 {
                    return glib::ControlFlow::Continue;
                }
                support::test_click_at(&state.view.texts[0], 60., 20., &["F8", "Down"]);
            }
            8 => {
                let state = states.borrow()[0].clone();
                if (fraction(&state.view) - 0.55).abs() > 0.01 {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&state.view.columns.widget, &["Home"]);
            }
            9 => {
                let state = states.borrow()[0].clone();
                if (fraction(&state.view) - 0.5).abs() > 0.01 {
                    return glib::ControlFlow::Continue;
                }
                support::test_click_at(&state.view.texts[0], 60., 20., &[]);
            }
            10 => {
                support::test_keys(&states.borrow()[0].view.texts[0], &["alt+Down"]);
            }
            11 => {
                let state = states.borrow()[0].clone();
                if state.view.selection.selected() != 1 {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&state.view.texts[0], &["alt+Up", "alt+Up"]);
            }
            12 => {
                let state = states.borrow()[0].clone();
                if overview_phase.get() == 0 && state.view.selection.selected() != 19 {
                    return glib::ControlFlow::Continue;
                }
                if overview_phase.get() == 0
                    && first_visible_number(&state.view).is_none_or(|number| number < 1000)
                {
                    return glib::ControlFlow::Continue;
                }
                if overview_phase.get() == 0
                    && !visible_list_label(
                        state.view.list.upcast_ref(),
                        state.view.list.upcast_ref(),
                        "3811",
                    )
                {
                    return glib::ControlFlow::Continue;
                }
                match overview_phase.get() {
                    0 => {
                        assert_eq!(state.view.ruler.test_count(), 20);
                        assert_eq!(state.view.ruler.widget.width(), 20);
                        assert!(state.view.vertical.is_mapped());
                        assert!(state.view.columns.widget.width() >= 919);
                        assert!(state.view.viewport.hscrollbar().is_mapped());
                        for text in &state.view.texts {
                            let scroll = text
                                .ancestor(gtk::ScrolledWindow::static_type())
                                .unwrap()
                                .downcast::<gtk::ScrolledWindow>()
                                .unwrap();
                            assert!(
                                !scroll.vscrollbar().is_mapped(),
                                "columns share one external vertical scrollbar"
                            );
                        }
                        support::test_click(&state.view.ruler.test_button(0).unwrap(), &[]);
                        overview_phase.set(1);
                        pause.set(Instant::now());
                        return glib::ControlFlow::Continue;
                    }
                    1 => {
                        if pause.get().elapsed() < Duration::from_millis(450) {
                            return glib::ControlFlow::Continue;
                        }
                        if state.view.selection.selected() != 0
                            || first_visible_number(&state.view).is_none_or(|n| n > 100)
                        {
                            return glib::ControlFlow::Continue;
                        }
                        support::test_click_at(&state.view.texts[0], 60., 20., &["ctrl+End"]);
                        overview_phase.set(2);
                        pause.set(Instant::now());
                        return glib::ControlFlow::Continue;
                    }
                    2 => {
                        if state.view.selection.selected() == 0
                            || first_visible_number(&state.view).is_none_or(|n| n < 3500)
                        {
                            return glib::ControlFlow::Continue;
                        }
                        let current_line = (state.view.selection.selected() * 200 + 11).to_string();
                        if !visible_list_label(
                            state.view.list.upcast_ref(),
                            state.view.list.upcast_ref(),
                            &current_line,
                        ) {
                            return glib::ControlFlow::Continue;
                        }
                        let bar = state.view.viewport.hscrollbar();
                        support::test_drag_at(
                            &bar,
                            bar.width() as f32 / 3.,
                            bar.height() as f32 / 2.,
                            210,
                            0,
                        );
                        overview_phase.set(3);
                        pause.set(Instant::now());
                        return glib::ControlFlow::Continue;
                    }
                    _ => {
                        if state.view.viewport.hadjustment().value() < 100. {
                            return glib::ControlFlow::Continue;
                        }
                        if !support::try_capture(ui.window.upcast_ref(), "compare-shared-scroll") {
                            return glib::ControlFlow::Continue;
                        }
                    }
                }
                check_wrap_geometry(&state.view, true);
                let wrap = super::selftest::wrap_control(ui.window.upcast_ref()).unwrap();
                assert!(wrap.is_active());
                support::test_click(&wrap, &[]);
            }
            13 => {
                let state = states.borrow()[0].clone();
                if state.view.texts[0].wrap_mode() != gtk::WrapMode::None
                    || state.view.alignment.test_pending()
                    || stored_wrap() != Some(false)
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    source_view(original.borrow().as_ref().unwrap().container.upcast_ref())
                        .unwrap()
                        .wrap_mode(),
                    gtk::WrapMode::WordChar
                );
                check_wrap_geometry(&state.view, false);
                let scroll = state.view.texts[1]
                    .ancestor(gtk::ScrolledWindow::static_type())
                    .unwrap()
                    .downcast::<gtk::ScrolledWindow>()
                    .unwrap();
                assert!(
                    !scroll.hscrollbar().is_mapped(),
                    "unwrapped comparison is clipped without an extra horizontal bar"
                );
                assert!(
                    scroll.hadjustment().upper() > scroll.hadjustment().page_size(),
                    "long native line exceeds the viewport"
                );
                assert!(
                    ui.window.width() < 800,
                    "unwrapped native text does not widen the window"
                );
                let next = open(&ui);
                next.choose(
                    0,
                    sources::Choice::from_doc(original.borrow().as_ref().unwrap()),
                );
                next.choose(1, sources::Choice::File(right.clone()));
                states.borrow_mut().push(next);
            }
            14 => {
                let next = states.borrow()[1].clone();
                if !next.picker.compare.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&next.picker.compare, &[]);
            }
            15 => {
                let next = states.borrow()[1].clone();
                if next.busy.get()
                    || !next.view.ready.get()
                    || next.view.texts[0].wrap_mode() != gtk::WrapMode::None
                {
                    return glib::ControlFlow::Continue;
                }
                let ratio = fraction(&next.view);
                if !ratio.is_finite() || (ratio - 0.5).abs() >= 0.01 {
                    assert!(pause.get().elapsed() < Duration::from_secs(3),
                        "second comparison split did not settle: ratio={ratio}, width={}, stored={:?}",
                        next.view.columns.widget.width(), stored_ratio());
                    return glib::ControlFlow::Continue;
                }
                assert!((ratio - 0.5).abs() < 0.01);
                support::test_click_at(
                    &next.view.texts[0],
                    60.,
                    20.,
                    &["F8", "Right", "Right", "Right"],
                );
            }
            16 => {
                let all = states.borrow();
                if (fraction(&all[1].view) - 0.65).abs() > 0.01
                    || stored_ratio().is_none_or(|ratio| ratio.abs_diff(6500) > 100)
                {
                    return glib::ControlFlow::Continue;
                }
                let doc = all[0].document.borrow().upgrade().unwrap();
                let button = tab_button(ui.window.upcast_ref(), &doc.label.text()).unwrap();
                assert!(button.is_mapped() && button.width() > 0);
                if !support::try_capture(ui.window.upcast_ref(), "compare-before-tab-return") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&button, &[]);
            }
            17 => {
                let first = states.borrow()[0].clone();
                let doc = first.document.borrow().upgrade().unwrap();
                if !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
                    || !first.view.root.is_mapped()
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    (fraction(&first.view) - 0.65).abs() < 0.01,
                    "reactivated comparison uses the shared split"
                );
                assert_eq!(std::fs::read_to_string(&left).unwrap(), source);
                assert_eq!(std::fs::read_to_string(&right).unwrap(), other);
                if !support::try_capture(ui.window.upcast_ref(), "compare-divider-shared") {
                    return glib::ControlFlow::Continue;
                }
                eprintln!("DIFF_INTERACTION_SELFTEST PASS native9px divider drag, proportional resize, shared preview and multiple results, native double-click reset, F8/Right5%/Home, AltDown/AltUp, native ruler click and current follows source scroll, one vertical scrollbar, native shared horizontal drag, independent persisted comparison wrap, no source writes");
                crate::source_appearance::cleanup_schemes();
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        eprintln!("comparison interaction phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
