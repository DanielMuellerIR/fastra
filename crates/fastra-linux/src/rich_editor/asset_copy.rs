use super::*;
use std::collections::BTreeMap;
struct Watch {
    clipboard: gtk::gdk::Clipboard,
    changed: Rc<Cell<bool>>,
    handler: Option<glib::SignalHandlerId>,
}
impl Watch {
    fn new(clipboard: gtk::gdk::Clipboard) -> Self {
        let changed = Rc::new(Cell::new(false));
        let copy = changed.clone();
        let handler = clipboard.connect_changed(move |_| copy.set(true));
        Self {
            clipboard,
            changed,
            handler: Some(handler),
        }
    }
}
impl Drop for Watch {
    fn drop(&mut self) {
        if let Some(handler) = self.handler.take() {
            self.clipboard.disconnect(handler);
        }
    }
}
struct Export {
    package: String,
    replacements: Value,
    image: Option<(&'static str, std::sync::Arc<Vec<u8>>)>,
}
pub(super) fn copy(editor: Rc<RichEditor>, value: Value) {
    let Some(lease) = asset_flow::Lease::capture(&editor) else {
        return;
    };
    let Some(bookmark) = value["bookmark"].as_str().map(str::to_owned) else {
        return;
    };
    let Some(sources) = value["imageSources"]
        .as_array()
        .filter(|values| values.len() <= 128)
    else {
        finish(&editor, &bookmark, false, false);
        return;
    };
    let mut selected = BTreeMap::new();
    let mut expansion = 0usize;
    for source in sources {
        let Some(uri) = source.as_str() else {
            finish(&editor, &bookmark, false, false);
            return;
        };
        let Some(image) = uri
            .strip_prefix(images::PREFIX)
            .and_then(|token| editor.images.borrow().lookup(token).cloned())
        else {
            editor.clipboard_error("images");
            finish(&editor, &bookmark, false, false);
            return;
        };
        expansion = expansion.saturating_add(image.displayed.len().div_ceil(3) * 4);
        if expansion > transfer::MAX_IMAGES {
            editor.clipboard_error("size");
            finish(&editor, &bookmark, false, false);
            return;
        }
        selected.insert(uri.to_owned(), image);
    }
    let Some(markdown) = value["markdown"]
        .as_str()
        .filter(|s| s.len() <= MAX_BYTES && !s.contains('\0'))
        .map(str::to_owned)
    else {
        finish(&editor, &bookmark, false, false);
        return;
    };
    let Ok(events) = crate::markdown::syntax::events(&markdown, &Cancellation::default()) else {
        editor.clipboard_error("size"); finish(&editor, &bookmark, false, false); return;
    };
    let references = events.into_iter().filter_map(|(event, _, _)| match event {
            Event::Start(Tag::Image { dest_url, .. }) => Some(dest_url.to_string()),
            _ => None,
        })
        .collect::<std::collections::BTreeSet<_>>();
    if selected
        .values()
        .any(|image| !references.contains(&image.source.raw))
    {
        editor.clipboard_error("images");
        finish(&editor, &bookmark, false, false);
        return;
    }
    let watch = Watch::new(editor.view.clipboard());
    let source_url = lease
        .path
        .as_ref()
        .map(|path| gio::File::for_path(path).uri().to_string())
        .unwrap_or_default();
    let cut = value["cut"] == true;
    let plain = value["plain"].as_str().unwrap_or("").to_owned();
    let single = selected.len() == 1 && plain.is_empty();
    let weak = Rc::downgrade(&editor);
    crate::git_view::background(
        move || {
            let mut total = 0usize;
            let mut image_data = BTreeMap::new();
            let mut replacements = serde_json::Map::new();
            let mut image = None;
            for (uri, entry) in selected {
                total = total
                    .checked_add(entry.original.len())
                    .ok_or("Image copy budget")?;
                if total > transfer::MAX_IMAGES {
                    return Err("Image copy budget".into());
                }
                let url = gio::File::for_path(&entry.source.path).uri().to_string();
                image_data.insert(
                    url,
                    glib::base64_encode(entry.original.as_slice()).to_string(),
                );
                replacements.insert(
                    uri,
                    Value::String(format!(
                        "data:{};base64,{}",
                        entry.mime,
                        glib::base64_encode(entry.displayed.as_slice())
                    )),
                );
                if single {
                    image = Some((entry.mime, entry.displayed.clone()));
                }
            }
            let raw = serde_json::to_vec(&image_data).map_err(|e| e.to_string())?;
            let package =
                json!({"markdown":markdown,"url":source_url,"images":glib::base64_encode(&raw).to_string()})
                    .to_string();
            if package.len() > transfer::MAX_PACKAGE {
                return Err("Image package budget".into());
            }
            Ok(Export {
                package,
                replacements: Value::Object(replacements),
                image,
            })
        },
        move |result| {
            let Some(editor) = weak.upgrade() else {
                return;
            };
            let export = match result {
                Ok(export) if lease.current(&editor) && !watch.changed.get() => export,
                _ => {
                    editor.clipboard_error("stale");
                    finish(&editor, &bookmark, false, false);
                    return;
                }
            };
            let code = format!(
                "return JSON.stringify(fastraVisual.exportClipboardHTML({},{}));",
                json!(bookmark),
                export.replacements
            );
            let weak = Rc::downgrade(&editor);
            editor.evaluate(&code, move |result| {
                let Some(editor) = weak.upgrade() else {
                    return;
                };
                let success = if let Some(Value::String(html)) =
                    result.filter(|_| lease.current(&editor) && !watch.changed.get())
                {
                    let mut providers = vec![
                        gtk::gdk::ContentProvider::for_value(&plain.to_value()),
                        gtk::gdk::ContentProvider::for_bytes(
                            "text/html",
                            &glib::Bytes::from_owned(html.into_bytes()),
                        ),
                        gtk::gdk::ContentProvider::for_bytes(
                            clipboard::MIME,
                            &glib::Bytes::from_owned(export.package.into_bytes()),
                        ),
                    ];
                    if let Some((mime, bytes)) = export.image {
                        providers.push(gtk::gdk::ContentProvider::for_bytes(
                            mime,
                            &glib::Bytes::from_owned(bytes.as_ref().clone()),
                        ));
                    }
                    editor
                        .view
                        .clipboard()
                        .set_content(Some(&gtk::gdk::ContentProvider::new_union(&providers)))
                        .is_ok()
                } else {
                    false
                };
                if !success {
                    editor.clipboard_error("stale");
                }
                finish(&editor, &bookmark, cut, success);
            });
        },
    );
}
fn finish(editor: &RichEditor, bookmark: &str, cut: bool, success: bool) {
    editor.evaluate(
        &format!(
            "return JSON.stringify(fastraVisual.completeClipboard({},{},{}));",
            json!(bookmark),
            cut,
            success
        ),
        |_| {},
    );
}
