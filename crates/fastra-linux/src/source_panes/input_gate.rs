use super::*;
use std::time::Instant;
fn keys(view: &sourceview5::View, sequence: &[&str]) {
    let native = view.native().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(native.surface().unwrap().as_ptr().cast()) }.to_string();
    let keys: Vec<_> = sequence.iter().map(|s| s.to_string()).collect();
    std::thread::spawn(move || {
        assert!(std::process::Command::new("xdotool")
            .args(["windowfocus", "--sync", &id, "key", "--clearmodifiers"])
            .args(keys)
            .status()
            .unwrap()
            .success());
    });
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let large = std::env::var("FASTRA_SPLIT_INPUT_CASE").unwrap() == "size";
    let original = if large {
        format!("{}\n", "a".repeat(32767)).repeat(1024)
    } else {
        "first\nsecond".into()
    };
    text_limits::validate(&original, ui.lang).unwrap();
    ui.add_document("split-input.txt", &original);
    let doc = ui.active().unwrap();
    let mut all = Vec::new();
    super::gate::views(doc.container.upcast_ref(), &mut all);
    super::gate::named::<gtk::CheckButton>(
        doc.container.upcast_ref(),
        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
    )
    .unwrap()
    .set_active(true);
    let stage = Cell::new(0);
    let pause = Cell::new(Instant::now());
    let start = Instant::now();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(start.elapsed().as_secs() < 60, "input stage{}", stage.get());
        if pause.get().elapsed() < Duration::from_millis(450) {
            return glib::ControlFlow::Continue;
        }
        assert_eq!(buffer_text(&all[0].buffer()), buffer_text(&all[1].buffer()));
        match stage.get() {
            0 => crate::git_view::test_click(
                &all[0],
                &["ctrl+Home", "shift+Right", "shift+Right", "shift+Right"],
            ),
            1 => {
                if large {
                    crate::git_view::test_click(&all[1], &["ctrl+End", "x"]);
                } else {
                    crate::git_view::test_click(
                        &all[1],
                        &["ctrl+End", "ctrl+shift+u", "1", "f", "6", "4", "2"],
                    );
                }
            }
            2 => {
                if large {
                    assert_eq!(original.len(), 32 * 1024 * 1024);
                    assert_eq!(buffer_text(&doc.buffer).len(), original.len() + 1);
                    assert_eq!(doc.revision.get(), 1);
                    assert!(text_limits::validate(&buffer_text(&doc.buffer), ui.lang).is_err());
                    println!("SPLIT RESOURCE BOUNDARY native keyboard32MiB+1 accepted by current input path; mirrors equal; validation rejects result. This is NOT a bounded-all-input product Go.");
                    crate::git_view::test_click(&all[1], &["ctrl+z"]);
                } else {
                    assert_eq!(
                        buffer_text(&doc.buffer),
                        original,
                        "IME preedit mutated source"
                    );
                    assert_eq!(doc.revision.get(), 0);
                    keys(&all[1], &["Return"]);
                }
            }
            3 => {
                if large {
                    assert_eq!(buffer_text(&doc.buffer), original);
                    assert!(all[0].buffer().can_redo() && all[1].buffer().can_redo());
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
                assert_eq!(buffer_text(&doc.buffer), format!("{original}🙂"));
                assert_eq!(doc.revision.get(), 1);
                assert_eq!(
                    all[0]
                        .buffer()
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((0, 3))
                );
                keys(&all[1], &["ctrl+z"]);
            }
            4 => {
                assert_eq!(buffer_text(&doc.buffer), original);
                keys(&all[1], &["ctrl+shift+z"]);
            }
            _ => {
                assert_eq!(buffer_text(&doc.buffer), format!("{original}🙂"));
                println!("SPLIT IME PASS native CtrlShiftU preedit unchanged, emoji commit + native undo/redo, independent inactive selection");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
        }
        stage.set(stage.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
