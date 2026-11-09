use super::*;
use std::path::PathBuf;

fn document_path(doc: &Document) -> Option<PathBuf> {
    doc.snapshot
        .borrow()
        .as_ref()
        .map(fastra_io::Snapshot::path)
        .or_else(|| {
            doc.section_view
                .borrow()
                .as_ref()
                .map(|v| v.source().path().to_owned())
        })
        .or_else(|| {
            doc.visual_view
                .borrow()
                .as_ref()
                .map(|v| v.print_source().snapshot().path())
        })
}

pub(super) fn open(ui: &Rc<Ui>) {
    let Some(doc) = ui.active() else { return };
    if doc.saving.get() {
        ui.status.set_text(ui.lang.text(
            "Speichern zuerst abschließen lassen.",
            "Wait for saving to finish.",
        ));
        return;
    }
    let Some(path) = document_path(&doc) else {
        ui.status.set_text(ui.lang.text(
            "Dateibytes benötigen eine gespeicherte Datei. Den neuen Text zuerst speichern.",
            "Disk bytes require a saved file. Save the new text first.",
        ));
        return;
    };
    if let Some(view) = doc.section_view.borrow().as_ref() {
        if doc.hex_editor.borrow().is_some() {
            super::hex_editor::open(ui, &doc, view.source());
            ui.status.set_text(ui.lang.text("Vorhandener Hexentwurf geöffnet. Er enthält gegebenenfalls noch ungespeicherte Bytes.","Existing hex draft opened. It may contain unsaved bytes."));
            return;
        }
    }
    let revision = doc.revision.get();
    let owner = Rc::downgrade(&doc);
    let weak = Rc::downgrade(ui);
    let requested = path.clone();
    let cancel = Cancellation::default();
    let worker_cancel = cancel.clone();
    ui.status.set_text(ui.lang.text("Dateibytes werden in einem neuen Tab geöffnet. Ungespeicherter Quelltext bleibt im bisherigen Tab.","Opening on-disk bytes in a new tab. Unsaved source text stays in the previous tab."));
    super::git_view::background(
        move || {
            let source = fastra_document::Document::open_hex(&requested, &worker_cancel)
                .map_err(|e| e.to_string())?;
            source
                .verify_current(&worker_cancel)
                .map_err(|e| e.to_string())?;
            Ok(source)
        },
        move |result| {
            let (Some(ui), Some(doc)) = (weak.upgrade(), owner.upgrade()) else {
                cancel.cancel();
                return;
            };
            if !ui.window.is_visible()
                || doc.saving.get()
                || doc.revision.get() != revision
                || document_path(&doc).as_ref() != Some(&path)
                || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
            {
                cancel.cancel();
                return;
            }
            match result {
                Ok(source) => {
                    let name = format!(
                        "{} · Hex",
                        super::project_view::display(
                            path.file_name().map(std::path::Path::new).unwrap_or(&path)
                        )
                    );
                    ui.add_section(&name, source, true, path, None);
                    ui.status.set_text(ui.lang.text("Hex zeigt die Dateibytes auf dem Datenträger. Ungespeicherter Quelltext bleibt im vorherigen Tab; Bearbeiten ist ein eigener, freigabepflichtiger Entwurf.","Hex shows on-disk file bytes. Unsaved source text stays in the previous tab; editing requires a separate approved draft."));
                }
                Err(error) => ui.status.set_text(&format!(
                    "{}: {error}",
                    ui.lang
                        .text("Dateibytes nicht geöffnet", "Disk bytes not opened")
                )),
            }
        },
    );
}
