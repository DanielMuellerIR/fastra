use super::*;
pub(super) fn install(editor: &Rc<RichEditor>) {
    // WebKits Accept-Handler greift trotz leerer Formate und Phase::None zu.
    // Nur der Fenster-Drop darf die Ablage abschließen und die Vorschau öffnen.
    let existing = editor.view.observe_controllers();
    let controllers = (0..existing.n_items())
        .filter_map(|index| existing.item(index).and_downcast::<gtk::EventController>())
        .collect::<Vec<_>>();
    for controller in controllers {
        if controller.is::<gtk::DropTargetAsync>() || controller.is::<gtk::DropTarget>() {
            editor.view.remove_controller(&controller);
        }
    }
}
fn discard(editor: &RichEditor, key: &str) {
    editor.evaluate(
        &format!(
            "fastraVisual.discardBookmark({});return JSON.stringify(false);",
            json!(key)
        ),
        |_| {},
    );
}

pub(super) fn choose(editor: Rc<RichEditor>) {
    if !editor.ready.get() || editor.busy.get() || editor.failed.get() || !editor.focused() {
        editor.clipboard_error("stale");
        return;
    }
    let Some(lease) = asset_flow::Lease::capture(&editor) else {
        return;
    };
    let Some(ui) = editor.ui.upgrade() else {
        return;
    };
    let parent = ui.window.clone();
    let lang = ui.lang;
    let weak = Rc::downgrade(&editor);
    editor.evaluate(
        "return JSON.stringify(fastraVisual.bookmark());",
        move |value| {
            let Some(Value::String(key)) = value else {
                return;
            };
            let dialog = gtk::FileDialog::builder()
                .title(lang.text("Bilder oder Dateien einfügen", "Insert images or files"))
                .modal(true)
                .build();
            dialog.open_multiple(Some(&parent), None::<&gio::Cancellable>, move |result| {
                let Some(editor) = weak.upgrade() else {
                    return;
                };
                if !lease.current(&editor) {
                    discard(&editor, &key);
                    editor.clipboard_error("stale");
                    return;
                }
                match result {
                    Ok(files) if files.n_items() <= 32 => {
                        let paths = (0..files.n_items())
                            .map(|index| {
                                files
                                    .item(index)
                                    .and_downcast::<gio::File>()
                                    .and_then(|file| file.path())
                            })
                            .collect::<Option<Vec<_>>>();
                        if let Some(paths) = paths {
                            asset_ui::receive(editor, transfer::Transfer::Files(paths), key);
                        } else {
                            discard(&editor, &key);
                            editor.clipboard_error("format");
                        }
                    }
                    _ => discard(&editor, &key),
                }
            });
        },
    );
}

pub(super) fn files_at(editor: Rc<RichEditor>, files: &[gio::File], x: f64, y: f64) -> bool {
    let Some(ui) = editor.ui.upgrade() else {
        return false;
    };
    let Some(point) = ui
        .window
        .compute_point(&editor.view, &gtk::graphene::Point::new(x as f32, y as f32))
    else {
        return false;
    };
    if point.x() < 0.
        || point.y() < 0.
        || point.x() >= editor.view.width() as f32
        || point.y() >= editor.view.height() as f32
    {
        return false;
    }
    if !editor.ready.get() || editor.busy.get() || editor.failed.get() || !editor.focused() {
        editor.clipboard_error("stale");
        return true;
    }
    if files.is_empty() || files.len() > 32 {
        editor.clipboard_error("size");
        return true;
    }
    let Some(paths) = files
        .iter()
        .map(|file| {
            file.path()
                .filter(|path| path.is_absolute() && path.as_os_str().len() <= 4096)
        })
        .collect::<Option<Vec<_>>>()
    else {
        editor.clipboard_error("format");
        return true;
    };
    let Some(lease) = asset_flow::Lease::capture(&editor) else {
        return true;
    };
    let weak = Rc::downgrade(&editor);
    editor.evaluate(&format!("return JSON.stringify(fastraVisual.caretClipboard({},{}));",point.x(),point.y()),move|result|{
        let Some(editor)=weak.upgrade()else{return;};
        if let Some(Value::String(key))=result{
            if lease.current(&editor){asset_ui::receive(editor,transfer::Transfer::Files(paths),key);}else{editor.clipboard_error("stale");discard(&editor,&key);}
        }else{editor.status.set_text(editor.text("Zum Einfügen auf Text innerhalb der Rich-Ansicht ablegen; nichts geöffnet oder gespeichert.","Drop onto text inside the rich editor to insert; nothing opened or saved."));}
    });
    true
}
