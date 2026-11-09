use super::*;
use std::time::{Duration, Instant};

pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let left = root.join("guard-left.txt");
    let right = root.join("guard-right.txt");
    let original = "x old\n";
    std::fs::write(&left, original).unwrap();
    std::fs::write(&right, "x new\n").unwrap();
    ui.load_path(left.clone());
    let source = RefCell::new(None::<Rc<crate::Document>>);
    let state = RefCell::new(None::<Rc<State>>);
    let phase = Cell::new(0);
    let beats = Cell::new(0u32);
    let paused_beats = Cell::new(0u32);
    let started = Instant::now();
    let pause = Cell::new(started);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        beats.set(beats.get() + 1);
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "comparison guard phase{}",
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
                support::test_click(&state.picker.compare, &[]);
            }
            2 | 7 | 12 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || !state.view.transfer[0].is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.view.transfer[0], &[]);
            }
            3 => {
                let Some(_) = transfer::test_preview().filter(|p| p.apply.is_sensitive()) else {
                    return glib::ControlFlow::Continue;
                };
                crate::source_panes::replace_result(
                    &source.borrow().as_ref().unwrap().buffer,
                    "x other\n",
                );
            }
            4 | 9 => {
                let preview = transfer::test_preview().unwrap();
                support::test_click(&preview.apply, &[]);
            }
            5 => {
                let preview = transfer::test_preview().unwrap();
                if preview.apply.is_sensitive()
                    || !preview
                        .view
                        .status
                        .text()
                        .contains(ui.lang.text("Vergleich geändert", "Comparison changed"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    buffer_text(&source.borrow().as_ref().unwrap().buffer),
                    "x other\n"
                );
                assert_eq!(std::fs::read_to_string(&left).unwrap(), original);
                if !support::try_capture(&preview.window, "compare-stale-document") {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&preview.window, &["Escape"]);
            }
            6 => {
                if transfer::test_preview().is_some() {
                    return glib::ControlFlow::Continue;
                }
                crate::source_panes::replace_result(
                    &source.borrow().as_ref().unwrap().buffer,
                    original,
                );
                let state = state.borrow().clone().unwrap();
                support::test_click(&state.view.refresh, &[]);
            }
            8 => {
                let Some(_) = transfer::test_preview().filter(|p| p.apply.is_sensitive()) else {
                    return glib::ControlFlow::Continue;
                };
                let modified = std::fs::metadata(&right).unwrap().modified().unwrap();
                std::fs::write(&right, "x NEW\n").unwrap();
                std::fs::File::open(&right)
                    .unwrap()
                    .set_times(std::fs::FileTimes::new().set_modified(modified))
                    .unwrap();
                assert_eq!(
                    std::fs::metadata(&right).unwrap().modified().unwrap(),
                    modified,
                    "mtime restored; ctime still protects the preview"
                );
            }
            10 => {
                let preview = transfer::test_preview().unwrap();
                if preview.apply.is_sensitive()
                    || !preview.view.status.text().contains(ui.lang.text(
                        "Vergleichsdatei hat sich geändert",
                        "comparison file changed",
                    ))
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    buffer_text(&source.borrow().as_ref().unwrap().buffer),
                    original
                );
                assert_eq!(std::fs::read_to_string(&left).unwrap(), original);
                if !support::try_capture(&preview.window, "compare-stale-file") {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&preview.window, &["Escape"]);
            }
            11 => {
                if transfer::test_preview().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let state = state.borrow().clone().unwrap();
                support::test_click(&state.view.refresh, &[]);
            }
            13 => {
                let Some(preview) = transfer::test_preview().filter(|p| p.apply.is_sensitive())
                else {
                    return glib::ControlFlow::Continue;
                };
                support::test_keys(&preview.window, &["Escape"]);
            }
            14 => {
                if transfer::test_preview().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let state = state.borrow().clone().unwrap();
                if !state.view.transfer[0].is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                std::fs::write(root.join("pause-transfer"), b"retain the comparison").unwrap();
                support::test_click(&state.view.transfer[0], &[]);
            }
            15 => {
                let state = state.borrow().clone().unwrap();
                if !state.busy.get() || !root.join("transfer-worker-ready").exists() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.preparing.get());
                support::test_click(&state.view.refresh, &[]);
            }
            16 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || !state.view.transfer[0].is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state.model.borrow().is_some(),
                    "cancelling only preparation retains the completed comparison"
                );
                assert!(state.view.status.text().contains(
                    ui.lang
                        .text("Vergleich bleibt erhalten", "comparison is retained")
                ));
                assert!(transfer::test_preview().is_none());
                std::fs::remove_file(root.join("pause-transfer")).unwrap();
            }
            17 => {
                if transfer::test_preview().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let doc = source.borrow().clone().unwrap();
                assert_eq!(buffer_text(&doc.buffer), original);
                for _ in 0..4 {
                    if doc.buffer.can_undo() {
                        doc.buffer.undo();
                    }
                }
                assert_eq!(buffer_text(&doc.buffer), original);
                assert!(!doc.buffer.is_modified());
            }
            18 => {
                let state = state.borrow().clone().unwrap();
                support::test_click(&state.view.refresh, &[]);
            }
            19 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || !state.view.transfer[0].is_sensitive() { return glib::ControlFlow::Continue; }
                support::test_click(&state.view.transfer[0], &[]);
            }
            20 => {
                let Some(preview) = transfer::test_preview().filter(|p| p.apply.is_sensitive()) else { return glib::ControlFlow::Continue; };
                std::fs::write(root.join("pause-apply"), b"hold after full verification").unwrap();
                paused_beats.set(beats.get());
                support::test_click(&preview.apply, &[]);
            }
            21 => {
                if !root.join("apply-worker-ready").exists() { return glib::ControlFlow::Continue; }
                assert!(transfer::test_preview().unwrap().busy.get());
                assert!(beats.get() > paused_beats.get() + 2, "GTK continues dispatching while the verified worker is held");
                let modified = std::fs::metadata(&right).unwrap().modified().unwrap();
                std::fs::write(&right, "x NOW\n").unwrap();
                std::fs::File::open(&right).unwrap().set_times(std::fs::FileTimes::new().set_modified(modified)).unwrap();
                std::fs::remove_file(root.join("pause-apply")).unwrap();
            }
            22 => {
                let preview = transfer::test_preview().unwrap();
                if preview.busy.get() { return glib::ControlFlow::Continue; }
                assert!(preview.view.status.text().contains(ui.lang.text("Vergleichsdatei hat sich geändert", "comparison file changed")));
                assert_eq!(buffer_text(&source.borrow().as_ref().unwrap().buffer), original);
                assert_eq!(std::fs::read_to_string(&left).unwrap(), original);
                if !support::try_capture(&preview.window, "compare-stale-after-worker") { return glib::ControlFlow::Continue; }
                support::test_keys(&preview.window, &["Escape"]);
            }
            23 => {
                let doc = source.borrow().clone().unwrap();
                let header = chrome::tab_header(&ui, &doc);
                support::test_click(
                    &header
                        .last_child()
                        .unwrap()
                        .downcast::<gtk::Button>()
                        .unwrap(),
                    &[],
                );
            }
            24 => {
                let state = state.borrow().clone().unwrap();
                if ui.documents.borrow().len() != 1 || state.view.transfer[0].is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!state.current());
                ui.load_path(left.clone());
            }
            25 => {
                if !ui
                    .active()
                    .is_some_and(|doc| doc.disk_path().as_ref() == Some(&left))
                {
                    return glib::ControlFlow::Continue;
                }
                let state = state.borrow().clone().unwrap();
                let result = state.document.borrow().upgrade().unwrap();
                support::test_click(&chrome::tab_header(&ui, &result), &[]);
            }
            _ => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || !state.active() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    !state.current(),
                    "new document at the same path cannot replace the old source identity"
                );
                assert!(!state.view.transfer[0].is_sensitive());
                assert_eq!(std::fs::read_to_string(&left).unwrap(), original);
                assert_eq!(std::fs::read_to_string(&right).unwrap(), "x NOW\n");
                eprintln!("DIFF_PICKER_SELFTEST PASS native Apply rejects changed document and same-size external file with restored mtime; Cancel writes nothing; cancelling preparation retains the complete comparison; post-worker same-size/mtime-restored file change rejected while GTK remains responsive; native source close disables transfers; same-path reopened document never rebinds old comparison");
                crate::source_appearance::cleanup_schemes();
                std::process::exit(0);
            }
        }
        eprintln!("comparison guard phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
