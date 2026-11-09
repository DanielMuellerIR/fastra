use super::*;
use fastra_core::{markdown_formatting as format, Utf16Range};

#[derive(Clone, Copy)]
pub(super) enum Command {
    Format(format::Command),
    Table(usize, bool),
}
pub(super) fn run(ui: &Rc<Ui>, doc: &Rc<Document>, target: source_panes::Target, command: Command) {
    if !allowed(doc) || !target.valid(doc) {
        ui.status.set_text(ui.lang.text("Formatierung benötigt eine zusammenhängende Auswahl im bearbeitbaren Markdown-Quelltext. Quelle oder Auswahl neu wählen.","Formatting requires a continuous selection in editable Markdown source. Select the source or selection again."));
        return;
    }
    ui.invalidate();
    let generation = ui.generation.get();
    let source = buffer_text(&target.buffer);
    let offsets = target.offsets();
    let cancel = Cancellation::default();
    *ui.cancellation.borrow_mut() = cancel.clone();
    let completion = cancel.clone();
    let lang = ui.lang;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        #[cfg(debug_assertions)]
        source_panes::delay_reply();
        let result = (|| {
            text_limits::validate(&source, lang)?;
            let selection = Utf16Range {
                location: source
                    .chars()
                    .take(offsets.0 as usize)
                    .map(char::len_utf16)
                    .sum(),
                length: source
                    .chars()
                    .skip(offsets.0 as usize)
                    .take((offsets.1 - offsets.0) as usize)
                    .map(char::len_utf16)
                    .sum(),
            };
            let edit = match command {
                Command::Format(command) => format::edit(&source, selection, command, &cancel),
                Command::Table(columns, header) => format::table(
                    &source,
                    selection,
                    columns,
                    header,
                    lang.text("Spalte", "Column"),
                    &cancel,
                )
                .map(Some),
            }
            .map_err(|error| error_text(lang, &error))?;
            let Some(edit) = edit else {
                return Ok(None);
            };
            let range = edit
                .range
                .byte_range(&source)
                .map_err(|e| error_text(lang, &e))?;
            let start = source[..range.start].chars().count() as i32;
            let end = start + source[range.clone()].chars().count() as i32;
            let mut candidate = source;
            candidate.replace_range(range, &edit.replacement);
            text_limits::validate(&candidate, lang)?;
            let selection = edit
                .selection
                .byte_range(&candidate)
                .map_err(|e| error_text(lang, &e))?;
            let a = candidate[..selection.start].chars().count() as i32;
            let b = a + candidate[selection].chars().count() as i32;
            cancel.check().map_err(|e| error_text(lang, &e))?;
            Ok::<_, String>(Some((start, end, edit.replacement, a, b)))
        })();
        let _ = tx.send(result);
    });
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    glib::timeout_add_local(Duration::from_millis(20), move || {
        let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) else {
            completion.cancel();
            return glib::ControlFlow::Break;
        };
        if ui.generation.get() != generation || !allowed(&doc) || !target.valid(&doc) {
            completion.cancel();
            if ui.generation.get() == generation {
                ui.status.set_text(ui.lang.text(
                    "Quelle oder Auswahl geändert. Formatierung nicht übernommen.",
                    "Source or selection changed. Formatting was not applied.",
                ));
            }
            return glib::ControlFlow::Break;
        }
        match rx.try_recv() {
            Ok(Ok(Some((a, b, replacement, start, end)))) => {
                let buffer = &target.buffer;
                buffer.begin_user_action();
                buffer.end_user_action();
                buffer.begin_user_action();
                buffer.delete(&mut buffer.iter_at_offset(a), &mut buffer.iter_at_offset(b));
                buffer.insert(&mut buffer.iter_at_offset(a), &replacement);
                buffer.select_range(&buffer.iter_at_offset(end), &buffer.iter_at_offset(start));
                buffer.end_user_action();
                target.view.grab_focus();
                glib::ControlFlow::Break
            }
            Ok(Ok(None)) => glib::ControlFlow::Break,
            Ok(Err(error)) => {
                ui.status.set_text(&error);
                glib::ControlFlow::Break
            }
            Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
            Err(_) => glib::ControlFlow::Break,
        }
    });
}

pub(super) fn table(ui: &Rc<Ui>, doc: &Rc<Document>, target: source_panes::Target) {
    if !allowed(doc) || !target.valid(doc) {
        ui.status.set_text(ui.lang.text("Formatierung benötigt eine zusammenhängende Auswahl im bearbeitbaren Markdown-Quelltext. Quelle oder Auswahl neu wählen.","Formatting requires a continuous selection in editable Markdown source. Select the source or selection again."));
        return;
    }
    let owner = Rc::downgrade(doc);
    let weak = Rc::downgrade(ui);
    super::table_prompt(&ui.window, ui.lang, move |columns, header| {
        if let (Some(ui), Some(doc)) = (weak.upgrade(), owner.upgrade()) {
            run(&ui, &doc, target, Command::Table(columns, header));
        }
    });
}
