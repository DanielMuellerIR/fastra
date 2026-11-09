use super::*;
use std::{path::Path, time::Duration};

pub(crate) struct Prepared {
    body: String,
    configuration: Value,
    images: images::Cache,
    prefix: String,
}
pub(crate) fn prepare(
    source: &str,
    path: Option<&Path>,
    lang: Language,
    cancel: &crate::viewer::Cancellation,
) -> Result<Prepared, String> {
    let prefix = glib::uuid_string_random().to_string();
    let sources = images::Sources::collect(source, path, &prefix)?;
    let page = page_images(source, &prefix, false, lang.0, Some(&sources)).map_err(|_| {
        lang.text(
            "Rich-Markdown: höchstens 2 MiB und 10.000 Blöcke; kein Nullzeichen.",
            "Rich Markdown: at most 2 MiB and 10,000 blocks; no NUL character.",
        )
        .to_owned()
    })?;
    let images = sources.load(cancel);
    Ok(Prepared {
        body: page.body,
        configuration: page.configuration,
        images,
        prefix,
    })
}
impl RichEditor {
    pub(crate) fn can_replace_source(&self) -> bool {
        self.ready_for_saved_source() && !self.clipboard_busy.get()
    }
    fn replacement_error(&self, reason: &str) -> String {
        let (de,en) = match reason {
            "limit" => ("Der Rich-Verlauf überschreitet 32 MiB. Die vorhandene Ansicht und ihr Undo bleiben erhalten; nichts übernommen.", "The Rich history exceeds 32 MiB. The existing view and its Undo are retained; nothing applied."),
            "images" => ("Die Bildgrenze der Rich-Ansicht ist erreicht (256 Bilder, 64 MiB oder 64 Millionen Pixel). Nichts übernommen.", "The Rich view image limit was reached (256 images, 64 MiB or 64 million pixels). Nothing applied."),
            "busy" => ("Rich-Eingabe oder Synchronisation noch nicht abgeschlossen. Nichts übernommen; erneut vergleichen.", "Rich input or synchronization is still pending. Nothing applied; compare again."),
            "stale" => ("Rich-Quelle inzwischen geändert. Nichts überschrieben; erneut vergleichen.", "The Rich source changed. Nothing overwritten; compare again."),
            "timeout" => ("Rich-Übernahme antwortet nicht. Weitere Änderungen angehalten; Quelle und Ansicht prüfen.", "Rich transfer did not respond. Further changes are held; review the source and view."),
            _ => ("Rich-Editor konnte die vollständige Vorschau nicht unverändert übernehmen. Quelle und Ansicht bleiben erhalten; erneut vergleichen.", "The Rich editor could not adopt the complete preview unchanged. Source and view are retained; compare again."),
        };
        self.text(de, en).into()
    }
    pub(crate) fn replace_source(
        self: &Rc<Self>,
        mut prepared: Prepared,
        expected: &str,
        done: Box<dyn FnOnce(Result<(), String>)>,
    ) {
        if !self.can_replace_source() || self.expected.borrow().as_str() != expected {
            done(Err(self.replacement_error("stale")));
            return;
        }
        let mut body = prepared.images.versioned_html(&prepared.body);
        prepared.images.reuse_versions(&self.images.borrow(), &mut body);
        if !self.images.borrow().can_extend(&prepared.images) {
            done(Err(self.replacement_error("images")));
            return;
        }
        self.images
            .borrow_mut()
            .images
            .extend(prepared.images.images);
        let output = prepared.configuration["markdown"]
            .as_str()
            .unwrap()
            .to_owned();
        let code = format!("const outcome=await fastraVisual.replaceSource({},{},{},{});return JSON.stringify({{ok:outcome===true,reason:outcome,...fastraVisual.clipboardState()}});", json!(expected), json!(body), prepared.configuration, json!(prepared.prefix));
        self.busy.set(true);
        let operation = self.operation.get().wrapping_add(1);
        self.operation.set(operation);
        let completion = Rc::new(RefCell::new(Some(done)));
        let expired = completion.clone();
        let closed = self
            .text(
                "Rich-Ansicht geschlossen. Nichts übernommen.",
                "Rich view closed. Nothing applied.",
            )
            .to_owned();
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_secs(10), move || {
            if let Some(done) = expired.borrow_mut().take() {
                let error = if let Some(editor) = weak.upgrade() {
                    editor.operation.set(editor.operation.get().wrapping_add(1));
                    editor.busy.set(false);
                    editor.fail("Rich-Übernahme abgebrochen. Ungesicherte Ansicht bleibt erhalten; weitere Änderungen angehalten.", "Rich transfer stopped. The unsaved view is retained; further changes are held.");
                    editor.replacement_error("timeout")
                } else {
                    closed
                };
                done(Err(error));
            }
        });
        let weak = Rc::downgrade(self);
        self.evaluate(&code, move |result| {
            let Some(editor) = weak.upgrade().filter(|editor| editor.operation.get() == operation) else { return; };
            if completion.borrow().is_none() { return; }
            let revision = result.as_ref().filter(|value| value["ok"] == true && value["markdown"].as_str() == Some(output.as_str())).and_then(|value| value["revision"].as_u64());
            let Some(revision) = revision else {
                editor.busy.set(false);
                let reason = result.as_ref().and_then(|value| value["reason"].as_str()).unwrap_or("failed");
                if matches!(reason,"insert"|"incomplete"|"unsupported"|"failed") { editor.fail("Rich-Ansicht konnte nicht verlustfrei aktualisiert werden. Quelle erhalten; weitere Änderungen angehalten.", "Rich view could not be updated losslessly. Source retained; further changes are held."); }
                let error = editor.replacement_error(reason);
                if let Some(done) = completion.borrow_mut().take() { done(Err(error)); }
                return;
            };
            let weak = Rc::downgrade(&editor);
            glib::timeout_add_local(Duration::from_millis(20), move || {
                if completion.borrow().is_none() { return glib::ControlFlow::Break; }
                let Some(editor) = weak.upgrade() else { return glib::ControlFlow::Break; };
                let accepted = editor.input_revision.get() == revision && editor.expected.borrow().as_str() == output && editor.current().is_some();
                if accepted || editor.failed.get() {
                    editor.busy.set(false);
                    let result = if accepted { Ok(()) } else { Err(editor.replacement_error("failed")) };
                    if let Some(done) = completion.borrow_mut().take() { done(result); }
                    glib::ControlFlow::Break
                } else { glib::ControlFlow::Continue }
            });
        });
    }
    #[cfg(debug_assertions)]
    pub(crate) fn image_cache_metrics(&self) -> (usize, usize, u64) {
        let cache = self.images.borrow();
        (cache.images.len(), cache.bytes(), cache.pixels())
    }
}
