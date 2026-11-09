use super::*;
use std::time::{Duration, Instant};

pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let count = std::env::var("FASTRA_DIFF_LARGE_ROWS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(40_000);
    assert!((40_000..=200_000).contains(&count));
    let budget_case = std::env::var_os("FASTRA_DIFF_LARGE_BUDGET").is_some();
    let mut left = String::new();
    let mut right = String::new();
    let mut differences = 0;
    for index in 0..count {
        if index > 0 {
            left.push('\n');
            right.push('\n');
        }
        let line = if count == 200_000 && !budget_case {
            format!("line{index:06} ")
        } else {
            format!("line{index:06} deterministic source with enough words to test real native wrapping ")
        };
        left.push_str(&line);
        left.push_str("old");
        if index % 12 == 6 {
            if count == 40_000 {
                right.push_str(&format!("line{index:06} "));
            } else {
                right.push_str(&line);
            }
            right.push_str("new");
            differences += 1;
        } else {
            right.push_str(&line);
            right.push_str("old");
        }
    }
    let left_path = root.join("large-left.txt");
    let right_path = root.join("large-right.txt");
    std::fs::write(&left_path, &left).unwrap();
    std::fs::write(&right_path, &right).unwrap();
    std::fs::write(root.join("pause-comparison"), b"first worker only").unwrap();
    ui.window.set_default_size(1100, 780);
    let measuring = Rc::new(Cell::new(false));
    let maximum = Rc::new(Cell::new(Duration::ZERO));
    let last = Rc::new(Cell::new(Instant::now()));
    let active = measuring.clone();
    let gap = maximum.clone();
    let prior = last.clone();
    glib::timeout_add_local(Duration::from_millis(10), move || {
        let now = Instant::now();
        let elapsed = now - prior.replace(now);
        if active.get() {
            gap.set(gap.get().max(elapsed));
        }
        glib::ControlFlow::Continue
    });
    let state = RefCell::new(None::<Rc<State>>);
    let phase = Cell::new(0);
    let middle = Cell::new(0usize);
    let started = Instant::now();
    let pause = Cell::new(started);
    glib::timeout_add_local(Duration::from_millis(20), move || {
        assert!(
            started.elapsed() < Duration::from_secs(90)
                && (![6, 7, 9].contains(&phase.get())
                    || pause.get().elapsed() < Duration::from_secs(6)),
            "large comparison phase{}, middle={}, max GTK gap {:?}, state={:?}",
            phase.get(),
            middle.get(),
            maximum.get(),
            state.borrow().as_ref().map(|state| (
                state.busy.get(),
                state.view.selection.selected(),
                state.view.texts[0].visible_rect(),
                state.view.texts[0].height(),
                ui.window.height(),
                state.view.texts[0].buffer().line_count(),
                state
                    .view
                    .data
                    .borrow()
                    .as_ref()
                    .map(|data| data.blocks.last().cloned())
            ))
        );
        if phase.get() != 2 && pause.get().elapsed() < Duration::from_millis(300) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let picker = open(&ui);
                picker.choose(0, sources::Choice::File(left_path.clone()));
                picker.choose(1, sources::Choice::File(right_path.clone()));
                *state.borrow_mut() = Some(picker);
            }
            1 => {
                let state = state.borrow().clone().unwrap();
                if !state.picker.compare.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.picker.compare, &[]);
            }
            2 => {
                let state = state.borrow().clone().unwrap();
                if !state.busy.get()
                    || !state.view.refresh.is_mapped()
                    || state.view.refresh.width() < 30
                    || !root.join("comparison-worker-ready").exists()
                {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.view.refresh, &[]);
            }
            3 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || state.model.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state
                    .view
                    .status
                    .text()
                    .contains(ui.lang.text("abgebrochen", "cancelled")));
                assert!(state
                    .view
                    .transfer
                    .iter()
                    .all(|button| !button.is_sensitive()));
                std::fs::remove_file(root.join("pause-comparison")).unwrap();
            }
            4 => {
                let state = state.borrow().clone().unwrap();
                last.set(Instant::now());
                measuring.set(true);
                support::test_click(&state.view.refresh, &[]);
            }
            5 => {
                let state = state.borrow().clone().unwrap();
                if !state.busy.get() && budget_case {
                    assert!(state.model.borrow().is_none());
                    assert!(!state.view.ready.get());
                    assert!(state
                        .view
                        .status
                        .text()
                        .contains(ui.lang.text("Rechenbudget", "computation budget")));
                    assert!(state
                        .view
                        .transfer
                        .iter()
                        .all(|button| !button.is_sensitive()));
                    assert_eq!(std::fs::read_to_string(&left_path).unwrap(), left);
                    assert_eq!(std::fs::read_to_string(&right_path).unwrap(), right);
                    if !support::try_capture(ui.window.upcast_ref(), "compare-large-budget") {
                        return glib::ControlFlow::Continue;
                    }
                    measuring.set(false);
                    assert!(maximum.get() < Duration::from_millis(350));
                    eprintln!("DIFF_PICKER_SELFTEST PASS large native computation limit: localized visible complete failure, no partial model or transfer, sources unchanged; max GTK heartbeat gap {:?}", maximum.get());
                    crate::source_appearance::cleanup_schemes();
                    std::process::exit(0);
                }
                assert!(
                    state.busy.get() || state.model.borrow().is_some(),
                    "large comparison stopped: {}",
                    state.view.status.text()
                );
                if state.busy.get()
                    || state.model.borrow().is_none()
                    || state.view.alignment.test_pending()
                    || !state.view.previous.is_mapped()
                    || state.view.previous.width() <= 0
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
                    differences
                );
                assert_eq!(
                    state.view.data.borrow().as_ref().unwrap().line_counts,
                    (count, count)
                );
                assert_eq!(state.view.ruler.test_count(), differences.min(160));
                support::test_click(&state.view.previous, &[]);
            }
            6 => {
                let state = state.borrow().clone().unwrap();
                if state.view.selection.selected() as usize != differences - 1
                    || state.view.alignment.test_pending()
                {
                    return glib::ControlFlow::Continue;
                }
                let text = &state.view.texts[0];
                let first = text.line_at_y(text.visible_rect().y()).0.line().max(0) as usize;
                let data = state.view.data.borrow();
                let data = data.as_ref().unwrap();
                let top = data.columns[0].lines[first..]
                    .iter()
                    .find_map(|line| line.number)
                    .unwrap();
                if top < count - 100 {
                    return glib::ControlFlow::Continue;
                }
                let row = data.blocks.last().unwrap().start;
                let geometry = state.view.texts.each_ref().map(|text| {
                    let iter = text.buffer().iter_at_line(row as i32).unwrap();
                    let (y, height) = text.line_yrange(&iter);
                    let scroll = text
                        .ancestor(gtk::ScrolledWindow::static_type())
                        .unwrap()
                        .downcast::<gtk::ScrolledWindow>()
                        .unwrap();
                    (
                        y,
                        height,
                        scroll.vadjustment().value(),
                        scroll.vadjustment().upper(),
                        text.buffer_to_window_coords(gtk::TextWindowType::Widget, 0, y)
                            .1,
                    )
                });
                if geometry[0].4 < 0
                    || geometry[0].4 + geometry[0].1 > text.height()
                    || geometry[0].4.abs_diff(geometry[1].4) > 1
                    || geometry[0].1.abs_diff(geometry[1].1) > 1
                {
                    assert!(
                        pause.get().elapsed() < Duration::from_secs(5),
                        "last changed row must be visible and aligned: {:?}",
                        geometry
                    );
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(ui.window.upcast_ref(), "compare-large-last") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.view.previous, &[]);
            }
            7 => {
                let state = state.borrow().clone().unwrap();
                if state.view.selection.selected() as usize != differences - 2
                    || state.view.alignment.test_pending()
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(state.view.ruler.test_count(), 160);
                let current = state
                    .view
                    .ruler
                    .test_button(differences - 2)
                    .expect("unsampled current difference retained");
                if !current.is_mapped() || current.width() <= 0 || current.height() <= 0 {
                    return glib::ControlFlow::Continue;
                }
                // Die letzten beiden Marker überlappen; der aktuelle muss den echten Klick erhalten.
                support::test_click(&current, &[]);
            }
            8 => {
                let state = state.borrow().clone().unwrap();
                assert_eq!(
                    state.view.selection.selected() as usize,
                    differences - 2,
                    "overlapping current marker remains clickable"
                );
                let (index, button) = state.view.ruler.test_middle();
                middle.set(index);
                // In der dichten Übersicht liegt die Mitte unter dem nächsten Marker.
                support::test_click_at(&button, button.width() as f32 / 2., 0.5, &[]);
            }
            9 => {
                let state = state.borrow().clone().unwrap();
                if state.view.selection.selected() as usize != middle.get()
                    || state.view.alignment.test_pending()
                {
                    return glib::ControlFlow::Continue;
                }
                let row = state.view.data.borrow().as_ref().unwrap().blocks[middle.get()].start;
                let geometry = state.view.texts.each_ref().map(|text| {
                    let iter = text.buffer().iter_at_line(row as i32).unwrap();
                    let (y, height) = text.line_yrange(&iter);
                    (
                        text.buffer_to_window_coords(gtk::TextWindowType::Widget, 0, y)
                            .1,
                        height,
                    )
                });
                if geometry[0].0 < 0
                    || geometry[0].0 + geometry[0].1 > state.view.texts[0].height()
                    || geometry[0].0.abs_diff(geometry[1].0) > 1
                    || geometry[0].1.abs_diff(geometry[1].1) > 1
                {
                    assert!(
                        pause.get().elapsed() < Duration::from_secs(5),
                        "middle changed row must be visible and aligned: {:?}",
                        geometry
                    );
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(ui.window.upcast_ref(), "compare-large-middle") {
                    return glib::ControlFlow::Continue;
                }
                measuring.set(false);
                assert!(
                    maximum.get() < Duration::from_millis(350),
                    "GTK heartbeat stalled {:?}",
                    maximum.get()
                );
                assert_eq!(std::fs::read_to_string(&left_path).unwrap(), left);
                assert_eq!(std::fs::read_to_string(&right_path).unwrap(), right);
                eprintln!("DIFF_PICKER_SELFTEST PASS large native {count} lines/{} and {} bytes, {differences} complete blocks, native Cancel/Recalculate, folded virtual controls, last and middle source navigation with actual aligned visible rows, 160 reused overview markers with retained unsampled current and real click over overlapping last marker; max GTK heartbeat gap {:?}; no input writes",left.len(),right.len(),maximum.get());
                crate::source_appearance::cleanup_schemes();
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        eprintln!("large comparison phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
