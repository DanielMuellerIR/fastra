use super::*;
use std::{
    collections::{BTreeMap, BTreeSet},
    os::unix::fs::MetadataExt,
    path::PathBuf,
};

#[derive(Clone, PartialEq, Eq)]
struct Stamp {
    resolved: PathBuf,
    device: u64,
    inode: u64,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
type Stamps = BTreeMap<String, Option<Stamp>>;

fn stamps(cache: &images::Cache) -> Stamps {
    cache
        .images
        .iter()
        .map(|(key, image)| {
            let stamp = (|| {
                let resolved = image.source.path.canonicalize().ok()?;
                let metadata = std::fs::metadata(&resolved).ok()?;
                Some(Stamp {
                    resolved,
                    device: metadata.dev(),
                    inode: metadata.ino(),
                    size: metadata.len(),
                    modified: (metadata.mtime(), metadata.mtime_nsec()),
                    changed: (metadata.ctime(), metadata.ctime_nsec()),
                })
            })();
            (key.clone(), stamp)
        })
        .collect()
}

fn refresh(
    mut old: images::Cache,
    before: Stamps,
    retain: impl Fn(&images::Image) -> bool,
    cancel: &crate::viewer::Cancellation,
) -> (images::Cache, Stamps, bool) {
    let (kept, watched) = std::mem::take(&mut old.images)
        .into_iter()
        .partition(|(_, image)| retain(image));
    let mut retained = images::Cache { images: kept, warnings: Vec::new() };
    old.images = watched;
    let current = stamps(&old);
    if current == before {
        old.images.append(&mut retained.images);
        return (old, current, false);
    }
    let sources = images::Sources(
        old.images
            .iter()
            .map(|(key, image)| (key.clone(), image.source.clone()))
            .collect(),
    );
    let mut loaded = sources.load_with_retained(cancel, &retained);
    // Fehlende Quellen bleiben beobachtbar; ihre alten Bytes dürfen aber nicht weiter angezeigt oder kopiert werden.
    for (key, mut image) in std::mem::take(&mut old.images) {
        if let std::collections::btree_map::Entry::Vacant(entry) = loaded.images.entry(key) {
            image.version.clear();
            image.original = std::sync::Arc::new(Vec::new());
            image.displayed = image.original.clone();
            image.width = 0;
            image.height = 0;
            image.frames = 0;
            entry.insert(image);
        }
    }
    loaded.images.append(&mut retained.images);
    (loaded, current, true)
}

fn refresh_referenced(
    cache: images::Cache,
    before: Stamps,
    source: &str,
    path: Option<&std::path::Path>,
    session: &str,
    held_for_redo: &BTreeSet<PathBuf>,
    cancel: &crate::viewer::Cancellation,
) -> (images::Cache, Stamps, bool, bool) {
    let references = images::Sources::collect(source, path, session);
    // Zu einer erfolgreichen Bildrücknahme gehört ein vorübergehend fehlender
    // öffentlicher Name. Wiederholen prüft die erhaltenen Bytes vor der Freigabe.
    let (cache, stamps, changed) = refresh(cache, before, |image| {
        held_for_redo.contains(&image.source.path)
            && references.as_ref().is_ok_and(|refs| !refs.0.contains_key(&image.source.raw))
    }, cancel);
    // Undo-Versionen bleiben im Cache. Nur vollständig geprüfte Quellverweise
    // erlauben es, Meldungen für nicht mehr verwendete Bilder auszublenden.
    let warnings = cache.images.values().any(|image| {
        image.version.is_empty()
            && references
                .as_ref()
                .map_or(true, |references| references.0.contains_key(&image.source.raw))
    });
    (cache, stamps, changed, warnings)
}

fn install(editor: &Rc<RichEditor>) {
    let mapping: BTreeMap<_, _> = editor.images.borrow().images.iter().map(|(key, image)| {
        (key.clone(), json!({"raw":image.source.raw,"uri":format!("{}{key}?v={}",images::PREFIX,if image.version.is_empty(){"unavailable"}else{&image.version})}))
    }).collect();
    // Nur Bildadressen über ProseMirror aktualisieren, damit Dokumentzustand und Undo/Redo konsistent bleiben.
    let script = format!(
        r#"
        const mapping=JSON.parse({mapping});
        if(!window.fastraVisual)return JSON.stringify(false);
        window.fastraLocalImageMapping=mapping;
        window.fastraVisual?.updateLocalImages?.(mapping);
        return JSON.stringify(true);
    "#,
        mapping = json!(serde_json::to_string(&mapping).unwrap())
    );
    editor.evaluate(&script, |_| {});
}

pub(super) fn start(editor: &Rc<RichEditor>) {
    install(editor);
    let weak = Rc::downgrade(editor);
    let busy = Rc::new(Cell::new(false));
    let previous = Rc::new(RefCell::new(Stamps::default()));
    let warned = Rc::new(Cell::new(false));
    glib::timeout_add_local(std::time::Duration::from_millis(1500), move || {
        let Some(editor) = weak
            .upgrade()
            .filter(|editor| editor.active.get() && !editor.failed.get())
        else {
            return glib::ControlFlow::Break;
        };
        if busy.get()
            || editor.busy.get()
            || editor.clipboard_busy.get()
            || editor.current().is_none()
        {
            return glib::ControlFlow::Continue;
        }
        let cache = images::Cache {
            images: editor.images.borrow().images.clone(),
            warnings: Vec::new(),
        };
        if cache.images.is_empty() {
            return glib::ControlFlow::Continue;
        }
        busy.set(true);
        let old = previous.borrow().clone();
        let cancel = editor.image_cancel.clone();
        let revision = editor.revision.get();
        let input_revision = editor.input_revision.get();
        let operation = editor.operation.get();
        let path = editor.document.upgrade().and_then(|doc| doc.disk_path());
        let held_for_redo = path.as_deref().and_then(std::path::Path::parent).map_or_else(
            BTreeSet::new,
            |parent| editor.assets.borrow().records.values()
                .filter(|record| !record.visible && !record.receipt.is_applied())
                .flat_map(|record| record.receipt.preview())
                .map(|entry| parent.join(&entry.relative))
                .collect(),
        );
        let source_path = path.clone();
        let source = editor.expected.borrow().clone();
        let session = editor.session.clone();
        let weak = Rc::downgrade(&editor);
        let busy = busy.clone();
        let previous = previous.clone();
        let warned = warned.clone();
        let keys = cache
            .images
            .iter()
            .map(|(key, image)| (key.clone(), image.version.clone()))
            .collect::<BTreeMap<_, _>>();
        crate::git_view::background(
            move || {
                Ok(refresh_referenced(cache, old, &source, source_path.as_deref(), &session, &held_for_redo, &cancel))
            },
            move |result| {
                busy.set(false);
                let Some(editor) = weak
                    .upgrade()
                    .filter(|editor| editor.current().is_some() && !editor.failed.get())
                else {
                    return;
                };
                let Ok((cache, stamps, changed, warnings)) = result else {
                    return;
                };
                if editor.busy.get()
                    || editor.clipboard_busy.get()
                    || editor.revision.get() != revision
                    || editor.input_revision.get() != input_revision
                    || editor.operation.get() != operation
                    || editor.document.upgrade().and_then(|doc| doc.disk_path()) != path
                    || editor
                        .images
                        .borrow()
                        .images
                        .iter()
                        .map(|(key, image)| (key.clone(), image.version.clone()))
                        .collect::<BTreeMap<_, _>>()
                        != keys
                {
                    return;
                }
                *previous.borrow_mut() = stamps;
                if changed {
                    *editor.images.borrow_mut() = cache;
                    install(&editor);
                }
                let warning = editor.text("Ein lokales Bild fehlt oder konnte nicht sicher aktualisiert werden. Der Quellverweis bleibt erhalten.", "A local image is missing or could not be refreshed safely. Its source reference is retained.");
                if warnings && (changed || !warned.get()) {
                    warned.set(true);
                    editor.status.set_text(warning);
                } else if !warnings && warned.replace(false) && editor.status.text() == warning {
                    editor.status.set_text(editor.text(
                        "Lokale Bilder aktualisiert. Text und Rücknahme bleiben erhalten.",
                        "Local images refreshed. Text and Undo are retained.",
                    ));
                }
            },
        );
        glib::ControlFlow::Continue
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn incomplete_reference_analysis_keeps_refresh_and_missing_image_warning() {
        let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let directory = tempfile::tempdir_in(root).unwrap();
        let path = directory.path().join("document.md");
        let known = "![Missing](missing.png)\n";
        let cancel = crate::viewer::Cancellation::default();
        let cache = images::Sources::collect(known, Some(&path), "watch")
            .unwrap()
            .load(&cancel);
        let mut source = known.to_owned();
        for index in 0..128 {
            source.push_str(&format!("![Additional](additional-{index}.png)\n"));
        }
        assert!(images::Sources::collect(&source, Some(&path), "watch").is_err());
        let (mut cache, stamps, changed, warning) = refresh_referenced(
            cache, Stamps::default(), &source, Some(&path), "watch", &BTreeSet::new(), &cancel,
        );
        assert!(changed && warning);
        assert_eq!(cache.images.len(), 1);
        assert!(cache.images.values().all(|image| image.version.is_empty()));
        cache.warnings.clear();
        let (_, _, changed, warning) = refresh_referenced(
            cache, stamps, &source, Some(&path), "watch", &BTreeSet::new(), &cancel,
        );
        assert!(!changed && warning);
    }
}
