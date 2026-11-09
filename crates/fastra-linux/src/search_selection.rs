//! Der Suchbereich bleibt vom sichtbaren Treffer und dessen Einfügemarke getrennt.
use super::*;
use std::rc::Weak;

pub(super) struct Frozen {
    doc: Weak<Document>,
    buffer: sourceview5::Buffer,
    start: gtk::TextMark,
    end: gtk::TextMark,
}
impl Drop for Frozen {
    fn drop(&mut self) {
        self.buffer.delete_mark(&self.start);
        self.buffer.delete_mark(&self.end);
    }
}
pub(super) fn capture(ui: &Ui) {
    let frozen = ui.active().and_then(|doc| {
        let (a, b) = selected_offsets(&doc)?;
        if a >= b || (!doc.has_source_text() || doc.is_rich_active()) {
            return None;
        }
        let buffer = doc.buffer.clone();
        Some(Frozen {
            doc: Rc::downgrade(&doc),
            start: buffer.create_mark(None, &buffer.iter_at_offset(a), true),
            end: buffer.create_mark(None, &buffer.iter_at_offset(b), false),
            buffer,
        })
    });
    *ui.search_selection.borrow_mut() = frozen;
}
pub(super) fn range(ui: &Ui, doc: &Document) -> Option<(i32, i32)> {
    let frozen = ui.search_selection.borrow();
    let frozen = frozen.as_ref()?;
    if !frozen
        .doc
        .upgrade()
        .is_some_and(|owner| std::ptr::eq(owner.as_ref(), doc))
        || frozen.buffer != doc.buffer
        || frozen.start.is_deleted()
        || frozen.end.is_deleted()
    {
        return None;
    }
    let a = frozen.buffer.iter_at_mark(&frozen.start).offset();
    let b = frozen.buffer.iter_at_mark(&frozen.end).offset();
    (a < b).then_some((a, b))
}
pub(super) fn valid(ui: &Ui, doc: &Document, expected: Option<(i32, i32)>) -> bool {
    expected.is_none_or(|expected| ui.scope.selected() == 4 && range(ui, doc) == Some(expected))
}

pub(super) fn available(ui: &Ui) -> bool {
    ui.active().is_some_and(|doc| range(ui, &doc).is_some())
}
pub(super) fn refresh(ui: &Ui) {
    if let Some(toggle) = ui.selection_control.upgrade() {
        toggle.set_sensitive(
            ui.scope.selected() == 4
                || ui
                    .active()
                    .is_some_and(|doc| selected_offsets(&doc).is_some()),
        );
    }
}
pub(super) fn capture_multiline(ui: &Ui) {
    let multiline = ui.active().is_some_and(|doc| {
        selected_offsets(&doc).is_some_and(|(a, b)| {
            let buffer = source_panes::buffer(&doc);
            buffer
                .text(&buffer.iter_at_offset(a), &buffer.iter_at_offset(b), true)
                .contains(['\r', '\n'])
        })
    });
    if multiline {
        capture(ui);
        ui.scope.set_selected(4);
    } else {
        ui.scope.set_selected(0);
        ui.search_selection.borrow_mut().take();
    }
    refresh(ui);
}

#[cfg(debug_assertions)]
pub(super) mod selftest;
