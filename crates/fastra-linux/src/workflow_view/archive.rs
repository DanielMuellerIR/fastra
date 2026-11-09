use super::*;

impl View {
    pub(super) fn import_file(self: &Rc<Self>) {
        self.busy.set(true);
        self.refresh();
        let weak = Rc::downgrade(self);
        gtk::FileDialog::new().open(
            Some(&self.window),
            None::<&gio::Cancellable>,
            move |result| {
                let Some(v) = weak.upgrade() else {
                    return;
                };
                v.busy.set(false);
                let path = match result {
                    Ok(file) => match file.path() {
                        Some(path) => path,
                        None => {
                            v.error(Error::Invalid("local file".into()));
                            v.refresh();
                            return;
                        }
                    },
                    Err(_) => {
                        v.refresh();
                        return;
                    }
                };
                let Some(snapshot) = v.snapshot.borrow().clone() else {
                    return;
                };
                let snippet = v.snippet;
                v.run(
                    move || {
                        let bytes = read_archive(&path)?;
                        let mut library = snapshot.library;
                        if snippet {
                            library.snippets =
                                library.snippets.merged(&SnippetArchive::decode(&bytes)?)?;
                        } else {
                            library.workflows = library
                                .workflows
                                .merged(&WorkflowArchive::decode(&bytes)?)?;
                        }
                        library.validate()?;
                        Ok(library)
                    },
                    |v, library| v.confirm_import(library),
                );
            },
        );
    }
    pub(super) fn confirm_import(self: &Rc<Self>, library: Library) {
        let bytes = if self.snippet {
            library.snippets.encode()
        } else {
            library.workflows.encode()
        };
        let bytes = match bytes {
            Ok(bytes) => bytes,
            Err(e) => {
                self.error(e);
                return;
            }
        };
        let parent = match self.ui.upgrade() {
            Some(ui) => ui,
            None => return,
        };
        let dialog = window(
            &parent,
            self.lang.text(
                if self.snippet {
                    "Textbausteine importieren?"
                } else {
                    "Sammlung vor Import prüfen"
                },
                if self.snippet {
                    "Import text snippets?"
                } else {
                    "Review collection before importing"
                },
            ),
            true,
        );
        dialog.set_transient_for(Some(&self.window));
        let body = column();
        let text = output();
        if self.snippet {
            dialog.set_default_size(500, 340);
            dialog.set_size_request(500, 340);
            body.append(&label(self.lang.text("Die vorhandene Sammlung bleibt erhalten. Folgende Namen werden übernommen; Namenskonflikte sind bereits nummeriert:","The existing collection is preserved. These names will be imported; name conflicts have already received a number:")));
            let previous = self
                .snapshot
                .borrow()
                .as_ref()
                .map_or(0, |s| s.library.snippets.snippets.len());
            text.set_monospace(false);
            text.buffer().set_text(
                &library
                    .snippets
                    .snippets
                    .iter()
                    .skip(previous)
                    .map(|s| s.name.as_str())
                    .collect::<Vec<_>>()
                    .join("\n"),
            );
        } else {
            body.append(&label(self.lang.text("Vollständiger Stand nach dem Import. Bestehende Definitionen bleiben erhalten; neue erhalten eigene Kennungen und bei Bedarf einen Namenszusatz. Unbekannte Felder bleiben erhalten. Nicht unterstützte aktivierte Schritte lassen sich nicht ausführen.","Complete collection after importing. Existing definitions are preserved; new ones receive fresh IDs and a name suffix if needed. Unknown fields are preserved. Unsupported enabled steps cannot run.")));
            text.buffer()
                .set_text(std::str::from_utf8(&bytes).expect("JSON UTF-8"));
        }
        body.append(&scroll(&text));
        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let cancel = gtk::Button::with_label(self.lang.text("Abbrechen", "Cancel"));
        let accept = gtk::Button::with_label(self.lang.text(
            if self.snippet {
                "Importieren"
            } else {
                "Sammlung importieren"
            },
            if self.snippet {
                "Import"
            } else {
                "Import collection"
            },
        ));
        buttons.append(&cancel);
        buttons.append(&accept);
        body.append(&buttons);
        dialog.set_child(Some(&body));
        self.busy.set(true);
        self.refresh();
        let copy = dialog.clone();
        cancel.connect_clicked(move |_| copy.close());
        let weak = Rc::downgrade(self);
        dialog.connect_close_request(move |_| {
            if let Some(v) = weak.upgrade() {
                v.busy.set(false);
                v.refresh();
            }
            glib::Propagation::Proceed
        });
        let weak = Rc::downgrade(self);
        let copy = dialog.clone();
        let library = RefCell::new(Some(library));
        accept.connect_clicked(move |_| {
            let Some(view) = weak.upgrade() else {
                return;
            };
            let Some(library) = library.borrow_mut().take() else {
                return;
            };
            copy.close();
            let old_count = view.snapshot.borrow().as_ref().map_or(0, |snapshot| {
                if view.snippet {
                    snapshot.library.snippets.snippets.len()
                } else {
                    snapshot.library.workflows.workflows.len()
                }
            });
            let new_count = if view.snippet {
                library.snippets.snippets.len()
            } else {
                library.workflows.workflows.len()
            };
            let selected = if new_count > old_count {
                Some(old_count)
            } else {
                view.selected.get()
            };
            view.save_library(library,selected,view.lang.text(
                "Sammlung vollständig importiert. Die Textvorschau wurde noch nicht übernommen.",
                "Collection imported completely. No text preview has been applied.",
            ));
        });
        dialog.present();
    }
    pub(super) fn export_file(self: &Rc<Self>) {
        if self.snippet {
            let config = self.config.clone();
            self.run(
                move || Store::open(&config)?.load()?.library.snippets.encode(),
                |v, bytes| v.export_bytes(bytes),
            );
            return;
        }
        let bytes = match self.snapshot.borrow().as_ref().map(|s| s.library.workflows.encode()) {
            Some(Ok(bytes)) => bytes,
            Some(Err(e)) => {
                self.error(e);
                return;
            }
            None => return,
        };
        self.export_bytes(bytes);
    }
    fn export_bytes(self: &Rc<Self>, bytes: Vec<u8>) {
        let dialog = gtk::FileDialog::new();
        dialog.set_initial_name(Some(if self.snippet {
            "fastra-snippets.json"
        } else {
            "fastra-workflows.json"
        }));
        self.busy.set(true);
        self.refresh();
        let weak = Rc::downgrade(self);
        dialog.save(Some(&self.window),None::<&gio::Cancellable>,move|result|{let Some(v)=weak.upgrade()else{return;};v.busy.set(false);let path=match result{Ok(file)=>match file.path(){Some(path)=>path,None=>{v.error(Error::Invalid("local file".into()));v.refresh();return;}},Err(_)=>{v.refresh();return;}};let lang=v.lang;v.run(move||fastra_io::Transaction::save_new_document(&path,&bytes,&Cancellation::default()).map(|_|()).map_err(|e|Error::Invalid(format!("{} {e}",lang.text("Export legt eine neue Datei an. Bei vorhandenem Ziel bitte einen anderen Namen wählen.","Export creates a new file. Choose another name if the target exists.")))),|v,()|v.status.set_text(v.lang.text("Sammlung als Swift-kompatibles JSON exportiert. Zusatzfelder wurden erhalten.","Collection exported as Swift-compatible JSON. Additional fields were preserved.")));});
    }
}

fn read_archive(path: &std::path::Path) -> Result<Vec<u8>, Error> {
    use std::{fs::OpenOptions, io::Read, os::unix::fs::OpenOptionsExt};
    let path = std::fs::canonicalize(path)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > workflow::MAX_ARCHIVE_BYTES as u64 {
        return Err(Error::Limit);
    }
    let mut bytes = Vec::new();
    file.take(workflow::MAX_ARCHIVE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > workflow::MAX_ARCHIVE_BYTES {
        return Err(Error::Limit);
    }
    Ok(bytes)
}
