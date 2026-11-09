//! Ein Pfadwechsel beendet alte Ressourcen-/Receipt-Herkunft, ohne Ursprungsdateien zu bereinigen.
use super::*;
struct Archive {
    doc: std::rc::Weak<Document>,
    paths: std::collections::BTreeSet<std::path::PathBuf>,
}
thread_local! {static ARCHIVES:RefCell<Vec<Archive>>=const{RefCell::new(Vec::new())};}
pub(crate) fn origin_paths(doc: &Document) -> Vec<std::path::PathBuf> {
    ARCHIVES.with(|archives| {
        archives
            .borrow()
            .iter()
            .filter(|archive| {
                archive
                    .doc
                    .upgrade()
                    .is_some_and(|old| std::ptr::eq(old.as_ref(), doc))
            })
            .flat_map(|archive| archive.paths.iter().cloned())
            .collect()
    })
}
pub(crate) fn archive_available(doc: &Rc<Document>) -> bool {
    let incoming = doc
        .rich
        .borrow()
        .as_ref()
        .and_then(|editor| {
            doc.disk_path()
                .map(|path| asset_ui::origin_paths(&editor.assets.borrow(), &path))
        })
        .map_or(0, |paths| paths.len());
    ARCHIVES.with(|archives| {
        let mut archives = archives.borrow_mut();
        archives.retain(|archive| archive.doc.strong_count() > 0);
        archives
            .iter()
            .map(|archive| archive.paths.len())
            .sum::<usize>()
            .saturating_add(incoming)
            <= 4096
    })
}

pub(crate) fn has_assets(doc: &Document) -> bool {
    doc.rich
        .borrow()
        .as_ref()
        .is_some_and(|editor| editor.assets.borrow().bytes > 0)
}
pub(crate) struct Location {
    rich: bool,
    preview: bool,
    viewport: Option<Value>,
}
pub(crate) fn detach(ui: &Ui, doc: &Rc<Document>) -> Option<Location> {
    let editor = doc.rich.borrow_mut().take()?;
    let saved_viewport = viewport::get(doc);
    if let Some(path) = doc.disk_path() {
        let paths = asset_ui::origin_paths(&editor.assets.borrow(), &path);
        ARCHIVES.with(|archives| {
            let mut archives = archives.borrow_mut();
            if let Some(archive) = archives.iter_mut().find(|archive| {
                archive
                    .doc
                    .upgrade()
                    .is_some_and(|old| Rc::ptr_eq(&old, doc))
            }) {
                archive.paths.extend(paths);
            } else {
                archives.push(Archive {
                    doc: Rc::downgrade(doc),
                    paths: paths.into_iter().collect(),
                });
            }
        });
    }
    let active = editor.active.replace(false);
    editor.operation.set(editor.operation.get().wrapping_add(1));
    editor
        .clipboard_request
        .set(editor.clipboard_request.get().wrapping_add(1));
    editor.image_cancel.cancel();
    editor.view.stop_loading();
    if let Some(stack) = editor
        .widget
        .parent()
        .and_then(|parent| parent.downcast::<gtk::Stack>().ok())
    {
        stack.set_visible_child_name("source");
        stack.remove(&editor.widget);
    }
    let toggle = mode_toggle(doc, ui.lang);
    let mut parent = toggle.parent();
    while let Some(widget) = parent {
        if let Ok(options) = widget.clone().downcast::<gtk::FlowBox>() {
            source_controls(&options, &toggle, true);
            break;
        }
        parent = widget.parent();
    }
    toggle.set_sensitive(true);
    toggle.set_active(false);
    if let Some(preview) = doc.markdown_toggle.borrow().as_ref() {
        preview.set_sensitive(true);
    }
    Some(Location {
        rich: active,
        preview: editor.source_preview,
        viewport: saved_viewport,
    })
}
pub(crate) fn restore_mode(doc: &Rc<Document>, lang: Language, location: Option<Location>) {
    if let Some(location) = location {
        if let Some(saved) = location.viewport {
            viewport::remember(doc, &saved);
        }
        if let Some(preview) = doc.markdown_toggle.borrow().as_ref() {
            preview.set_active(location.preview);
        }
        if location.rich {
            mode_toggle(doc, lang).set_active(true);
        }
    }
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(crate) fn run_selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
