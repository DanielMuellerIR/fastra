use super::*;
use std::{
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
fn drag(source: String, widget: &gtk::Widget) {
    let native = widget.native().unwrap();
    let point = widget
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(widget.width() as f32 / 2., widget.height() as f32 / 2.),
        )
        .unwrap();
    let (x, y) = native.surface_transform();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let target = unsafe { xid(native.surface().unwrap().as_ptr().cast()) }.to_string();
    std::thread::spawn(move || {
        let activation = if std::env::var("FASTRA_TEST_WM").as_deref() == Ok("openbox") {
            "windowactivate"
        } else {
            "windowfocus"
        };
        assert!(Command::new("timeout")
            .args([
                "8s",
                "xdotool",
                activation,
                "--sync",
                &source,
                "windowmove",
                "--sync",
                &source,
                "1400",
                "100",
                "sleep",
                "0.2",
                "mousemove",
                "--window",
                &source,
                "160",
                "60",
                "mousedown",
                "1",
                "sleep",
                "0.2",
                "mousemove_relative",
                "--",
                "20",
                "0",
                "sleep",
                "0.2",
                "windowraise",
                &target,
                "mousemove",
                "--window",
                &target,
                &(point.x() as f64 - x).round().to_string(),
                &(point.y() as f64 - y).round().to_string(),
                "sleep",
                "0.1",
                "mousemove_relative",
                "--",
                "1",
                "1",
                "sleep",
                "0.1",
                "mousemove_relative",
                "--",
                "-1",
                "-1",
                "sleep",
                "0.4"
            ])
            .status()
            .unwrap()
            .success());
        assert!(Command::new("xdotool")
            .args(["mouseup", "1"])
            .status()
            .unwrap()
            .success());
    });
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let left = root.join("drop-left.txt");
    let right = root.join("neue Datei # 👩‍💻.txt");
    let ignored = root.join("second.txt");
    let ready = root.join("producer-ready");
    let receipt = root.join("producer-result");
    std::fs::write(&left, "old\n").unwrap();
    std::fs::write(&right, "new\n").unwrap();
    std::fs::write(&ignored, "ignored\n").unwrap();
    ui.load_path(left.clone());
    let source = RefCell::new(None::<Child>);
    let state = RefCell::new(None::<Rc<State>>);
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let hovered = Cell::new(false);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "comparison native drop phase{}: receipt={:?}",
            phase.get(),
            std::fs::read_to_string(&receipt)
        );
        if pause.get().elapsed() < Duration::from_millis(300) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                if !ui
                    .active()
                    .is_some_and(|doc| doc.disk_path().as_ref() == Some(&left))
                {
                    return glib::ControlFlow::Continue;
                }
                *state.borrow_mut() = Some(open(&ui));
                *source.borrow_mut() = Some(
                    Command::new(
                        std::env::var_os("FASTRA_DIFF_DROP_PRODUCER")
                            .expect("native producer executable"),
                    )
                    .args([
                        ready.as_os_str(),
                        receipt.as_os_str(),
                        right.as_os_str(),
                        ignored.as_os_str(),
                    ])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .spawn()
                    .unwrap(),
                );
            }
            1 => {
                let Ok(id) = std::fs::read_to_string(&ready) else {
                    return glib::ControlFlow::Continue;
                };
                let state = state.borrow().clone().unwrap();
                if !state.picker.ready() {
                    return glib::ControlFlow::Continue;
                }
                drag(id, state.picker.test_panel(1).as_ref());
            }
            2 => {
                let state = state.borrow().clone().unwrap();
                if state.picker.test_panel(1).has_css_class("drop-active") && !hovered.get() {
                    if !support::try_capture(&state.picker.window, "compare-drop-hover") {
                        return glib::ControlFlow::Continue;
                    }
                    hovered.set(true);
                }
                if !state.picker.compare.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(hovered.get(), "native enter highlights the field");
                assert_eq!(
                    state.choices.borrow()[1].as_ref().unwrap().path().as_ref(),
                    Some(&right)
                );
                assert_eq!(std::fs::read_to_string(&receipt).unwrap(), "COPY");
                if !support::try_capture(&state.picker.window, "compare-dropped") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.picker.compare, &[]);
            }
            _ => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || state.model.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    ui.documents.borrow().len(),
                    2,
                    "second dropped file never creates a source tab"
                );
                assert_eq!(
                    state.model.borrow().as_ref().unwrap().inputs[1]
                        .snapshot
                        .text,
                    "new\n"
                );
                assert_eq!(std::fs::read_to_string(&left).unwrap(), "old\n");
                assert_eq!(std::fs::read_to_string(&right).unwrap(), "new\n");
                assert_eq!(std::fs::read_to_string(&ignored).unwrap(), "ignored\n");
                if let Some(mut child) = source.borrow_mut().take() {
                    let _ = child.kill();
                    let _ = child.wait();
                }
                eprintln!("DIFF_PICKER_SELFTEST PASS independent native process FileList+conflicting String drag, hover highlight, COPY, first file with #/spaces/ZWJ path preserved, complete comparison, no extra source tab or source writes");
                crate::source_appearance::cleanup_schemes();
                std::process::exit(0);
            }
        }
        eprintln!("comparison native drop phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
