use super::*;
use approval::search::Replacement;
use std::{rc::Weak, sync::Arc};

pub(super) struct Context {
    pub owner: Weak<Ui>,
    pub doc: Weak<Document>,
    pub buffer: sourceview5::Buffer,
    pub generation: u64,
    pub lang: Language,
    pub current: Rc<dyn Fn() -> bool>,
    pub applied: Rc<dyn Fn()>,
}
pub(super) fn run(context: Context, command: Replacement) {
    if !(command.current)() || !(context.current)() {
        (command.finish)();
        return;
    }
    let Some(doc) = context.doc.upgrade() else {
        (command.finish)();
        return;
    };
    let Some(ui) = context.owner.upgrade() else {
        (command.finish)();
        return;
    };
    if !ui.window.is_visible()
        || ui.window_close_dialog.get()
        || ui.close_committed.get()
        || close_protocol::active(&ui)
        || doc.close_pending.get()
        || doc.source_edits_locked()
    {
        (command.finish)();
        return;
    }
    let epoch = source_panes::stamp(&doc).map(|stamp| stamp.3);
    let source = buffer_text(&context.buffer);
    let revision = doc.revision.get();
    let generation = context.generation;
    let preview = command.preview.clone();
    let cancel = command.cancel.clone();
    let hit = command.hit;
    let range = command.range;
    let lang = context.lang;
    git_view::background(
        move || {
            #[cfg(debug_assertions)]
            if let Ok(value) = std::env::var("FASTRA_SINGLE_REPLY_DELAY_MS") {
                assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                let delay = value.parse::<u64>().unwrap();
                assert!(delay <= 5000);
                std::thread::sleep(Duration::from_millis(delay));
            } else {
                source_panes::delay_reply();
            }
            let text = preview
                .apply(&source, revision, generation, &[hit], &cancel)
                .map_err(|e| error_text(lang, &e))?;
            text_limits::validate(&text, lang)?;
            if text == source {
                return Ok(None);
            }
            let replacement = preview
                .matches()
                .get(hit)
                .ok_or_else(|| error_text(lang, &fastra_core::Error::Stale))?
                .replacement
                .clone();
            cancel.check().map_err(|e| error_text(lang, &e))?;
            Ok::<_, String>(Some((text, replacement)))
        },
        move |result| {
            (command.finish)();
            let Some(doc) = context.doc.upgrade() else {
                return;
            };
            let Some(ui) = context.owner.upgrade() else {
                return;
            };
            if !ui.window.is_visible()
                || ui.window_close_dialog.get()
                || ui.close_committed.get()
                || close_protocol::active(&ui)
                || doc.close_pending.get()
                || doc.source_edits_locked()
                || source_panes::stamp(&doc).map(|stamp| stamp.3) != epoch
            {
                return;
            }
            if !(command.current)()
                || !(context.current)()
                || doc.revision.get() != revision
                || buffer_text(&context.buffer) != command.preview.source()
            {
                return;
            }
            match result {
                Ok(Some((text, replacement))) => {
                    let buffer = &context.buffer;
                    if range.0 < 0 || range.1 < range.0 || range.1 > buffer.char_count() {
                        return;
                    }
                    buffer.begin_user_action();
                    buffer.end_user_action();
                    buffer.begin_user_action();
                    buffer.delete(
                        &mut buffer.iter_at_offset(range.0),
                        &mut buffer.iter_at_offset(range.1),
                    );
                    buffer.insert(&mut buffer.iter_at_offset(range.0), &replacement);
                    buffer.end_user_action();
                    doc.update_saved_baseline_status(&text);
                    (context.applied)();
                }
                Ok(None) => {}
                Err(error) => (command.report)(&error),
            }
        },
    );
}

#[cfg(debug_assertions)]
pub(super) mod selftest;

pub(super) fn install(ui: &Rc<Ui>) {
    let weak = Rc::downgrade(ui);
    *ui.approval.on_replace.borrow_mut() = Some(Rc::new(move |command| {
        let Some(ui) = weak.upgrade() else {
            (command.finish)();
            return;
        };
        let Some(doc) = ui.active() else {
            (command.finish)();
            return;
        };
        let buffer = match ui
            .pending
            .borrow()
            .as_ref()
            .filter(|p| Arc::ptr_eq(&p.preview, &command.preview))
            .and_then(|p| p.target.as_ref().map(|t| t.buffer.clone()))
        {
            Some(value) => value,
            None => {
                (command.finish)();
                return;
            }
        };
        let generation = ui.generation.get();
        let ordinal = command.ordinal;
        let preview = command.preview.clone();
        let owner = Rc::downgrade(&ui);
        let document = Rc::downgrade(&doc);
        let current = Rc::new(move || {
            let (Some(ui), Some(doc)) = (owner.upgrade(), document.upgrade()) else {
                return false;
            };
            ui.generation.get() == generation
                && !doc.close_pending.get()
                && !doc.source_edits_locked()
                && ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
                && ui.pending.borrow().as_ref().is_some_and(|p| {
                    Arc::ptr_eq(&p.preview, &preview)
                        && p.target.as_ref().is_some_and(|target| {
                            target.valid_document(&doc)
                                && search_selection::valid(&ui, &doc, p.selection)
                        })
                })
        });
        let owner = Rc::downgrade(&ui);
        let document = Rc::downgrade(&doc);
        let applied = Rc::new(move || {
            let (Some(ui), Some(doc)) = (owner.upgrade(), document.upgrade()) else {
                return;
            };
            let expected = ui.generation.get() + 1;
            let revision = doc.revision.get();
            let owner = Rc::downgrade(&ui);
            let document = Rc::downgrade(&doc);
            ui.approval.resume_at(
                ordinal,
                Rc::new(move || {
                    let (Some(ui), Some(doc)) = (owner.upgrade(), document.upgrade()) else {
                        return false;
                    };
                    ui.generation.get() == expected
                        && doc.revision.get() == revision
                        && ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
                }),
            );
            ui.search();
        });
        run(
            Context {
                owner: Rc::downgrade(&ui),
                doc: Rc::downgrade(&doc),
                buffer,
                generation,
                lang: ui.lang,
                current,
                applied,
            },
            command,
        );
    }));
}
