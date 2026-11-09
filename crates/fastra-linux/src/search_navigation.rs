//! Suchsprünge verwenden unveränderliche Vorschauen und eigene Darstellungs-Tags.
use super::*;
use approval::search::Navigation;
use std::{rc::Weak, sync::Arc};
#[cfg(debug_assertions)]
pub(super) mod collection_test;
#[cfg(debug_assertions)]
pub(super) mod selftest;
#[cfg(debug_assertions)]
static DISK_REPLIES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

pub(super) struct Emphasis {
    doc: Weak<Document>,
    preview: std::sync::Weak<Preview>,
    cancel: Cancellation,
    all: gtk::TextTag,
    active: gtk::TextTag,
    #[cfg(debug_assertions)]
    range: (i32, i32),
}
#[cfg(debug_assertions)]
impl Emphasis {
    pub(crate) fn test_range(&self) -> (i32, i32) {
        self.range
    }
}
pub(super) fn clear_cancelled(ui: &Ui) {
    let cancelled = ui
        .search_emphasis
        .borrow()
        .as_ref()
        .is_some_and(|emphasis| emphasis.cancel.check().is_err());
    if cancelled {
        ui.search_emphasis.borrow_mut().take();
    }
}
impl Drop for Emphasis {
    fn drop(&mut self) {
        if let Some(doc) = self.doc.upgrade() {
            source_panes::search_caret(&doc, None);
            let table = doc.buffer.tag_table();
            table.remove(&self.active);
            table.remove(&self.all);
        }
    }
}
pub(super) fn clear_pane(ui: &Ui, items: &[approval::Item]) {
    let clear = ui
        .search_emphasis
        .borrow()
        .as_ref()
        .is_some_and(|emphasis| {
            emphasis.preview.upgrade().is_none_or(|preview| {
                items
                    .iter()
                    .any(|item| Arc::ptr_eq(&item.preview, &preview))
            })
        });
    if clear {
        ui.search_emphasis.borrow_mut().take();
    }
}
fn stale(lang: Language) -> &'static str {
    lang.text(
        "Die Trefferquelle hat sich geändert. Suche neu berechnen; kein Quellsprung ausgeführt.",
        "The match source changed. Recalculate the search; no source jump was made.",
    )
}
fn usable(ui: &Ui, doc: &Document) -> bool {
    ui.window.is_visible()
        && !ui.window_close_dialog.get()
        && !ui.close_committed.get()
        && !close_protocol::active(ui)
        && !doc.close_pending.get()
        && doc.has_source_text() && !doc.is_rich_active()
}
fn display(ui: &Rc<Ui>, doc: &Rc<Document>, navigation: &Navigation) -> Result<(), String> {
    if !(navigation.current)() || !usable(ui, doc) {
        return Err(stale(ui.lang).into());
    }
    let index = ui
        .documents
        .borrow()
        .iter()
        .position(|candidate| Rc::ptr_eq(candidate, doc))
        .ok_or_else(|| stale(ui.lang).to_string())?;
    if ui.tabs.current_page() != Some(index as u32) {
        ui.tabs.set_current_page(Some(index as u32));
    }
    let target = source_panes::capture(doc).ok_or_else(|| stale(ui.lang).to_string())?;
    if navigation.range.0 < 0
        || navigation.range.0 > navigation.range.1
        || navigation.range.1 > target.buffer.char_count()
    {
        return Err(stale(ui.lang).into());
    }
    ui.search_emphasis.borrow_mut().take();
    let all = gtk::TextTag::builder()
        .background_rgba(&gtk::gdk::RGBA::new(1., 0.85, 0.18, 0.42))
        .build();
    let active = gtk::TextTag::builder()
        .background_rgba(&gtk::gdk::RGBA::new(1., 0.70, 0.08, 0.65))
        .build();
    let table = doc.buffer.tag_table();
    table.add(&all);
    table.add(&active);
    if let Some(panes) = doc.source_panes.borrow().as_ref() {
        for buffer in &panes.buffers {
            for &(a, b) in &navigation.ranges {
                if a >= 0 && a <= b && b <= buffer.char_count() {
                    buffer.apply_tag(&all, &buffer.iter_at_offset(a), &buffer.iter_at_offset(b));
                }
            }
            buffer.apply_tag(
                &active,
                &buffer.iter_at_offset(navigation.range.0),
                &buffer.iter_at_offset(navigation.range.1),
            );
        }
    }
    *ui.search_emphasis.borrow_mut() = Some(Emphasis {
        doc: Rc::downgrade(doc),
        preview: Arc::downgrade(&navigation.preview),
        cancel: navigation.cancel.clone(),
        all,
        active,
        #[cfg(debug_assertions)]
        range: navigation.range,
    });
    source_panes::search_caret(
        doc,
        (navigation.range.0 == navigation.range.1).then_some(navigation.range.0),
    );
    let mut iter = target.buffer.iter_at_offset(navigation.range.0);
    if navigation.explicit {
        target.view.scroll_to_iter(&mut iter, 0.15, false, 0., 0.);
    }
    // Eigene Marks halten den Suchbereich fest, während die native Auswahl
    // den tatsächlichen Treffer für Kopieren und anschließendes Bearbeiten zeigt.
    target.buffer.select_range(
        &target.buffer.iter_at_offset(navigation.range.0),
        &target.buffer.iter_at_offset(navigation.range.1),
    );
    Ok(())
}
pub(super) fn file(ui: &Rc<Ui>) {
    let weak = Rc::downgrade(ui);
    *ui.approval.inline_source.borrow_mut() = Some(Rc::new(move || {
        let ui = weak.upgrade()?;
        if !matches!(ui.scope.selected(), 0 | 4) || ui.replace.text().is_empty() {
            return None;
        }
        let doc = ui.active()?;
        let pending = ui.pending.borrow();
        let pending = pending.as_ref()?;
        let target = pending.target.as_ref()?;
        (target.valid_document(&doc) && search_selection::valid(&ui, &doc, pending.selection))
            .then(|| pending.preview.clone())
    }));
    let weak = Rc::downgrade(ui);
    *ui.approval.on_navigate.borrow_mut() = Some(Rc::new(move |navigation| {
        let Some(ui) = weak.upgrade() else {
            return;
        };
        let target = ui
            .pending
            .borrow()
            .as_ref()
            .filter(|pending| Arc::ptr_eq(&pending.preview, &navigation.preview))
            .and_then(|pending| pending.target.clone());
        let result = (|| {
            let target = target.ok_or_else(|| stale(ui.lang).to_string())?;
            let doc = ui
                .active()
                .filter(|doc| target.valid_document_for_reading(doc))
                .ok_or_else(|| stale(ui.lang).to_string())?;
            display(&ui, &doc, &navigation)
        })();
        if let Err(error) = result {
            (navigation.report)(&error);
        }
    }));
}
pub(super) fn memory(ui: &Rc<Ui>, doc: &Rc<Document>, navigation: Navigation) {
    if !navigation.explicit {
        return;
    }
    if doc.revision.get() != navigation.preview.revision() {
        (navigation.report)(stale(ui.lang));
        return;
    }
    if let Err(error) = display(ui, doc, &navigation) {
        (navigation.report)(&error);
    }
}

pub(super) fn disk(
    ui: &Rc<Ui>,
    path: std::path::PathBuf,
    binding: [u8; 32],
    navigation: Navigation,
    project: Option<project_view::WorkBinding>,
) {
    if !navigation.explicit || !(navigation.current)() {
        return;
    }
    let generation = ui.generation.get();
    let preview = navigation.preview.clone();
    let cancel = navigation.cancel.clone();
    let lang = ui.lang;
    (navigation.report)(lang.text("Trefferquelle wird geprüft …", "Checking match source …"));
    let weak = Rc::downgrade(ui);
    git_view::background(
        move || {
            if let Some(project) = project.as_ref() {
                project.validate().map_err(|_| stale(lang).to_string())?;
            }
            #[cfg(debug_assertions)]
            source_panes::delay_reply();
            let snapshot = fastra_io::Snapshot::read_bounded(&path, 4 * 1024 * 1024, &cancel)
                .map_err(|e| io_error_text(lang, &e))?;
            if snapshot
                .binding_digest()
                .map_err(|e| io_error_text(lang, &e))?
                != binding
            {
                return Err(stale(lang).into());
            }
            let decoded = fastra_core::encoding::decode(snapshot.bytes(), None)
                .map_err(|_| stale(lang).to_string())?;
            cancel.check().map_err(|_| stale(lang).to_string())?;
            if decoded.text() != preview.source() {
                return Err(stale(lang).into());
            }
            if let Some(project) = project.as_ref() {
                project.validate().map_err(|_| stale(lang).to_string())?;
            }
            Ok((Arc::new(decoded), snapshot))
        },
        move |result| {
            #[cfg(debug_assertions)]
            DISK_REPLIES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let Some(ui) = weak.upgrade().filter(|ui| {
                ui.window.is_visible()
                    && ui.generation.get() == generation
                    && (navigation.current)()
            }) else {
                return;
            };
            let result = (|| {
                let (decoded, snapshot) = result?;
                let path = snapshot.path();
                let identity = snapshot.file_identity();
                let existing = ui
                    .documents
                    .borrow()
                    .iter()
                    .find(|doc| {
                        doc.snapshot
                            .borrow()
                            .as_ref()
                            .is_some_and(|stored| stored.file_identity() == identity)
                            || doc.disk_path().as_ref() == Some(&path)
                    })
                    .cloned();
                let doc = if let Some(doc) = existing {
                    if !usable(&ui, &doc) || buffer_text(&doc.buffer) != decoded.text() {
                        return Err(lang.text("Die geöffnete Datei enthält andere oder gesperrte Inhalte. Quelle zuerst prüfen; kein Quellsprung ausgeführt.","The open file has different or locked contents. Check the source first; no source jump was made.").into());
                    }
                    doc
                } else {
                    let name = path
                        .file_name()
                        .map(|name| project_view::display(std::path::Path::new(name)))
                        .unwrap_or_default();
                    ui.add_loaded_text(&name, decoded, snapshot)
                };
                display(&ui, &doc, &navigation)
            })();
            match result {
                Ok(()) => (navigation.report)(""),
                Err(error) => (navigation.report)(&error),
            }
        },
    );
}
