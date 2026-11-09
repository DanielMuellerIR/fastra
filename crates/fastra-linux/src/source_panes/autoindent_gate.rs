//! Unverbrauchter Default-Return auf echten Quellansichten ohne IME-Kompositionsvertrag.
use super::*;
use std::time::{Duration, Instant};
#[derive(PartialEq, Eq)]
struct State {
    text: String,
    bytes: Option<usize>,
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
            .bytes(),
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
    let case = std::env::var("FASTRA_AUTOINDENT_GATE_CASE").unwrap();
    let secondary = std::env::var_os("FASTRA_COMMIT_GATE_SECONDARY").is_some();
    let big = case == "bytes-prefix" || case == "crlf-limit";
    let original = if big {
        let row = if case == "crlf-limit" {
            format!("{}\r\n", "x".repeat(32766))
        } else {
            format!("{}\n", "x".repeat(32767))
        };
        let mut text = row.repeat(1023);
        let n = fastra_document::EDITABLE_BYTES - 1 - text.len();
        if case == "bytes-prefix" {
            text.push_str("    ");
            text.push_str(&"x".repeat(n - 4));
        } else {
            text.push_str(&"x".repeat(n));
        }
        text
    } else {
        match case.as_str() {
            "trim" => "    alpha   tail".into(),
            "inside-indent" => "    alpha".into(),
            "selection" | "selection-reverse" | "rectangle-compat" | "locked-selection" => {
                "    aa\n   bb\n cc".into()
            }
            "crlf-trim" => " \taa  \r\nb".into(),
            "valid" => "    alpha".into(),
            _ => panic!("unknown case"),
        }
    };
    text_limits::validate(&original, ui.lang).unwrap();
    ui.add_document("native-return.txt", &original);
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
    let buffer = view.buffer();
    assert!(view.is_auto_indent());
    if std::env::var_os("FASTRA_RETURN_BASELINE").is_none() {
        assert_eq!(
            view.property::<u32>("fastra-return-plan-abi-v1"),
            0x52544e31
        );
    }
    buffer.begin_user_action();
    buffer.insert(&mut buffer.end_iter(), "redo");
    buffer.end_user_action();
    buffer.undo();
    assert!(buffer_text(&buffer) == original);
    assert!(buffer.can_redo());
    if case == "rectangle-compat" {
        doc.rectangles.borrow()[index].select((0, 0), (1, 1));
    }
    let (insert, bound) = match case.as_str() {
        "trim" => (9, 9),
        "inside-indent" => (2, 2),
        "selection" | "rectangle-compat" | "locked-selection" => (4, 12),
        "selection-reverse" => (12, 4),
        "crlf-trim" => (4, 4),
        _ => (buffer.char_count(), buffer.char_count()),
    };
    if case != "rectangle-compat" {
        buffer.select_range(
            &buffer.iter_at_offset(insert),
            &buffer.iter_at_offset(bound),
        );
    } else {
        assert!(doc.rectangles.borrow()[index].is_selected());
        assert!(!buffer.has_selection());
        assert!(!view.property::<bool>("fastra-linear-return-v1"));
    }
    let peer = views[1 - index].buffer();
    peer.select_range(&peer.iter_at_offset(2), &peer.iter_at_offset(1));
    let before = state(&doc, &buffer);
    let other = state(&doc, &peer);
    assert_eq!(before.bytes, Some(original.len()));
    assert_eq!(other.bytes, Some(original.len()));
    let begins = Rc::new(Cell::new(0));
    let marks = Rc::new(Cell::new(0));
    let n = begins.clone();
    buffer.connect_begin_user_action(move |_| n.set(n.get() + 1));
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
            "return gate timeout stage={} actual={:?} peer={:?} begins={} text={:?}",
            stage.get(), state(&doc, &buffer), state(&doc, &peer), begins.get(),
            (buffer.char_count()<100).then(|| buffer_text(&buffer))
        );
        if at.get().elapsed() < Duration::from_millis(500) {
            return glib::ControlFlow::Continue;
        }
        match stage.get() {
            0 => {
                view.grab_focus();
                if case == "locked-selection" {
                    ui.window_close_dialog.set(true);
                }
                keys(&view, &["Return"]);
            }
            1 => {
                if case == "rectangle-compat" {
                    println!(
                        "RECT_RETURN_RESULT {}",
                        serde_json::json!({"secondary":secondary,"text":buffer_text(&buffer),"peer":buffer_text(&peer),"insert":buffer.cursor_position(),"bound":buffer.iter_at_mark(&buffer.selection_bound()).offset(),"dirty":buffer.is_modified(),"undo":buffer.can_undo(),"redo":buffer.can_redo(),"revision":doc.revision.get(),"begins":begins.get()})
                    );
                    println!(
                        "SOURCE_RETURN_GATE case=rectangle-compat secondary={secondary} observed_native_grid_path PASS"
                    );
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
                if case == "bytes-prefix" || case == "locked-selection" {
                    assert_eq!(
                        state(&doc, &buffer),
                        before,
                        "rejected Return changed active state"
                    );
                    assert_eq!(
                        state(&doc, &peer),
                        other,
                        "rejected Return changed peer state"
                    );
                    assert_eq!(begins.get(), 0);
                    assert_eq!(marks.get(), 0);
                    println!(
                        "SOURCE_RETURN_GATE case={case} secondary={secondary} rejected_before_history text_directed_selection_dirty_revision_undo_redo_preserved PASS"
                    );
                    ui.window_close_dialog.set(false);
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
                let expected = match case.as_str() {
                    "trim" => "    alpha\n    tail".to_owned(),
                    "inside-indent" => "  \n  alpha".to_owned(),
                    "selection" | "selection-reverse" => "    \n\n cc".to_owned(),
                    "crlf-trim" => " \taa\n \t\r\nb".to_owned(),
                    _ => format!(
                        "{original}{}",
                        if case == "valid" { "\n    " } else { "\n" }
                    ),
                };
                assert!(
                    buffer_text(&buffer) == expected,
                    "Return result differs from readonly native plan: {:?}",
                    state(&doc, &buffer)
                );
                assert!(buffer_text(&peer) == expected);
                assert_eq!(state(&doc, &buffer).bytes, Some(expected.len()));
                assert_eq!(state(&doc, &peer).bytes, Some(expected.len()));
                assert_eq!(begins.get(), 1);
                assert!(buffer.can_undo());
                keys(&view, &["ctrl+z"]);
            }
            _ => {
                if buffer
                    .downcast_ref::<byte_buffer::Buffer>()
                    .unwrap()
                    .bytes()
                    != Some(original.len())
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    buffer_text(&buffer) == original,
                    "one Undo did not restore Return: {:?}",
                    state(&doc, &buffer)
                );
                assert!(buffer_text(&peer) == original);
                assert!(buffer.can_redo());
                println!(
                    "SOURCE_RETURN_GATE case={case} secondary={secondary} original_eol_bytes_kept native_single_undo PASS"
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
