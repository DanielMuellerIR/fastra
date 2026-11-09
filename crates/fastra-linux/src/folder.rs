use super::*;
use fastra_search::{FolderPreview, Request};
#[path = "folder_workflow.rs"]
mod workflow;
use std::{path::PathBuf, sync::Arc};

fn check_project(
    project: Option<&super::project_view::WorkBinding>,
    cancel: &Cancellation,
) -> std::result::Result<(), fastra_search::Error> {
    cancel.check()?;
    if let Some(project) = project {
        project.validate().map_err(|_| match cancel.check() {
            Err(error) => fastra_search::Error::Core(error),
            Ok(()) => fastra_search::Error::Stale,
        })?;
    }
    cancel.check()?;
    Ok(())
}
#[derive(Clone)]
pub(super) struct SearchConfiguration {
    path: Option<PathBuf>,
    text: String,
    exclusions: String,
    known_text: bool,
}
struct FolderWindow {
    host: Rc<Ui>,
    workflow: Option<fastra_workflow::Workflow>,
    files: Vec<PathBuf>,
    stages: Option<Rc<workflow::Stages>>,
    window: glib::WeakRef<gtk::Window>,
    root: gtk::Entry,
    raw_root: RefCell<Option<PathBuf>>,
    setting_root: Cell<bool>,
    project: Option<super::project_view::Binding>,
    project_work: RefCell<Option<super::project_view::WorkBinding>>,
    excludes: gtk::Entry,
    known_text: gtk::CheckButton,
    sources: RefCell<Option<Rc<search_sources::Controls>>>,
    status: gtk::Label,
    pane: Rc<super::approval::ApprovalPane>,
    apply: gtk::Button,
    undo: gtk::Button,
    search: gtk::Button,
    cancel_button: gtk::Button,
    generation: Cell<u64>,
    busy: Cell<bool>,
    reading: Cell<bool>,
    cancel: RefCell<Cancellation>,
    pending: RefCell<Option<Arc<FolderPreview>>>,
    transaction: RefCell<Option<fastra_io::Transaction>>,
    transaction_paths: RefCell<std::collections::HashSet<PathBuf>>,
    parent_handler: RefCell<Option<glib::SignalHandlerId>>,
}
thread_local! {
    static WINDOWS:RefCell<Vec<std::rc::Weak<FolderWindow>>>=const{RefCell::new(Vec::new())};
}
#[cfg(debug_assertions)]
pub(super) fn test_sources(ui: &Ui) -> Rc<search_sources::Controls> {
    WINDOWS.with_borrow(|windows| windows.iter().rev().filter_map(std::rc::Weak::upgrade).find(|s|s.host.window == ui.window && s.visible()).unwrap().sources.borrow().as_ref().unwrap().clone())
}
#[cfg(debug_assertions)]
pub(super) fn test_matches(ui: &Ui) -> Option<usize> {
    WINDOWS.with_borrow(|windows| windows.iter().rev().filter_map(std::rc::Weak::upgrade).find(|s|s.host.window == ui.window && s.visible()).and_then(|s|s.pending.borrow().as_ref().map(|p|p.matches())))
}
#[cfg(debug_assertions)]
pub(super) fn test_root(ui: &Ui, path: PathBuf) {
    WINDOWS.with_borrow(|windows| {
        let state = windows.iter().rev().filter_map(std::rc::Weak::upgrade).find(|s|s.host.window == ui.window && s.visible()).unwrap();
        state.set_root(path); state.inputs_changed();
    });
}
pub(super) fn any_busy() -> bool {
    WINDOWS.with_borrow(|all| {
        all.iter()
            .filter_map(std::rc::Weak::upgrade)
            .any(|state| state.busy.get() || state.sources.borrow().as_ref().is_some_and(|s|s.busy()))
    })
}
// destroy_with_parent umgeht die close-request-Sperre des Kindfensters.
pub(super) fn prevent_close(host: &Ui) -> bool {
    WINDOWS.with_borrow(|windows| {
        for state in windows.iter().filter_map(std::rc::Weak::upgrade).filter(|s| s.host.window == host.window && s.reading.get()) {
            state.cancel.borrow().cancel();
        }
    });
    let busy = WINDOWS.with(|windows| {
        let mut windows = windows.borrow_mut();
        windows.retain(|state| state.upgrade().is_some());
        windows
            .iter()
            .rev()
            .filter_map(std::rc::Weak::upgrade)
            .find(|state| ((state.busy.get() && !state.reading.get()) || state.sources.borrow().as_ref().is_some_and(|s|s.busy())) && state.host.window == host.window)
    });
    let Some(state) = busy else {
        return false;
    };
    if state.sources.borrow().as_ref().is_some_and(|s|s.busy()) {
        host.status.set_text(host.lang.text("Suchquellen werden geladen oder gespeichert. Danach erneut schließen.", "Search sources are loading or saving. Close again afterwards."));
        if let Some(window) = state.window.upgrade() { window.present(); }
        return true;
    }
    state.status.set_text(host.lang.text(
        "Vorgang läuft; zuerst abbrechen und Ergebnis abwarten.",
        "Operation running; cancel and wait for the result first.",
    ));
    host.status.set_text(host.lang.text(
        "Dateivorgang läuft noch. Vor dem Schließen das Ergebnis abwarten.",
        "File operation is still running. Wait for its result before closing.",
    ));
    if let Some(window) = state.window.upgrade() {
        window.present();
    }
    true
}

impl Drop for FolderWindow {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
        if let Some(id) = self.parent_handler.get_mut().take() {
            self.host.window.disconnect(id);
        }
    }
}
impl FolderWindow {
    fn visible(&self) -> bool {
        self.host.window.is_visible()
            && self
                .window
                .upgrade()
                .is_some_and(|window| window.is_visible())
    }
    fn close_hidden(&self) {
        self.invalidate();
        self.set_busy(false);
        if let Some(window) = self.window.upgrade() {
            window.close();
        }
    }
    fn remember_configuration(&self) {
        if self.workflow.is_some() || !self.files.is_empty() {
            return;
        }
        let value = SearchConfiguration {
            path: self.raw_root.borrow().clone(),
            text: self.root.text().into(),
            exclusions: self.excludes.text().into(),
            known_text: self.known_text.is_active(),
        };
        if let Some(project) = self.project.as_ref() {
            *self.host.project_configuration.borrow_mut() = Some((project.owner_id(), value));
        } else {
            *self.host.folder_configuration.borrow_mut() = Some(value);
        }
    }
    fn inputs_changed(self: &Rc<Self>) {
        self.invalidate();
        if self.workflow.is_some() || !self.visible() || self.transaction.borrow().is_some() {
            return;
        }
        if self.sources.borrow().is_none() && self.root.text().is_empty() && self.raw_root.borrow().is_none() {
            return;
        }
        if !search_live::folder_ready(&self.host.find.text()) {
            self.status.set_text(self.host.lang.text(
                "Auch 1–2 Zeichen sind suchbar: Suchen klicken oder Return drücken.",
                "Patterns of 1–2 characters are searchable: click Find or press Return.",
            ));
            return;
        }
        let generation = self.generation.get();
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(420), move || {
            let Some(state) = weak.upgrade().filter(|state| {
                state.generation.get() == generation
                    && state.visible()
                    && state.transaction.borrow().is_none()
            }) else {
                return glib::ControlFlow::Break;
            };
            if state.busy.get() {
                return glib::ControlFlow::Continue;
            }
            state.search();
            glib::ControlFlow::Break
        });
    }
    fn locale(&self) -> Result<Option<fastra_core::text_operations::TitlecaseLocale>, String> {
        if self.workflow.as_ref().is_some_and(|flow| {
            flow.steps
                .iter()
                .any(|step| step.enabled && step.uses_text_locale())
        }) {
            crate::operations::titlecase_locale()
                .map(Some)
                .map_err(|_| {
                    self.host
                        .lang
                        .text(
                            "Die Text-Systemlocale konnte nicht bestimmt werden.",
                            "The system text locale could not be determined.",
                        )
                        .to_string()
                })
        } else {
            Ok(None)
        }
    }
    fn locale_current(&self) -> bool {
        let pending = self.pending.borrow();
        pending.as_ref().is_none_or(|p| {
            self.locale()
                .is_ok_and(|locale| locale.as_ref() == p.workflow_locale())
        })
    }
    fn set_root(&self, path: PathBuf) {
        *self.raw_root.borrow_mut() = Some(path.clone());
        self.setting_root.set(true);
        self.root.set_text(&super::project_view::display(&path));
        self.setting_root.set(false);
        self.invalidate();
        #[cfg(debug_assertions)]
        if self.project.is_none() {
            if let Some(sources) = self.sources.borrow().as_ref() { sources.test_root(path); }
        }
    }
    fn project_current(&self) -> bool {
        self.project.as_ref().is_none_or(|p| p.is_current())
    }
    fn project_stale(&self) {
        self.invalidate();
        self.status.set_text(self.host.lang.text("Projekt geändert oder Wurzel ersetzt. Projekt erneut wählen und Vorschau neu berechnen.","Project changed or root replaced. Select the project again and recalculate the preview."));
    }
    fn work_binding(
        &self,
        cancel: &Cancellation,
    ) -> Result<Option<super::project_view::WorkBinding>, String> {
        let work = self.project.as_ref().map(|p| p.work(cancel)).transpose()?;
        *self.project_work.borrow_mut() = work.clone();
        Ok(work)
    }
    fn set_busy(&self, busy: bool) {
        self.busy.set(busy);
        if !busy { self.reading.set(false); }
        // Lesende Live-Suche darf ein offenes Quellenmenü nicht schließen.
        let sources_locked = busy && !self.reading.get();
        self.cancel_button.set_sensitive(busy);
        if let Some(sources) = self.sources.borrow().as_ref() { sources.set_busy(sources_locked); }
        if !busy {
            self.project_work.borrow_mut().take();
        }
        if let Some(row) = self.root.parent() {
            row.set_sensitive(!busy);
        }
        self.excludes.set_sensitive(!sources_locked && self.files.is_empty());
        self.known_text
            .set_sensitive(!sources_locked && self.files.is_empty());
        let editable =
            !busy && self.pending.borrow().is_some() && self.transaction.borrow().is_none();
        self.pane.freeze(!editable);
        self.search
            .set_sensitive(!busy && self.transaction.borrow().is_none());
    }
    fn invalidate(&self) {
        self.cancel.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
        self.pending.borrow_mut().take();
        if let Some(stages) = &self.stages {
            stages.clear();
        }
        self.apply.set_sensitive(false);
        self.pane.clear();
    }
    fn search(self: &Rc<Self>) {
        if self.busy.get() || self.transaction.borrow().is_some() || !self.visible() {
            return;
        }
        if !self.project_current() {
            self.project_stale();
            return;
        }
        if self.workflow.is_none() {
            super::search_history::remember(&self.host);
        }
        self.invalidate();
        self.reading.set(self.workflow.is_none());
        self.set_busy(true);
        self.search.set_sensitive(false);
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let project = match self.work_binding(&cancel) {
            Ok(value) => value,
            Err(error) => {
                self.set_busy(false);
                self.status.set_text(&format!("{} {error}",self.host.lang.text("Projektauftrag nicht gestartet. Projekt prüfen oder laufende Aufträge abwarten.","Project operation not started. Review the project or wait for active operations.")));
                return;
            }
        };
        let configuration = self.sources.borrow().as_ref().map(|sources|sources.request());
        let configuration = match configuration.transpose() {
            Ok(value) => value,
            Err(error) => { self.set_busy(false); self.status.set_text(&error); return; }
        };
        let selected_paths = configuration.as_ref().and_then(|value|value.paths.clone());
        let request = Request {
            roots: configuration.as_ref().map(|value|value.roots.clone()).unwrap_or_else(||vec![self
                .raw_root
                .borrow()
                .clone()
                .unwrap_or_else(|| PathBuf::from(self.root.text().as_str()))]),
            search: SearchRequest {
                pattern: self.host.find.text().into(),
                replacement: self.host.replace.text().into(),
                mode: match self.host.mode.selected() {
                    1 => SearchMode::Wildcard,
                    2 => SearchMode::Regex,
                    _ => SearchMode::Literal,
                },
                case_sensitive: self.host.case.is_active(),
                range: None,
            },
            flags: fastra_core::SearchFlags {
                whole_word: self.host.whole_word.is_active(),
            },
            exclusions: configuration.map(|value|value.exclusions).unwrap_or_else(||self.excludes.text().split(';').map(str::to_owned).collect()),
            include_hidden: false,
            known_text_only: self.known_text.is_active(),
        };
        let flow = self.workflow.clone();
        let files = self.files.clone();
        let locale = match self.locale() {
            Ok(locale) => locale,
            Err(error) => {
                self.set_busy(false);
                self.status.set_text(&error);
                return;
            }
        };
        let completion_locale = locale.clone();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let result = (|| {
                check_project(project.as_ref(), &cancel)?;
                let result = if let Some(definition) = flow {
                    fastra_search::preview_workflow(
                        &fastra_search::WorkflowRequest {
                            roots: if files.is_empty() {
                                request.roots
                            } else {
                                vec![]
                            },
                            files,
                            exclusions: request.exclusions,
                            known_text_only: request.known_text_only,
                            definition,
                            locale,
                        },
                        generation,
                        &cancel,
                    )?
                } else {
                    fastra_search::preview_selected(&request, selected_paths.as_deref(), generation, &cancel)?
                };
                check_project(project.as_ref(), &cancel)?;
                Ok(result)
            })();
            #[cfg(debug_assertions)]
            readonly_test::delay(&cancel);
            let _ = tx.send(result);
        });
        self.status.set_text(
            self.host
                .lang
                .text("Ordner wird gelesen …", "Reading folder …"),
        );
        self.status.set_visible(self.workflow.is_some());
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(30), move || {
            let Some(state) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            match rx.try_recv() {
                Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
                result => {
                    state.set_busy(false);
                    state.search.set_sensitive(true);
                    if !state.visible() {
                        state.close_hidden();
                        return glib::ControlFlow::Break;
                    }
                    if !state.project_current() {
                        state.project_stale();
                        return glib::ControlFlow::Break;
                    }
                    if !state.visible() {
                        state.close_hidden();
                        return glib::ControlFlow::Break;
                    }
                    if generation != state.generation.get() {
                        return glib::ControlFlow::Break;
                    }
                    if state.locale().as_ref().ok() != Some(&completion_locale) {
                        state.invalidate();
                        state.status.set_text(state.host.lang.text(
                            "Die Text-Systemlocale hat sich geändert. Vorschau neu berechnen.",
                            "The system text locale changed. Recalculate the preview.",
                        ));
                        return glib::ControlFlow::Break;
                    }
                    match result {
                        Ok(Ok(preview)) => {
                            if state.workflow.is_some() {
                                let paths =
                                    preview.files().iter().map(|file| file.path()).collect();
                                if state.overlaps_dirty(&paths, &std::collections::HashSet::new()) {
                                    state.status.set_text(state.host.lang.text("Betroffene offene Dateien zuerst speichern oder schließen. Keine anwendbare Dateivorschau erzeugt.","Save or close affected open files first. No applicable file preview was created."));
                                    state.set_busy(false);
                                    return glib::ControlFlow::Break;
                                }
                            }
                            let items = preview
                                .files()
                                .iter()
                                .map(|file| super::approval::Item {
                                    label: format!(
                                        "{}{}",
                                        project_view::display(&file.path()),
                                        preview.workflow_locale().map_or_else(
                                            String::new,
                                            |locale| format!(
                                                " · {}: {}",
                                                state.host.lang.text(
                                                    "Text-Systemlocale",
                                                    "System text locale"
                                                ),
                                                locale.as_str()
                                            )
                                        )
                                    ),
                                    preview: file.shared_preview(),
                                })
                                .collect();
                            let skipped = preview
                                .skipped()
                                .iter()
                                .take(30)
                                .map(|s| {
                                    format!(
                                        "{}: {}",
                                        project_view::display(&s.path),
                                        skip_reason(state.host.lang, s.reason)
                                    )
                                })
                                .collect::<Vec<_>>()
                                .join("\n");
                            let locale_text =
                                preview
                                    .workflow_locale()
                                    .map_or_else(String::new, |locale| {
                                        format!(
                                            " · {}: {}",
                                            state
                                                .host
                                                .lang
                                                .text("Text-Systemlocale", "System text locale"),
                                            locale.as_str()
                                        )
                                    });
                            let summary = if state.workflow.is_some() {
                                format!(
                                    "{} {} · {} {}{}",
                                    state
                                        .host
                                        .lang
                                        .text("Vollständige Dateien:", "Complete files:"),
                                    preview.files().len(),
                                    state.host.lang.text("Übersprungen:", "Skipped:"),
                                    preview.skipped().len(),
                                    locale_text
                                )
                            } else {
                                format!(
                                    "{} {} · {} {}",
                                    preview.matches(),
                                    state.host.lang.text("Treffer", "matches"),
                                    preview.skipped().len(),
                                    state.host.lang.text("übersprungen", "skipped")
                                )
                            };
                            state.status.set_text(&format!("{summary}\n{skipped}"));
                            state.status.set_visible(state.workflow.is_some() || !preview.skipped().is_empty());
                            let preview = Arc::new(preview);
                            if let Some(stages) = &state.stages {
                                stages.set(preview.clone());
                            }
                            *state.pending.borrow_mut() = Some(preview);
                            state.pane.set_items(items);
                            state.set_busy(false);
                        }
                        Ok(Err(error)) => state.error(&error),
                        Err(_) => state.status.set_text("Search worker stopped"),
                    };
                    glib::ControlFlow::Break
                }
            }
        });
    }
    fn error(&self, error: &fastra_search::Error) {
        if let fastra_search::Error::File(fastra_io::Error::RecoveryRequired(path)) = error {
            if let Err(error) = session::remember_journal(&self.host, path.clone()) {
                self.host.status.set_text(&format!(
                    "{} {error}",
                    self.host.lang.text(
                        "Dateitransaktionsindex nicht gesichert:",
                        "File transaction index not saved:"
                    )
                ));
            }
        }
        use fastra_search::Error;
        let lang = self.host.lang;
        let message=match error {
            Error::File(error)=>io_error_text(lang,error),
            Error::Core(error)=>error_text(lang,error),
            Error::Stale=>lang.text("Die Ordnerbasis wurde geändert. Bitte eine neue Vorschau erstellen; kein Apply ausgeführt.","The folder basis changed. Create a new preview; Apply was not performed.").into(),
            Error::Limit=>lang.text("Die Ordnersuche überschreitet eine angezeigte Zeit-, Mengen- oder Speichergrenze. Keine teilweise anwendbare Vorschau erzeugt.","The folder search exceeds a displayed time, count or memory limit. No partially applicable preview was produced.").into(),
            Error::InvalidRoots=>lang.text("Bitte einen lesbaren absoluten Ordnerpfad wählen.","Choose a readable absolute folder path.").into(),
            Error::InvalidApproval=>lang.text("Die Freigaben passen nicht zur Vorschau. Bitte neu berechnen.","Approvals do not match the preview. Recalculate it.").into(),
            Error::Workflow{path,error}=>format!("{} {}: {}",lang.text("Dateiauftrag vollständig abgelehnt:","Complete file workflow refused:"),project_view::display(path),crate::workflow_view::message(error,lang)),
            Error::Encoding{path,error}=>format!("{} {}: {}{}",lang.text("Dateiauftrag vollständig abgelehnt:","Complete file workflow refused:"),project_view::display(path),lang.text("Das Ergebnis ist in der ursprünglichen Dateikodierung nicht darstellbar. Keine Datei geändert.","The result cannot be represented in the original file encoding. No file changed."),match error{fastra_core::encoding::EncodingError::Unrepresentable(c)=>format!(" (U+{:04X})",*c as u32),_=>String::new()}),
            Error::WorkflowInput{path,message}=>format!("{} {}: {}",lang.text("Dateiauftrag vollständig abgelehnt:","Complete file workflow refused:"),project_view::display(path),match message.as_str(){"DuplicateInput"=>lang.text("Dieselbe Datei wurde mehrfach ausgewählt.","The same file was selected more than once."),"NotWritable"=>lang.text("Die Datei oder ihr Ordner ist nicht schreibbar.","The file or its directory is not writable."),"Binary"=>lang.text("Binärdaten oder nicht verlustfrei dekodierbar.","Binary data or not losslessly decodable."),"TooLarge"=>lang.text("Die Datei überschreitet die Größenbegrenzung.","The file exceeds the size limit."),"LongLine"|"NUL/long line"=>lang.text("NUL-Zeichen oder eine Zeile überschreitet die Anzeigegrenze.","NUL character or a line exceeds the display limit."),"LinkOrSpecial"|"not a regular file"=>lang.text("Verweise und besondere Dateien sind nicht zugelassen.","Links and special files are not allowed."),"UnsupportedFile"=>lang.text("Die Metadaten können nicht sicher erhalten werden.","Metadata cannot be preserved safely."),"NonUnicodePath"=>lang.text("Nicht-UTF-8-Pfad bei aktiven Ausschlussregeln.","Non-UTF-8 path with active exclusion rules."),_=>message}),
            Error::Io(error)=>format!("{} {error}",lang.text("Der Ordner konnte nicht vollständig gelesen werden.","The folder could not be read completely.")),
        };
        self.status.set_text(&message);
    }
    fn overlaps_dirty(
        &self,
        paths: &std::collections::HashSet<PathBuf>,
        readonly_paths: &std::collections::HashSet<PathBuf>,
    ) -> bool {
        self.host.documents.borrow().iter().any(|doc| {
            doc.disk_path().is_some_and(|path| {
                (readonly_paths.contains(&path) && doc.is_read_only())
                    || (paths.contains(&path)
                        && (doc.buffer.is_modified()
                            || doc.saving.get()
                            || doc.is_rich_active()
                            || doc
                                .hex_editor
                                .borrow()
                                .as_ref()
                                .is_some_and(|hex| hex.dirty())))
            })
        })
    }
    fn apply(self: &Rc<Self>) {
        if !super::git_pull::write_allowed(&self.host) {self.status.set_text(&self.host.status.text());return;}
        if !self.project_current() {
            self.project_stale();
            return;
        }
        if self.busy.get() || self.transaction.borrow().is_some() || !self.pane.root.is_mapped() {
            return;
        }
        if !self.locale_current() {
            self.invalidate();
            self.status.set_text(self.host.lang.text(
                "Die Text-Systemlocale hat sich geändert. Vorschau neu berechnen.",
                "The system text locale changed. Recalculate the preview.",
            ));
            return;
        }
        let Some(preview) = self.pending.borrow().clone() else {
            return;
        };
        let Some(approvals) = self.pane.approvals() else {
            return;
        };
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.set_busy(true);
        self.apply.set_sensitive(false);
        self.search.set_sensitive(false);
        let planning_project = match self.work_binding(&cancel) {
            Ok(value) => value,
            Err(error) => {
                self.set_busy(false);
                self.status.set_text(&format!("{} {error}",self.host.lang.text("Projektauftrag nicht gestartet. Projekt prüfen oder laufende Aufträge abwarten.","Project operation not started. Review the project or wait for active operations.")));
                return;
            }
        };
        let planning = preview.clone();
        let planning_cancel = cancel.clone();
        let planning_approvals = approvals.clone();
        let weak = Rc::downgrade(self);
        let lang = self.host.lang;
        git_view::background(
            move || {
                if let Err(error) = check_project(planning_project.as_ref(), &planning_cancel) {
                    return Ok(Err(error));
                }
                #[cfg(debug_assertions)]
                if std::env::var_os("FASTRA_FOLDER_PARENT_HIDE_DELAY").is_some() {
                    std::thread::sleep(Duration::from_millis(250));
                }
                let paths =
                    match planning.changed_paths(generation, &planning_approvals, &planning_cancel)
                    {
                        Ok(paths) => paths,
                        Err(error) => return Ok(Err(error)),
                    };
                for (file, indices) in planning.files().iter().zip(&planning_approvals) {
                    let output = match file.after(indices, &planning_cancel) {
                        Ok(text) => text,
                        Err(error) => return Ok(Err(error)),
                    };
                    crate::text_limits::validate(&output, lang)?;
                }
                if let Err(error) = check_project(planning_project.as_ref(), &planning_cancel) {
                    return Ok(Err(error));
                }
                Ok(Ok(paths))
            },
            move |result| {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                if !state.visible() {
                    state.close_hidden();
                    return;
                }
                if !state.project_current() {
                    state.set_busy(false);
                    state.project_stale();
                    return;
                }
                if generation != state.generation.get()
                    || state.cancel.borrow().check().is_err()
                    || !state.visible()
                {
                    state.set_busy(false);
                    return;
                }
                let result = match result {
                    Ok(value) => value,
                    Err(error) => {
                        state.set_busy(false);
                        state.status.set_text(&error);
                        return;
                    }
                };
                match result {
                    Ok(paths) => {
                        let paths: std::collections::HashSet<_> = paths.into_iter().collect();
                        let guarded = if state.workflow.is_some() {
                            preview.files().iter().map(|file| file.path()).collect()
                        } else {
                            paths.clone()
                        };
                        if !state.locale_current() {
                            state.set_busy(false);
                            state.invalidate();
                            state.status.set_text(state.host.lang.text(
                                "Die Text-Systemlocale hat sich geändert. Vorschau neu berechnen.",
                                "The system text locale changed. Recalculate the preview.",
                            ));
                            return;
                        }
                        if state.overlaps_dirty(&guarded, &paths) {
                            state.set_busy(false);
                            state.status.set_text(state.host.lang.text("Betroffene offene Dateien zuerst speichern; ungesicherte Editoränderungen werden nicht überschrieben.","Save affected open files first; unsaved editor changes will not be overwritten."));
                            return;
                        }
                        *state.transaction_paths.borrow_mut() = paths;
                        state.apply_ready(preview, approvals, generation, cancel);
                    }
                    Err(error) => {
                        state.set_busy(false);
                        state.error(&error);
                    }
                }
            },
        );
    }
    fn apply_ready(
        self: &Rc<Self>,
        preview: Arc<FolderPreview>,
        approvals: Vec<Vec<usize>>,
        generation: u64,
        cancel: Cancellation,
    ) {
        if !self.visible() {
            self.close_hidden();
            return;
        }
        if !self.project_current() {
            self.set_busy(false);
            self.project_stale();
            return;
        }
        if generation != self.generation.get() || cancel.check().is_err() {
            self.set_busy(false);
            self.invalidate();
            return;
        }
        let changed_paths = self.transaction_paths.borrow().clone();
        let (tx, rx) = mpsc::channel();
        let project = match self.work_binding(&cancel) {
            Ok(value) => value,
            Err(error) => {
                self.set_busy(false);
                self.status.set_text(&format!("{} {error}",self.host.lang.text("Projektauftrag nicht gestartet. Projekt prüfen oder laufende Aufträge abwarten.","Project operation not started. Review the project or wait for active operations.")));
                return;
            }
        };
        std::thread::spawn(move || {
            let result = (|| {
                check_project(project.as_ref(), &cancel)?;
                preview.apply(generation, &approvals, &cancel)
            })()
            .map(|tx| {
                let snapshots = match tx.as_ref() {
                    Some(transaction) => transaction
                        .applied_snapshots(&cancel)
                        .map(|snapshots| {
                            snapshots
                                .into_iter()
                                .filter(|snapshot| changed_paths.contains(&snapshot.path()))
                                .collect()
                        })
                        .map_err(fastra_search::Error::File),
                    None => Ok(vec![]),
                };
                (tx, snapshots)
            });
            #[cfg(debug_assertions)] test_quit_pause("apply");
            let _ = tx.send(result);
        });
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(30), move || {
            let Some(state) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            match rx.try_recv() {
                Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
                result => {
                    state.set_busy(false);
                    match result {
                        Ok(Ok((transaction, snapshots))) => {
                            if let Some(tx) = transaction.as_ref() {
                                if let Err(error) =
                                    session::remember_journal(&state.host, tx.path().to_owned())
                                {
                                    state.host.status.set_text(&format!(
                                        "{} {error}",
                                        state.host.lang.text(
                                            "Dateitransaktionsindex nicht gesichert:",
                                            "File transaction index not saved:"
                                        )
                                    ));
                                }
                            }
                            let changed = transaction.is_some();
                            let journal = transaction
                                .as_ref()
                                .map(|t| super::project_view::display(t.path()));
                            *state.transaction.borrow_mut() = transaction;
                            if state.transaction.borrow().is_none() {
                                state.transaction_paths.borrow_mut().clear();
                            }
                            state
                                .undo
                                .set_sensitive(state.transaction.borrow().is_some());
                            match snapshots {
                                Ok(snapshots) => state.refresh(snapshots),
                                Err(error) => {
                                    state.error(&error);
                                    state.pending.borrow_mut().take();
                                    return glib::ControlFlow::Break;
                                }
                            }
                            state.status.set_text(&if changed {format!("{}{}",state.host.lang.text("Dateien geändert. Rückgängig bleibt verfügbar. Sicherung: ","Files changed. Undo remains available. Recovery: "),journal.unwrap_or_default())}else{state.host.lang.text("Keine wirksame Ersetzung; keine Datei geschrieben.","No effective replacement; no file written.").into()});
                            state
                                .search
                                .set_sensitive(state.transaction.borrow().is_none());
                            state.pending.borrow_mut().take();
                            state.set_busy(false);
                        }
                        Ok(Err(error)) => {
                            state.error(&error);
                            state.search.set_sensitive(true)
                        }
                        Err(_) => state.status.set_text("Apply worker stopped"),
                    };
                    if !state.host.window.is_visible() {
                        if let Some(window) = state.window.upgrade() {
                            window.close();
                        }
                    }
                    glib::ControlFlow::Break
                }
            }
        });
    }
    fn refresh(&self, snapshots: Vec<fastra_io::Snapshot>) {
        self.host.refresh_clean_documents(snapshots);
    }
    fn undo(self: &Rc<Self>) {
        if !super::git_pull::write_allowed(&self.host) {self.status.set_text(&self.host.status.text());return;}
        if !self.visible() {
            return;
        }
        if self.busy.get() {
            return;
        }
        let Some(mut transaction) = self.transaction.borrow_mut().take() else {
            return;
        };
        // Neue Editoränderungen dürfen bei einem Platten-Undo nicht verloren gehen.
        if self.host.documents.borrow().iter().any(|d| {
            d.disk_path()
                .is_some_and(|path| self.transaction_paths.borrow().contains(&path))
                && (d.is_read_only()
                    || d.buffer.is_modified()
                    || d.saving.get()
                    || d.is_rich_active()
                    || d.hex_editor
                        .borrow()
                        .as_ref()
                        .is_some_and(|hex| hex.dirty()))
        }) {
            *self.transaction.borrow_mut() = Some(transaction);
            self.status.set_text(self.host.lang.text(
                "Offene Änderungen zuerst speichern.",
                "Save open changes first.",
            ));
            return;
        }
        self.set_busy(true);
        self.undo.set_sensitive(false);
        let changed_paths = self.transaction_paths.borrow().clone();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            #[cfg(debug_assertions)]
            if std::env::var_os("FASTRA_FOLDER_UNDO_HIDE_DELAY").is_some() {
                std::thread::sleep(Duration::from_millis(250));
            }
            let result = transaction
                .undo(&cancel)
                .and_then(|_| transaction.restored_snapshots(&cancel))
                .map(|snapshots| {
                    snapshots
                        .into_iter()
                        .filter(|snapshot| changed_paths.contains(&snapshot.path()))
                        .collect()
                });
            #[cfg(debug_assertions)] test_quit_pause("undo");
            let _ = tx.send((transaction, result));
        });
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(30), move || {
            let Some(state) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            match rx.try_recv() {
                Err(mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
                Ok((transaction, result)) => {
                    state.set_busy(false);
                    match result {
                        Ok(snapshots) => {
                            state.transaction_paths.borrow_mut().clear();
                            state.refresh(snapshots);
                            state.pane.clear();
                            state.status.set_text(state.host.lang.text("Dateien wiederhergestellt. Die Sicherung bleibt für die Wiederaufnahme erhalten.","Files restored. Recovery data is retained."));
                            state.search.set_sensitive(true);
                        }
                        Err(error) => {
                            state
                                .status
                                .set_text(&io_error_text(state.host.lang, &error));
                            state.undo.set_sensitive(true);
                            *state.transaction.borrow_mut() = Some(transaction);
                            state.set_busy(false);
                        }
                    }
                    if !state.host.window.is_visible() {
                        if let Some(window) = state.window.upgrade() {
                            window.close();
                        }
                    }
                    glib::ControlFlow::Break
                }
                Err(_) => {
                    state.set_busy(false);
                    if !state.host.window.is_visible() {
                        if let Some(window) = state.window.upgrade() {
                            window.close();
                        }
                    }
                    state.status.set_text("Undo worker stopped");
                    glib::ControlFlow::Break
                }
            }
        });
    }
}
fn skip_reason(lang: Language, reason: fastra_search::SkipReason) -> &'static str {
    use fastra_search::SkipReason::*;
    match reason {
        LinkOrSpecial => lang.text("Verweis oder besondere Datei", "Link or special file"),
        Binary => lang.text(
            "Binärdaten oder nicht dekodierbar",
            "Binary or undecodable data",
        ),
        TooLarge => lang.text("Dateigrenze überschritten", "File size limit exceeded"),
        LongLine => lang.text("Zeilengrenze überschritten", "Line length limit exceeded"),
        NonUnicodePath => lang.text(
            "Nicht-UTF-8-Pfad mit aktiven Ausschlussregeln; ohne diese Regeln durchsuchbar",
            "Non-UTF-8 path with active exclusion rules; searchable without these rules",
        ),
        UnsupportedFile => lang.text(
            "Metadaten nicht sicher erhaltbar",
            "Metadata cannot be preserved safely",
        ),
    }
}
pub fn open(host: &Rc<Ui>) {
    open_inner(host, None);
}
pub(super) fn open_project(host: &Rc<Ui>, binding: super::project_view::Binding) {
    open_inner(host, Some(binding));
}
pub(super) fn open_workflow(host: &Rc<Ui>, definition: fastra_workflow::Workflow, scope: u8) {
    let project = if scope == 2 {
        project_view::current_binding(host)
    } else {
        None
    };
    if scope == 2 && project.is_none() {
        host.status.set_text(host.lang.text(
            "Zuerst eine Projektwurzel wählen.",
            "Choose a project root first.",
        ));
        return;
    }
    let files = if scope == 0 {
        let Some(doc) = host.active() else {
            return;
        };
        let Some(path) = doc.disk_path() else {
            host.status.set_text(
                host.lang
                    .text("Die Datei zuerst speichern.", "Save the file first."),
            );
            return;
        };
        vec![path]
    } else {
        vec![]
    };
    open_mode(host, project, Some(definition), files);
}
fn open_inner(host: &Rc<Ui>, project: Option<super::project_view::Binding>) -> Rc<FolderWindow> {
    open_mode(host, project, None, vec![])
}
fn open_mode(
    host: &Rc<Ui>,
    project: Option<super::project_view::Binding>,
    workflow: Option<fastra_workflow::Workflow>,
    files: Vec<PathBuf>,
) -> Rc<FolderWindow> {
    let lang = host.lang;
    let width = 1000;
    #[cfg(debug_assertions)]
    let width = std::env::var("FASTRA_FOLDER_WIDTH")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(width);
    let title = if workflow.is_some() {
        lang.text(
            "Textablauf · Dateien prüfen und ändern",
            "Text workflow · Review and change files",
        )
    } else if project.is_some() {
        lang.text(
            "Projekt · Vorschau und Ersetzen",
            "Project · Preview and Replace",
        )
    } else {
        lang.text(
            "Ordner · Vorschau und Ersetzen",
            "Folder · Preview and Replace",
        )
    };
    let window = gtk::Window::builder()
        .title(title)
        .transient_for(&host.window)
        .modal(true)
        .default_width(width)
        .default_height(850)
        .build();
    window.set_destroy_with_parent(true);
    if let Some(application) = host.window.application() {
        window.set_application(Some(&application));
    }
    let header = gtk::HeaderBar::new();
    header.set_show_title_buttons(true);
    header.set_title_widget(Some(&gtk::Label::new(Some(title))));
    window.set_titlebar(Some(&header));
    let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
    root.set_margin_top(12);
    root.set_margin_bottom(12);
    root.set_margin_start(12);
    root.set_margin_end(12);
    let folder = gtk::Entry::builder()
        .hexpand(true)
        .placeholder_text(lang.text("Absoluter Ordnerpfad", "Absolute folder path"))
        .build();
    let choose = gtk::Button::with_label(lang.text("Ordner wählen …", "Choose folder …"));
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    row.append(&folder);
    row.append(&choose);
    root.append(&row);
    let summary = gtk::Label::new(Some(&format!(
        "{} {} → {}",
        lang.text("Aktuelles Suchmuster:", "Current search pattern:"),
        host.find.text(),
        host.replace.text()
    )));
    if let Some(definition) = &workflow {
        summary.set_text(&format!(
            "{}: {} · {}",
            lang.text("Unveränderliche Ablaufkopie", "Immutable workflow copy"),
            definition.name,
            lang.text(
                "Nur nach vollständiger Vorschau und Freigabe. Fehler sperren alle Dateien.",
                "Only after complete preview and approval. Errors block every file."
            )
        ));
    }
    summary.set_wrap(true);
    root.append(&summary);
    if let Some(definition) = &workflow {
        let expander = gtk::Expander::new(Some(
            lang.text("Verwendete Definition prüfen", "Review the definition used"),
        ));
        let details = git_view::output();
        let yes = |value| {
            if value {
                lang.text("ja", "yes")
            } else {
                lang.text("nein", "no")
            }
        };
        let text=definition.steps.iter().enumerate().map(|(i,step)|format!("{}. {} · {}\n{}: {:?} → {:?}\n{}: {:?}\nRegex: {} · {}: {} · {}: {} · {}: {}\n{}: {} · {}: {} · {}: {} · {}: {}\n\n",i+1,crate::workflow_view::title(&step.kind,lang),if step.enabled{lang.text("aktiv","enabled")}else{lang.text("ausgelassen","disabled")},lang.text("Ersetzen","Replace"),step.find,step.replacement,lang.text("Argument","Argument"),step.argument,yes(step.regex),lang.text("Groß-/Kleinschreibung","Case-sensitive"),yes(step.case_sensitive),lang.text("Ganze Wörter","Whole words"),yes(step.whole_word),lang.text("Wörtliche Platzhalterersetzung","Literal wildcard replacement"),yes(step.literal_wildcard),lang.text("Tabulatorbreite","Tab width"),step.tab_width,lang.text("Einrückungsbreite","Indent width"),step.indent_width,lang.text("Tabs verwenden","Use tabs"),yes(step.uses_tabs),lang.text("Umbruchspalte","Wrap column"),step.wrap_column)).collect::<String>();
        details.buffer().set_text(&text);
        let scroll = git_view::scroll(&details);
        scroll.set_min_content_height(80);
        scroll.set_max_content_height(140);
        scroll.set_vexpand(false);
        expander.set_child(Some(&scroll));
        root.append(&expander);
    }
    let excludes = gtk::Entry::builder()
        .placeholder_text(lang.text(
            "Ausschlüsse mit ; trennen, z. B. .json; build/**",
            "Separate exclusions with ; e.g. .json; build/**",
        ))
        .build();
    root.append(&excludes);
    let known_text = gtk::CheckButton::with_label(
        lang.text("Nur bekannte Textformate", "Known text formats only"),
    );
    known_text.set_active(true);
    root.append(&known_text);
    let controls = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(4)
        .column_spacing(8)
        .row_spacing(4)
        .build();
    let search = gtk::Button::with_label(lang.text("Vorschau erstellen", "Create preview"));
    let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    cancel.set_sensitive(false);
    let apply = gtk::Button::with_label(lang.text(
        "Freigegebene Treffer in Dateien anwenden",
        "Apply approved matches to files",
    ));
    if workflow.is_some() {
        apply.set_label(lang.text("Freigegebene Dateien ändern", "Change approved files"));
    }
    apply.set_sensitive(false);
    let undo =
        gtk::Button::with_label(lang.text("Dateiänderungen rückgängig", "Undo file changes"));
    undo.set_sensitive(false);
    for b in [&search, &cancel, &apply, &undo] {
        controls.insert(b, -1)
    }
    root.append(&controls);
    let status=gtk::Label::new(Some(lang.text("Versteckte Dateien werden ausgelassen. Grenzen: 4 MiB/Datei, 64 KiB/Zeile, 10.000 Treffer, 128 MiB Vorschau. Übersprungene Eingaben werden aufgelistet.","Hidden files are skipped. Limits: 4 MiB/file, 64 KiB/line, 10,000 matches, 128 MiB preview. Skipped inputs are listed.")));
    if workflow.is_some() {
        status.set_text(lang.text("Vollständiger Dateiauftrag: höchstens 32 Dateien, 4 MiB je Datei, je 16 MiB Eingaben/Ausgaben und 32 MiB Zwischenstufen. Fehler sperren den gesamten Auftrag.","Complete file workflow: at most 32 files, 4 MiB per file, 16 MiB sources/outputs each and 32 MiB intermediate stages. Errors block the whole job."));
    }
    status.set_wrap(true);
    status.set_xalign(0.);
    status.set_selectable(true);
    let status_scroll = gtk::ScrolledWindow::builder()
        .max_content_height(100)
        .propagate_natural_height(true)
        .child(&status)
        .build();
    root.append(&status_scroll);
    let pane = super::approval::ApprovalPane::new(lang);
    let stages = workflow.as_ref().map(|_| workflow::Stages::new(lang));
    if let Some(stages) = &stages {
        let notebook = gtk::Notebook::new();
        notebook.set_vexpand(true);
        notebook.append_page(
            &pane.root,
            Some(&gtk::Label::new(Some(lang.text(
                "Endergebnisse und Freigaben",
                "Final results and approvals",
            )))),
        );
        notebook.append_page(
            &stages.root,
            Some(&gtk::Label::new(Some(lang.text(
                "Vollständige Zwischenstufen",
                "Complete intermediate stages",
            )))),
        );
        root.append(&notebook);
    } else {
        root.append(&pane.root);
    }
    window.set_child(Some(&root));
    let state = Rc::new(FolderWindow {
        host: host.clone(),
        workflow,
        files,
        stages,
        window: window.downgrade(),
        root: folder,
        raw_root: RefCell::new(None),
        setting_root: Cell::new(false),
        project,
        project_work: RefCell::new(None),
        excludes,
        known_text,
        sources: RefCell::new(None),
        status,
        pane,
        apply,
        undo,
        search,
        cancel_button: cancel.clone(),
        generation: Cell::new(1),
        busy: Cell::new(false),
        reading: Cell::new(false),
        cancel: RefCell::new(Cancellation::default()),
        pending: RefCell::new(None),
        transaction: RefCell::new(None),
        transaction_paths: RefCell::new(std::collections::HashSet::new()),
        parent_handler: RefCell::new(None),
    });
    if state.workflow.is_none() {
        let weak = Rc::downgrade(&state);
        *state.pane.on_navigate.borrow_mut() = Some(Rc::new(move |navigation| {
            let Some(state) = weak.upgrade() else { return; };
            let preview = state.pending.borrow().clone();
            let Some(preview) = preview else {
                return;
            };
            let Some(file) = preview
                .files()
                .get(navigation.item)
                .filter(|file| Arc::ptr_eq(&file.shared_preview(), &navigation.preview))
            else {
                return;
            };
            if !navigation.explicit {
                return;
            }
            let project = match state
                .project
                .as_ref()
                .map(|binding| binding.work(&navigation.cancel))
                .transpose()
            {
                Ok(project) => project,
                Err(_) => {
                    (navigation.report)(state.host.lang.text("Projektbindung geändert. Suche neu berechnen; kein Quellsprung ausgeführt.", "Project binding changed. Recalculate the search; no source jump was made."));
                    return;
                }
            };
            match file.snapshot_binding() {
                Ok(binding) => {
                    search_navigation::disk(&state.host, file.path(), binding, navigation, project)
                }
                Err(error) => (navigation.report)(&io_error_text(state.host.lang, &error)),
            }
        }));
    }
    WINDOWS.with(|windows| {
        let mut windows = windows.borrow_mut();
        windows.retain(|state| state.upgrade().is_some());
        windows.push(Rc::downgrade(&state));
    });
    let weak = Rc::downgrade(&state);
    let id = host.window.connect_visible_notify(move |parent| {
        if !parent.is_visible() {
            if let Some(state) = weak.upgrade() {
                state.cancel.borrow().cancel();
                state.invalidate();
                if let Some(window) = state.window.upgrade() {
                    window.set_visible(false);
                    if !state.busy.get() {
                        window.close();
                    }
                }
            }
        }
    });
    *state.parent_handler.borrow_mut() = Some(id);
    if state.workflow.is_none() && state.files.is_empty() {
        let saved = if let Some(project) = state.project.as_ref() {
            state
                .host
                .project_configuration
                .borrow()
                .as_ref()
                .filter(|(owner, _)| *owner == project.owner_id())
                .map(|(_, value)| value.clone())
        } else {
            state.host.folder_configuration.borrow().clone()
        };
        if let Some(saved) = saved {
            *state.raw_root.borrow_mut() = saved.path;
            state.root.set_text(&saved.text);
            state.excludes.set_text(&saved.exclusions);
            state.known_text.set_active(saved.known_text);
        }
    }
    if !state.files.is_empty() {
        state.excludes.set_sensitive(false);
        state.known_text.set_sensitive(false);
        state.set_root(state.files[0].clone());
        state.root.set_editable(false);
        choose.set_sensitive(false);
    }
    if let Some(project) = &state.project {
        state.set_root(project.root.path.clone());
        state.root.set_editable(false);
        state.root.set_tooltip_text(Some(lang.text("Gebundene Projektwurzel. Zum Wechseln dieses Fenster schließen und im Projektbaum wählen.","Bound project root. To change it, close this window and choose in the project tree.")));
        choose.set_sensitive(false);
    }
    let weak = Rc::downgrade(&state);
    state.root.connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            if !s.setting_root.get() {
                s.raw_root.borrow_mut().take();
                s.inputs_changed();
            }
        }
    });
    let weak = Rc::downgrade(&state);
    state.excludes.connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            s.inputs_changed();
        }
    });
    let weak = Rc::downgrade(&state);
    state.known_text.connect_toggled(move |_| {
        if let Some(s) = weak.upgrade() {
            s.inputs_changed();
        }
    });
    let weak = Rc::downgrade(&state);
    state.search.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.search();
        }
    });
    let weak = Rc::downgrade(&state);
    state.apply.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.apply();
        }
    });
    let weak = Rc::downgrade(&state);
    state.undo.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.undo();
        }
    });
    let weak = Rc::downgrade(&state);
    cancel.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.cancel.borrow().cancel();
        }
    });
    let weak = Rc::downgrade(&state);
    state.pane.on_changed(Rc::new(move |valid| {
        if let Some(state) = weak.upgrade() {
            state.apply.set_sensitive(
                valid
                    && state.pane.has_approvals()
                    && !state.busy.get()
                    && state.transaction.borrow().is_none()
                    && state.pending.borrow().is_some()
                    && state.locale_current()
                    && state.pane.root.is_mapped(),
            );
        }
    }));
    let weak = Rc::downgrade(&state);
    state.pane.root.connect_map(move |_| {
        if let Some(state) = weak.upgrade() {
            state.set_busy(state.busy.get());
        }
    });
    let weak = Rc::downgrade(&state);
    state.pane.root.connect_unmap(move |_| {
        if let Some(state) = weak.upgrade() {
            state.apply.set_sensitive(false);
        }
    });
    let weak = Rc::downgrade(&state);
    choose.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            let dialog = gtk::FileDialog::new();
            let weak = Rc::downgrade(&s);
            dialog.select_folder(
                s.window.upgrade().as_ref(),
                None::<&gio::Cancellable>,
                move |result| {
                    if let (Some(s), Ok(file)) = (weak.upgrade(), result) {
                        if s.busy.get() {
                            return;
                        }
                        if let Some(path) = file.path() {
                            if s.window.upgrade().is_some_and(|w| w.is_visible())
                                && s.host.window.is_visible()
                            {
                                s.set_root(path);
                                s.inputs_changed();
                            }
                        }
                    }
                },
            );
        }
    });
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_FOLDER_SELFTEST").is_some() {
        run_selftest(state.clone());
    }
    if state.workflow.is_some() {
        let weak = Rc::downgrade(&state);
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let Some(state) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if !state.busy.get() && !state.locale_current() {
                state.invalidate();
                state.status.set_text(state.host.lang.text(
                    "Die Text-Systemlocale hat sich geändert. Vorschau neu berechnen.",
                    "The system text locale changed. Recalculate the preview.",
                ));
            }
            glib::ControlFlow::Continue
        });
    }
    let close_state = RefCell::new(Some(state.clone()));
    window.connect_close_request(move |_| {
        let Some(state) = close_state.borrow().clone() else {
            return glib::Propagation::Proceed;
        };
        if state.sources.borrow().as_ref().is_some_and(|s|s.busy()) {
            state.status.set_text(state.host.lang.text("Suchquellen werden geladen oder gespeichert. Danach erneut schließen.", "Search sources are loading or saving. Close again afterwards."));return glib::Propagation::Stop;
        }
        if state.busy.get() && !state.reading.get() {
            state.status.set_text(state.host.lang.text(
                "Vorgang läuft; zuerst abbrechen und Ergebnis abwarten.",
                "Operation running; cancel and wait for the result first.",
            ));
            return glib::Propagation::Stop;
        }
        state.remember_configuration();
        state.invalidate();
        close_state.borrow_mut().take();
        glib::Propagation::Proceed
    });
    if state.workflow.is_none() {
        let weak = Rc::downgrade(&state);
        let changed = Rc::new(move || {
            if let Some(state) = weak.upgrade() {
                state.inputs_changed();
            }
        });
        state.search.set_label(lang.text("Suchen", "Find"));
        state.apply.set_label(lang.text("Freigegebene übernehmen", "Apply approved"));
        state.undo.set_label(lang.text("Rückgängig", "Undo"));
        for widget in [row.clone().upcast::<gtk::Widget>(), state.excludes.clone().upcast(), state.known_text.clone().upcast()] {
            if let Some(parent) = widget.parent().and_downcast::<gtk::Box>() { parent.remove(&widget); }
        }
        let weak = Rc::downgrade(&state);
        let source_changed = Rc::new(move || { if let Some(state) = weak.upgrade() { state.inputs_changed(); } });
        let sources = search_sources::Controls::new(host, &window, state.project.as_ref().map(|p|p.root.path.clone()), &state.excludes, &state.known_text, source_changed);
        *state.sources.borrow_mut() = Some(sources.clone());
        let header = sources.header(&chrome::search::scopes(host, &window, 3));
        super::chrome::search::collection(host, super::chrome::search::Collection {
            window: &window, selected: if state.project.is_some() { 3 } else { 2 }, root: &root,
            pane: &state.pane, status: &state.status, actions: &[&state.search, &cancel, &state.undo, &state.apply],
            extras: &[sources.root.clone().upcast()], header: header.as_ref(), changed });
    }
    let weak = Rc::downgrade(&state);
    window.connect_map(move |_| {
        if let Some(state) = weak.upgrade() {
            state.inputs_changed();
        }
    });
    window.present();
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_WORKFLOW_DISK_SELFTEST").is_some() {
        workflow::gui_test(state.clone());
    }
    state
}

#[cfg(debug_assertions)]
fn run_selftest(state: Rc<FolderWindow>) {
    assert_eq!(
        std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(),
        Ok("1"),
        "Folder tests require a private display"
    );
    let base = std::env::var_os("FASTRA_UI_TEST_ROOT").expect("Isolated filesystem test root");
    let dir = PathBuf::from(base).join(format!(
        "folder-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&dir).unwrap();
    std::fs::create_dir(dir.join("sub")).unwrap();
    let a = dir.join("a.txt");
    let b = dir.join("sub/b.txt");
    let none = dir.join("none.txt");
    let original = b"\xef\xbb\xbfcat cat\r\n";
    std::fs::write(&a, original).unwrap();
    std::fs::write(&b, [0xff, 0xfe, b'c', 0, b'a', 0, b't', 0]).unwrap();
    std::fs::write(&none, "none").unwrap();
    state.host.add_document("a.txt", "cat cat\r\n");
    let doc = state.host.active().unwrap();
    let snapshot = fastra_io::Snapshot::read(&a, &Cancellation::default()).unwrap();
    *doc.format.borrow_mut() =
        Arc::new(fastra_core::encoding::decode(snapshot.bytes(), None).unwrap());
    *doc.snapshot.borrow_mut() = Some(snapshot);
    state.host.add_document("none.txt", "none");
    let unrelated = state.host.active().unwrap();
    *unrelated.snapshot.borrow_mut() =
        Some(fastra_io::Snapshot::read(&none, &Cancellation::default()).unwrap());
    unrelated.buffer.place_cursor(&unrelated.buffer.end_iter());
    unrelated.buffer.insert_at_cursor(" dirty");
    let checked_dirty = Cell::new(false);
    let configured = Cell::new(false);
    state.root.set_text(dir.to_str().unwrap());
    let capture: RefCell<Option<mpsc::Receiver<bool>>> = RefCell::new(None);
    let captured = Cell::new(false);
    let stage = Cell::new(0);
    let start = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(60),
            "Folder window test timed out at {}",
            stage.get()
        );
        if state.pending.borrow().is_some()
            && !state.pane.test_approve_initial()
            && state.transaction.borrow().is_none()
        {
            return glib::ControlFlow::Continue;
        }
        match stage.get() {
            0 => {
                if !configured.replace(true) {
                    state.set_root(dir.clone());
                    return glib::ControlFlow::Continue;
                }
                if state.sources.borrow().as_ref().is_some_and(|s| s.busy()) { return glib::ControlFlow::Continue; }
                state.search.emit_clicked();
                stage.set(1);
            }
            1 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                let p = state.pending.borrow();
                assert_eq!(p.as_ref().unwrap().matches(), 3);
                drop(p);
                state.pane.test_approve_hit(0,0,false);
                if !state.pane.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(state.pane.test_display(1), "cat dog\n");
                if !checked_dirty.replace(true) {
                    doc.buffer.begin_user_action();
                    doc.buffer.insert_at_cursor(" dirty");
                    doc.buffer.end_user_action();
                    state.apply.emit_clicked();
                    assert!(state.busy.get());
                    stage.set(10);
                    return glib::ControlFlow::Continue;
                }
                if !captured.get() {
                    if let Some(directory) = std::env::var_os("FASTRA_FOLDER_SCREENSHOTS") {
                        if capture.borrow().is_none() {
                            let directory = PathBuf::from(directory);
                            std::fs::create_dir_all(&directory).unwrap();
                            let (tx, rx) = mpsc::channel();
                            *capture.borrow_mut() = Some(rx);
                            let window = state.window.upgrade().unwrap();
                            glib::timeout_add_local_once(Duration::from_millis(600), move || {
                                let paintable = gtk::WidgetPaintable::new(Some(&window));
                                let snapshot = gtk::Snapshot::new();
                                paintable.snapshot(
                                    &snapshot,
                                    f64::from(window.width()),
                                    f64::from(window.height()),
                                );
                                let node = snapshot.to_node().expect("Painted folder window");
                                let texture =
                                    window.renderer().unwrap().render_texture(&node, None);
                                let _ = tx.send(
                                    texture.save_to_png(directory.join("folder.png")).is_ok(),
                                );
                            });
                            return glib::ControlFlow::Continue;
                        }
                        match capture.borrow().as_ref().unwrap().try_recv() {
                            Ok(true) => captured.set(true),
                            Ok(false) => panic!("Folder screenshot failed"),
                            Err(mpsc::TryRecvError::Empty) => return glib::ControlFlow::Continue,
                            Err(_) => panic!("Screenshot worker stopped"),
                        }
                    } else {
                        captured.set(true);
                    }
                }
                state.apply.emit_clicked();
                assert!(state.busy.get());
                assert!(!state.pane.checks.is_sensitive());
                assert!(!state.sources.borrow().as_ref().unwrap().root.is_sensitive());
                let window = state.window.upgrade().unwrap();
                window.close();
                assert!(window.is_visible(), "A writing operation must still block closing its window");
                assert!(prevent_close(&state.host), "A writing operation must still block closing the owner");
                stage.set(2);
            }
            10 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.transaction.borrow().is_none());
                assert_eq!(std::fs::read(&a).unwrap(), original);
                doc.buffer.undo();
                doc.buffer.set_modified(false);
                assert_eq!(buffer_text(&doc.buffer), "cat cat\r\n");
                stage.set(1);
            }
            2 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state.transaction.borrow().is_some(),
                    "{}",
                    state.status.text()
                );
                assert_eq!(std::fs::read(&a).unwrap(), b"\xef\xbb\xbfcat dog\r\n");
                assert_eq!(buffer_text(&doc.buffer), "cat dog\r\n");
                assert!(!doc.buffer.is_modified());
                state.undo.emit_clicked();
                stage.set(3);
            }
            3 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state.transaction.borrow().is_none(),
                    "{}",
                    state.status.text()
                );
                assert_eq!(std::fs::read(&a).unwrap(), original);
                assert_eq!(buffer_text(&doc.buffer), "cat cat\r\n");
                assert_eq!(buffer_text(&unrelated.buffer), "none dirty");
                assert!(unrelated.buffer.is_modified());
                state.search.emit_clicked();
                stage.set(4);
            }
            4 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.pending.borrow().is_some(), "{}", state.status.text());
                std::fs::write(&none, "cat").unwrap();
                state.apply.emit_clicked();
                stage.set(5);
            }
            5 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.transaction.borrow().is_none());
                assert_eq!(std::fs::read(&a).unwrap(), original);
                assert!(
                    state
                        .status
                        .text()
                        .contains(state.host.lang.text("geändert", "changed")),
                    "{}",
                    state.status.text()
                );
                eprintln!("FASTRA_FOLDER_SELFTEST_OK complete-preview/selective-apply/controls-frozen/codec-bom/open-editor-refresh/disk-undo/nonmatching-input-stale");
                std::fs::remove_dir_all(&dir).unwrap();
                state.host.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

#[cfg(debug_assertions)]
mod project_test;
#[cfg(debug_assertions)]
pub(super) use project_test::run_project_selftest;

#[cfg(debug_assertions)]
fn test_quit_pause(phase:&str){
    let Some(root)=std::env::var_os("FASTRA_FOLDER_QUIT_TEST_DIR")else{return;};
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(),Ok("1"));
    let root=PathBuf::from(root);assert!(root.is_absolute());
    if !root.join(format!("pause-{phase}")).exists(){return;}
    std::fs::write(root.join(format!("ready-{phase}")),b"real transaction returned; Main completion pending").unwrap();
    let start=std::time::Instant::now();
    while !root.join(format!("release-{phase}")).exists(){assert!(start.elapsed()<Duration::from_secs(30));std::thread::sleep(Duration::from_millis(5));}
}

#[cfg(debug_assertions)]
pub(super) mod readonly_test;
