use super::*;
use std::time::{Duration, Instant};

pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let left = root.join("state-left.txt");
    let right = root.join("state-right.txt");
    let binary = root.join("binary.txt");
    let bom = root.join("bom.txt");
    std::fs::write(&left, "Hello  \n\n").unwrap();
    std::fs::write(&right, "hello\n").unwrap();
    std::fs::write(&binary, b"binary\0text").unwrap();
    std::fs::write(
        &bom,
        [
            vec![0xff, 0xfe],
            "hello\n"
                .encode_utf16()
                .flat_map(u16::to_le_bytes)
                .collect(),
        ]
        .concat(),
    )
    .unwrap();
    ui.load_path(left.clone());
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let state = RefCell::new(None::<Rc<State>>);
    let reopened = RefCell::new(None::<Rc<State>>);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "comparison states phase{}",
            phase.get()
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
                let picker = open(&ui);
                picker.choose(1, sources::Choice::File(root.join("missing.txt")));
                *state.borrow_mut() = Some(picker);
            }
            1 => {
                let state = state.borrow().clone().unwrap();
                if !state.picker.ready()
                    || state.picker.test_problem(1)
                        != ui.lang.text("Datei nicht gefunden.", "File not found.")
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(!state.picker.compare.is_sensitive());
                if !support::try_capture(&state.picker.window, "compare-missing") {
                    return glib::ControlFlow::Continue;
                }
                state.choose(1, sources::Choice::File(root.clone()));
            }
            2 => {
                let state = state.borrow().clone().unwrap();
                if !state
                    .picker
                    .test_problem(1)
                    .contains(ui.lang.text("Für zwei Ordner", "For two folders"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(!state.picker.compare.is_sensitive());
                state.choose(1, sources::Choice::File(binary.clone()));
            }
            3 => {
                let state = state.borrow().clone().unwrap();
                if !state
                    .picker
                    .test_problem(1)
                    .contains(ui.lang.text("Binärdatei", "Binary file"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(!state.picker.compare.is_sensitive());
                state.choose(1, sources::Choice::File(bom.clone()));
            }
            4 => {
                let state = state.borrow().clone().unwrap();
                if !state.picker.compare.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state.picker.test_problem(1).is_empty(),
                    "UTF-16 BOM is not mistaken for binary"
                );
                state.choose(0, sources::Choice::File(left.clone()));
                state.choose(1, sources::Choice::File(right.clone()));
            }
            5..=8 => {
                let state = state.borrow().clone().unwrap();
                if !state.picker.compare.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.picker.options[(phase.get() - 5) as usize], &[]);
            }
            9 => {
                let state = state.borrow().clone().unwrap();
                assert!(state.picker.options.iter().all(|option| option.is_active()));
                assert!(!state.picker.options[0].is_sensitive());
                if !support::try_capture(&state.picker.window, "compare-options") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.picker.compare, &[]);
            }
            10 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || state.model.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let model = state.model.borrow();
                let comparison = &model.as_ref().unwrap().comparison;
                assert!(comparison.blocks().is_empty());
                assert!(!comparison.byte_identical());
                assert!(
                    state.origins.borrow().iter().all(Option::is_none),
                    "disk choices never bind a matching open tab implicitly"
                );
                assert!(state
                    .view
                    .transfer
                    .iter()
                    .all(|button| !button.is_sensitive()));
                assert_eq!(ui.documents.borrow().len(), 2);
                if !support::try_capture(ui.window.upcast_ref(), "compare-identical-options") {
                    return glib::ControlFlow::Continue;
                }
                *reopened.borrow_mut() = Some(open(&ui));
            }
            11 => {
                let state = reopened.borrow().clone().unwrap();
                if !state.picker.ready() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state.picker.options.iter().all(|option| option.is_active()),
                    "all four native choices persisted across a fresh dialog"
                );
                assert!(!state.picker.options[0].is_sensitive());
                support::test_click(&state.picker.options[1], &[]);
            }
            12 => {
                let state = reopened.borrow().clone().unwrap();
                assert!(state.picker.options[0].is_sensitive());
                assert!(
                    state.picker.options[0].is_active(),
                    "trailing-whitespace choice survives disabling all-whitespace"
                );
                support::test_keys(&state.picker.window, &["Escape"]);
            }
            _ => {
                if reopened
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .picker
                    .window
                    .is_visible()
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&left).unwrap(), "Hello  \n\n");
                assert_eq!(std::fs::read_to_string(&right).unwrap(), "hello\n");
                eprintln!("DIFF_PICKER_SELFTEST PASS visible missing/directory/binary refusal; valid UTF-16 BOM; native four options, retained disabled choice and persisted fresh dialog; explicit disk sources stay readonly with an already-open matching document; identical-under-options visible; native Cancel");
                crate::source_appearance::cleanup_schemes();
                std::process::exit(0);
            }
        }
        eprintln!("comparison states phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
