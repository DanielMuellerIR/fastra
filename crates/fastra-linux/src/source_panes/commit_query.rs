use super::*;
use glib::translate::IntoGlib;
pub(super) fn available() -> bool {
    unsafe {
        let ty = gtk::TextView::static_type().into_glib();
        let class = glib::gobject_ffi::g_type_class_ref(ty);
        let id = glib::gobject_ffi::g_signal_lookup(c"preflight-commit".as_ptr(), ty);
        let mut query: glib::gobject_ffi::GSignalQuery = std::mem::zeroed();
        if id != 0 {
            glib::gobject_ffi::g_signal_query(id, &mut query);
        }
        let ok = id != 0
            && query.itype == ty
            && query.return_type == glib::Type::BOOL.into_glib()
            && query.n_params == 3
            && *query.param_types == glib::Type::STRING.into_glib()
            && *query.param_types.add(1) == glib::Type::I32.into_glib()
            && *query.param_types.add(2) == glib::Type::I32.into_glib()
            && query.signal_flags == glib::gobject_ffi::G_SIGNAL_RUN_LAST;
        glib::gobject_ffi::g_type_class_unref(class);
        ok
    }
}
fn allowed(buffer: &sourceview5::Buffer, text: &str, start: i32, end: i32) -> bool {
    let Some(counter) = buffer.downcast_ref::<super::byte_buffer::Buffer>() else {
        return false;
    };
    let Some(bytes) = counter.bytes() else {
        return false;
    };
    if start < 0
        || end < start
        || end > buffer.char_count()
        || text.as_bytes().contains(&0)
        || text.len() > fastra_document::EDITABLE_BYTES
    {
        return false;
    }
    let a = buffer.iter_at_offset(start);
    let z = buffer.iter_at_offset(end);
    let Some(total) = super::byte_buffer::range_bytes(&a, &z)
        .and_then(|n| bytes.checked_sub(n))
        .and_then(|n| n.checked_add(text.len()))
    else {
        return false;
    };
    if total > fastra_document::EDITABLE_BYTES {
        return false;
    }
    let limit = fastra_document::TEXT_SECTION_BYTES;
    let mut prefix = 0usize;
    let mut at = a;
    while at.backward_char() {
        let ch = at.char();
        if ch == '\r' || ch == '\n' {
            break;
        }
        prefix += ch.len_utf8();
        if prefix > limit {
            return false;
        }
    }
    let mut suffix = 0usize;
    let mut at = z;
    while !at.is_end() {
        let ch = at.char();
        if ch == '\r' || ch == '\n' {
            break;
        }
        suffix += ch.len_utf8();
        if suffix > limit {
            return false;
        }
        at.forward_char();
    }
    let mut line = prefix;
    for byte in text.bytes() {
        if byte == b'\r' || byte == b'\n' {
            line = 0
        } else {
            line += 1;
            if line > limit {
                return false;
            }
        }
    }
    line.checked_add(suffix).is_some_and(|n| n <= limit)
}
pub(super) fn install(view: &sourceview5::View, ui: &Rc<Ui>) {
    super::delete_query::install(view, ui);
    if !super::native_input_enabled() || !available() {
        return;
    }
    let weak = view.downgrade();
    let ui = Rc::downgrade(ui);
    view.connect_local("preflight-commit",false,move|values|{
        let valid=(||{let view=weak.upgrade()?;let buffer=view.buffer().downcast::<sourceview5::Buffer>().ok()?;let text=values[1].get::<String>().ok()?;let start=values[2].get::<i32>().ok()?;let end=values[3].get::<i32>().ok()?;Some(allowed(&buffer,&text,start,end))})().unwrap_or(false);
        if !valid{if let Some(ui)=ui.upgrade(){ui.status.set_text(ui.lang.text("Das Ergebnis überschreitet die Texteditorgrenze von 32 MiB oder 64 KiB je logischer Zeile. Keine Änderung übernommen.","The result exceeds the text editor limit of 32 MiB or 64 KiB per logical line. No change was applied."));}}
        Some((!valid).to_value())
    });
}
