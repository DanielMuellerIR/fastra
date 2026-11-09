use super::{buffer_text, Document, Ui};
use fastra_core::encoding::LineEnding;
use gtk::{glib, prelude::*};
use std::{cell::Cell, rc::Rc};

pub(super) struct State {
    saved: Cell<LineEnding>,
    pending: Cell<Option<LineEnding>>,
    updating: Cell<bool>,
    choice: glib::WeakRef<gtk::DropDown>,
}
impl State {
    pub(super) fn new(text: &str) -> Self {
        Self {
            saved: Cell::new(LineEnding::detect(text)),
            pending: Cell::new(None),
            updating: Cell::new(false),
            choice: glib::WeakRef::new(),
        }
    }
    pub(super) fn current(&self) -> LineEnding {
        self.pending.get().unwrap_or(self.saved.get())
    }
    pub(super) fn pending(&self) -> Option<LineEnding> {
        self.pending.get()
    }
    pub(super) fn saved(&self) -> LineEnding {
        self.saved.get()
    }
    pub(super) fn editor_ending(&self, original: &str) -> LineEnding {
        if self.pending().is_some() || self.saved() != LineEnding::detect(original) {
            self.current()
        } else {
            super::rectangle::detected_ending(original)
        }
    }
    pub(super) fn accept(&self, choice: LineEnding) {
        self.saved.set(choice);
        self.pending.set(None);
    }
    pub(super) fn reset(&self, text: &str) {
        self.saved.set(LineEnding::detect(text));
        self.pending.set(None);
    }
    pub(super) fn restore(&self, saved: Option<u8>, pending: Option<u8>, text: &str) {
        self.saved.set(
            saved
                .and_then(decode)
                .unwrap_or_else(|| LineEnding::detect(text)),
        );
        self.pending.set(pending.and_then(decode));
    }
}
pub(super) fn encode(value: LineEnding) -> u8 {
    match value {
        LineEnding::Lf => 0,
        LineEnding::CrLf => 1,
        LineEnding::Cr => 2,
    }
}
pub(super) fn decode(value: u8) -> Option<LineEnding> {
    match value {
        0 => Some(LineEnding::Lf),
        1 => Some(LineEnding::CrLf),
        2 => Some(LineEnding::Cr),
        _ => None,
    }
}
fn allowed(ui: &Ui, doc: &Document) -> bool {
    !doc.source_edits_locked()
        && !doc.saving.get()
        && !doc.close_pending.get()
        && !ui.window_close_dialog.get()
        && !ui.close_committed.get()
        && !doc
            .hex_editor
            .borrow()
            .as_ref()
            .is_some_and(|editor| editor.dirty())
        && ui
            .active()
            .is_some_and(|active| std::ptr::eq(active.as_ref(), doc))
}
pub(super) fn refresh(ui: &Ui, doc: &Document) {
    let Some(choice) = doc.line_endings.choice.upgrade() else {
        return;
    };
    doc.line_endings.updating.set(true);
    choice.set_selected(u32::from(encode(doc.line_endings.current())));
    choice.set_sensitive(allowed(ui, doc));
    choice.set_tooltip_text(Some(if doc.line_endings.pending().is_some() {
        ui.lang.text("Vorgemerkt: Umbrüche werden erst beim Speichern konvertiert. Der aktuelle Quelltext bleibt erhalten.", "Pending: line endings convert only when saving. Current source remains unchanged.")
    } else {
        ui.lang.text("Zeilenenden wählen. Erst Speichern vereinheitlicht die Umbrüche; die Kodierung bleibt erhalten.", "Choose line endings. Saving normalizes them; the encoding is retained.")
    }));
    doc.line_endings.updating.set(false);
}
pub(super) fn install(ui: &Rc<Ui>, doc: &Rc<Document>, row: &gtk::Box) {
    row.append(&gtk::Label::new(Some(
        ui.lang.text("Zeilenenden", "Line endings"),
    )));
    let choice = gtk::DropDown::from_strings(&["LF", "CRLF", "CR"]);
    doc.line_endings.choice.set(Some(&choice));
    choice.set_selected(u32::from(encode(doc.line_endings.current())));
    let owner = Rc::downgrade(ui);
    let document = Rc::downgrade(doc);
    choice.connect_selected_notify(move |choice| {
        let (Some(ui), Some(doc)) = (owner.upgrade(), document.upgrade()) else {
            return;
        };
        if doc.line_endings.updating.get() {
            return;
        }
        if let Some(value) = u8::try_from(choice.selected()).ok().and_then(decode) {
            choose(&ui, &doc, value);
        }
        refresh(&ui, &doc);
    });
    row.append(&choice);
}
fn choose(ui: &Rc<Ui>, doc: &Rc<Document>, value: LineEnding) {
    if !allowed(ui, doc) || value == doc.line_endings.current() {
        return;
    }
    doc.line_endings
        .pending
        .set((value != doc.line_endings.saved()).then_some(value));
    doc.revision.set(doc.revision.get().wrapping_add(1));
    for rect in doc.rectangles.borrow().iter() {
        rect.invalidate_request();
    }
    doc.update_saved_baseline_status(&buffer_text(&doc.buffer));
    doc.update_label();
    ui.invalidate();
    super::session::changed(ui);
    ui.status.set_text(ui.lang.text(
        "Zeilenenden vorgemerkt. Erst Speichern konvertiert den Quelltext.",
        "Line endings selected. Source converts only when saved.",
    ));
}
pub(super) fn converted(
    text: &str,
    pending: Option<LineEnding>,
) -> Result<String, fastra_io::Error> {
    let result = pending.map_or_else(|| text.to_owned(), |ending| ending.convert(text));
    if result.len() > fastra_document::EDITABLE_BYTES
        || result.contains('\0')
        || result
            .split(['\r', '\n'])
            .any(|line| line.len() > fastra_document::TEXT_SECTION_BYTES)
    {
        return Err(fastra_io::Error::Limit);
    }
    Ok(result)
}
fn converted_offset(source: &str, offset: i32, ending: LineEnding) -> i32 {
    let mut before = 0;
    let mut after = 0;
    let mut chars = source.chars().peekable();
    while before < offset {
        let Some(c) = chars.next() else { break };
        before += 1;
        if c == '\r' || c == '\n' {
            if c == '\r' && chars.peek() == Some(&'\n') {
                chars.next();
                before += 1;
            }
            after += if ending == LineEnding::CrLf { 2 } else { 1 };
        } else {
            after += 1;
        }
    }
    after
}
pub(super) fn complete(
    doc: &Document,
    source: &str,
    saved: &str,
    revision: u64,
    choice: LineEnding,
    pending: Option<LineEnding>,
) -> bool {
    let current = doc.revision.get() == revision
        && doc.line_endings.pending() == pending
        && buffer_text(&doc.buffer) == source;
    doc.line_endings.saved.set(choice);
    if !current {
        return false;
    }
    if source != saved {
        let buffers=doc.source_panes.borrow().as_ref().map(|p|p.buffers.to_vec()).unwrap_or_else(||vec![doc.buffer.clone()]);
        let selections:Vec<_>=buffers.iter().map(|buffer|(
            converted_offset(source,buffer.cursor_position(),choice),
            converted_offset(source,buffer.iter_at_mark(&buffer.selection_bound()).offset(),choice)
        )).collect();
        doc.buffer.begin_user_action();
        let (mut a, mut b) = doc.buffer.bounds();
        doc.buffer.delete(&mut a, &mut b);
        doc.buffer.insert(&mut a, saved);
        doc.buffer.end_user_action();
        for (buffer,(insert,bound)) in buffers.iter().zip(selections){buffer.select_range(&buffer.iter_at_offset(insert),&buffer.iter_at_offset(bound));}
    }
    doc.line_endings.pending.set(None);
    true
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_EOL_NOOP_CLOSE_SELFTEST").is_some() {
        no_op_close_gui_test::run(ui);
    } else if std::env::var_os("FASTRA_EOL_RICH_SELFTEST").is_some() {
        rich_gui_test::run(ui);
    } else {
        gui_test::run(ui);
    }
}

fn save_receipt(
    ui: &Ui,
    doc: &Document,
    before: u64,
    after: u64,
    adopted: bool,
) -> super::close_protocol::SaveOutcome {
    if adopted
        && doc.revision.get() == after
        && !doc.buffer.is_modified()
        && doc.line_endings.pending().is_none()
        && ui.window.is_visible()
        && ui
            .documents
            .borrow()
            .iter()
            .any(|item| std::ptr::eq(item.as_ref(), doc))
    {
        super::close_protocol::SaveOutcome::Saved { before, after }
    } else {
        super::close_protocol::SaveOutcome::Stale
    }
}
pub(super) fn finish_save(
    ui: &Rc<Ui>,
    doc: &Rc<Document>,
    before: u64,
    adopted: bool,
    rebuilt: bool,
    ticket: Option<Rc<super::close_protocol::Ticket>>,
    done: super::close_protocol::SaveCompletion,
) {
    let after = doc.revision.get();
    if !adopted || !rebuilt || !doc.is_rich_active() {
        done(save_receipt(ui, doc, before, after, adopted));
        return;
    }
    let owner = Rc::downgrade(ui);
    let document = Rc::downgrade(doc);
    let started = std::time::Instant::now();
    let mut done = Some(done);
    glib::timeout_add_local(std::time::Duration::from_millis(20), move || {
        let (Some(ui), Some(doc)) = (owner.upgrade(), document.upgrade()) else {
            if let Some(done) = done.take() {
                done(super::close_protocol::SaveOutcome::Stale);
            }
            return glib::ControlFlow::Break;
        };
        if started.elapsed() > std::time::Duration::from_secs(10)
            || ticket.as_ref().is_some_and(|ticket| !ticket.current())
            || save_receipt(&ui, &doc, before, after, true)
                == super::close_protocol::SaveOutcome::Stale
        {
            if let Some(done) = done.take() {
                done(super::close_protocol::SaveOutcome::Stale);
            }
            return glib::ControlFlow::Break;
        }
        let editor = doc
            .rich
            .borrow()
            .clone()
            .filter(|editor| editor.active.get());
        if editor
            .as_ref()
            .is_some_and(|editor| !editor.ready_for_saved_source())
        {
            return glib::ControlFlow::Continue;
        }
        let completed = done.take().unwrap();
        if let (Some(ticket), Some(editor)) = (&ticket, editor) {
            ticket.hold_saved_editor(
                editor,
                Box::new(move |held| {
                    completed(save_receipt(&ui, &doc, before, after, held));
                }),
            );
        } else if doc.close_pending.get() {
            if let Some(editor) = doc
                .rich
                .borrow()
                .clone()
                .filter(|editor| editor.active.get())
            {
                let fences = super::rich_editor::CloseFences::new();
                let owned = fences.clone();
                let target = doc.clone();
                super::rich_editor::hold_for_close(
                    fences,
                    editor,
                    Box::new(move |held| {
                        completed(save_receipt(&ui, &target, before, after, held));
                        owned.cancel();
                    }),
                );
            } else {
                completed(save_receipt(&ui, &doc, before, after, true));
            }
        } else {
            completed(save_receipt(&ui, &doc, before, after, true));
        }
        glib::ControlFlow::Break
    });
}

#[cfg(debug_assertions)]
mod rich_gui_test;

#[cfg(debug_assertions)]
pub(super) fn select_for_test(doc: &Document, ending: LineEnding) {
    doc.line_endings
        .choice
        .upgrade()
        .unwrap()
        .set_selected(u32::from(encode(ending)));
}

#[cfg(debug_assertions)]
mod no_op_close_gui_test;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn explicit_conversion_preserves_unicode_and_normalizes_all_three_forms() {
        let source = "é🙂\r\n二\rthree\nlast";
        assert_eq!(converted(source, None).unwrap(), source);
        assert_eq!(
            converted(source, Some(LineEnding::Lf)).unwrap(),
            "é🙂\n二\nthree\nlast"
        );
        assert_eq!(
            converted(source, Some(LineEnding::CrLf)).unwrap(),
            "é🙂\r\n二\r\nthree\r\nlast"
        );
        assert_eq!(
            converted(source, Some(LineEnding::Cr)).unwrap(),
            "é🙂\r二\rthree\rlast"
        );
    }
    #[test]
    fn conversion_keeps_empty_last_line_and_handles_utf8_byte_limits() {
        assert_eq!(
            converted("a\n\n", Some(LineEnding::CrLf)).unwrap(),
            "a\r\n\r\n"
        );
        assert!(converted(&"é".repeat(32768), Some(LineEnding::CrLf)).is_ok());
        assert!(converted(&"é".repeat(32769), Some(LineEnding::Lf)).is_err());
        assert!(converted("a\0b", None).is_err());
        let at_limit = "\n".repeat(fastra_document::EDITABLE_BYTES / 2);
        assert_eq!(
            converted(&at_limit, Some(LineEnding::CrLf)).unwrap().len(),
            fastra_document::EDITABLE_BYTES
        );
        assert!(converted(&(at_limit + "\n"), Some(LineEnding::CrLf)).is_err());
    }
    #[test]
    fn caret_boundaries_follow_unicode_and_original_crlf_pairs() {
        let source = "é🙂\r\n二\rA\nZ";
        for (ending, expected) in [
            (LineEnding::Lf, vec![0, 1, 2, 3, 3, 4, 5, 6, 7, 8]),
            (LineEnding::CrLf, vec![0, 1, 2, 4, 4, 5, 7, 8, 10, 11]),
            (LineEnding::Cr, vec![0, 1, 2, 3, 3, 4, 5, 6, 7, 8]),
        ] {
            let observed: Vec<_> = (0..=source.chars().count() as i32)
                .map(|offset| converted_offset(source, offset, ending))
                .collect();
            assert_eq!(observed, expected);
        }
    }
}
