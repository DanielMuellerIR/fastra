//! UTF-8-Zähler an der tatsächlichen Buffer-Classclosure, unabhängig von Signal-Afterhandlern.
use super::*;
use gtk::subclass::prelude::*;
use sourceview5::subclass::prelude::*;
mod imp {
    use super::*;
    pub struct Buffer {
        pub bytes: Cell<usize>,
        pub depth: Cell<u32>,
        pub valid: Cell<bool>,
    }
    impl Default for Buffer {
        fn default() -> Self {
            Self {
                bytes: Cell::new(0),
                depth: Cell::new(0),
                valid: Cell::new(true),
            }
        }
    }
    #[glib::object_subclass]
    impl ObjectSubclass for Buffer {
        const NAME: &'static str = "FastraCountedSourceBuffer";
        type Type = super::Buffer;
        type ParentType = sourceview5::Buffer;
    }
    impl ObjectImpl for Buffer {}
    struct Mutation<'a>(&'a Cell<u32>);
    impl Drop for Mutation<'_> {
        fn drop(&mut self) {
            self.0.set(self.0.get() - 1);
        }
    }
    impl Buffer {
        fn enter(&self) -> Mutation<'_> {
            self.depth.set(self.depth.get() + 1);
            Mutation(&self.depth)
        }
        fn add(&self, bytes: usize) {
            if let Some(n) = self.bytes.get().checked_add(bytes) {
                self.bytes.set(n)
            } else {
                self.valid.set(false)
            }
        }
    }
    impl TextBufferImpl for Buffer {
        fn insert_text(&self, at: &mut gtk::TextIter, text: &str) {
            let _mutation = self.enter();
            self.add(text.len());
            self.parent_insert_text(at, text);
        }
        fn delete_range(&self, start: &mut gtk::TextIter, end: &mut gtk::TextIter) {
            let _mutation = self.enter();
            if start.offset() == 0 && end.offset() == self.obj().char_count() {
                self.bytes.set(0);
                self.valid.set(true);
            } else if let Some(bytes) =
                super::range_bytes(start, end).and_then(|n| self.bytes.get().checked_sub(n))
            {
                self.bytes.set(bytes)
            } else {
                self.valid.set(false)
            }
            self.parent_delete_range(start, end);
        }
        fn insert_child_anchor(&self, at: &mut gtk::TextIter, anchor: &gtk::TextChildAnchor) {
            self.valid.set(false);
            self.parent_insert_child_anchor(at, anchor);
        }
        fn insert_paintable(&self, at: &mut gtk::TextIter, p: &gtk::gdk::Paintable) {
            self.valid.set(false);
            self.parent_insert_paintable(at, p);
        }
    }
    impl BufferImpl for Buffer {}
}
glib::wrapper! {pub struct Buffer(ObjectSubclass<imp::Buffer>) @extends sourceview5::Buffer,gtk::TextBuffer;}
impl Buffer {
    pub(super) fn new(table: Option<&gtk::TextTagTable>) -> Self {
        glib::Object::builder().property("tag-table", table).build()
    }
    pub(super) fn bytes(&self) -> Option<usize> {
        let s = self.imp();
        (s.valid.get() && s.depth.get() == 0).then(|| s.bytes.get())
    }
}
pub(super) fn range_bytes(start: &gtk::TextIter, end: &gtk::TextIter) -> Option<usize> {
    if start.offset() > end.offset() {
        return None;
    }
    if start.line() == end.line() {
        return usize::try_from(end.line_index() - start.line_index()).ok();
    }
    let mut bytes = usize::try_from(start.bytes_in_line() - start.line_index()).ok()?;
    let mut line = *start;
    line.forward_line();
    if line.line() <= start.line() {
        return None;
    }
    while line.line() < end.line() {
        bytes = bytes.checked_add(usize::try_from(line.bytes_in_line()).ok()?)?;
        let previous = line.line();
        line.forward_line();
        if line.line() <= previous {
            return None;
        }
    }
    bytes.checked_add(usize::try_from(end.line_index()).ok()?)
}
#[cfg(debug_assertions)]
pub(super) fn count_gate(ui: Rc<Ui>) {
    let optional = super::native_input_enabled();
    let factory = super::new_buffer(None);
    assert_eq!(
        factory.is::<Buffer>(),
        optional && super::commit_query::available()
    );
    if !optional {
        assert_eq!(factory.type_(), sourceview5::Buffer::static_type());
        eprintln!("DEFAULT_SYSTEM_FACTORY_RAW PASS");
    }
    let b = Buffer::new(None);
    b.set_enable_undo(false);
    b.set_text("a");
    b.set_enable_undo(true);
    let stop = b.connect_changed(|b| b.stop_signal_emission_by_name("insert-text"));
    b.begin_user_action();
    b.insert(&mut b.end_iter(), "é");
    b.end_user_action();
    assert_eq!(b.bytes(), Some(3));
    assert_eq!(buffer_text(&b), "aé");
    b.disconnect(stop);
    b.undo();
    assert_eq!(b.bytes(), Some(1));
    assert_eq!(buffer_text(&b), "a");
    b.redo();
    assert_eq!(b.bytes(), Some(3));
    b.set_text("é\r\n🙂x\u{2028}z\nlast");
    assert_eq!(b.bytes(), Some(buffer_text(&b).len()));
    eprintln!("COUNT_REENTRANT_BASELINE_BEGIN");
    let raw = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
    raw.set_text("a");
    let once = Rc::new(Cell::new(false));
    let flag = once.clone();
    raw.connect_changed(move |b| {
        if !flag.replace(true) {
            b.insert(&mut b.end_iter(), "界");
        }
    });
    raw.insert(&mut raw.end_iter(), "é");
    assert_eq!(buffer_text(&raw).len(), 6);
    eprintln!("COUNT_REENTRANT_BASELINE_END OWN_BEGIN");
    let reentrant = Rc::new(Cell::new(false));
    let flag = reentrant.clone();
    let id = b.connect_changed(move |b| {
        if !flag.replace(true) {
            b.insert(&mut b.end_iter(), "界");
        }
    });
    b.insert(&mut b.end_iter(), "é");
    b.disconnect(id);
    assert_eq!(b.bytes(), Some(buffer_text(&b).len()));
    for text in ["é\r\n🙂\rX\n", "a\u{2028}b\u{2029}c\r\nend", "a\n", ""] {
        b.set_text(text);
        for a in 0..=b.char_count() {
            for z in a..=b.char_count() {
                let start = b.iter_at_offset(a);
                let end = b.iter_at_offset(z);
                assert_eq!(
                    range_bytes(&start, &end),
                    Some(b.text(&start, &end, true).len())
                );
            }
        }
    }
    b.set_text("é\r\n🙂x\nlast");
    let deleted_before = b.bytes();
    let veto_delete =
        b.connect_delete_range(|b, _, _| b.stop_signal_emission_by_name("delete-range"));
    b.delete(&mut b.start_iter(), &mut b.end_iter());
    b.disconnect(veto_delete);
    assert_eq!(b.bytes(), deleted_before);
    let before = b.bytes();
    let veto = b.connect_insert_text(|b, _, _| b.stop_signal_emission_by_name("insert-text"));
    b.insert(&mut b.end_iter(), "rejected");
    b.disconnect(veto);
    assert_eq!(b.bytes(), before);
    let mut a = b.iter_at_offset(1);
    let mut z = b.iter_at_offset(b.char_count() - 1);
    b.delete(&mut a, &mut z);
    assert_eq!(b.bytes(), Some(buffer_text(&b).len()));
    println!("SOURCE_SUBCLASS_COUNT_GATE stopped_outer changed_reentrant before_veto undo redo set_text CRLF_unicode multiline_delete PASS");
    ui.window.application().unwrap().quit();
}
