//! Begrenzter nativer Delete-/Backspace-/Join-Gate ohne aktive Komposition.
use super::*;
use std::time::{Duration, Instant};
#[derive(PartialEq, Eq)]
struct State {
    text: String,
    bytes: usize,
    insert: i32,
    bound: i32,
    dirty: bool,
    undo: bool,
    redo: bool,
    revision: u64,
}
impl std::fmt::Debug for State {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("State")
            .field("text_bytes", &self.text.len())
            .field("cache_bytes", &self.bytes)
            .field("insert", &self.insert)
            .field("bound", &self.bound)
            .field("dirty", &self.dirty)
            .field("undo", &self.undo)
            .field("redo", &self.redo)
            .field("revision", &self.revision)
            .finish()
    }
}

fn state(doc: &Document, b: &gtk::TextBuffer) -> State {
    State {
        text: buffer_text(b),
        bytes: b
            .downcast_ref::<byte_buffer::Buffer>()
            .unwrap()
            .bytes()
            .unwrap(),
        insert: b.iter_at_mark(&b.get_insert()).offset(),
        bound: b.iter_at_mark(&b.selection_bound()).offset(),
        dirty: b.is_modified(),
        undo: b.can_undo(),
        redo: b.can_redo(),
        revision: doc.revision.get(),
    }
}
fn keys(view: &sourceview5::View, sequence: &[&str]) {
    let native = view.native().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(native.surface().unwrap().as_ptr().cast()) }.to_string();
    let keys: Vec<_> = sequence.iter().map(|s| s.to_string()).collect();
    std::thread::spawn(move || {
        assert!(
            std::process::Command::new("xdotool")
                .args(["windowfocus", "--sync", &id, "key", "--clearmodifiers"])
                .args(keys)
                .status()
                .unwrap()
                .success()
        )
    });
}

pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let case = std::env::var("FASTRA_DELETE_GATE_CASE").unwrap();
    let secondary = std::env::var_os("FASTRA_COMMIT_GATE_SECONDARY").is_some();
    let original = match case.as_str() {
        "large-join" => {
            let mut text = "a\n".repeat(70000);
            while text.len() + 32768 <= fastra_document::EDITABLE_BYTES {
                text.push_str(&"x".repeat(32767));
                text.push('\n');
            }
            text.push_str(&"x".repeat(fastra_document::EDITABLE_BYTES - text.len()));
            text
        }
        "lf" | "backspace-lf" | "join" | "valid-commit-lf" => {
            format!("{}\n{}", "a".repeat(40000), "b".repeat(40000))
        }
        "crlf" | "backspace-crlf" => format!("{}\r\n{}", "a".repeat(40000), "b".repeat(40000)),
        "selection" | "selection-reverse" => format!("{}\nx", "é".repeat(32768)),
        "smart" => format!("\t{}", "a".repeat(65535)),
        "valid-smart" => "\tx".into(),
        "nfd" => format!("{}שּׁ", "a".repeat(65533)),
        "valid-delete" => "ab\ncd".into(),
        "valid-commit-overwrite" => "abc".into(),
        "locked-join" => "aa\nbb".into(),
        "valid-nfd" => "xשּׁ".into(),
        "valid-join" => "aa \n\tbb \n cc".into(),
        _ => panic!("unknown delete case"),
    };
    text_limits::validate(&original, ui.lang).unwrap();
    ui.add_document("native-delete.txt", &original);
    let doc = ui.active().unwrap();
    let mut views = Vec::new();
    super::gate::views(doc.container.upcast_ref(), &mut views);
    assert_eq!(views.len(), 2);
    super::gate::named::<gtk::CheckButton>(
        doc.container.upcast_ref(),
        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
    )
    .unwrap()
    .set_active(true);
    let index = usize::from(secondary);
    let view = views[index].clone();
    assert!(!view.is_smart_backspace());
    if case.contains("smart") {
        view.set_smart_backspace(true);
        view.set_tab_width(8);
        view.set_indent_width(4);
    }
    let buffer = view.buffer();
    assert!(buffer.is::<byte_buffer::Buffer>());
    buffer.begin_user_action();
    buffer.insert(&mut buffer.end_iter(), "redo");
    buffer.end_user_action();
    buffer.undo();
    assert_eq!(buffer_text(&buffer), original);
    assert!(buffer.can_redo());
    let (insert, bound) = match case.as_str() {
        "lf" | "crlf" => (40000, 40000),
        "backspace-lf" => (40001, 40001),
        "backspace-crlf" => (40002, 40002),
        "selection" => (32768, 32769),
        "selection-reverse" => (32769, 32768),
        "valid-delete" => (2, 2),
        "valid-commit-lf" => (40000, 40001),
        "valid-commit-overwrite" => (1, 1),
        "smart" | "valid-smart" => (1, 1),
        "join" | "valid-join" | "large-join" | "locked-join" => (buffer.char_count(), 0),
        _ => (buffer.char_count(), buffer.char_count()),
    };
    buffer.select_range(
        &buffer.iter_at_offset(insert),
        &buffer.iter_at_offset(bound),
    );
    let peer = views[1 - index].buffer();
    peer.select_range(&peer.iter_at_offset(2), &peer.iter_at_offset(1));
    let before = state(&doc, &buffer);
    let other = state(&doc, &peer);
    let begins = Rc::new(Cell::new(0));
    let changes = Rc::new(Cell::new(0));
    let marks = Rc::new(Cell::new(0));
    let n = begins.clone();
    buffer.connect_begin_user_action(move |_| n.set(n.get() + 1));
    let n = changes.clone();
    buffer.connect_changed(move |_| n.set(n.get() + 1));
    let n = marks.clone();
    buffer.connect_mark_set(move |b, _, mark| {
        if *mark == b.get_insert() || *mark == b.selection_bound() {
            n.set(n.get() + 1);
        }
    });
    let stage = Cell::new(0);
    let at = Cell::new(Instant::now());
    let start = Instant::now();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            start.elapsed() < Duration::from_secs(35),
            "delete gate timeout"
        );
        if at.get().elapsed() < Duration::from_millis(500) {
            return glib::ControlFlow::Continue;
        }
        match stage.get() {
            0 => {
                view.grab_focus();
                if case.contains("smart") {
                    view.set_smart_backspace(true);
                    view.set_tab_width(8);
                    view.set_indent_width(4);
                    assert_eq!(view.visual_column(&buffer.iter_at_offset(1)), 8);
                }
                if case == "locked-join" {
                    view.set_editable(false);
                }
                if case.starts_with("valid-commit-") {
                    if case == "valid-commit-overwrite" {
                        view.set_overwrite(true);
                    }
                    let controllers = view.observe_controllers();
                    let context = (0..controllers.n_items())
                        .find_map(|i| {
                            controllers
                                .item(i)?
                                .downcast::<gtk::EventControllerKey>()
                                .ok()?
                                .im_context()
                        })
                        .expect("original native IMContext missing");
                    context.emit_by_name::<()>(
                        "commit",
                        &[&if case == "valid-commit-lf" {
                            "\nx"
                        } else {
                            "Z"
                        }],
                    );
                } else if case == "join"
                    || case == "valid-join"
                    || case == "large-join"
                    || case == "locked-join"
                {
                    view.emit_by_name::<()>("join-lines", &[]);
                } else {
                    keys(
                        &view,
                        &[
                            if case.contains("backspace")
                                || case.contains("nfd")
                                || case.contains("smart")
                            {
                                "BackSpace"
                            } else {
                                "Delete"
                            },
                        ],
                    );
                }
            }
            1 => {
                if case.starts_with("valid-") {
                    let dynamic_expected;
                    let expected = match case.as_str() {
                        "valid-commit-lf" => {
                            dynamic_expected =
                                format!("{}\nx{}", "a".repeat(40000), "b".repeat(40000));
                            &dynamic_expected
                        }
                        "valid-commit-overwrite" => "aZc",
                        "valid-delete" => "abcd",
                        "valid-nfd" => "xשּ",
                        "valid-smart" => "    x",
                        "valid-join" => "aa bb cc",
                        _ => unreachable!(),
                    };
                    assert_eq!(
                        buffer_text(&buffer),
                        expected,
                        "native accepted plan result"
                    );
                    assert_eq!(begins.get(), 1, "accepted command must own one UserAction");
                    assert!(
                        buffer.can_undo(),
                        "accepted native action has no undo entry"
                    );
                    if case.starts_with("valid-commit-") {
                        buffer.undo();
                    } else {
                        keys(&view, &["ctrl+z"]);
                    }
                } else {
                    assert_eq!(
                        state(&doc, &buffer),
                        before,
                        "rejected native command changed active state"
                    );
                    assert_eq!(
                        state(&doc, &peer),
                        other,
                        "rejected native command changed inactive state"
                    );
                    assert_eq!(begins.get(), 0, "rejected command began history");
                    assert_eq!(changes.get(), 0, "rejected command changed text");
                    assert_eq!(marks.get(), 0, "rejected command moved selection marks");
                    println!(
                        "SOURCE_DELETE_GATE case={case} secondary={secondary} text_bytes directed_selection dirty revision undo_redo no_user_action no_selection_mark_changes PASS"
                    );
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
            }
            _ => {
                assert!(
                    buffer_text(&buffer) == original,
                    "one native Undo did not restore active source: {:?}",
                    state(&doc, &buffer)
                );
                assert!(
                    buffer_text(&peer) == original,
                    "one native Undo did not restore peer source"
                );
                assert!(buffer.can_redo());
                println!(
                    "SOURCE_DELETE_GATE case={case} secondary={secondary} valid_native_single_undo PASS"
                );
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
        }
        stage.set(stage.get() + 1);
        at.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
