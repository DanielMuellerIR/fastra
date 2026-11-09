use super::*;
use fastra_io::markdown_assets::Receipt;
use std::collections::{BTreeMap, BTreeSet};
type Done = Box<dyn FnOnce(bool)>;
pub(super) struct Record {
    pub receipt: Receipt,
    pub visible: bool,
    pending_owner: Option<asset_flow::Lease>,
}
struct RetainedCommit {
    _receipt: Receipt,
    paths: Vec<std::path::PathBuf>,
}
#[derive(Default)]
pub(super) struct State {
    pub records: BTreeMap<String, Record>,
    pub bytes: usize,
    retained: Vec<RetainedCommit>,
    accepted: BTreeMap<String, asset_flow::Lease>,
    running: Option<(u64, BTreeSet<String>)>,
    waiters: Vec<Done>,
}
fn discard(editor: &RichEditor, key: &str) {
    editor.evaluate(
        &format!(
            "fastraVisual.discardBookmark({});return JSON.stringify(true);",
            json!(key)
        ),
        |_| {},
    );
}
fn write_allowed(editor:&RichEditor) -> bool {
    let Some(ui)=editor.ui.upgrade()else{return false;};
    if crate::git_pull::write_allowed(&ui) {true}else{editor.status.set_text(&ui.status.text());false}
}
pub(super) fn receive(editor: Rc<RichEditor>, transfer: transfer::Transfer, key: String) {
    if let transfer::Transfer::Markdown { source, images, .. } = &transfer {
        if images.is_empty() && !transfer::has_images(source) {
            if let Ok(page) = page(source, &glib::uuid_string_random(), false, false) {
                editor.evaluate(&format!("return JSON.stringify(fastraVisual.insertBookmarked({},{},{},null,[],false));",json!(key),json!(page.fragment),page.configuration["opaqueSources"]),|_|{});
            } else {
                discard(&editor, &key);
                editor.clipboard_error("size");
            }
            return;
        }
    }
    if editor.busy.get() {
        editor.clipboard_error("busy");
        discard(&editor, &key);
        return;
    }
    editor.operation.set(editor.operation.get() + 1);
    let Some(lease) = asset_flow::Lease::capture(&editor) else {
        discard(&editor, &key);
        return;
    };
    if let transfer::Transfer::Rtf(bytes) = transfer {
        materialize_rtf(editor, lease, bytes, key);
        return;
    }
    if editor.assets.borrow().running.is_some() {
        editor.clipboard_error("busy");
        discard(&editor, &key);
        return;
    }
    editor.busy.set(true);
    editor.status.set_text(editor.text(
        "Bilder und lokale Dateien werden geprüft …",
        "Checking images and local files …",
    ));
    let cancel = crate::viewer::Cancellation::default();
    let worker_cancel = cancel.clone();
    let worker_lease = lease.clone();
    let weak = Rc::downgrade(&editor);
    let poll = weak.clone();
    let poll_lease = lease.clone();
    let complete = Rc::new(Cell::new(false));
    let done = complete.clone();
    glib::timeout_add_local(std::time::Duration::from_millis(30), move || {
        if done.get() {
            return glib::ControlFlow::Break;
        }
        if poll.upgrade().is_none_or(|e| !poll_lease.current(&e)) {
            cancel.cancel();
            return glib::ControlFlow::Break;
        }
        glib::ControlFlow::Continue
    });
    crate::git_view::background(
        move || asset_flow::prepare(transfer, &worker_lease, &worker_cancel),
        move |result| {
            complete.set(true);
            let Some(editor) = weak.upgrade() else {
                return;
            };
            if !lease.current(&editor) {
                editor.busy.set(false);
                editor.clipboard_error("stale");
                discard(&editor, &key);
                return;
            }
            match result {
                Ok(prepared) => preview(editor, lease, prepared, key),
                Err(error) => {
                    editor.busy.set(false);
                    discard(&editor, &key);
                    editor.status.set_text(&format!(
                        "{} {error}",
                        editor.text(
                            "Einfügen angehalten; Quelle unverändert:",
                            "Paste held; source unchanged:"
                        )
                    ));
                }
            }
        },
    );
}
fn text_page(text: &str) -> gtk::ScrolledWindow {
    let view = gtk::TextView::builder()
        .editable(false)
        .cursor_visible(true)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .build();
    view.buffer().set_text(text);
    crate::git_view::scroll(&view)
}
fn preview(
    editor: Rc<RichEditor>,
    lease: asset_flow::Lease,
    prepared: asset_flow::Prepared,
    key: String,
) {
    let Some(ui) = editor.ui.upgrade() else {
        return;
    };
    let lang = ui.lang;
    let added = prepared
        .pictures
        .iter()
        .map(|p| p.bytes.len())
        .sum::<usize>();
    if editor.assets.borrow().bytes.saturating_add(added) > transfer::MAX_IMAGES
        || editor.assets.borrow().records.len() + editor.assets.borrow().retained.len() >= 32
        || editor.images.borrow().images.len() + prepared.cache.images.len() > 256
        || editor
            .images
            .borrow()
            .bytes()
            .saturating_add(prepared.cache.bytes())
            > transfer::MAX_IMAGES
        || editor
            .images
            .borrow()
            .pixels()
            .saturating_add(prepared.cache.pixels())
            > 64_000_000
    {
        editor.busy.set(false);
        editor.clipboard_error("size");
        discard(&editor, &key);
        return;
    }
    let window = crate::git_view::window(
        &ui,
        lang.text("Bilder und Dateien einfügen", "Insert images and files"),
        true,
    );
    window.set_default_size(900, 740);
    window.set_size_request(700, 620);
    if let Ok(width) = std::env::var("FASTRA_RICH_WIDTH")
        .ok()
        .and_then(|v| v.parse::<i32>().ok())
        .ok_or(())
    {
        window.set_default_size(width.max(700), 740);
    }
    let root = crate::git_view::column();
    root.append(&crate::git_view::label(lang.text("Prüfen Sie alle Bilddateien und den Einfügeinhalt. Erst die Zustimmung speichert neue Bilder neben dem Dokument und fügt den Inhalt in die Bearbeitung ein. Das Dokument selbst schreiben Sie später mit Speichern.","Review every image file and the insertion content. Approval saves new images beside the document and inserts content into the editor. Save writes the document separately.")));
    let notebook = gtk::Notebook::new();
    notebook.set_vexpand(true);
    let files = crate::git_view::column();
    if let Some(plan) = prepared.plan.as_ref() {
        for (entry, picture) in plan.preview().iter().zip(&prepared.pictures) {
            let row = gtk::Box::new(gtk::Orientation::Vertical, 6);
            let heading = gtk::Label::new(Some(&format!(
                "{} · {} B · {} × {} · {} {}\nSHA-256 {}",
                entry.relative.display(),
                entry.bytes,
                picture.width,
                picture.height,
                picture.frames,
                lang.text("Frames", "frames"),
                entry.sha256
            )));
            heading.set_xalign(0.);
            heading.set_wrap(true);
            heading.set_selectable(true);
            row.append(&heading);
            if let Some(raster) = picture.thumbnail.as_ref() {
                let bytes = glib::Bytes::from_owned(raster.rgb.clone());
                let texture = gtk::gdk::MemoryTexture::new(
                    raster.width as i32,
                    raster.height as i32,
                    gtk::gdk::MemoryFormat::R8g8b8,
                    &bytes,
                    raster.width as usize * 3,
                );
                let image = gtk::Picture::for_paintable(&texture);
                image.set_content_fit(gtk::ContentFit::Contain);
                image.set_height_request(180);
                row.append(&image);
            }
            row.append(&crate::git_view::label(if picture.converted{lang.text("Als PNG konvertiert; mehrseitige TIFF/HEIC werden abgewiesen. Metadaten können sich ändern. Die Eingabe bleibt unverändert.","Converted to PNG; multipage TIFF/HEIC is refused. Metadata may change. The input stays unchanged.")}else{lang.text("Die vollständigen Bildbytes werden unverändert kopiert. Vorschau: erster Frame, Transparenz auf Weiß.","The complete image bytes are copied unchanged. Preview: first frame, transparency on white.")}));
            files.append(&row);
            files.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        }
    }
    for path in &prepared.opens {
        files.append(&crate::git_view::label(&format!(
            "{} {}",
            lang.text("Anschließend regulär öffnen:", "Open normally afterwards:"),
            path.display()
        )));
    }
    notebook.append_page(
        &crate::git_view::scroll(&files),
        Some(&gtk::Label::new(Some(
            lang.text("Bilddateien und Öffnen", "Images and open actions"),
        ))),
    );
    notebook.append_page(
        &text_page(&prepared.snippet),
        Some(&gtk::Label::new(Some(
            lang.text("Einfügeinhalt", "Insertion content"),
        ))),
    );
    notebook.append_page(
        &text_page(&editor.expected.borrow()),
        Some(&gtk::Label::new(Some(
            lang.text("Aktuelle Quelle", "Current source"),
        ))),
    );
    root.append(&notebook);
    root.append(&crate::git_view::label(lang.text("Rückgängig entfernt eigene Bildnamen nur, wenn keine geschützten Verweise verbleiben. Bild-Inodes bleiben für Wiederholen oder Wiederherstellung erhalten; offene Fremd-Editoren verlieren keine Daten. Rücknahmedateien werden nicht automatisch gelöscht.","Undo removes owned image names only when no protected references remain. Image inodes are retained for Redo or recovery, preserving edits from other editors. Recovery files are never deleted automatically.")));
    let status = gtk::Label::new(None);
    status.set_wrap(true);
    status.set_xalign(0.);
    status.set_selectable(true);
    root.append(&status);
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    let apply = gtk::Button::with_label(if prepared.plan.is_some() {
        lang.text("Bilder speichern und einfügen", "Save images and insert")
    } else {
        lang.text("Dateien öffnen", "Open files")
    });
    buttons.append(&cancel);
    buttons.append(&apply);
    root.append(&buttons);
    window.set_child(Some(&root));
    let prepared = Rc::new(RefCell::new(Some(prepared)));
    let committing = Rc::new(Cell::new(false));
    let completed = Rc::new(Cell::new(false));
    let cancellation = fastra_core::Cancellation::default();
    let weak_editor = Rc::downgrade(&editor);
    let close_key = key.clone();
    let close_commit = committing.clone();
    let close_done = completed.clone();
    let close_cancel = cancellation.clone();
    let close_status = status.clone();
    window.connect_close_request(move |_| {
        close_cancel.cancel();
        if close_commit.get() {
            close_status
                .set_text(lang.text("Abbruch wird abgeschlossen …", "Finishing cancellation …"));
            return glib::Propagation::Stop;
        }
        if !close_done.get() {
            if let Some(editor) = weak_editor.upgrade() {
                editor.busy.set(false);
                discard(&editor, &close_key);
            }
        }
        glib::Propagation::Proceed
    });
    let weak_window = window.downgrade();
    cancel.connect_clicked(move |_| {
        if let Some(window) = weak_window.upgrade() {
            window.close();
        }
    });
    let weak_window = window.downgrade();
    let weak_editor = Rc::downgrade(&editor);
    let prepare_copy = prepared.clone();
    let commit_copy = committing.clone();
    let complete_copy = completed.clone();
    let action_cancel = cancellation.clone();
    let status_copy = status.clone();
    let key_copy = key.clone();
    apply.connect_clicked(move|button|{
        let (Some(editor),Some(window))=(weak_editor.upgrade(),weak_window.upgrade())else{return;};if !lease.current(&editor){status_copy.set_text(lang.text("Dokument oder Einfügestelle geändert. Neu einfügen; nichts gespeichert.","Document or insertion target changed. Paste again; nothing saved."));button.set_sensitive(false);return;}
        if !write_allowed(&editor) {status_copy.set_text(&editor.status.text());return;}
        button.set_sensitive(false);let apply_button=button.clone();let verify_key=key_copy.clone();let prepared=prepare_copy.clone();let committing=commit_copy.clone();let completed=complete_copy.clone();let cancel=action_cancel.clone();let status=status_copy.clone();let lease=lease.clone();let weak=Rc::downgrade(&editor);let window=window.downgrade();
        editor.evaluate(&format!("return JSON.stringify(fastraVisual.validateClipboardBookmark({}));",json!(key_copy)),move|valid|{
            let (Some(editor),Some(window))=(weak.upgrade(),window.upgrade())else{return;};if !may_insert(&cancel, lease.current(&editor)) || valid!=Some(Value::Bool(true)){status.set_text(lang.text("Auswahl inzwischen geändert; nichts gespeichert. Neu einfügen.","Selection changed; nothing saved. Paste again."));return;}
            if !write_allowed(&editor) {status.set_text(&editor.status.text());apply_button.set_sensitive(true);return;}
            let Some(mut prepared)=prepared.borrow_mut().take()else{return;};
            if prepared.plan.is_none(){completed.set(true);editor.busy.set(false);discard(&editor,&verify_key);window.close();if let Some(ui)=editor.ui.upgrade(){super::super::desktop_open::open_files(&ui,&prepared.opens.iter().map(gio::File::for_path).collect::<Vec<_>>());}return;}
            committing.set(true);status.set_text(lang.text("Geprüfte Bilddateien werden angelegt …","Creating reviewed image files …"));
            let plan=prepared.plan.take().unwrap();let owner=lease.owner.clone();let worker_cancel=cancel.clone();let weak=Rc::downgrade(&editor);let window=window.downgrade();
            let publication=crate::asset_io::begin();
            crate::asset_io::background(move||{let result=plan.apply(&owner,&worker_cancel);#[cfg(debug_assertions)] test_pause("apply");Ok(result)},move|result|{
                let pending_publication=publication;
                committing.set(false);let Some(editor)=weak.upgrade()else{if let Ok(Ok(receipt))=result{compensate_commit(None,receipt,lease.clone(),status.clone());}return;};
                let receipt=match result{Ok(Ok(receipt))=>receipt,other=>{status.set_text(&format!("{} {}",lang.text("Nicht eingefügt; Wiederherstellungsort beachten:","Not inserted; inspect recovery location:"),match other{Ok(Err(error))=>error.to_string(),Err(error)=>error,_=>String::new()}));editor.busy.set(false);return;}};
                if !may_insert(&cancel, lease.current(&editor)) {
                    discard(&editor,&verify_key);
                    compensate_commit(Some(editor),receipt,lease.clone(),status.clone());return;
                }
                let added=prepared.pictures.iter().map(|p|p.bytes.len()).sum::<usize>();let id=glib::uuid_string_random().to_string();editor.assets.borrow_mut().bytes+=added;editor.assets.borrow_mut().records.insert(id.clone(),Record{receipt,visible:true,pending_owner:Some(lease.clone())});
                editor.images.borrow_mut().images.append(&mut prepared.cache.images);
                let sources=prepared.sources.0.values().filter_map(|source|editor.images.borrow().uri(&source.token)).collect::<Vec<_>>();
                let page=match page_images(&prepared.snippet,&glib::uuid_string_random(),false,lang.0,Some(&prepared.sources)){Ok(page)=>page,Err(_)=>{editor.fail("Bildinhalt überschreitet die Rich-Grenze. Rücknahmedaten bleiben erhalten.","Image content exceeds rich limits. Recovery data is retained.");rollback_insertion(editor,id);return;}};
                let before=editor.expected.borrow().clone();completed.set(true);if let Some(window)=window.upgrade(){window.close();}editor.view.grab_focus();
                let code=format!("const ok=fastraVisual.insertBookmarked({},{},{},{},{},false);return JSON.stringify({{ok,...fastraVisual.clipboardState()}});",json!(verify_key),json!(editor.images.borrow().versioned_html(&page.fragment)),page.configuration["opaqueSources"],json!(id),json!(sources));
                let weak=Rc::downgrade(&editor);let pending=prepared.opens;let insertion_lease=lease.clone();editor.evaluate(&code,move|result|{
                    let _pending_publication=pending_publication;
                    let Some(editor)=weak.upgrade()else{return;};
                    let Some(value)=result.filter(|value|value["ok"]==true)else{rollback_insertion(editor,id);return;};
                    let Some(revision)=value["revision"].as_u64()else{rollback_insertion(editor,id);return;};
                    let mut accepted=editor.assets.borrow().accepted.contains_key(&id);
                    if !accepted && revision==editor.input_revision.get()+1 && *editor.expected.borrow()==before && insertion_lease.current(&editor){
                        if let Some(text)=value["markdown"].as_str(){accepted=editor.accept(text,revision);if accepted{mark_accepted(&editor,&value);}else{editor.reject_image_change(json!({"revision":revision,"base":before,"inputType":"insertFromPaste"}));}}
                    }
                    if !accepted{rollback_insertion(editor,id);return;}
                    // Eine ältere RPC-Antwort darf weder einen inzwischen ausgeführten Undo zurücknehmen noch weitere Dateien in einem neuen UI-Owner öffnen.
                    let current=editor.input_revision.get()==revision && value["markdown"].as_str()==Some(editor.expected.borrow().as_str())
                        && editor.assets.borrow().accepted.get(&id).is_some_and(|accepted|accepted.current(&editor));
                    if current{finish_image(&editor,revision);if !pending.is_empty(){if let Some(ui)=editor.ui.upgrade(){super::super::desktop_open::open_files(&ui,&pending.iter().map(gio::File::for_path).collect::<Vec<_>>());}}}
                });
            });
        });
    });
    window.present();
}
fn may_insert(cancel: &Cancellation, current: bool) -> bool {
    current && cancel.check().is_ok()
}
type ReferenceCapture = (std::path::PathBuf, Vec<(std::path::PathBuf, String)>, bool);
fn compensate_receipt(
    receipt: Receipt,
    owner: &fastra_io::markdown_assets::Owner,
    references: Option<ReferenceCapture>,
) -> (Receipt, Result<(), String>) {
    compensate_receipt_with(receipt, owner, references, || {})
}
fn compensate_receipt_with(
    mut receipt: Receipt,
    owner: &fastra_io::markdown_assets::Owner,
    references: Option<ReferenceCapture>,
    after_undo: impl FnOnce(),
) -> (Receipt, Result<(), String>) {
    // Die abgebrochene Apply-Cancellation darf die notwendige Rücknahme nicht sofort abbrechen.
    let cancel = Cancellation::default();
    let deadline = cancel.clone();
    let (finished, wait) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        if matches!(
            wait.recv_timeout(std::time::Duration::from_secs(5)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout)
        ) {
            deadline.cancel();
        }
    });
    let result = (|| {
        let (path, texts, complete) =
            references.ok_or("Reference ownership unavailable; image names retained")?;
        let protection = asset_refs::Protection::scan(&path, &texts, complete, &cancel);
        if protection.protects(
            receipt
                .preview()
                .iter()
                .map(|entry| path.parent().unwrap().join(&entry.relative)),
        ) || !protection.current(&cancel)
        {
            return Err("Image references protect the created names; files retained".into());
        }
        receipt
            .undo(owner, &cancel)
            .map_err(|error| error.to_string())?;
        after_undo();
        #[cfg(debug_assertions)] test_pause("undo");
        if !protection.current(&cancel) {
            return restore_compensation(
                &mut receipt,
                owner,
                "Reference sources changed during cancelled image rollback",
            );
        }
        Ok(())
    })();
    let _ = finished.send(());
    (receipt, result)
}
fn restore_compensation(
    receipt: &mut Receipt,
    owner: &fastra_io::markdown_assets::Owner,
    reason: &str,
) -> Result<(), String> {
    match receipt.rollback_undo(owner) {
        Ok(()) => Err(format!("{reason}; image names restored and retained")),
        Err(error) => Err(format!("{reason}; restoring image names failed: {error}")),
    }
}
fn compensate_commit(
    editor: Option<Rc<RichEditor>>,
    receipt: Receipt,
    lease: asset_flow::Lease,
    status: gtk::Label,
) {
    let captured = editor
        .as_ref()
        .and_then(|editor| editor.document.upgrade())
        .and_then(|doc| {
            doc.disk_path()
                .filter(|path| Some(path) == lease.path.as_ref())
                .map(|path| {
                    let mut opened = asset_refs::capture(&doc);
                    if doc.buffer.char_count() > 262144 {
                        opened.complete = false;
                    } else {
                        opened.texts.push((path.clone(), buffer_text(&doc.buffer)));
                    }
                    (path, opened)
                })
        });
    let references = captured
        .as_ref()
        .filter(|(_, opened)| opened.current())
        .map(|(path, opened)| (path.clone(), opened.texts.clone(), opened.complete));
    let opened = captured.map(|(_, opened)| opened);
    let weak = editor.as_ref().map(Rc::downgrade);
    let lang = Language(
        editor
            .as_ref()
            .is_some_and(|editor| editor.ui.upgrade().is_some_and(|ui| ui.lang.0)),
    );
    let owner = lease.owner.clone();
    crate::asset_io::background(
        move || {let result=compensate_receipt(receipt, &owner, references);#[cfg(debug_assertions)] test_pause("worker");Ok(result)},
        move |result| {
            if let Ok((mut receipt, outcome)) = result {
                // OpenSnapshot enthält GTK-/Fensterstamps und bleibt deshalb bis zum Main-Abschluss hier.
                if !receipt.is_applied() && opened.as_ref().is_none_or(|opened| !opened.current()) {
                    crate::asset_io::background(
                        move || {
                            let outcome = restore_compensation(
                                &mut receipt,
                                &lease.owner,
                                "Open reference documents changed during cancelled image rollback",
                            );
                            #[cfg(debug_assertions)] test_pause("restore");
                            Ok((receipt, outcome))
                        },
                        move |result| present_compensation(weak, result, lease.path, status, lang),
                    );
                } else {
                    present_compensation(weak, Ok((receipt, outcome)), lease.path, status, lang);
                }
            } else {
                present_compensation(weak, result, lease.path, status, lang);
            }
        },
    );
}
fn present_compensation(
    weak: Option<std::rc::Weak<RichEditor>>,
    result: Result<(Receipt, Result<(), String>), String>,
    path: Option<std::path::PathBuf>,
    status: gtk::Label,
    lang: Language,
) {
    let editor = weak.and_then(|weak| weak.upgrade());
    let message = match result {
        Ok((receipt, outcome)) => {
            let mut paths = receipt
                .recovery_paths()
                .into_iter()
                .map(|(_, path)| path)
                .collect::<Vec<_>>();
            if paths.is_empty() {
                if let Some(parent) = path.as_deref().and_then(std::path::Path::parent) {
                    paths.extend(
                        receipt
                            .preview()
                            .iter()
                            .map(|entry| parent.join(&entry.relative)),
                    );
                }
            }
            let text = match &outcome {
                    Ok(()) => lang.text("Einfügen abgebrochen; eigene Bildnamen zurückgenommen. Rücknahmedaten bleiben erhalten.", "Insertion cancelled; owned image names rolled back. Recovery data is retained."),
                    Err(_) => lang.text("Nicht eingefügt. Bildrücknahme unvollständig; Dateien und Wiederherstellungsorte prüfen:", "Not inserted. Image rollback incomplete; inspect files and recovery locations:"),
                };
            let message = format!(
                "{text}\n{}\n{}",
                outcome.err().unwrap_or_default(),
                paths
                    .iter()
                    .take(if editor.is_some() { 1 } else { usize::MAX })
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>()
                    .join("\n")
            );
            if let Some(editor) = &editor {
                let bytes = receipt
                    .preview()
                    .iter()
                    .map(|entry| entry.bytes)
                    .sum::<usize>();
                let mut state = editor.assets.borrow_mut();
                state.bytes += bytes;
                // Abgebrochene Einfügungen gehören nicht zum Quelltext-Undo und dürfen beim Moduswechsel nicht erneut veröffentlicht werden.
                state.retained.push(RetainedCommit {
                    _receipt: receipt,
                    paths,
                });
            }
            if editor.is_some() {
                format!(
                    "{message}\n{}",
                    lang.text(
                        "Alle Orte: Bildmenü → Rücknahmedaten.",
                        "All locations: Image menu → recovery files."
                    )
                )
            } else {
                message
            }
        }
        Err(error) => format!(
            "{} {error}",
            lang.text(
                "Bildrücknahme fehlgeschlagen; angelegte Dateien prüfen.",
                "Image rollback failed; inspect created files."
            )
        ),
    };
    status.set_text(&message);
    if let Some(editor) = editor {
        editor.busy.set(false);
        editor.status.set_text(&message);
    } else {
        eprintln!("{message}");
    }
}

pub(super) fn mark_accepted(editor: &RichEditor, value: &Value) {
    let Some(lease) = asset_flow::Lease::capture(editor) else {
        return;
    };
    let mut state = editor.assets.borrow_mut();
    if let Some(ids) = value["imageTransactions"].as_array() {
        for id in ids.iter().filter_map(Value::as_str) {
            if let Some(record) = state.records.get_mut(id) {
                record.pending_owner = None;
                state.accepted.insert(id.to_owned(), lease.clone());
            }
        }
    }
}
pub(super) fn finish_image(editor: &Rc<RichEditor>, revision: u64) {
    let weak = Rc::downgrade(editor);
    let operation = editor.operation.get();
    editor.evaluate(
        &format!(
            "fastraVisual.completeImageAction({},{});return JSON.stringify(true);",
            json!(editor.session),
            revision
        ),
        move |_| {
            if let Some(editor) = weak.upgrade().filter(|editor| {
                editor.operation.get() == operation
                    && editor.input_revision.get() == revision
                    && editor.assets.borrow().running.is_none()
            }) {
                editor.busy.set(false);
                editor.status.set_text(editor.text(
                    "Rich-Markdown · Bilder mit Dateivorschau · Rücknahmedaten im Bildmenü",
                    "Rich Markdown · image file preview · recovery files in Image menu",
                ));
            }
        },
    );
}
fn rollback_insertion(editor: Rc<RichEditor>, id: String) {
    let Some(mut record) = editor.assets.borrow_mut().records.remove(&id) else {
        return;
    };
    let owner = fastra_io::markdown_assets::Owner {
        document: editor.session.clone(),
        revision: editor.revision.get(),
        generation: editor.ui.upgrade().map_or(0, |ui| ui.generation.get()),
    };
    let removed = record
        .receipt
        .preview()
        .iter()
        .map(|entry| entry.bytes)
        .sum::<usize>();
    let old_bytes = editor.assets.borrow().bytes;
    editor.assets.borrow_mut().bytes = old_bytes.saturating_sub(removed);
    let document = editor.document.upgrade();
    let opened = document.as_ref().map(asset_refs::capture);
    let path = document.as_ref().and_then(|doc| doc.disk_path());
    let complete = opened.as_ref().is_some_and(|opened| opened.complete);
    let texts = opened.map(|opened| opened.texts).unwrap_or_default();
    let weak = Rc::downgrade(&editor);
    crate::asset_io::background(
        move || {
            let protected = path.as_ref().is_none_or(|path| {
                asset_refs::Protection::scan(path, &texts, complete, &Cancellation::default())
                    .protects(
                        record
                            .receipt
                            .preview()
                            .iter()
                            .map(|entry| path.parent().unwrap().join(&entry.relative)),
                    )
            });
            let result = if protected {
                Ok(())
            } else {
                record.receipt.undo(&owner, &Cancellation::default())
            };
            let paths = if record.receipt.is_applied() {
                path.as_ref()
                    .and_then(|path| path.parent())
                    .map(|parent| {
                        record
                            .receipt
                            .preview()
                            .iter()
                            .map(|entry| parent.join(&entry.relative))
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default()
            } else {
                record
                    .receipt
                    .recovery_paths()
                    .into_iter()
                    .map(|(_, path)| path)
                    .collect()
            };
            Ok((paths, result))
        },
        move |result| {
            if let Some(editor) = weak.upgrade() {
                editor.busy.set(false);
                editor.status.set_text(&format!(
                    "{} {result:?}",
                    editor.text(
                        "Einfügen verworfen; Rücknahmedaten bleiben erhalten.",
                        "Insertion discarded; recovery data is retained."
                    )
                ));
            }
        },
    );
}
fn restore_changes(
    records: &mut BTreeMap<String, Record>,
    changed: &[(String, bool)],
    prior: &BTreeMap<String, bool>,
    owner: &fastra_io::markdown_assets::Owner,
) -> Option<String> {
    let mut failure = None;
    for (id, was_redo) in changed.iter().rev() {
        let record = records.get_mut(id).unwrap();
        let result = if *was_redo {
            record.receipt.undo(owner, &Cancellation::default())
        } else {
            record.receipt.rollback_undo(owner)
        };
        if let Err(error) = result {
            failure = Some(error.to_string());
        }
    }
    for (id, visible) in prior {
        records.get_mut(id).unwrap().visible = *visible;
    }
    failure
}
fn complete_reconcile(
    editor: &Rc<RichEditor>,
    records: BTreeMap<String, Record>,
    old_busy: bool,
    ok: bool,
    failure: Option<String>,
) {
    let mut state = editor.assets.borrow_mut();
    state.records = records;
    state.running = None;
    let callbacks = std::mem::take(&mut state.waiters);
    drop(state);
    editor.busy.set(old_busy);
    if let Some(error) = failure {
        editor.failed.set(true);
        editor.status.set_text(&format!(
            "{} {error}",
            editor.text(
                "Bildaktion angehalten; Rücknahmedaten prüfen:",
                "Image action held; inspect recovery data:"
            )
        ));
    }
    for callback in callbacks {
        callback(ok);
    }
}
pub(super) fn reconcile(editor: Rc<RichEditor>, value: &Value, done: Done) {
    reconcile_inner(editor, value, false, done);
}
pub(super) fn reconcile_saved(editor: Rc<RichEditor>, value: &Value, done: Done) {
    reconcile_inner(editor, value, true, done);
}
fn reconcile_inner(editor: Rc<RichEditor>, value: &Value, saved: bool, done: Done) {
    let revision = value["revision"].as_u64().unwrap_or(0);
    let desired = value["imageTransactions"]
        .as_array()
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<BTreeSet<_>>()
        })
        .unwrap_or_default();
    let mut state = editor.assets.borrow_mut();
    if let Some((pending, ids)) = state.running.as_ref() {
        if *pending == revision && *ids == desired && state.waiters.len() < 2 {
            state.waiters.push(done);
            editor.busy.set(true);
        } else {
            drop(state);
            done(false);
        }
        return;
    }
    if desired.iter().any(|id| {
        state
            .records
            .get(id)
            .and_then(|record| record.pending_owner.as_ref())
            .is_some_and(|owner| !owner.current(&editor))
    }) {
        drop(state);
        done(false);
        return;
    }
    if desired.len() > 128 || desired.iter().any(|id| !state.records.contains_key(id)) {
        drop(state);
        done(false);
        return;
    }
    if state.records.iter().all(|(id, record)| {
        record.visible == desired.contains(id)
            && !(saved && !record.visible && record.receipt.is_applied())
    }) {
        drop(state);
        done(true);
        return;
    }
    if !write_allowed(&editor) {drop(state);done(false);return;}
    let Some(lease) = asset_flow::Lease::capture(&editor) else {
        drop(state);
        done(false);
        return;
    };
    let Some(doc) = editor.current() else {
        drop(state);
        done(false);
        return;
    };
    let opened = asset_refs::capture(&doc);
    let texts = opened.texts.clone();
    let complete = opened.complete;
    let records = std::mem::take(&mut state.records);
    let prior = records
        .iter()
        .map(|(id, record)| (id.clone(), record.visible))
        .collect::<BTreeMap<_, _>>();
    state.running = Some((revision, desired.clone()));
    state.waiters.push(done);
    drop(state);
    let old_busy = editor.busy.replace(true);
    let worker_lease = lease.clone();
    let weak = Rc::downgrade(&editor);
    crate::asset_io::background(
        move || {
            let mut records = records;
            let mut changed = Vec::new();
            let protection = worker_lease.path.as_deref().map(|path| {
                asset_refs::Protection::scan(path, &texts, complete, &Cancellation::default())
            });
            let mut failure = None;
            for (id, record) in records.iter_mut() {
                let visible = desired.contains(id);
                if visible == record.visible && !(saved && !visible && record.receipt.is_applied())
                {
                    continue;
                }
                if visible && !record.receipt.is_applied() {
                    if let Err(error) = record
                        .receipt
                        .redo(&worker_lease.owner, &Cancellation::default())
                    {
                        failure = Some(error.to_string());
                        break;
                    }
                    changed.push((id.clone(), true));
                } else if !visible && record.receipt.is_applied() {
                    let protected = protection.as_ref().is_none_or(|p| {
                        p.protects(record.receipt.preview().iter().filter_map(|p| {
                            worker_lease
                                .path
                                .as_ref()
                                .and_then(|d| d.parent())
                                .map(|d| d.join(&p.relative))
                        }))
                    });
                    if !protected {
                        match record
                            .receipt
                            .undo(&worker_lease.owner, &Cancellation::default())
                        {
                            Ok(()) => changed.push((id.clone(), false)),
                            Err(fastra_io::Error::RecoveryRequired(path)) => {
                                failure = Some(format!("Recovery required: {}", path.display()));
                                break;
                            }
                            Err(_) => {} // Fremdgeänderte Bilder behalten wie am Mac ihren sichtbaren Namen.
                        }
                    }
                }
                record.visible = visible;
            }
            if protection
                .as_ref()
                .is_some_and(|p| !p.current(&Cancellation::default()))
            {
                failure = Some("Reference sources changed during image operation".into());
            }
            if failure.is_some() {
                if let Some(error) =
                    restore_changes(&mut records, &changed, &prior, &worker_lease.owner)
                {
                    failure = Some(error);
                }
                changed.clear();
            }
            Ok((records, changed, prior, failure))
        },
        move |result| {
            let Ok((mut records, changed, prior, failure)) = result else {
                if let Some(editor) = weak.upgrade() {
                    complete_reconcile(
                        &editor,
                        BTreeMap::new(),
                        old_busy,
                        false,
                        Some("Image worker failed".into()),
                    );
                }
                return;
            };
            let owner_current = weak
                .upgrade()
                .is_some_and(|editor| lease.current(&editor) && opened.current());
            if !owner_current && !changed.is_empty() {
                let owner = lease.owner;
                crate::asset_io::background(
                    move || {
                        let error = restore_changes(&mut records, &changed, &prior, &owner);
                        Ok((records, error.or(failure)))
                    },
                    move |result| {
                        if let Some(editor) = weak.upgrade() {
                            if let Ok((records, failure)) = result {
                                complete_reconcile(&editor, records, old_busy, false, failure);
                            }
                        }
                    },
                );
            } else if let Some(editor) = weak.upgrade() {
                let ok = owner_current && failure.is_none();
                complete_reconcile(&editor, records, old_busy, ok, failure);
            }
        },
    );
}
fn materialize_rtf(editor: Rc<RichEditor>, lease: asset_flow::Lease, bytes: Vec<u8>, key: String) {
    editor.busy.set(true);
    let weak = Rc::downgrade(&editor);
    crate::git_view::background(
        move || {
            use std::io::Write;
            let scratch = tempfile::Builder::new()
                .prefix("fastra-clipboard-rtf-")
                .tempdir_in("/var/tmp")
                .map_err(|e| e.to_string())?;
            let path = scratch.path().join("Clipboard.rtf");
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
                .map_err(|e| e.to_string())?;
            file.write_all(&bytes).map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            Ok((scratch, path))
        },
        move |result| {
            if let Some(editor) = weak.upgrade() {
                editor.busy.set(false);
                discard(&editor, &key);
                if !lease.current(&editor) {
                    editor.clipboard_error("stale");
                    return;
                }
                match result {
                    Ok((scratch, path)) => {
                        if let Some(ui) = editor.ui.upgrade() {
                            super::super::import_view::open_materialized_rtf(&ui, path, scratch);
                        }
                    }
                    Err(error) => editor.status.set_text(&error),
                }
            }
        },
    );
}

pub(super) fn recovery(editor: &Rc<RichEditor>) {
    let Some(ui) = editor.ui.upgrade() else {
        return;
    };
    let window = crate::git_view::window(
        &ui,
        ui.lang.text("Bild-Rücknahmedaten", "Image recovery files"),
        false,
    );
    window.set_default_size(760, 500);
    let root = crate::git_view::column();
    root.append(&crate::git_view::label(ui.lang.text("Diese Dateien bleiben absichtlich erhalten, auch wenn ein anderes Programm noch einen offenen Bild-Handle besitzt. Sie werden nicht automatisch gelöscht. Kopieren Sie benötigte Dateien zuerst an einen eigenen Ort. Fremdgeänderte Bilder oder Kollisionen werden niemals überschrieben.","These files are retained deliberately, including when another application still holds an image handle. They are never deleted automatically. Copy needed files to your own location first. Changed images and collisions are never overwritten.")));
    let mut text = String::new();
    for record in editor.assets.borrow().records.values() {
        for (original, current) in record.receipt.recovery_paths() {
            text.push_str(&format!(
                "{}\n→ {}\n\n",
                original.display(),
                current.display()
            ));
        }
    }
    for retained in &editor.assets.borrow().retained {
        for path in &retained.paths {
            text.push_str(&format!("{}\n\n", path.display()));
        }
    }
    if let Some(doc) = editor.document.upgrade() {
        for path in super::save_as::origin_paths(&doc) { text.push_str(&format!("{}\n\n",path.display())); }
    }
    if text.is_empty() {
        text=ui.lang.text("Für dieses Dokument sind keine Rücknahmedateien bekannt. Nach dem Schließen einer Ansicht bleiben bereits erhaltene Dateien im images-Ordner unter .fastra-image-undo-… vorhanden.","No recovery files are known for this document. After a view is closed, already retained files remain in images under .fastra-image-undo-….").into();
    }
    root.append(&text_page(&text));
    let close = gtk::Button::with_label(ui.lang.text("Schließen", "Close"));
    let weak = window.downgrade();
    close.connect_clicked(move |_| {
        if let Some(window) = weak.upgrade() {
            window.close();
        }
    });
    root.append(&close);
    window.set_child(Some(&root));
    window.present();
}

pub(super) fn html(editor: Rc<RichEditor>, html: String, key: String) {
    let Some(lease) = asset_flow::Lease::capture(&editor) else {
        discard(&editor, &key);
        return;
    };
    let weak = Rc::downgrade(&editor);
    editor.evaluate(&format!("return JSON.stringify(fastraVisual.inspectClipboardHTML({}));",json!(html)),move|result|{
        let Some(editor)=weak.upgrade()else{return;};
        if !lease.current(&editor){editor.clipboard_error("stale");discard(&editor,&key);return;}
        let Some(value)=result else{editor.clipboard_error("read");discard(&editor,&key);return;};
        if value["ok"]!=true{editor.clipboard_error(value["reason"].as_str().unwrap_or("format"));discard(&editor,&key);return;}
        if value["images"].as_array().is_some_and(|images|!images.is_empty()){
            editor.busy.set(true);let weak=Rc::downgrade(&editor);
            crate::git_view::background(move||{
                let entries=value["images"].as_array().ok_or("HTML image package")?;
                let mut images=serde_json::Map::new();
                for image in entries{let url=image["url"].as_str().ok_or("HTML image location")?;let bytes=image["base64"].as_str().ok_or("HTML image bytes")?;images.insert(url.to_owned(),Value::String(bytes.to_owned()));}
                let encoded=glib::base64_encode(serde_json::to_string(&images).map_err(|e|e.to_string())?.as_bytes());
                let package=json!({"markdown":value["markdown"],"url":value["url"],"images":encoded.as_str()}).to_string();
                transfer::decode(clipboard::MIME,package.as_bytes()).map_err(str::to_owned)
            },move|result|{
                let Some(editor)=weak.upgrade()else{return;};editor.busy.set(false);
                if !lease.current(&editor){discard(&editor,&key);editor.clipboard_error("stale");return;}
                match result{Ok(transfer)=>receive(editor,transfer,key),Err(error)=>{editor.status.set_text(&error);discard(&editor,&key);}}
            });
        }else{
            let weak=Rc::downgrade(&editor);
            editor.evaluate(&format!("return JSON.stringify(fastraVisual.insertClipboardHTML({},{}));",json!(key),json!(html)),move|value|{if let Some(editor)=weak.upgrade(){if !value.as_ref().is_some_and(|value|value["ok"]==true){editor.clipboard_error(value.as_ref().and_then(|value|value["reason"].as_str()).unwrap_or("format"));}}});
        }
    });
}

pub(super) fn for_source(editor: Rc<RichEditor>, done: Box<dyn FnOnce(bool)>) {
    if editor
        .assets
        .borrow()
        .records
        .values()
        .all(|record| record.receipt.is_applied())
    {
        done(true);
        return;
    }
    if !write_allowed(&editor) {done(false);return;}
    let Some(lease) = asset_flow::Lease::capture(&editor) else {
        done(false);
        return;
    };
    let mut records = std::mem::take(&mut editor.assets.borrow_mut().records);
    editor.busy.set(true);
    let worker = lease.clone();
    let weak = Rc::downgrade(&editor);
    crate::asset_io::background(
        move || {
            let mut error = None;
            for record in records.values_mut() {
                if !record.receipt.is_applied() {
                    if let Err(failure) = record.receipt.rollback_undo(&worker.owner) {
                        error = Some(failure.to_string());
                        break;
                    }
                }
            }
            Ok((records, error))
        },
        move |result| {
            let Some(editor) = weak.upgrade() else {
                done(false);
                return;
            };
            editor.busy.set(false);
            match result {
                Ok((records, error)) => {
                    editor.assets.borrow_mut().records = records;
                    let ok = error.is_none() && lease.current(&editor);
                    if let Some(error) = error {
                        editor.status.set_text(&format!("{} {error}",editor.text("Quelltextwechsel angehalten; Bildnamen für Quelltext-Undo konnten nicht vollständig wiederhergestellt werden:","Source switch held; image names needed for source Undo could not all be restored:")));
                    }
                    if !ok {
                        editor.release();
                    }
                    done(ok);
                }
                Err(error) => {
                    editor.status.set_text(&error);
                    done(false);
                }
            }
        },
    );
}

#[cfg(test)]
mod completion_tests {
    use super::*;
    #[test]
    fn cancel_after_successful_apply_compensates_without_inserting() {
        use fastra_io::markdown_assets::{Input, Owner, Plan};
        let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let dir = tempfile::tempdir_in(root).unwrap();
        let path = dir.path().join("document.md");
        std::fs::write(&path, "Original\n").unwrap();
        let owner = Owner {
            document: "cancel-race".into(),
            revision: 1,
            generation: 1,
        };
        let cancel = Cancellation::default();
        let plan = Plan::prepare(
            &path,
            owner.clone(),
            vec![Input {
                extension: "png".into(),
                bytes: std::sync::Arc::new(b"approved bytes".to_vec()),
            }],
            &cancel,
        )
        .unwrap();
        let receipt = plan.apply(&owner, &cancel).unwrap();
        let target = dir.path().join(&receipt.preview()[0].relative);
        assert!(target.exists());
        // Apply hat bereits Erfolg gemeldet; erst danach trifft der Close/Cancel auf Main ein.
        assert!(may_insert(&cancel, true));
        cancel.cancel();
        assert!(!may_insert(&cancel, true));
        let (receipt, result) =
            compensate_receipt(receipt, &owner, Some((path.clone(), Vec::new(), true)));
        result.unwrap();
        assert!(!receipt.is_applied());
        assert!(!target.exists());
        let recovery = receipt.recovery_paths();
        assert_eq!(recovery.len(), 1);
        assert_eq!(std::fs::read(&recovery[0].1).unwrap(), b"approved bytes");
        assert_eq!(std::fs::read(&path).unwrap(), b"Original\n");
    }
    #[test]
    fn compensation_reports_changed_assets_and_keeps_their_live_names() {
        use fastra_io::markdown_assets::{Input, Owner, Plan};
        let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let dir = tempfile::tempdir_in(root).unwrap();
        let path = dir.path().join("document.md");
        std::fs::write(&path, "Original\n").unwrap();
        let owner = Owner {
            document: "cancel-race".into(),
            revision: 1,
            generation: 1,
        };
        let receipt = Plan::prepare(
            &path,
            owner.clone(),
            vec![Input {
                extension: "png".into(),
                bytes: std::sync::Arc::new(b"approved bytes".to_vec()),
            }],
            &Cancellation::default(),
        )
        .unwrap()
        .apply(&owner, &Cancellation::default())
        .unwrap();
        let target = dir.path().join(&receipt.preview()[0].relative);
        std::fs::write(&target, "External editor bytes").unwrap();
        let (receipt, result) = compensate_receipt(receipt, &owner, Some((path, Vec::new(), true)));
        assert!(result.is_err());
        assert!(receipt.is_applied());
        assert_eq!(std::fs::read(target).unwrap(), b"External editor bytes");
        assert!(!may_insert(&Cancellation::default(), false));
    }
}

#[cfg(test)]
mod compensation_reference_tests {
    use super::*;
    #[test]
    fn cancelled_insert_retains_newly_referenced_image_names() {
        use fastra_io::markdown_assets::{Input, Owner, Plan};
        let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let dir = tempfile::tempdir_in(root).unwrap();
        let path = dir.path().join("document.md");
        std::fs::write(&path, "Original\n").unwrap();
        let owner = Owner {
            document: "cancel-reference".into(),
            revision: 1,
            generation: 1,
        };
        let receipt = Plan::prepare(
            &path,
            owner.clone(),
            vec![Input {
                extension: "png".into(),
                bytes: std::sync::Arc::new(b"approved bytes".to_vec()),
            }],
            &Cancellation::default(),
        )
        .unwrap()
        .apply(&owner, &Cancellation::default())
        .unwrap();
        let relative = receipt.preview()[0].relative.clone();
        let target = dir.path().join(&relative);
        let source = format!("![new reference]({})", relative.display());
        let (receipt, result) = compensate_receipt(
            receipt,
            &owner,
            Some((path.clone(), vec![(path, source)], true)),
        );
        assert!(result.is_err());
        assert!(receipt.is_applied());
        assert_eq!(std::fs::read(target).unwrap(), b"approved bytes");
    }
}

#[cfg(test)]
mod compensation_drift_tests {
    use super::*;
    use fastra_io::markdown_assets::{Input, Owner, Plan};
    fn fixture() -> (tempfile::TempDir, std::path::PathBuf, Owner, Receipt) {
        let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let dir = tempfile::tempdir_in(root).unwrap();
        let path = dir.path().join("document.md");
        std::fs::write(&path, "Original\n").unwrap();
        let owner = Owner {
            document: "cancel-drift".into(),
            revision: 1,
            generation: 1,
        };
        let receipt = Plan::prepare(
            &path,
            owner.clone(),
            vec![Input {
                extension: "png".into(),
                bytes: std::sync::Arc::new(b"approved bytes".to_vec()),
            }],
            &Cancellation::default(),
        )
        .unwrap()
        .apply(&owner, &Cancellation::default())
        .unwrap();
        (dir, path, owner, receipt)
    }
    #[test]
    fn saved_reference_drift_after_actual_undo_restores_names() {
        for existing in [false, true] {
            let (dir, path, owner, receipt) = fixture();
            let sibling = dir.path().join(".notes.md");
            if existing {
                std::fs::write(&sibling, "No reference\n").unwrap();
            }
            let relative = receipt.preview()[0].relative.clone();
            let target = dir.path().join(&relative);
            let (receipt, result) = compensate_receipt_with(
                receipt,
                &owner,
                Some((path.clone(), Vec::new(), true)),
                || {
                    // Echte Undo-Phase: der Live-Name ist bereits im Claim, die Nachprüfung steht noch aus.
                    assert!(!target.exists());
                    std::fs::write(
                        &sibling,
                        format!("![new reference]({})", relative.display()),
                    )
                    .unwrap();
                },
            );
            assert!(result.unwrap_err().contains("Reference sources changed"));
            assert!(receipt.is_applied());
            assert_eq!(std::fs::read(target).unwrap(), b"approved bytes");
            assert_eq!(std::fs::read(path).unwrap(), b"Original\n");
        }
    }
    #[test]
    fn open_snapshot_postcheck_restores_an_actual_undo() {
        let (dir, _path, owner, mut receipt) = fixture();
        let target = dir.path().join(&receipt.preview()[0].relative);
        receipt.undo(&owner, &Cancellation::default()).unwrap();
        assert!(!target.exists());
        // Derselbe Rückbenennungspfad wie beim auf Main erkannten OpenSnapshot-Drift.
        let result = restore_compensation(&mut receipt, &owner, "Open reference documents changed");
        assert!(result.unwrap_err().contains("restored and retained"));
        assert!(receipt.is_applied());
        assert_eq!(std::fs::read(target).unwrap(), b"approved bytes");
    }
    #[test]
    fn drift_restore_collision_reports_and_retains_both_versions() {
        let (dir, path, owner, receipt) = fixture();
        let sibling = dir.path().join("sibling.md");
        let relative = receipt.preview()[0].relative.clone();
        let target = dir.path().join(&relative);
        let (receipt, result) =
            compensate_receipt_with(receipt, &owner, Some((path, Vec::new(), true)), || {
                assert!(!target.exists());
                std::fs::write(
                    &sibling,
                    format!("![new reference]({})", relative.display()),
                )
                .unwrap();
                std::fs::write(&target, "Foreign collision bytes").unwrap();
            });
        assert!(result.unwrap_err().contains("restoring image names failed"));
        assert!(!receipt.is_applied());
        assert_eq!(std::fs::read(target).unwrap(), b"Foreign collision bytes");
        let paths = receipt.recovery_paths();
        assert_eq!(paths.len(), 1);
        assert_eq!(std::fs::read(&paths[0].1).unwrap(), b"approved bytes");
    }
}

#[cfg(debug_assertions)]
pub(super) fn test_seed_clipboard(editor:&RichEditor){
    static SEEDED:std::sync::atomic::AtomicBool=std::sync::atomic::AtomicBool::new(false);
    if std::env::var_os("FASTRA_QUIT_ASSET_IO_TEST_DIR").is_none() || SEEDED.swap(true,std::sync::atomic::Ordering::SeqCst){return;}
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(),Ok("1"));
    editor.view.clipboard().set_content(Some(&gtk::gdk::ContentProvider::for_bytes("image/png",&glib::Bytes::from_static(include_bytes!("../../tests/fixtures/pixel-1.png"))))).unwrap();
}
#[cfg(debug_assertions)]
fn test_pause(phase:&str){
    let Some(root)=std::env::var_os("FASTRA_QUIT_ASSET_IO_TEST_DIR")else{return;};
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(),Ok("1"));
    let root=std::path::PathBuf::from(root);assert!(root.is_absolute());
    if !root.join(format!("pause-{phase}")).exists(){return;}
    std::fs::write(root.join(format!("ready-{phase}")),b"ready").unwrap();
    let start=std::time::Instant::now();
    while !root.join(format!("release-{phase}")).exists(){assert!(start.elapsed()<std::time::Duration::from_secs(30));std::thread::sleep(std::time::Duration::from_millis(5));}
}

pub(super) fn origin_paths(state: &State, document: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut paths = std::collections::BTreeSet::new();
    for record in state.records.values() {
        paths.extend(record.receipt.recovery_paths().into_iter().map(|(_,path)|path));
        if record.receipt.is_applied() {
            if let Some(parent) = document.parent() { paths.extend(record.receipt.preview().iter().map(|entry|parent.join(&entry.relative))); }
        }
    }
    for retained in &state.retained { paths.extend(retained.paths.iter().cloned()); }
    paths.into_iter().collect()
}
