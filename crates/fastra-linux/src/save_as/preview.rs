use super::*;
use sha2::{Digest, Sha256};
fn text_page(text: &str) -> gtk::ScrolledWindow {
    let buffer = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
    buffer.set_enable_undo(false);
    buffer.set_text(text);
    let view = editor(&buffer);
    view.set_editable(false);
    git_view::scroll(&view)
}
fn comparison(before: &str, after: &str, lang: Language) -> gtk::Paned {
    let before_box = git_view::column();
    before_box.append(&git_view::label(
        lang.text("Quelle vorher", "Source before"),
    ));
    before_box.append(&text_page(before));
    let after_box = git_view::column();
    after_box.append(&git_view::label(
        lang.text("Vollständiges Ziel", "Complete target"),
    ));
    after_box.append(&text_page(after));
    let panes = gtk::Paned::new(gtk::Orientation::Horizontal);
    panes.set_vexpand(true);
    panes.set_start_child(Some(&before_box));
    panes.set_end_child(Some(&after_box));
    git_view::balance_panes(&panes);
    panes
}
pub(super) fn show(flow: Rc<Flow>, prepared: backend::Prepared) {
    let Some(ui) = flow.ui.upgrade() else {
        flow.finish(Terminal::Stale);
        return;
    };
    let Some(doc) = flow.lease.document.upgrade() else {
        flow.finish(Terminal::Stale);
        return;
    };
    if !rich_editor::save_as::archive_available(&doc) {
        flow.finish(Terminal::Failed(ui.lang.text("Die Grenze gespeicherter Bild-Herkunftspfade ist erreicht. Originaldateien bleiben erhalten.","Retained image-origin path limit reached. Original files were retained.").into()));
        return;
    }
    if prepared.original.len().max(prepared.output.len()) > 4 * 1024 * 1024 {
        flow.finish(Terminal::Failed(ui.lang.text("Die vollständige Speichern-unter-Vorschau ist auf 4 MiB je Textseite begrenzt. Nichts veröffentlicht.","The complete Save-as preview is limited to 4 MiB per text page. Nothing published.").into()));
        return;
    }
    let existing = prepared.target_text.as_deref();
    let Some(window) = flow.window() else {
        flow.finish(Terminal::Stale);
        return;
    };
    let lang = ui.lang;
    let root = git_view::column();
    let header = gtk::Label::new(Some(&format!(
        "{}\n{}\n{} B · SHA-256 {:x}",
        lang.text("Geprüftes Speicherziel:", "Reviewed save target:"),
        project_view::display(&prepared.target.path()),
        prepared.encoded.len(),
        Sha256::digest(&prepared.encoded)
    )));
    header.set_text(&format!(
        "{}\n{}",
        header.text(),
        document_view::format_text(&flow.lease.format, &prepared.output, lang)
    ));
    header.set_xalign(0.);
    header.set_wrap(true);
    header.set_selectable(true);
    root.append(&header);
    root.append(&git_view::label(lang.text("Nur das genehmigte Ziel und unten aufgeführte neue Bildkopien werden geschrieben. Ursprüngliche Dokumente und Bilddateien werden weder verschoben noch bereinigt. Bei einem Ziel gleich der Quelldatei gilt normales Speichern.","Only the approved target and new image copies listed below are written. Original documents and images are neither moved nor cleaned up. A target identical to the source uses normal save semantics.")));
    let notebook = gtk::Notebook::new();
    notebook.set_vexpand(true);
    let comparison = comparison(&prepared.original, &prepared.output, lang);
    notebook.append_page(
        &comparison,
        Some(&gtk::Label::new(Some(lang.text(
            "Vollständiger Textvergleich",
            "Complete text comparison",
        )))),
    );
    let mut files = String::new();
    for image in &prepared.images {
        files.push_str(&format!(
            "{}\n→ {}\n{} B · SHA-256 {:x}\n\n",
            if image.requested == image.snapshot.path() {
                project_view::display(&image.requested)
            } else {
                format!(
                    "{} [→ {}]",
                    project_view::display(&image.requested),
                    project_view::display(&image.snapshot.path())
                )
            },
            project_view::display(&image.destination),
            image.snapshot.bytes().len(),
            Sha256::digest(image.snapshot.bytes())
        ));
    }
    if files.is_empty() {
        files=lang.text("Keine neuen Bilddateien. Bei gleichem tatsächlichem Elternordner behalten relative Verweise ihre Basis.","No new image files. Relative references keep their base within the same actual parent folder.").into();
    }
    notebook.append_page(
        &text_page(&files),
        Some(&gtk::Label::new(Some(
            lang.text("Alle Bildkopien", "All image copies"),
        ))),
    );
    if let Some(existing) = existing {
        notebook.append_page(
            &text_page(existing),
            Some(&gtk::Label::new(Some(
                lang.text("Vorhandenes Ziel vorher", "Existing target before"),
            ))),
        );
    }
    root.append(&notebook);
    let path_changed = prepared.target.path() != prepared.source.path();
    let reset_undo = path_changed && (prepared.relocated || rich_editor::save_as::has_assets(&doc));
    root.append(&git_view::label(if reset_undo{lang.text("Nach dem Pfadwechsel beginnt Rückgängig neu. Alte Bildtickets bleiben ausschließlich mit ihrer ursprünglichen Herkunft als Rücknahmedaten erhalten; sie wirken nicht auf neue Zielbilder.","Undo starts fresh after this path change. Old image tickets are retained only as recovery data at their original locations; they never act on new target images.")}else{lang.text("Text-Rückgängig bleibt erhalten. Neue Zielbilder gehören zum gespeicherten Dokument.","Text Undo is preserved. New target images belong to the saved document.")}));
    let overwrite = gtk::CheckButton::with_label(lang.text(
        "Genau den oben gezeigten vorhandenen Zielstand ersetzen",
        "Replace exactly the existing target state shown above",
    ));
    overwrite.set_visible(prepared.target.existing().is_some());
    root.append(&overwrite);
    let status = gtk::Label::new(None);
    status.set_wrap(true);
    status.set_xalign(0.);
    root.append(&status);
    let seen = Rc::new(Cell::new(false));
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    let apply =
        gtk::Button::with_label(lang.text("Geprüft speichern unter", "Save reviewed target"));
    apply.set_sensitive(false);
    buttons.append(&cancel);
    buttons.append(&apply);
    root.append(&buttons);
    let apply_copy = apply.clone();
    let seen_copy = seen.clone();
    overwrite.connect_toggled(move |check| {
        apply_copy.set_sensitive(seen_copy.get() && check.is_active())
    });
    let seen_copy = seen.clone();
    let apply_copy = apply.clone();
    let overwrite_copy = overwrite.clone();
    let status_copy = status.clone();
    let frames = Cell::new(0);
    comparison.add_tick_callback(move|panes,_|{
        if panes.is_mapped() && panes.start_child().is_some_and(|child|child.is_mapped()&&child.width()>=120) && panes.end_child().is_some_and(|child|child.is_mapped()&&child.width()>=120){
            seen_copy.set(true);apply_copy.set_sensitive(!overwrite_copy.is_visible()||overwrite_copy.is_active());return glib::ControlFlow::Break;
        }
        frames.set(frames.get()+1);if frames.get()>=120{status_copy.set_text(lang.text("Der vollständige Vergleich konnte nicht sichtbar aufgebaut werden. Abbrechen und neu öffnen.","The complete comparison could not be laid out visibly. Cancel and reopen."));return glib::ControlFlow::Break;}
        glib::ControlFlow::Continue
    });
    let weak = Rc::downgrade(&flow);
    cancel.connect_clicked(move |_| {
        if let Some(flow) = weak.upgrade() {
            let window = flow.window.borrow().clone();
            if let Some(window) = window {
                window.close();
            }
        }
    });
    let prepared = Rc::new(RefCell::new(Some(prepared)));
    let ready = prepared.clone();
    let held = flow.clone();
    apply.connect_clicked(move |button| {
        if !held.current() {
            held.finish(Terminal::Stale);
            return;
        }
        if held.cancel.check().is_err() {
            held.finish(Terminal::Cancelled);
            return;
        }
        if !seen.get() {
            status.set_text(lang.text(
                "Zuerst beide Seiten des vollständigen Textvergleichs anzeigen.",
                "First display both sides of the complete text comparison.",
            ));
            return;
        }
        let Some(ui)=held.ui.upgrade()else{held.finish(Terminal::Stale);return;};
        if !super::super::git_pull::write_allowed(&ui) {status.set_text(&ui.status.text());return;}
        let Some(prepared) = ready.borrow_mut().take() else {
            return;
        };
        button.set_sensitive(false);
        held.committing.set(true);
        held.lock_views();
        publish(held.clone(), prepared, reset_undo);
    });
    window.set_child(Some(&root));
    window.present();
    header.select_region(0, 0);
    cancel.grab_focus();
}
fn publish(flow: Rc<Flow>, prepared: backend::Prepared, reset_undo: bool) {
    let owner = prepared.owner.clone();
    let lang = flow.ui.upgrade().map_or(Language(false), |ui| ui.lang);
    let expected_target = prepared.target.path();
    let cancel = flow.cancel.clone();
    git_view::background(
        move || Ok(prepared.publish(&cancel)),
        move |result| {
            match result {
            Ok(backend::Outcome::Published {
                snapshot,
                content,
                assets,
            }) => {
                // Nach realer Veröffentlichung behalten wir benötigte Bilder unabhängig von Abbruch/Ownerdrift.
                drop(assets);
                // Am unveränderten Speicherort gilt normales Speichern: spätere Eingaben bleiben dirty, die tatsächlich gespeicherte Basis wird trotzdem übernommen.
                if snapshot.path()==flow.lease.path {
                    if let Some(ui)=flow.ui.upgrade(){if let Some(doc)=flow.lease.same_location_owned(&ui){adopt_same_location(flow,ui,doc,snapshot,content);return;}}
                }
                if !flow.current() || flow.cancel.check().is_err() {
                    flow.finish(Terminal::PublishedButNotAdopted(snapshot.path()));
                    return;
                }
                adopt(flow, snapshot, content, reset_undo);
            }
            Ok(backend::Outcome::Failed {
                mut reason,
                target,
                possibly_published,
                assets,
                recovery,
                journal,
            }) => {
                if let Some(journal) = journal {
                    if let Some(ui) = flow.ui.upgrade() {
                        if let Err(error)=session::remember_journal(&ui,journal){reason.push_str(&format!("\n{} {error}",lang.text("Der Transaktionsindex konnte nicht gesichert werden; den genannten Wiederherstellungsort erhalten.","The transaction index could not be saved; retain the reported recovery location.")));}
                    }
                }
                if possibly_published {
                    let mut locations = recovery;
                    locations.push(target.clone());
                    failed(
                        flow,
                        format!(
                            "{} {reason}",
                            lang.text("Das Ziel kann bereits veröffentlicht sein; vor erneutem Speichern prüfen.","Target may already have been published; inspect it before retrying.")
                        ),
                        locations,
                    );
                    return;
                }
                let reason=format!("{} {reason}",lang.text("Zieltext nicht veröffentlicht.","Target text was not published."));
                let Some(receipt) = assets else {
                    let mut locations = recovery;
                    locations.push(target);
                    failed(flow, reason, locations);
                    return;
                };
                let capture = flow.lease.document.upgrade().map(|doc| {
                    let mut opened = rich_editor::asset_refs::capture(&doc);
                    if doc.buffer.char_count() <= 262144 {
                        opened
                            .texts
                            .push((flow.lease.path.clone(), buffer_text(&doc.buffer)));
                    } else {
                        opened.complete = false;
                    }
                    opened
                });
                let texts = capture
                    .as_ref()
                    .map(|opened| opened.texts.clone())
                    .unwrap_or_default();
                let complete = capture.as_ref().is_some_and(|opened| opened.complete);
                let worker_target = target.clone();
                let worker_owner = owner.clone();
                git_view::background(
                    move || {
                        Ok(rollback::compensate(
                            receipt,
                            &worker_owner,
                            &worker_target,
                            &texts,
                            complete,
                            lang,
                        ))
                    },
                    move |result| {
                        let Ok((mut receipt, outcome)) = result else {
                            failed(
                                flow,
                                format!("{reason}; {}",lang.text("Bildrücknahme unerwartet beendet.","Image rollback worker failed.")),
                                vec![target],
                            );
                            return;
                        };
                        if !receipt.is_applied()
                            && capture.as_ref().is_none_or(|opened| !opened.current())
                        {
                            git_view::background(
                                move || {
                                    let result = receipt.rollback_undo(&owner);
                                    Ok((receipt, result))
                                },
                                move |result| {
                                    let mut locations = vec![target.clone()];
                                    let detail = match result {
                                        Ok((receipt, result)) => {
                                            locations.extend(receipt_paths(&receipt, &target));
                                            format!("{} {result:?}",lang.text("Offene Verweise geändert; Bildnamen wiederhergestellt oder als Rücknahmedaten erhalten:","Open references changed; image names restored or retained:"))
                                        }
                                        Err(error) => error,
                                    };
                                    failed(flow, format!("{reason}; {detail}"), locations);
                                },
                            );
                        } else {
                            let mut locations = recovery;
                            locations.extend(receipt_paths(&receipt, &target));
                            failed(
                                flow,
                                format!("{reason}; {} {outcome:?}",lang.text("Bildrücknahme:","Image rollback:")),
                                locations,
                            );
                        }
                    },
                );
            }
            Err(error) => failed(flow,format!("{} {error}",lang.text("Speicherabschluss unerwartet beendet; Zielzustand vor erneutem Speichern prüfen.","Save completion ended unexpectedly; inspect target state before retrying.")),vec![expected_target]),
        }
        },
    );
}
fn receipt_paths(
    receipt: &fastra_io::markdown_assets::Receipt,
    target: &std::path::Path,
) -> Vec<PathBuf> {
    let mut paths = receipt
        .recovery_paths()
        .into_iter()
        .map(|(_, path)| path)
        .collect::<Vec<_>>();
    if receipt.is_applied() {
        if let Some(parent) = target.parent() {
            paths.extend(
                receipt
                    .preview()
                    .iter()
                    .map(|entry| parent.join(&entry.relative)),
            );
        }
    }
    paths
}
fn failed(flow: Rc<Flow>, reason: String, locations: Vec<PathBuf>) {
    if let Some(ui) = flow.ui.upgrade() {
        let window = git_view::window(
            &ui,
            ui.lang.text(
                "Speichern unter: Ergebnis prüfen",
                "Save as: inspect result",
            ),
            false,
        );
        window.set_default_size(800, 580);
        let root = git_view::column();
        root.append(&git_view::label(ui.lang.text("Speichern unter wurde nicht vollständig übernommen. Ursprünglicher Tabpfad und neuere Eingaben bleiben erhalten. Ziel- und Wiederherstellungsorte stehen unten. Der Fehlertext nennt den Veröffentlichungsstand; keine Daten werden still gelöscht.","Save as was not fully adopted. The original tab path and newer input were retained. Target and recovery locations are listed below. The error identifies the publication state; no data is silently deleted.")));
        root.append(&text_page(&format!(
            "{reason}\n\n{}",
            locations
                .iter()
                .map(|path| project_view::display(path))
                .collect::<Vec<_>>()
                .join("\n")
        )));
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
    flow.finish(Terminal::Failed(reason));
}
fn adopt_same_location(
    flow: Rc<Flow>,
    ui: Rc<Ui>,
    doc: Rc<Document>,
    snapshot: fastra_io::Snapshot,
    content: String,
) {
    let path = snapshot.path();
    let rich = if flow.text != content
        && doc.revision.get() == flow.lease.revision
        && buffer_text(&doc.buffer) == flow.text
    {
        flow.held.borrow_mut().take();
        rich_editor::save_as::detach(&ui, &doc)
    } else {
        None
    };
    line_endings::complete(
        &doc,
        &flow.text,
        &content,
        flow.lease.revision,
        flow.lease.chosen_ending,
        flow.lease.pending_ending,
    );
    *doc.snapshot.borrow_mut() = Some(snapshot);
    *doc.original.borrow_mut() = content.clone();
    doc.update_saved_baseline_status(&buffer_text(&doc.buffer));
    doc.update_label();
    if doc.revision.get() == flow.lease.revision {
        rich_editor::after_save(&doc);
    }
    editor_options::saved(&doc);
    doc.format_label.set_text(&document_view::format_text(
        &doc.format.borrow(),
        &content,
        ui.lang,
    ));
    if doc.watch.borrow().is_none() {
        *doc.watch.borrow_mut() = Some(watch::attach(&ui, &doc));
    }
    session::changed(&ui);
    doc.saving.set(false);
    rich_editor::save_as::restore_mode(&doc, ui.lang, rich);
    flow.finish(Terminal::Saved(path));
}
fn adopt(flow: Rc<Flow>, snapshot: fastra_io::Snapshot, content: String, reset_undo: bool) {
    let (Some(ui), Some(doc)) = (flow.ui.upgrade(), flow.lease.document.upgrade()) else {
        flow.finish(Terminal::PublishedButNotAdopted(snapshot.path()));
        return;
    };
    let target = snapshot.path();
    let path_changed = target != flow.lease.path;
    let rich = if path_changed {
        flow.held.borrow_mut().take();
        rich_editor::save_as::detach(&ui, &doc)
    } else {
        None
    };
    if !reset_undo {
        line_endings::complete(
            &doc,
            &flow.text,
            &content,
            flow.lease.revision,
            flow.lease.chosen_ending,
            flow.lease.pending_ending,
        );
    }
    if reset_undo {
        doc.buffer.set_enable_undo(false);
    }
    if buffer_text(&doc.buffer) != content {
        doc.buffer.set_text(&content);
    }
    if reset_undo {
        doc.buffer.set_enable_undo(true);
    }
    *doc.snapshot.borrow_mut() = Some(snapshot);
    *doc.original.borrow_mut() = content.clone();
    doc.line_endings.accept(flow.lease.chosen_ending);
    doc.buffer.set_modified(false);
    if path_changed {
        doc.revision.set(doc.revision.get().wrapping_add(1));
    }
    if path_changed {
        watch::relocated(&doc);
    } else {
        rich_editor::after_save(&doc);
    }
    editor_options::saved(&doc);
    doc.update_label();
    doc.reopen.set_sensitive(true);
    doc.format_label.set_text(&document_view::format_text(
        &doc.format.borrow(),
        &content,
        ui.lang,
    ));
    if doc.watch.borrow().is_none() {
        *doc.watch.borrow_mut() = Some(watch::attach(&ui, &doc));
    }
    if path_changed {
        ui.invalidate();
    }
    session::changed(&ui);
    if let Some(preview) = doc.markdown.borrow().as_ref() {
        preview.schedule(&doc, ui.lang);
    }
    doc.saving.set(false);
    rich_editor::save_as::restore_mode(&doc, ui.lang, rich);
    flow.finish(Terminal::Saved(target));
}
