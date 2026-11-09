use super::*;
use std::{collections::BTreeMap, os::unix::fs::MetadataExt, path::PathBuf};

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
    cancel: &crate::viewer::Cancellation,
) -> (images::Cache, Stamps, bool) {
    let current = stamps(&old);
    if current == before {
        return (old, current, false);
    }
    let sources = images::Sources(
        old.images
            .iter()
            .map(|(key, image)| (key.clone(), image.source.clone()))
            .collect(),
    );
    let mut loaded = sources.load(cancel);
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
    (loaded, current, true)
}

fn install(editor: &Rc<RichEditor>) {
    let mapping: BTreeMap<_, _> = editor.images.borrow().images.iter().map(|(key, image)| {
        (key.clone(), json!({"raw":image.source.raw,"uri":format!("{}{key}?v={}",images::PREFIX,if image.version.is_empty(){"unavailable"}else{&image.version})}))
    }).collect();
    // Nur Bildadressen ändern. Quellverweise, Auswahl, Text und native DOM-Rücknahme bleiben unberührt.
    let script = format!(
        r#"
        const mapping=JSON.parse({mapping});
        const root=document.getElementById('fastra-visual');
        if(!root || !window.fastraVisual)return JSON.stringify(false);
        window.fastraLocalImageMapping=mapping;
        if(!window.fastraLocalImageObserver){{
          const update=()=>{{for(const image of root.querySelectorAll('img[data-md-src]')){{
            const current=image.getAttribute('src') || '';
            if(!current.startsWith('fastra-rich://image/'))continue;
            const token=current.slice('fastra-rich://image/'.length).split('?v=')[0];
            const entry=window.fastraLocalImageMapping[token];
            if(entry && entry.raw===image.dataset.mdSrc && current!==entry.uri)image.setAttribute('src',entry.uri);
          }}}};
          window.fastraLocalImageObserver=new MutationObserver(update);
          window.fastraLocalImageObserver.observe(root,{{subtree:true,childList:true,attributes:true,attributeFilter:['src','data-md-src']}});
          window.fastraRefreshLocalImages=update;
        }}
        window.fastraRefreshLocalImages();return JSON.stringify(true);
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
            move || Ok(refresh(cache, old, &cancel)),
            move |result| {
                busy.set(false);
                let Some(editor) = weak
                    .upgrade()
                    .filter(|editor| editor.current().is_some() && !editor.failed.get())
                else {
                    return;
                };
                let Ok((cache, stamps, changed)) = result else {
                    return;
                };
                if editor.busy.get()
                    || editor.clipboard_busy.get()
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
                    let warnings = !cache.warnings.is_empty();
                    *editor.images.borrow_mut() = cache;
                    install(&editor);
                    let warning = editor.text("Ein lokales Bild fehlt oder konnte nicht sicher aktualisiert werden. Der Quellverweis bleibt erhalten.", "A local image is missing or could not be refreshed safely. Its source reference is retained.");
                    if warnings {
                        warned.set(true);
                        editor.status.set_text(warning);
                    } else if warned.replace(false) && editor.status.text() == warning {
                        editor.status.set_text(editor.text(
                            "Lokale Bilder aktualisiert. Text und Rücknahme bleiben erhalten.",
                            "Local images refreshed. Text and Undo are retained.",
                        ));
                    }
                }
            },
        );
        glib::ControlFlow::Continue
    });
}
