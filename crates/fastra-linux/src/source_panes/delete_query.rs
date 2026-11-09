//! Vorab geplante native Delete-/Join-Transaktionen der passenden optionalen Laufzeit.
use super::*;
use glib::translate::IntoGlib;
type Edit = (i32, i32, String);
fn signal_available() -> bool {
    unsafe {
        let ty = gtk::TextBuffer::static_type().into_glib();
        let class = glib::gobject_ffi::g_type_class_ref(ty);
        let id = glib::gobject_ffi::g_signal_lookup(c"fastra-preflight-edits-v1".as_ptr(), ty);
        let mut query: glib::gobject_ffi::GSignalQuery = std::mem::zeroed();
        if id != 0 {
            glib::gobject_ffi::g_signal_query(id, &mut query);
        }
        let ok = id != 0
            && query.itype == ty
            && query.return_type == glib::Type::BOOL.into_glib()
            && query.n_params == 1
            && *query.param_types == glib::Variant::static_type().into_glib()
            && query.signal_flags == glib::gobject_ffi::G_SIGNAL_RUN_LAST;
        glib::gobject_ffi::g_type_class_unref(class);
        ok
    }
}
pub(super) fn available() -> bool {
    if !signal_available() {
        return false;
    }
    let buffer = sourceview5::Buffer::new(None);
    let Some(line) = buffer.find_property("fastra-preflight-line-bytes-v1") else {
        return false;
    };
    let Some(planner) = buffer.find_property("fastra-edit-plan-abi-v1") else {
        return false;
    };
    let Some(metadata) = buffer.find_property("fastra-iter-metadata-abi-v1") else {
        return false;
    };
    metadata.owner_type() == gtk::TextBuffer::static_type()
        && metadata.value_type() == u32::static_type()
        && metadata.flags().contains(glib::ParamFlags::READABLE)
        && !metadata.flags().contains(glib::ParamFlags::WRITABLE)
        && buffer.property::<u32>("fastra-iter-metadata-abi-v1") == 0x49545231
        && line.owner_type() == gtk::TextBuffer::static_type()
        && line.value_type() == u32::static_type()
        && line
            .flags()
            .contains(glib::ParamFlags::READABLE | glib::ParamFlags::WRITABLE)
        && planner.owner_type() == sourceview5::Buffer::static_type()
        && planner.value_type() == u32::static_type()
        && planner.flags().contains(glib::ParamFlags::READABLE)
        && !planner.flags().contains(glib::ParamFlags::WRITABLE)
        && buffer.property::<u32>("fastra-edit-plan-abi-v1") == 0x46454431
}

fn add(line: &mut usize, ch: char) -> bool {
    if ch == '\r' || ch == '\n' {
        *line = 0;
    } else {
        *line += ch.len_utf8();
    }
    *line <= fastra_document::TEXT_SECTION_BYTES
}
fn allowed(buffer: &gtk::TextBuffer, edits: &[Edit]) -> bool {
    let Some(counter) = buffer.downcast_ref::<byte_buffer::Buffer>() else {
        return false;
    };
    let Some(mut total) = counter.bytes() else {
        return false;
    };
    let mut previous = 0;
    for (start, end, text) in edits {
        if *start < previous
            || *end < *start
            || *end > buffer.char_count()
            || text.as_bytes().contains(&0)
        {
            return false;
        }
        let Some(value) =
            byte_buffer::range_bytes(&buffer.iter_at_offset(*start), &buffer.iter_at_offset(*end))
                .and_then(|bytes| total.checked_sub(bytes))
                .and_then(|bytes| bytes.checked_add(text.len()))
        else {
            return false;
        };
        total = value;
        previous = *end;
    }
    if total > fastra_document::EDITABLE_BYTES {
        return false;
    }
    let Some((first, _, _)) = edits.first() else {
        return true;
    };
    let mut line = 0;
    let mut at = buffer.iter_at_offset(*first);
    while at.backward_char() {
        let ch = at.char();
        if ch == '\r' || ch == '\n' {
            break;
        }
        if !add(&mut line, ch) {
            return false;
        }
    }
    let mut at = buffer.iter_at_offset(*first);
    for (start, end, text) in edits {
        while at.offset() < *start {
            if !add(&mut line, at.char()) {
                return false;
            }
            at.forward_char();
        }
        for ch in text.chars() {
            if !add(&mut line, ch) {
                return false;
            }
        }
        at = buffer.iter_at_offset(*end);
    }
    while !at.is_end() {
        let ch = at.char();
        if ch == '\r' || ch == '\n' {
            break;
        }
        if !add(&mut line, ch) {
            return false;
        }
        at.forward_char();
    }
    true
}
pub(super) fn install(view: &sourceview5::View, ui: &Rc<Ui>) {
    if !super::native_input_enabled() {
        return;
    }
    assert!(available(), "native edit preflight ABI missing");
    if let Some(own) = view.downcast_ref::<super::view::View>() {
        own.bind_return_owner(ui);
    }
    let buffer = view.buffer();
    let spec = buffer
        .find_property("fastra-preflight-line-bytes-v1")
        .expect("native edit line budget missing");
    assert_eq!(spec.owner_type(), gtk::TextBuffer::static_type());
    assert_eq!(spec.value_type(), u32::static_type());
    assert!(
        spec.flags()
            .contains(glib::ParamFlags::READABLE | glib::ParamFlags::WRITABLE)
    );
    let planner = buffer
        .find_property("fastra-edit-plan-abi-v1")
        .expect("native SourceView planner ABI missing");
    assert_eq!(planner.owner_type(), sourceview5::Buffer::static_type());
    assert_eq!(planner.value_type(), u32::static_type());
    assert!(planner.flags().contains(glib::ParamFlags::READABLE));
    assert!(!planner.flags().contains(glib::ParamFlags::WRITABLE));
    assert_eq!(
        buffer.property::<u32>("fastra-edit-plan-abi-v1"),
        0x46454431
    );
    let line_bytes = u32::try_from(fastra_document::TEXT_SECTION_BYTES).unwrap();
    buffer.set_property("fastra-preflight-line-bytes-v1", line_bytes);
    assert_eq!(
        buffer.property::<u32>("fastra-preflight-line-bytes-v1"),
        line_bytes
    );
    let weak = buffer.downgrade();
    let ui = Rc::downgrade(ui);
    buffer.connect_local("fastra-preflight-edits-v1", false, move |values| {
        let valid = (|| {
            let buffer = weak.upgrade()?;
            let ui = ui.upgrade()?;
            let doc = ui.active()?;
            let target = super::capture(&doc)?;
            if target.buffer.clone().upcast::<gtk::TextBuffer>() != buffer
                || !target.same_pane(&doc)
                || !target.view.is_editable()
                || !target.view.is_sensitive()
                || ui.window_close_dialog.get()
                || ui.close_committed.get()
                || close_protocol::active(&ui)
            {
                return Some(false);
            }
            let plan = values[1].get::<glib::Variant>().ok()?;
            if plan.n_children() > fastra_document::TEXT_SECTION_BYTES + 2 {
                return Some(false);
            }
            let edits = plan.get::<Vec<Edit>>()?;
            let valid = allowed(&buffer, &edits);
            if std::env::var_os("FASTRA_DELETE_GATE_CASE").is_some() {
                eprintln!(
                    "DELETE_NATIVE_PLAN edits={} readonly_projected_valid={valid}",
                    edits.len()
                );
                assert!(edits.len() <= fastra_document::TEXT_SECTION_BYTES + 2);
            }
            Some(valid)
        })()
        .unwrap_or(false);
        if !valid {
            if let Some(ui) = ui.upgrade() {
                ui.status.set_text(ui.lang.text(
                    "Die Änderung ist für diese Quellansicht nicht möglich oder überschreitet die Textgrenzen.",
                    "The change is unavailable for this source view or exceeds the text limits.",
                ));
            }
        }
        Some((!valid).to_value())
    });
}
