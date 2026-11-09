//! Explizite Pfadkopie mit gebundenem Ziel und vorab inventarisierten Markdown-Bildern.
use super::*;
use std::{path::PathBuf, rc::Weak, sync::Arc};
mod backend;
mod preview;
mod rollback;
#[derive(Debug)]
pub(super) enum Terminal {
    Saved(PathBuf),
    Cancelled,
    Failed(String),
    Stale,
    PublishedButNotAdopted(PathBuf),
}
type Completion = Box<dyn FnOnce(Terminal)>;
thread_local! {static BUTTONS:RefCell<Vec<(Weak<Ui>,glib::WeakRef<gtk::Button>)>>=const{RefCell::new(Vec::new())};}
pub(super) fn refresh(ui: &Ui) {
    BUTTONS.with(|buttons| {
        let mut buttons = buttons.borrow_mut();
        buttons.retain(|(owner, button)| owner.strong_count() > 0 && button.upgrade().is_some());
        for (owner, button) in buttons.iter() {
            if owner
                .upgrade()
                .is_some_and(|owner| std::ptr::eq(owner.as_ref(), ui))
            {
                if let Some(button) = button.upgrade() {
                    button.set_sensitive(ui.active().is_some_and(|doc| {
                        doc.snapshot.borrow().is_some()
                            && !doc.saving.get()
                            && !doc.is_read_only()
                            && doc.hex_editor.borrow().is_none()
                    }));
                }
            }
        }
    });
}

struct Lease {
    document: Weak<Document>,
    revision: u64,
    pending_ending: Option<fastra_core::encoding::LineEnding>,
    chosen_ending: fastra_core::encoding::LineEnding,
    generation: u64,
    path: PathBuf,
    binding: [u8; 32],
    format: Arc<fastra_core::encoding::Decoded>,
    choice: Option<(u64, Option<String>, bool)>,
    language: Option<String>,
    project: Option<project_view::Binding>,
    project_context: Option<String>,
}
impl Lease {
    fn same_location_owned(&self, ui: &Rc<Ui>) -> Option<Rc<Document>> {
        let doc = self.document.upgrade()?;
        let current = ui.window.is_visible()
            && ui
                .documents
                .borrow()
                .iter()
                .any(|current| Rc::ptr_eq(current, &doc))
            && doc.disk_path().as_ref() == Some(&self.path)
            && !doc.is_read_only()
            && doc.hex_editor.borrow().is_none()
            && doc
                .snapshot
                .borrow()
                .as_ref()
                .and_then(|snapshot| snapshot.binding_digest().ok())
                == Some(self.binding)
            && Arc::ptr_eq(&self.format, &doc.format.borrow());
        current.then_some(doc)
    }
    fn current(&self, ui: &Rc<Ui>) -> bool {
        let Some(doc) = self.document.upgrade() else {
            return false;
        };
        let current_project = project_view::current_binding(ui);
        let project_current = self.project_context == project_view::context_id(ui)
            && match (&self.project, &current_project) {
                (Some(old), Some(current)) => {
                    old.is_current() && current.is_current() && old.owner_id() == current.owner_id()
                }
                (None, _) => true,
                _ => false,
            };
        let current = project_current
            && ui.window.is_visible()
            && ui.generation.get() == self.generation
            && ui
                .active()
                .is_some_and(|current| Rc::ptr_eq(&current, &doc))
            && ui
                .documents
                .borrow()
                .iter()
                .any(|current| Rc::ptr_eq(current, &doc))
            && doc.revision.get() == self.revision
            && doc.disk_path().as_ref() == Some(&self.path)
            && doc
                .snapshot
                .borrow()
                .as_ref()
                .and_then(|snapshot| snapshot.binding_digest().ok())
                == Some(self.binding)
            && Arc::ptr_eq(&self.format, &doc.format.borrow())
            && editor_options::save_as_stamp(&doc)
                .as_ref()
                .map(|(generation, choice, _)| (*generation, choice))
                == self
                    .choice
                    .as_ref()
                    .map(|(generation, choice, _)| (*generation, choice))
            && doc
                .buffer
                .language()
                .map(|language| language.id().to_string())
                == self.language;
        #[cfg(debug_assertions)]
        if !current && std::env::var_os("FASTRA_SAVE_AS_SELFTEST").is_some() {
            eprintln!("Save-as stale flags: project={} generation={} revision={} format={} choice={} language={}",project_current,ui.generation.get()==self.generation,doc.revision.get()==self.revision,Arc::ptr_eq(&self.format,&doc.format.borrow()),editor_options::save_as_stamp(&doc).as_ref().map(|(generation,choice,_)|(*generation,choice))==self.choice.as_ref().map(|(generation,choice,_)|(*generation,choice)),doc.buffer.language().map(|language|language.id().to_string())==self.language);
        }
        current
    }
}
struct Flow {
    ui: Weak<Ui>,
    lease: Lease,
    text: String,
    source: fastra_io::Snapshot,
    held: RefCell<Option<Rc<rich_editor::RichEditor>>>,
    done: RefCell<Option<Completion>>,
    cancel: Cancellation,
    committing: Cell<bool>,
    window: RefCell<Option<gtk::Window>>,
    locked: RefCell<Vec<(glib::WeakRef<sourceview5::View>, bool)>>,
    project_work: Option<project_view::WorkBinding>,
}
impl Flow {
    fn current(&self) -> bool {
        self.ui.upgrade().is_some_and(|ui| self.lease.current(&ui))
    }
    fn finished(&self) -> bool {
        self.done.borrow().is_none()
    }
    fn finish(&self, terminal: Terminal) {
        let Some(done) = self.done.borrow_mut().take() else {
            return;
        };
        for (view, editable) in self.locked.borrow_mut().drain(..) {
            if let Some(view) = view.upgrade() {
                view.set_editable(editable);
            }
        }
        if let Some(editor) = self.held.borrow_mut().take() {
            if editor.active.get() {
                editor.release();
            }
        }
        if let Some(doc) = self.lease.document.upgrade() {
            doc.saving.set(false);
        }
        if let Some(window) = self.window.borrow_mut().take() {
            window.destroy();
        }
        if let Some(ui) = self.ui.upgrade() {
            ui.refresh_save();
            let lang = ui.lang;
            ui.status.set_text(&match &terminal {
            Terminal::Saved(path)=>format!("{} {}",lang.text("Ziel gespeichert:","Saved at target:"),project_view::display(path)),
            Terminal::Cancelled=>lang.text("Speichern unter abgebrochen; nichts veröffentlicht.","Save as cancelled; nothing published.").into(),
            Terminal::Failed(reason)=>format!("{} {reason}",lang.text("Speichern unter angehalten:","Save as held:")),
            Terminal::Stale=>lang.text("Dokument, Format oder Fensterkontext geändert. Neuere Eingaben bleiben erhalten; Speichern unter neu starten.","Document, format or window context changed. Newer input was retained; restart Save as.").into(),
            Terminal::PublishedButNotAdopted(path)=>format!("{} {}",lang.text("Ziel wurde veröffentlicht, aber nicht in diesen Tab übernommen. Neuere Eingaben und ursprünglicher Tabpfad bleiben erhalten. Ziel prüfen:","Target was published but not adopted into this tab. Newer input and the original tab path were retained. Inspect target:"),project_view::display(path)),
        });
        }
        done(terminal);
    }
    fn lock_views(&self) {
        fn walk(widget: &gtk::Widget, out: &mut Vec<(glib::WeakRef<sourceview5::View>, bool)>) {
            if let Ok(view) = widget.clone().downcast::<sourceview5::View>() {
                let editable = view.is_editable();
                out.push((view.downgrade(), editable));
                view.set_editable(false);
            }
            let mut child = widget.first_child();
            while let Some(next) = child {
                walk(&next, out);
                child = next.next_sibling();
            }
        }
        if let Some(doc) = self.lease.document.upgrade() {
            walk(doc.container.upcast_ref(), &mut self.locked.borrow_mut());
        }
    }
    fn window(self: &Rc<Self>) -> Option<gtk::Window> {
        if let Some(window) = self.window.borrow().as_ref() {
            return Some(window.clone());
        }
        let ui = self.ui.upgrade()?;
        let window = git_view::window(
            &ui,
            ui.lang.text("Speichern unter prüfen", "Review Save as"),
            true,
        );
        window.set_default_size(960, 760);
        #[cfg(debug_assertions)]
        if let Some(width) = std::env::var("FASTRA_SAVE_AS_WIDTH")
            .ok()
            .and_then(|value| value.parse::<i32>().ok())
        {
            window.set_default_size(width.max(700), 760);
        }
        window.set_size_request(700, 620);
        let weak = Rc::downgrade(self);
        window.connect_close_request(move |_| {
            let Some(flow) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            flow.cancel.cancel();
            if flow.committing.get() {
                return glib::Propagation::Stop;
            }
            flow.finish(Terminal::Cancelled);
            glib::Propagation::Stop
        });
        *self.window.borrow_mut() = Some(window.clone());
        Some(window)
    }
    fn prepare(self: &Rc<Self>, path: PathBuf) {
        if !self.current() {
            self.finish(Terminal::Stale);
            return;
        }
        let Some(ui) = self.ui.upgrade() else {
            self.finish(Terminal::Stale);
            return;
        };
        let Some(window) = self.window() else {
            self.finish(Terminal::Stale);
            return;
        };
        let root = git_view::column();
        root.append(&git_view::label(ui.lang.text(
            "Zielzustand und alle benutzten relativen Bilder werden geprüft …",
            "Checking target state and all used relative images …",
        )));
        let cancel = gtk::Button::with_label(ui.lang.text("Abbrechen", "Cancel"));
        let weak = Rc::downgrade(self);
        cancel.connect_clicked(move |_| {
            if let Some(flow) = weak.upgrade() {
                flow.cancel.cancel();
                flow.finish(Terminal::Cancelled);
            }
        });
        root.append(&cancel);
        window.set_child(Some(&root));
        window.present();
        let source = self.source.clone();
        let text = self.text.clone();
        let pending_ending = self.lease.pending_ending;
        let format = self.lease.format.clone();
        let cancel = self.cancel.clone();
        let markdown = markdown_path(&self.lease.path)
            || markdown_path(&path)
            || self.held.borrow().is_some()
            || self
                .lease
                .language
                .as_deref()
                .is_some_and(|id| matches!(id, "markdown" | "commonmark"));
        let owner = fastra_io::markdown_assets::Owner {
            document: format!("save-as-{:p}", self.as_ref()),
            revision: self.lease.revision,
            generation: self.lease.generation,
        };
        let flow = self.clone();
        let lang = ui.lang;
        let project = self.project_work.clone();
        git_view::background(
            move || {
                let text = line_endings::converted(&text, pending_ending)
                    .map_err(|error| io_error_text(lang, &error))?;
                backend::prepare(
                    source,
                    text,
                    format,
                    path,
                    backend::Mode {
                        markdown,
                        lang,
                        project,
                    },
                    owner,
                    &cancel,
                )
            },
            move |result| {
                if flow.finished() {
                    return;
                }
                if !flow.current() {
                    flow.finish(Terminal::Stale);
                    return;
                }
                match result {
                    Ok(prepared) => preview::show(flow, prepared),
                    Err(reason) => flow.finish(Terminal::Failed(reason)),
                }
            },
        );
    }
}
fn markdown_path(path: &std::path::Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| {
            matches!(
                ext.to_ascii_lowercase().as_str(),
                "md" | "markdown" | "mdown" | "mkd"
            )
        })
}
pub(super) fn request(ui: &Rc<Ui>, done: Completion) {
    if !git_pull::write_allowed(ui) {done(Terminal::Failed(ui.status.text().to_string()));return;}
    let Some(doc) = ui.active().filter(|doc| {
        !doc.is_read_only() && doc.hex_editor.borrow().is_none() && doc.snapshot.borrow().is_some()
    }) else {
        ui.status.set_text(ui.lang.text(
            "Speichern unter benötigt ein gespeichertes Textdokument.",
            "Save as requires a saved text document.",
        ));
        done(Terminal::Failed(ui.lang.text("Nur vollständig geladene, bereits gespeicherte Textdokumente unterstützen diesen Pfad. Neue Dokumente zuerst mit Speichern sichern.","This path requires fully loaded, already saved text. Save a new document first.").into()));
        return;
    };
    if doc.saving.replace(true) {
        ui.status.set_text(
            ui.lang
                .text("Speichern läuft bereits.", "Saving is already running."),
        );
        done(Terminal::Failed(
            ui.lang
                .text("Speichern läuft bereits.", "Saving is already running.")
                .into(),
        ));
        return;
    }
    ui.refresh_save();
    let held = doc.rich.borrow().clone();
    let start = move |ui: Rc<Ui>,
                      doc: Rc<Document>,
                      held: Option<Rc<rich_editor::RichEditor>>,
                      done: Completion| {
        let source = doc.snapshot.borrow().clone().unwrap();
        let text = buffer_text(&doc.buffer);
        let Some(binding) = source.binding_digest().ok() else {
            doc.saving.set(false);
            ui.refresh_save();
            done(Terminal::Failed(
                ui.lang
                    .text(
                        "Quellbindung nicht verfügbar.",
                        "Source binding unavailable",
                    )
                    .into(),
            ));
            return;
        };
        let cancel = Cancellation::default();
        let project = project_view::current_binding(&ui);
        let project_work = match project
            .as_ref()
            .map(|project| project.work(&cancel))
            .transpose()
        {
            Ok(work) => work,
            Err(reason) => {
                doc.saving.set(false);
                ui.refresh_save();
                done(Terminal::Failed(reason));
                return;
            }
        };
        let flow = Rc::new(Flow {
            ui: Rc::downgrade(&ui),
            lease: Lease {
                project,
                project_context: project_view::context_id(&ui),
                document: Rc::downgrade(&doc),
                revision: doc.revision.get(),
                pending_ending: doc.line_endings.pending(),
                chosen_ending: doc.line_endings.current(),
                generation: ui.generation.get(),
                path: source.path(),
                binding,
                format: doc.format.borrow().clone(),
                choice: editor_options::save_as_stamp(&doc),
                language: doc
                    .buffer
                    .language()
                    .map(|language| language.id().to_string()),
            },
            text,
            source,
            held: RefCell::new(held),
            done: RefCell::new(Some(done)),
            cancel,
            project_work,
            committing: Cell::new(false),
            window: RefCell::new(None),
            locked: RefCell::new(Vec::new()),
        });
        let chooser = gtk::FileDialog::builder()
            .title(ui.lang.text("Speichern unter …", "Save as …"))
            .build();
        chooser.set_initial_file(Some(&gio::File::for_path(&flow.lease.path)));
        let lang = ui.lang;
        chooser.save(
            Some(&ui.window),
            None::<&gio::Cancellable>,
            move |result| match result {
                Ok(file) => {
                    if let Some(path) = file.path() {
                        flow.prepare(path);
                    } else {
                        flow.finish(Terminal::Failed(
                            lang.text(
                                "Nur lokale Speicherziele werden unterstützt.",
                                "Only local targets are supported",
                            )
                            .into(),
                        ));
                    }
                }
                Err(error) => {
                    if error.matches(gtk::DialogError::Dismissed)
                        || error.matches(gio::IOErrorEnum::Cancelled)
                    {
                        flow.finish(Terminal::Cancelled);
                    } else {
                        flow.finish(Terminal::Failed(error.to_string()));
                    }
                }
            },
        );
    };
    if let Some(editor) = held.clone() {
        let ui = ui.clone();
        editor.synchronize(
            true,
            Box::new(move |ok| {
                if ok {
                    start(ui, doc, held, done);
                } else {
                    doc.saving.set(false);
                    ui.refresh_save();
                    done(Terminal::Failed(
                        ui.lang
                            .text(
                                "Rich-Eingaben konnten nicht synchronisiert werden.",
                                "Rich input could not be synchronized.",
                            )
                            .into(),
                    ));
                }
            }),
        );
    } else {
        start(ui.clone(), doc, held, done);
    }
}
pub(super) fn install(ui: &Rc<Ui>, toolbar: &gtk::FlowBox) {
    let button = gtk::Button::with_label(ui.lang.text("Speichern unter …", "Save as …"));
    button.set_tooltip_text(Some(ui.lang.text(
        "Gespeichertes Textdokument an ein geprüftes neues Ziel kopieren (Strg+Umschalt+S).",
        "Copy saved text to a reviewed target (Ctrl+Shift+S).",
    )));
    let weak = Rc::downgrade(ui);
    button.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            request(&ui, Box::new(|_| {}));
        }
    });
    let position = ui
        .save
        .parent()
        .and_then(|parent| parent.downcast::<gtk::FlowBoxChild>().ok())
        .map_or(-1, |child| child.index() + 1);
    toolbar.insert(&button, position);
    BUTTONS.with(|buttons| {
        buttons
            .borrow_mut()
            .push((Rc::downgrade(ui), button.downgrade()))
    });
    refresh(ui);
}
