//! Sichtbarer PMT-Auftrag: erst vollständige Vorschau, dann ausdrückliche Adoption.
use super::{git_view as support, Language, Ui};
#[path = "import_diagnostics.rs"]
mod diagnostics;
#[cfg(debug_assertions)]
#[path = "import_rtf_gui_test.rs"]
mod rtf_gui_test;
#[path = "import_routing.rs"]
mod routing;
use gtk::{gio, prelude::*};
pub(super) use routing::{route_open, route_open_completed};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::{Rc, Weak},
};

fn import_error(lang: Language, error: fastra_import::Error) -> String {
    use fastra_import::Error::*;
    match error {
        Tool { message, output } => format!(
            "{}\n{}",
            message.unwrap_or_else(|| lang
                .text(
                    "Das Werkzeug meldet einen Fehler.",
                    "The tool reported an error."
                )
                .into()),
            support::bytes(&output.stderr)
        ),
        Process(error) => match error {
            fastra_process::Error::Cancelled(_) => {
                lang.text("Import abgebrochen.", "Import cancelled.").into()
            }
            fastra_process::Error::TimedOut(_) => lang
                .text(
                    "Import-Zeitlimit erreicht. Nichts übernommen.",
                    "Import time limit reached. Nothing adopted.",
                )
                .into(),
            fastra_process::Error::Unavailable => lang
                .text("Lokales Werkzeug nicht gefunden.", "Local tool not found.")
                .into(),
            fastra_process::Error::OutputLimit(_) => lang
                .text(
                    "Die Werkzeugausgabe ist zu groß für eine vollständige Vorschau.",
                    "Tool output is too large for a complete preview.",
                )
                .into(),
            other => format!(
                "{}: {other}",
                lang.text("Werkzeug nicht gestartet", "Tool not started")
            ),
        },
        UnsafeTree(_) => lang
            .text(
                "Der Ergebnisbaum enthält unerlaubte oder geänderte Dateien. Nichts übernommen.",
                "The result tree contains disallowed or changed files. Nothing adopted.",
            )
            .into(),
        StaleOwner | StalePrepared => lang
            .text(
                "Die Importbasis hat sich geändert. Neu vorbereiten.",
                "The import basis changed. Prepare again.",
            )
            .into(),
        InvalidPath(_) => lang.text("Ein Importpfad ist ungültig. Das Werkzeug und alle Importpfade müssen absolutes UTF-8 verwenden.","An import path is invalid. The tool and all import paths must use absolute UTF-8.").into(),
        Cancelled => lang.text("Import abgebrochen.", "Import cancelled.").into(),
        PublishedButNotDurable {
            publication,
            message,
        } => format!(
            "{}: {}\n{message}",
            lang.text(
                "Bereits angelegt; Dauerhaftigkeit prüfen",
                "Already published; inspect durability"
            ),
            publication.markdown.display()
        ),
        other => format!(
            "{}: {other}",
            lang.text("Import nicht abgeschlossen", "Import not completed")
        ),
    }
}
fn owner(ui: &Rc<Ui>) -> Option<fastra_import::OwnerBinding> {
    let doc = ui.active()?;
    let project = super::project_view::current_binding(ui);
    // Eine geänderte oder noch geladene Projektwahl ist keine projektlose Basis.
    if ui.project.borrow().is_some() && project.as_ref().is_none_or(|p| !p.is_current()) {
        return None;
    }
    Some(fastra_import::OwnerBinding {
        document_id: format!("document-{:x}", Rc::as_ptr(&doc) as usize),
        document_revision: doc.revision.get(),
        project_id: project.map(|p| p.owner_id()),
        generation: ui.generation.get(),
    })
}
fn path_text(path: &std::path::Path) -> Result<&str, ()> {
    path.to_str().ok_or(())
}
fn set_path(entry: &gtk::Entry, path: &std::path::Path, status: &gtk::Label, lang: Language) {
    match path_text(path) {
        Ok(text) => entry.set_text(text),
        Err(()) => {
            entry.set_text("");
            status.set_text(lang.text(
                "Dieser Pfad enthält ungültiges UTF-8 und kann nicht importiert werden. Bitte einen anderen Pfad wählen.",
                "This path contains invalid UTF-8 and cannot be imported. Choose another path.",
            ));
        }
    }
}
fn preview_text(preview: &fastra_import::ImportPreview, lang: Language) -> Result<String, String> {
    let mut text = format!(
        "{}: {}\n{}: {}\n\n",
        lang.text("Einstieg", "Entry"),
        preview.entry.display(),
        lang.text("Dateien", "Files"),
        preview.files.len()
    );
    for (path, file) in &preview.files {
        text.push_str(&format!(
            "{:?} · {} {}\n",
            path,
            file.bytes,
            lang.text("Bytes", "bytes")
        ));
    }
    for doc in &preview.documents {
        text.push_str(&format!(
            "\n{} {}: {} → {}\n",
            lang.text("Dokument", "Document"),
            doc.source_index,
            doc.title,
            doc.markdown.display()
        ));
    }
    text.push_str(&format!(
        "\n{}\n",
        lang.text("Warnungen und Verluste", "Warnings and losses")
    ));
    text.push_str(&diagnostics::text(&preview.response, lang));
    let source_name = preview
        .response
        .input
        .as_deref()
        .and_then(|p| std::path::Path::new(p).file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("");
    let parser = fastra_import::ProgressParser::new(source_name);
    for line in preview
        .process_output
        .stderr
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
    {
        if std::str::from_utf8(line).is_ok_and(|line| parser.is_progress_line(line)) {
            continue;
        }
        text.push_str(&format!(
            "{}: {}\n",
            lang.text("Werkzeugdiagnose", "Tool diagnostic"),
            support::bytes(line)
        ));
    }
    for (path, content) in &preview.markdown_text {
        if text
            .len()
            .saturating_add(content.len())
            .saturating_add(path.as_os_str().len())
            .saturating_add(32)
            > 2 * 1024 * 1024
        {
            return Err(lang.text("Der vollständige Ergebnistext überschreitet die Vorschaugrenze. Nichts übernommen.","The complete result text exceeds the preview limit. Nothing adopted.").into());
        }
        text.push_str(&format!("\n──── {} ────\n", path.display()));
        text.push_str(content);
        text.push('\n');
    }
    if text.contains('\0')
        || text.len() > 2 * 1024 * 1024
        || text.lines().any(|line| line.len() > 16384)
    {
        return Err(lang
            .text(
                "Die vollständige Diagnose überschreitet die Anzeigegrenze. Nichts übernommen.",
                "The complete diagnostic exceeds the display limit. Nothing adopted.",
            )
            .into());
    }
    Ok(text)
}
pub(super) struct State {
    window: gtk::Window,
    ui: Weak<Ui>,
    lang: Language,
    program: gtk::Entry,
    source: gtk::Entry,
    destination: gtk::Entry,
    stem: gtk::Entry,
    catalog: gtk::TextView,
    preview: gtk::TextView,
    raw: gtk::TextView,
    status: gtk::Label,
    spinner: gtk::Spinner,
    prepare: gtk::Button,
    adopt: gtk::Button,
    catalog_button: gtk::Button,
    notebook: gtk::Notebook,
    cancel: RefCell<fastra_import::Cancellation>,
    generation: Cell<u64>,
    prepared: RefCell<Option<fastra_import::PreparedImport>>,
    busy: Cell<bool>,
    adopting: Cell<bool>,
}
impl State {
    fn busy(&self, busy: bool) {
        self.busy.set(busy);
        self.spinner.set_spinning(busy);
        self.spinner.set_visible(busy);
        for entry in [&self.program, &self.source, &self.destination, &self.stem] {
            entry.set_sensitive(!busy);
        }
        self.prepare.set_sensitive(!busy);
        self.catalog_button.set_sensitive(!busy);
        self.adopt
            .set_sensitive(!busy && self.prepared.borrow().is_some());
    }
    fn start(self: &Rc<Self>, catalog_only: bool) {
        if self.busy.get() {
            return;
        }
        self.prepared.borrow_mut().take();
        self.adopt.set_sensitive(false);
        let Some(ui) = self.ui.upgrade() else { return };
        let Some(expected_owner) = owner(&ui) else {
            self.status.set_text(self.lang.text(
                "Ein gültiges Zieldokument und eine unveränderte Projektwahl werden benötigt.",
                "A valid target document and unchanged project selection are required.",
            ));
            return;
        };
        let program = PathBuf::from(self.program.text().as_str());
        let source = PathBuf::from(self.source.text().as_str());
        let destination = PathBuf::from(self.destination.text().as_str());
        let cancel = fastra_import::Cancellation::default();
        self.cancel.borrow().cancel();
        *self.cancel.borrow_mut() = cancel.clone();
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        self.busy(true);
        self.status.set_text(self.lang.text(
            "Lokales Werkzeug läuft … Abbrechen bleibt verfügbar.",
            "Local tool is running … Cancel remains available.",
        ));
        let lang = self.lang;
        let weak = Rc::downgrade(self);
        let progress = std::sync::Arc::new(std::sync::Mutex::new(None::<fastra_import::Progress>));
        let worker_progress = progress.clone();
        let expected = expected_owner.clone();
        let poll = weak.clone();
        gtk::glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
            let Some(state) = poll
                .upgrade()
                .filter(|s| s.busy.get() && s.generation.get() == generation)
            else {
                return gtk::glib::ControlFlow::Break;
            };
            if !catalog_only
                && state.ui.upgrade().and_then(|ui| owner(&ui)).as_ref() != Some(&expected)
            {
                state.cancel.borrow().cancel();
                state.status.set_text(lang.text(
                    "Die Importbasis hat sich geändert. Import wird abgebrochen.",
                    "The import basis changed. Cancelling import.",
                ));
            } else if let Some(value) = progress.lock().unwrap_or_else(|e| e.into_inner()).take() {
                state.status.set_text(&progress_text(&value, lang));
            }
            gtk::glib::ControlFlow::Continue
        });
        support::background(
            move || {
                let importer = fastra_import::Importer::new(program).map_err(|e| e.to_string())?;
                let limits = fastra_import::Limits {
                    max_json_bytes: 1024 * 1024,
                    max_entries: 500,
                    max_path_bytes: 1024,
                    max_total_bytes: 64 * 1024 * 1024,
                    max_file_bytes: 32 * 1024 * 1024,
                    max_markdown_bytes: 4 * 1024 * 1024,
                    ..Default::default()
                };
                if catalog_only {
                    let probe = importer
                        .probe_cached(Default::default(), limits, &cancel)
                        .map_err(|e| import_error(lang, e))?;
                    let mut text = format!("Poor Man’s Text {}\n\n", probe.catalog.version);
                    for format in probe.catalog.formats {
                        text.push_str(&format!(
                            "{} · .{} · {}\n{}\n\n",
                            format.format,
                            format.extensions.join(", ."),
                            if format.available {
                                lang.text("verfügbar", "available")
                            } else {
                                lang.text("nicht verfügbar", "unavailable")
                            },
                            format.unavailable_reason.unwrap_or_default()
                        ));
                    }
                    Ok((None, text))
                } else {
                    let probe = importer
                        .probe_cached(Default::default(), limits, &cancel)
                        .map_err(|e| import_error(lang, e))?;
                    let prepared = importer
                        .prepare_observed(
                            &source,
                            &destination,
                            expected_owner,
                            Default::default(),
                            limits,
                            &cancel,
                            probe.supports_progress,
                            &mut |value| {
                                *worker_progress.lock().unwrap_or_else(|e| e.into_inner()) =
                                    Some(value);
                            },
                        )
                        .map_err(|e| import_error(lang, e))?;
                    let text = preview_text(prepared.preview(), lang)?;
                    Ok((Some(prepared), text))
                }
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                if state.generation.get() != generation {
                    return;
                }
                state.busy(false);
                if state.cancel.borrow().is_cancelled() {
                    state.status.set_text(lang.text(
                        "Abgebrochen. Nichts übernommen.",
                        "Cancelled. Nothing adopted.",
                    ));
                    return;
                }
                match result {
                    Ok((prepared, text)) => {
                        if let Some(prepared) = prepared {
                            let current = state.ui.upgrade().and_then(|ui| owner(&ui));
                            if current.as_ref() != Some(&prepared.preview().owner) {
                                state.status.set_text(lang.text("Das Zieldokument hat sich geändert. Import erneut vorbereiten.","The target document changed. Prepare the import again."));
                                return;
                            }
                            state
                                .raw
                                .buffer()
                                .set_text(&raw_response(prepared.preview(), lang));
                            state.preview.buffer().set_text(&text);
                            *state.prepared.borrow_mut() = Some(prepared);
                            state.adopt.set_sensitive(true);
                            state.notebook.set_current_page(Some(1));
                            state.status.set_text(lang.text("Vollständige Vorschau prüfen. Erst „Übernehmen“ legt den neuen Ergebnisordner an.","Review the complete preview. Only Adopt creates the new result folder."));
                        } else {
                            state.catalog.buffer().set_text(&text);
                            state.notebook.set_current_page(Some(0));
                            state.status.set_text(
                                lang.text("Formatkatalog geladen.", "Format catalog loaded."),
                            );
                        }
                    }
                    Err(error) => {
                        state.preview.buffer().set_text(&error);
                        state.notebook.set_current_page(Some(1));
                        state.status.set_text(lang.text(
                            "Import nicht übernommen. Diagnose prüfen.",
                            "Import not adopted. Review the diagnostic.",
                        ));
                    }
                }
            },
        );
    }
    fn adopt(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(ui) = self.ui.upgrade() else { return };
        let Some(current) = owner(&ui) else { return };
        if self
            .prepared
            .borrow()
            .as_ref()
            .is_none_or(|p| p.preview().owner != current)
        {
            self.status.set_text(self.lang.text(
                "Die Vorschau ist veraltet. Neu vorbereiten.",
                "The preview is stale. Prepare it again.",
            ));
            return;
        }
        let prepared = self.prepared.borrow_mut().take().unwrap();
        let stem = self.stem.text().to_string();
        let cancel = fastra_import::Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.adopting.set(true);
        self.busy(true);
        self.status.set_text(self.lang.text(
            "Geprüften Ergebnisbaum übernehmen …",
            "Adopting the validated result tree …",
        ));
        let weak = Rc::downgrade(self);
        let weak_ui = self.ui.clone();
        let lang = self.lang;
        support::background(
            move || {
                prepared
                    .adopt(&current, &stem, &cancel)
                    .map_err(|e| import_error(lang, e))
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.adopting.set(false);
                state.busy(false);
                match result {
                    Ok(publication) => {
                        state.status.set_text(&format!(
                            "{}: {}",
                            lang.text("Übernommen", "Adopted"),
                            publication.markdown.display()
                        ));
                        if let Some(ui) = weak_ui.upgrade() {
                            ui.status.set_text(&format!(
                                "{}: {}",
                                lang.text("Import übernommen", "Import adopted"),
                                publication.markdown.display()
                            ));
                            if owner(&ui).as_ref() == Some(&publication.owner) {
                                let expected = publication.owner.clone();
                                let owner_ui = Rc::downgrade(&ui);
                                ui.load_path_owned(
                                    publication.markdown,
                                    Rc::new(move || {
                                        owner_ui.upgrade().and_then(|ui| owner(&ui)).as_ref()
                                            == Some(&expected)
                                    }),
                                );
                            } else {
                                state.status.set_text(lang.text("Ergebnis erhalten; Zieldokument geändert. Bitte den gemeldeten Einstieg selbst öffnen.","Result preserved; target document changed. Open the reported entry explicitly."));
                            }
                        }
                    }
                    Err(error) => {
                        state.preview.buffer().set_text(&error);
                        state.status.set_text(lang.text(
                            "Übernahme beendet. Diagnose und möglichen Zielpfad prüfen.",
                            "Adoption ended. Inspect the diagnostic and any reported target path.",
                        ));
                    }
                }
            },
        );
    }
}
pub(super) fn open_for_file(ui: &Rc<Ui>, path: PathBuf) { let state = open(ui); set_path(&state.source, &path, &state.status, ui.lang); }

#[allow(deprecated)]
pub(super) fn open(ui: &Rc<Ui>) -> Rc<State> {
    let lang = ui.lang;
    let window = support::window(
        ui,
        lang.text("Dokument importieren", "Import document"),
        true,
    );
    window.set_default_size(900, 760);
    window.set_size_request(640, 640);
    let root = support::column();
    root.append(&support::label(lang.text(
        "Lokales Werkzeug und Quelle wählen; Ergebnis vor jeder Übernahme vollständig prüfen.",
        "Choose a local tool and source; review the complete result before adoption.",
    )));
    let grid = gtk::Grid::builder()
        .column_spacing(8)
        .row_spacing(8)
        .build();
    let mut entries = Vec::new();
    let mut choosers = Vec::new();
    for (index, title) in [
        lang.text("Werkzeug", "Tool"),
        lang.text("Quelle", "Source"),
        lang.text("Zielordner", "Destination"),
        lang.text("Ergebnisname", "Result name"),
    ]
    .into_iter()
    .enumerate()
    {
        let entry = gtk::Entry::builder()
            .hexpand(true)
            .width_chars(12)
            .max_width_chars(24)
            .build();
        grid.attach(&support::label(title), 0, index as i32, 1, 1);
        grid.attach(&entry, 1, index as i32, 1, 1);
        if index < 3 {
            let button = gtk::Button::with_label(lang.text("Wählen …", "Choose …"));
            grid.attach(&button, 2, index as i32, 1, 1);
            choosers.push(button);
        }
        entries.push(entry);
    }
    root.append(&grid);
    let initial_status = gtk::Label::new(None);
    let program = entries[0].clone();
    let source = entries[1].clone();
    if let Some(path) = ui.active().and_then(|d| d.disk_path()) {
        set_path(&source, &path, &initial_status, lang);
    }
    let destination = entries[2].clone();
    if let Some(path) = ui.active().and_then(|d| d.disk_path()) {
        if let Some(parent) = path.parent() {
            set_path(&destination, parent, &initial_status, lang);
        }
    }
    let stem = entries[3].clone();
    stem.set_text(lang.text("Import", "Import"));
    let package = gtk::Button::with_label(lang.text("Paket …", "Package …"));
    grid.attach(&package, 3, 1, 1, 1);
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let catalog_button = gtk::Button::with_label(lang.text("Formate laden", "Load formats"));
    let prepare = gtk::Button::with_label(lang.text("Vorschau vorbereiten", "Prepare preview"));
    let adopt = gtk::Button::with_label(lang.text("Übernehmen", "Adopt"));
    adopt.set_sensitive(false);
    let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    for b in [&catalog_button, &prepare, &adopt, &cancel] {
        actions.append(b);
    }
    root.append(&actions);
    let status = support::label(lang.text(
        "Quelle bleibt erhalten. Das Ergebnis wird als neuer Ordner angelegt.",
        "The source is preserved. The result is created as a new folder.",
    ));
    if !initial_status.text().is_empty() {
        status.set_text(&initial_status.text());
    }
    let discovered_program = program.clone();
    let discovery_status = status.clone();
    support::background(
        || Ok(routing::discover_tool()),
        move |result| {
            if discovered_program.text().is_empty() {
                if let Ok(Some(path)) = result {
                    set_path(&discovered_program, &path, &discovery_status, lang);
                }
            }
        },
    );
    let spinner = gtk::Spinner::new();
    spinner.set_visible(false);
    let progress = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    progress.append(&spinner);
    progress.append(&status);
    root.append(&progress);
    let notebook = gtk::Notebook::new();
    notebook.set_vexpand(true);
    let catalog = support::output();
    let preview = support::output();
    let raw = support::output();
    for (view, title) in [
        (&catalog, lang.text("Formatkatalog", "Format catalog")),
        (
            &preview,
            lang.text("Vorschau und Diagnosen", "Preview and diagnostics"),
        ),
        (
            &raw,
            lang.text("Technische Details (JSON)", "Technical details (JSON)"),
        ),
    ] {
        notebook.append_page(&support::scroll(view), Some(&gtk::Label::new(Some(title))));
    }
    root.append(&notebook);
    window.set_child(Some(&root));
    let state = Rc::new(State {
        window: window.clone(),
        ui: Rc::downgrade(ui),
        lang,
        program,
        source,
        destination,
        stem,
        catalog,
        preview,
        raw,
        status,
        spinner,
        prepare,
        adopt,
        catalog_button,
        notebook,
        cancel: RefCell::new(Default::default()),
        generation: Cell::new(0),
        prepared: RefCell::new(None),
        busy: Cell::new(false),
        adopting: Cell::new(false),
    });
    for (index, button) in choosers.into_iter().enumerate() {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            let Some(state) = weak.upgrade() else { return };
            if state.busy.get() {
                return;
            }
            let entry = match index {
                0 => state.program.clone(),
                1 => state.source.clone(),
                _ => state.destination.clone(),
            };
            let status = state.status.clone();
            let dialog = gtk::FileDialog::new();
            if index == 2 {
                dialog.select_folder(
                    Some(&state.window),
                    None::<&gio::Cancellable>,
                    move |result| {
                        if let Ok(file) = result {
                            if let Some(path) = file.path() {
                                set_path(&entry, &path, &status, lang);
                            }
                        }
                    },
                );
            } else {
                dialog.open(
                    Some(&state.window),
                    None::<&gio::Cancellable>,
                    move |result| {
                        if let Ok(file) = result {
                            if let Some(path) = file.path() {
                                set_path(&entry, &path, &status, lang);
                            }
                        }
                    },
                );
            }
        });
    }
    let weak = Rc::downgrade(&state);
    package.connect_clicked(move |_| {
        let Some(state) = weak.upgrade() else { return };
        if state.busy.get() {
            return;
        }
        let entry = state.source.clone();
        let status = state.status.clone();
        gtk::FileDialog::new().select_folder(
            Some(&state.window),
            None::<&gio::Cancellable>,
            move |result| {
                if let Ok(file) = result {
                    if let Some(path) = file.path() {
                        set_path(&entry, &path, &status, lang);
                    }
                }
            },
        );
    });
    for entry in [
        &state.program,
        &state.source,
        &state.destination,
        &state.stem,
    ] {
        let weak = Rc::downgrade(&state);
        entry.connect_changed(move |_| {
            if let Some(state) = weak.upgrade() {
                state.prepared.borrow_mut().take();
                state.adopt.set_sensitive(false);
            }
        });
    }
    let weak = Rc::downgrade(&state);
    state.catalog_button.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.start(true);
        }
    });
    let weak = Rc::downgrade(&state);
    state.prepare.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.start(false);
        }
    });
    let weak = Rc::downgrade(&state);
    state.adopt.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.adopt();
        }
    });
    let weak = Rc::downgrade(&state);
    cancel.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.cancel.borrow().cancel();
            if !state.busy.get() {
                state.window.close();
            }
        }
    });
    let weak = Rc::downgrade(&state);
    window.connect_close_request(move |_| {
        if let Some(state) = weak.upgrade() {
            if state.adopting.get() {
                state.cancel.borrow().cancel();
                state.status.set_text(lang.text(
                    "Übernahme wird beendet. Bitte auf das Ergebnis warten.",
                    "Adoption is ending. Please wait for its result.",
                ));
                return gtk::glib::Propagation::Stop;
            }
        }
        gtk::glib::Propagation::Proceed
    });
    support::hold(&window, state.clone(), |s| s.cancel.borrow().cancel());
    window.present();
    state
}

#[cfg(debug_assertions)]
#[path = "import_gui_test.rs"]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_IMPORT_HOST_TEST").is_some() {
        gui_test::run(ui);
        return;
    }
    let fixture = PathBuf::from(std::env::var_os("FASTRA_TOOL_FIXTURE").unwrap());
    let state = open(&ui);
    support::test_size(&state.window);
    state
        .program
        .set_text(&fixture.join("poormans-text").to_string_lossy());
    state
        .source
        .set_text(&fixture.join("source.mbox").to_string_lossy());
    state
        .destination
        .set_text(&fixture.join("destination").to_string_lossy());
    state.stem.set_text("result");
    state.catalog_button.emit_clicked();
    let stage = Cell::new(0);
    let deadline = std::time::Instant::now();
    let original = std::fs::read(fixture.join("source.mbox")).unwrap();
    let document_paths = RefCell::new(Vec::<PathBuf>::new());
    gtk::glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
        assert!(
            deadline.elapsed() < std::time::Duration::from_secs(30),
            "Import tool timed out: {}",
            state.status.text()
        );
        if state.busy.get() {
            return gtk::glib::ControlFlow::Continue;
        }
        match stage.get() {
            0 => {
                let b = state.catalog.buffer();
                assert!(
                    b.text(&b.start_iter(), &b.end_iter(), true)
                        .contains("mbox"),
                    "{}",
                    state.status.text()
                );
                state.prepare.emit_clicked();
                stage.set(1);
            }
            1 => {
                assert!(state.prepared.borrow().is_some(), "{}", state.status.text());
                assert!(state.adopt.is_sensitive());
                *document_paths.borrow_mut() = state
                    .prepared
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .preview()
                    .documents
                    .iter()
                    .map(|d| d.markdown.clone())
                    .collect();
                assert!(!document_paths.borrow().is_empty());
                assert!(!fixture.join("destination/result/index.md").exists());
                let b = state.preview.buffer();
                assert!(b
                    .text(&b.start_iter(), &b.end_iter(), true)
                    .contains("index.md"));
                let preview = state.prepared.borrow();
                let expected = preview.as_ref().unwrap().preview();
                let visible = super::buffer_text(&state.preview.buffer());
                for content in expected.markdown_text.values() {
                    assert!(
                        visible.contains(content),
                        "Complete imported Markdown must be visible before adoption"
                    );
                }
                drop(preview);
                let doc = ui.active().unwrap();
                doc.revision.set(doc.revision.get() + 1);
                state.adopt.emit_clicked();
                assert!(!state.busy.get());
                assert!(!fixture.join("destination/result/index.md").exists());
                state.prepare.emit_clicked();
                stage.set(2);
            }
            2 => {
                assert!(state.prepared.borrow().is_some(), "{}", state.status.text());
                state.adopt.emit_clicked();
                stage.set(3);
            }
            3 => {
                assert!(
                    fixture.join("destination/result/index.md").is_file(),
                    "{}",
                    state.status.text()
                );
                for relative in document_paths.borrow().iter() {
                    assert!(fixture.join("destination/result").join(relative).is_file());
                }
                assert_eq!(
                    std::fs::read(fixture.join("source.mbox")).unwrap(),
                    original
                );
                stage.set(4);
            }
            _ => {
                let opened = ui
                    .active()
                    .and_then(|doc| doc.snapshot.borrow().as_ref().map(|s| s.path().to_owned()));
                if opened.as_ref() != Some(&fixture.join("destination/result/index.md")) {
                    return gtk::glib::ControlFlow::Continue;
                }
                support::finish(state.window.clone(), ui.clone(), "import");
                return gtk::glib::ControlFlow::Break;
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}

fn raw_response(preview: &fastra_import::ImportPreview, lang: Language) -> String {
    let stderr = &preview.process_output.stderr;
    let end = stderr.len().min(128 * 1024);
    let mut text = format!(
        "{}\n\nstderr:\n{}",
        support::bytes(&preview.process_output.stdout),
        support::bytes(&stderr[..end])
    );
    if end < stderr.len() {
        text.push_str(lang.text("\n[stderr-Anzeige begrenzt; vollständige Bytes bleiben in diesem vorbereiteten Import erhalten]","\n[stderr display limit; complete bytes remain in this prepared import]"));
    }
    text
}

fn progress_text(progress: &fastra_import::Progress, lang: Language) -> String {
    use fastra_import::{Phase, Unit};
    if let Some(counts) = &progress.counts {
        let unit = match counts.unit {
            Unit::File => lang.text("Dateien", "Files"),
            Unit::Page => lang.text("Seiten", "Pages"),
            Unit::Sheet => lang.text("Tabellenblätter", "Sheets"),
            Unit::Frame => lang.text("Bilder", "Frames"),
            Unit::Slide => lang.text("Folien", "Slides"),
            Unit::Chapter => lang.text("Kapitel", "Chapters"),
            Unit::Cell => lang.text("Zellen", "Cells"),
            Unit::Message => lang.text("Nachrichten", "Messages"),
            Unit::Note => lang.text("Notizen", "Notes"),
        };
        return format!("{unit}: {} / {}", counts.completed, counts.total);
    }
    match progress.phase {
        Phase::DetectingInput => lang.text("Dokument wird erkannt …", "Detecting document …"),
        Phase::PreparingOutput => lang.text("Ausgabe wird vorbereitet …", "Preparing output …"),
        Phase::Converting => lang.text("Dokument wird umgewandelt …", "Converting document …"),
        Phase::Publishing | Phase::Finished => lang.text(
            "Ergebnis wird für die Vorschau geprüft …",
            "Validating result for preview …",
        ),
    }
    .into()
}

/// Materialisierte Clipboardbytes bleiben bis zum Ende des sichtbaren Importdialogs privat erhalten.
pub(super) fn open_materialized_rtf(ui:&Rc<Ui>,path:PathBuf,scratch:tempfile::TempDir){
    let state=open(ui);set_path(&state.source,&path,&state.status,ui.lang);
    #[cfg(debug_assertions)]
    rtf_gui_test::opened(&state);
    if let Some(root)=state.window.child().and_downcast::<gtk::Box>(){root.prepend(&support::label(ui.lang.text("RTF aus der Zwischenablage: Formatierung und Textmarker können bei der Konvertierung verloren gehen. Quelle, vollständige Vorschau und Verlustdiagnosen vor der Übernahme prüfen.","RTF from the clipboard: conversion can lose formatting and highlights. Review the source, complete preview and loss diagnostics before adoption.")));}
    let retained=Rc::new(RefCell::new(Some(scratch)));state.window.connect_destroy(move |_|{retained.borrow_mut().take();});
}


#[cfg(debug_assertions)]
pub(super) fn test_real_rtf(ui: Rc<Ui>) { rtf_gui_test::begin(ui); }

#[cfg(debug_assertions)]
pub(super) fn start_rtf_test(ui: Rc<Ui>) { rtf_gui_test::start(ui); }

#[cfg(test)]
mod tests {
    #[test]
    fn import_paths_refuse_raw_bytes_instead_of_using_replacement_collision() {
        use std::os::unix::ffi::OsStrExt;
        let raw = std::path::Path::new(std::ffi::OsStr::from_bytes(b"/source-\xff.mbox"));
        let replacement = std::path::Path::new("/source-�.mbox");
        assert!(super::path_text(raw).is_err());
        assert_eq!(super::path_text(replacement), Ok("/source-�.mbox"));
        assert_eq!(
            super::path_text(std::path::Path::new("/café/雪")),
            Ok("/café/雪")
        );
    }
}
