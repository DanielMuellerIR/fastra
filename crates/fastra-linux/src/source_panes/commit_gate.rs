//! Native Tasten auf beiden echten Source-Panes; nur der finale GTK-Commit wird geprüft.
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
        assert!(std::process::Command::new("xdotool")
            .args(["windowfocus", "--sync", &id, "key", "--clearmodifiers"])
            .args(keys)
            .status()
            .unwrap()
            .success())
    });
}

pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    assert!(commit_query::available());
    let case = std::env::var("FASTRA_COMMIT_GATE_CASE").unwrap();
    let secondary = std::env::var_os("FASTRA_COMMIT_GATE_SECONDARY").is_some();
    let original = match case.as_str() {
        "bytes" => format!("{}\n", "a".repeat(32767)).repeat(1024),
        "line" | "overwrite" => "a".repeat(65536),
        "selection" => format!("{}\nx", "é".repeat(32768)),
        "valid" => "alpha\n🙂é".into(),
        _ => panic!("unknown case"),
    };
    text_limits::validate(&original, ui.lang).unwrap();
    ui.add_document("native-commit.txt", &original);
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
    assert!(buffer.is::<byte_buffer::Buffer>());
    buffer.begin_user_action();
    buffer.insert(&mut buffer.end_iter(), "redo");
    buffer.end_user_action();
    buffer.undo();
    assert!(
        buffer_text(&buffer) == original,
        "Redo fixture failed to restore source"
    );
    assert!(buffer.can_redo());
    if case == "selection" {
        buffer.select_range(&buffer.iter_at_offset(32768), &buffer.iter_at_offset(32769));
    } else if case == "overwrite" {
        buffer.place_cursor(&buffer.start_iter());
        view.set_overwrite(true);
    } else {
        buffer.place_cursor(&buffer.end_iter());
    }
    let peer = views[1 - index].buffer();
    peer.select_range(&peer.iter_at_offset(2), &peer.iter_at_offset(1));
    let before = state(&doc, &buffer);
    let other = state(&doc, &peer);
    let stage = Cell::new(0);
    let at = Cell::new(Instant::now());
    let start = Instant::now();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            start.elapsed() < Duration::from_secs(35),
            "commit gate timeout stage{}",
            stage.get()
        );
        if at.get().elapsed() < Duration::from_millis(500) {
            return glib::ControlFlow::Continue;
        }
        match stage.get() {
            0 => {
                view.grab_focus();
                keys(&view, &[if case == "overwrite" { "eacute" } else { "x" }]);
            }
            1 => {
                if case == "valid" {
                    assert_eq!(buffer_text(&buffer), format!("{original}x"));
                    assert_eq!(doc.revision.get(), before.revision + 1);
                    assert_eq!(
                        buffer
                            .downcast_ref::<byte_buffer::Buffer>()
                            .unwrap()
                            .bytes(),
                        Some(original.len() + 1)
                    );
                    keys(&view, &["ctrl+z"]);
                } else {
                    assert_eq!(
                        state(&doc, &buffer),
                        before,
                        "rejected commit changed active state"
                    );
                    assert_eq!(
                        state(&doc, &peer),
                        other,
                        "rejected commit changed inactive state"
                    );
                    println!("SOURCE_COMMIT_GATE case={case} secondary={secondary} text_bytes directed_selection dirty revision undo_redo_preserved PASS");
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
            }
            _ => {
                assert_eq!(buffer_text(&buffer), original);
                assert_eq!(buffer_text(&peer), original);
                assert!(buffer.can_redo());
                println!("SOURCE_COMMIT_GATE case=valid secondary={secondary} native_insert_single_undo PASS");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
        }
        stage.set(stage.get() + 1);
        at.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
