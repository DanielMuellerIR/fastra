use super::*;
use std::{path::PathBuf, rc::Weak};

pub(crate) struct Bookmark {
    editor: Weak<RichEditor>,
    lang: Language,
    key: String,
    session: String,
    input: u64,
    generation: u64,
    revision: u64,
    path: Option<PathBuf>,
    consumed: Cell<bool>,
}
impl Bookmark {
    pub(crate) fn current(&self) -> bool {
        !self.consumed.get()
            && self.editor.upgrade().is_some_and(|e| {
                e.ready.get()
                    && !e.busy.get()
                    && !e.failed.get()
                    && e.focused()
                    && e.session == self.session
                    && e.input_revision.get() == self.input
                    && e.ui.upgrade().is_some_and(|ui| {
                        ui.generation.get() == self.generation
                            && !ui.close_committed.get()
                            && !crate::close_protocol::active(&ui)
                    })
                    && e.current().is_some_and(|doc| {
                        doc.revision.get() == self.revision
                            && doc.disk_path() == self.path
                            && doc
                                .rich
                                .borrow()
                                .as_ref()
                                .is_some_and(|active| Rc::ptr_eq(active, &e))
                    })
            })
    }
    pub(crate) fn insert(
        self: &Rc<Self>,
        source: String,
        done: impl FnOnce(Result<(), String>) + 'static,
    ) {
        if !self.current() || source.len() > 256 * 1024 || source.contains('\0') {
            done(Err(self.lang.text("Dokument oder festgehaltene Einfügestelle wurde geändert. Textbausteine erneut öffnen.","The document or captured insertion point changed. Reopen text snippets.").into()));
            return;
        }
        let editor = self.editor.upgrade().unwrap();
        let path = self.path.clone();
        if path.is_none() && transfer::has_images(&source) {
            done(Err(self
                .lang
                .text(
                    "Das Dokument vor dem Einfügen von Bildverweisen speichern.",
                    "Save the document before inserting image references.",
                )
                .into()));
            return;
        }
        let session = glib::uuid_string_random().to_string();
        let owner = self.clone();
        let weak = Rc::downgrade(&editor);
        let cancel = editor.image_cancel.clone();
        crate::git_view::background(
            move || {
                let sources = images::Sources::collect(&source, path.as_deref(), &session)?;
                let page = page_images(&source, &session, false, false, Some(&sources))
                    .map_err(|e| format!("{e:?}"))?;
                let cache = sources.load(&cancel);
                cancel.core().check().map_err(|e| format!("{e:?}"))?;
                Ok::<_, String>((page, cache))
            },
            move |result| {
                let Some(editor) = weak.upgrade().filter(|_| owner.current()) else {
                    done(Err(owner
                        .lang
                        .text(
                            "Dokument oder Einfügestelle wurde geändert. Nichts eingefügt.",
                            "The document or insertion point changed. Nothing inserted.",
                        )
                        .into()));
                    return;
                };
                let (page, cache) = match result {
                    Ok(value) => value,
                    Err(error) => {
                        done(Err(format!(
                            "{} {error}",
                            owner.lang.text(
                                "Textbaustein konnte nicht vorbereitet werden:",
                                "Could not prepare the text snippet:"
                            )
                        )));
                        return;
                    }
                };
                {
                    let existing = editor.images.borrow();
                    if !existing.can_extend(&cache) {
                        done(Err(owner
                            .lang
                            .text(
                                "Die Bildgrenze der Rich-Ansicht ist erreicht. Nichts eingefügt.",
                                "The Rich view image limit was reached. Nothing inserted.",
                            )
                            .into()));
                        return;
                    }
                }
                let html = cache.versioned_html(&page.fragment);
                // Textbausteine werden relativ zum Ziel gerendert. Hier entstehen keine Bilddateien und keine versteckten Schreibvorgänge.
                editor.images.borrow_mut().images.extend(cache.images);
                let code = format!(
                    "return JSON.stringify(fastraVisual.insertBookmarked({},{},{},null,[],false));",
                    json!(owner.key),
                    json!(html),
                    page.configuration["opaqueSources"]
                );
                owner.consumed.set(true);
                let weak = Rc::downgrade(&editor);
                let lang = owner.lang;
                editor.evaluate(&code, move |value| {
                    let Some(editor) = weak.upgrade() else {
                        done(Err(lang.text("Zieldokument geschlossen. Nichts eingefügt.","The target document was closed. Nothing inserted.").into()));
                        return;
                    };
                    if value != Some(Value::Bool(true)) {
                        done(Err(lang.text("Die Einfügestelle ist nicht mehr gültig. Textbausteine erneut öffnen.","The insertion point is no longer valid. Reopen text snippets.").into()));
                        return;
                    }
                    let focus = Rc::downgrade(&editor);
                    editor.synchronize(false, Box::new(move |ok| {
                        done(if ok {Ok(())}else{Err(lang.text("Rich-Änderung konnte nicht synchronisiert werden. Der sichtbare Entwurf bleibt erhalten.","The Rich change could not be synchronized. The visible draft is retained.").into())});
                        if ok { glib::idle_add_local_once(move || {if let Some(editor)=focus.upgrade().filter(|e|e.focused()) {
                            editor.view.grab_focus();
                            editor.evaluate("document.getElementById('fastra-visual').focus();return JSON.stringify(true);",|_|{});
                        }});}
                    }));
                });
            },
        );
    }
}
impl Drop for Bookmark {
    fn drop(&mut self) {
        if !self.consumed.get() {
            if let Some(editor) = self.editor.upgrade() {
                editor.evaluate(
                    &format!(
                        "fastraVisual.discardBookmark({});return JSON.stringify(true);",
                        json!(self.key)
                    ),
                    |_| {},
                );
            }
        }
    }
}
pub(crate) fn capture(editor: &Rc<RichEditor>, done: impl FnOnce(Option<Rc<Bookmark>>) + 'static) {
    if !editor.ready.get() || editor.failed.get() || !editor.focused() {
        done(None);
        return;
    }
    let weak = Rc::downgrade(editor);
    let generation = editor.ui.upgrade().unwrap().generation.get();
    let session = editor.session.clone();
    editor.synchronize(
        true,
        Box::new(move |ok| {
            let Some(editor) = weak.upgrade().filter(|e| {
                ok && e.focused()
                    && e.session == session
                    && e.ui
                        .upgrade()
                        .is_some_and(|ui| ui.generation.get() == generation)
            }) else {
                done(None);
                return;
            };
            let doc = editor.current().unwrap();
            let revision = doc.revision.get();
            let path = doc.disk_path();
            let input = editor.input_revision.get();
            let weak = Rc::downgrade(&editor);
            editor.evaluate(
                "return JSON.stringify(fastraVisual.bookmark());",
                move |value| {
                    let Some(editor) = weak.upgrade() else {
                        done(None);
                        return;
                    };
                    editor.release();
                    let bookmark = value
                        .and_then(|v| v.as_str().map(str::to_string))
                        .map(|key| {
                            Rc::new(Bookmark {
                                editor: Rc::downgrade(&editor),
                                lang: editor.ui.upgrade().unwrap().lang,
                                key,
                                session,
                                input,
                                generation,
                                revision,
                                path,
                                consumed: Cell::new(false),
                            })
                        });
                    done(bookmark.filter(|b| b.current()));
                },
            );
        }),
    );
}
