use super::*;
use gtk::glib;
use std::{
    ffi::OsString,
    os::unix::{ffi::OsStringExt, fs::symlink},
    time::{Duration, Instant},
};
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let fixture = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let left = fixture.join(OsString::from_vec(b"left-\xff".to_vec()));
    let right = fixture.join("right-雪");
    for root in [&left, &right] {
        std::fs::create_dir_all(root).unwrap();
        for i in 0..110 {
            std::fs::write(root.join(format!("same-{i:03}.txt")), b"same\n").unwrap();
        }
    }
    let pair = PathBuf::from(OsString::from_vec(b"pair-\xff.txt".to_vec()));
    let original = "start\r\ncat café 🙂\r\nend\r\n";
    let fresh = "start\r\nNEW RIGHT café 🙂\r\nend\r\n";
    std::fs::write(left.join(&pair), original).unwrap();
    std::fs::write(right.join(&pair), b"old right\n").unwrap();
    for (index, path) in [left.join(&pair), right.join(&pair)].iter().enumerate() {
        std::fs::hard_link(path, fixture.join(format!("pair-alias-{index}"))).unwrap();
        assert!(matches!(fastra_io::Snapshot::read(path, &fastra_core::Cancellation::default()), Err(fastra_io::Error::UnsupportedMetadata)));
    }
    std::fs::write(left.join("left-only.txt"), b"left\n").unwrap();
    std::fs::write(right.join("right-only.txt"), b"right\n").unwrap();
    std::fs::write(left.join("binary.bin"), [0, 1, 2]).unwrap();
    std::fs::write(right.join("binary.bin"), [0, 2, 3]).unwrap();
    std::fs::write(left.join(".hidden"), b"hidden").unwrap();
    symlink("/outside-fastra", left.join("link")).unwrap();
    let state = open(&ui);
    support::test_size(&state.window);
    state.set_root(0, left.clone());
    state.set_root(1, right.clone());
    state.calculate.emit_clicked();
    let phase = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    let baseline = ui.documents.borrow().len();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(40),
            "folder compare phase {} {}",
            phase.get(),
            state.status.text()
        );
        if state.busy.get() {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let model = state.model.borrow();
                let Some(model) = model.as_ref() else {
                    return glib::ControlFlow::Continue;
                };
                if state.visible.borrow().len() != model.rows.len() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!model.complete());
                assert!(model.rows.iter().any(|r| r.kind == ContentKind::Special));
                assert!(!model
                    .rows
                    .iter()
                    .any(|r| r.relative_path == std::path::Path::new(".hidden")));
                assert!(state.next.is_sensitive());
                assert_eq!(state.list.observe_children().n_items(), 100);
                state.next.emit_clicked();
                assert!(state.list.observe_children().n_items() < 100);
                state.previous.emit_clicked();
                state.filters.set_selected(1);
                pause.set(Instant::now());
                phase.set(1);
            }
            1 => {
                if pause.get().elapsed() < Duration::from_millis(250)
                    || state.visible.borrow().len() != 2
                {
                    return glib::ControlFlow::Continue;
                }
                state.query.set_text("pair-");
                pause.set(Instant::now());
                phase.set(2);
            }
            2 => {
                if pause.get().elapsed() < Duration::from_millis(400)
                    || state.visible.borrow().len() != 1
                {
                    return glib::ControlFlow::Continue;
                }
                state.list.select_row(state.list.row_at_index(0).as_ref());
                assert!(state.pair.is_sensitive());
                phase.set(20);
                pause.set(Instant::now());
            }
            20 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                support::capture(&state.window, "folder-comparison");
                std::fs::write(right.join(&pair), fresh).unwrap();
                state.pair.emit_clicked();
                phase.set(3);
            }
            3 => {
                let Some(comparison) = state.last_pair.borrow().as_ref().and_then(Weak::upgrade)
                else {
                    return glib::ControlFlow::Continue;
                };
                let Some([left_source, right_source]) = comparison.test_pair_sources() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(left_source, (left.join(&pair), original.into()));
                assert_eq!(right_source, (right.join(&pair), fresh.into()));
                assert_eq!(ui.documents.borrow().len(), baseline + 1);
                let doc = ui.active().unwrap();
                assert!(doc.is_read_only());
                assert!(doc.comparison.borrow().as_ref().is_some_and(|state| Rc::ptr_eq(state, &comparison)));
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                assert_eq!(
                    std::fs::read(left.join(&pair)).unwrap(),
                    original.as_bytes()
                );
                assert_eq!(std::fs::read(right.join(&pair)).unwrap(), fresh.as_bytes());
                phase.set(30);
                pause.set(Instant::now());
            }
            30 => {
                if pause.get().elapsed() < Duration::from_millis(250) {
                    return glib::ControlFlow::Continue;
                }
                support::capture(ui.window.upcast_ref(), "folder-pair-fresh");
                state.calculate.emit_clicked();
                state.set_root(1, left.clone());
                phase.set(4);
                pause.set(Instant::now());
            }
            4 => {
                if pause.get().elapsed() < Duration::from_millis(500) {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state.model.borrow().is_none(),
                    "late old root result must not reappear"
                );
                assert!(!state.pair.is_sensitive());
                state.calculate.emit_clicked();
                state.invalidate();
                phase.set(5);
                pause.set(Instant::now());
            }
            5 => {
                if pause.get().elapsed() < Duration::from_millis(400) {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.model.borrow().is_none());
                println!("FASTRA folder comparison selftest PASS: raw paths, byte/status filters, pagination, fresh pair, original files unchanged, root/cancel stale guards");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
