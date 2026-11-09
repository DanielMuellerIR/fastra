use super::super::four_d_macro_runtime as engine;
use super::*;
fn failure(lang: Language, detail: &str) -> String {
    let explanation = if detail.contains("timed out") {
        lang.text(
            "Der Makrolauf wurde nach 60 Sekunden beendet.",
            "The macro run was stopped after 60 seconds.",
        )
    } else if detail.contains("Engine copy")
        || detail.contains("Engine file")
        || detail.contains("Engine directory")
    {
        lang.text(
            "Das Engine-Projekt konnte nicht vollständig und sicher kopiert werden.",
            "The engine project could not be copied completely and safely.",
        )
    } else if detail.contains("MacroRun.4dm") || detail.contains(".4DProject file") {
        lang.text("Das gewählte Engine-Projekt braucht eine eindeutige .4DProject-Datei und die Methode MacroRun.", "The selected engine project needs one .4DProject file and the MacroRun method.")
    } else if detail.contains("status file")
        || detail.contains("MacroRun status")
        || detail.contains("Status OK")
    {
        lang.text(
            "Das Makro hat kein vollständiges, gültiges Ergebnis bestätigt.",
            "The macro did not confirm a complete, valid result.",
        )
    } else if detail.contains("binding changed")
        || detail.contains("Runtime")
        || detail.contains("runtime")
        || detail.contains("sandbox")
    {
        lang.text(
            "Tool4D oder seine Isolation konnten nicht sicher gestartet werden.",
            "Tool4D or its isolation could not be started safely.",
        )
    } else if detail.contains("must not contain") || detail.contains("UTF-8") {
        lang.text(
            "Name, Pfad oder Ergebnis verletzen das MacroRun-Textformat.",
            "A name, path or result violates the MacroRun text format.",
        )
    } else if detail.contains("limit") || detail == "Limit" {
        lang.text(
            "Eine sichere Größen- oder Ausgabegrenze wurde erreicht; es gibt kein Teilergebnis.",
            "A safe size or output limit was reached; no partial result is available.",
        )
    } else {
        lang.text(
            "Der Makrolauf konnte keine Änderung vorbereiten.",
            "The macro run could not prepare a change.",
        )
    };
    format!("{explanation}\n{detail}")
}
pub(super) fn can_prepare(state: &State, m: &Macro) -> bool {
    match core::capability(m) {
        Capability::NativeText => true,
        Capability::Runtime(_) => {
            let c = state.hub.config.borrow();
            c.runtime.is_some() && c.engine.is_some()
        }
        _ => false,
    }
}
pub(super) fn render_settings(s: &State) {
    let c = s.hub.config.borrow();
    let lang = s.lang();
    for (label, path, empty) in [
        (
            &s.runtime_label,
            &c.runtime,
            lang.text("Tool4D nicht gewählt", "Tool4D not selected"),
        ),
        (
            &s.engine_label,
            &c.engine,
            lang.text(
                "MacroRun-Engine-Projekt nicht gewählt",
                "MacroRun engine project not selected",
            ),
        ),
    ] {
        let text = path
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| empty.into());
        label.set_text(&text);
        label.set_tooltip_text(Some(&text));
    }
}
pub(super) fn settings_controls(
    root: &gtk::Box,
    lang: Language,
) -> (gtk::Label, gtk::Label, gtk::Button, gtk::Button) {
    let mut labels = Vec::new();
    let mut buttons = Vec::new();
    for title in [
        lang.text("Tool4D wählen …", "Choose Tool4D …"),
        lang.text("Engine-Projekt wählen …", "Choose engine project …"),
    ] {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let button = gtk::Button::with_label(title);
        button.set_width_request(190);
        let label = gtk::Label::new(None);
        label.set_xalign(0.);
        label.set_hexpand(true);
        label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        label.set_max_width_chars(50);
        row.append(&button);
        row.append(&label);
        root.append(&row);
        labels.push(label);
        buttons.push(button);
    }
    (
        labels.remove(0),
        labels.remove(0),
        buttons.remove(0),
        buttons.remove(0),
    )
}
fn settings_owner(state: &State) -> Option<Owner> {
    state
        .hub
        .ui
        .upgrade()
        .and_then(|ui| source(&ui).map(|(_, owner, _)| owner))
}
fn owns_settings(state: &State, generation: u64, owner: &Owner) -> bool {
    state.generation.get() == generation
        && state.window.is_visible()
        && state.hub.ui.upgrade().is_some_and(|ui| current(&ui, owner))
}
pub(super) fn save_setting(state: &Rc<State>, change: discovery::Change) {
    let Some(owner) = settings_owner(state) else {
        return;
    };
    state.invalidate();
    let generation = state.generation.get();
    // Das Einreihen geschieht hier auf dem UI-Thread; Hintergrundtasks dürfen die Schreibfolge nicht vertauschen.
    let pending = discovery::update_config(change);
    state.prepare.set_sensitive(false);
    state.status.set_text(state.lang().text(
        "Makro-Auswahl wird gespeichert …",
        "Saving macro selection …",
    ));
    let weak = Rc::downgrade(state);
    git_view::background(
        move || {
            pending
                .recv()
                .map_err(|_| "Settings worker unavailable".to_owned())?
        },
        move |result| {
            let Some(s) = weak.upgrade() else { return };
            if !owns_settings(&s, generation, &owner) {
                return;
            }
            match result {
                Ok(config) => {
                    *s.hub.config.borrow_mut() = config;
                    s.hub.refresh(true, true);
                    s.status.set_text(s.lang().text("Auswahl gespeichert. Erst Vorschau vorbereiten startet Tool4D; Originalprojekt und Dateien bleiben unverändert.", "Selection saved. Only Prepare preview starts Tool4D; original project and files remain unchanged."));
                }
                Err(e) => {
                    s.render();
                    s.status.set_text(&format!("{}: {e}", s.lang().text("Die Auswahl wurde nicht gespeichert; die bisherige Wahl bleibt erhalten", "Selection was not saved; the previous choice is retained")));
                }
            }
        },
    );
}
pub(super) fn choose_setting(state: &Rc<State>, field: discovery::Field, folder: bool) {
    let Some(owner) = settings_owner(state) else {
        return;
    };
    let generation = state.generation.get();
    let weak = Rc::downgrade(state);
    let completion = move |result: Result<gio::File, glib::Error>| {
        let Some(s) = weak.upgrade() else { return };
        if !owns_settings(&s, generation, &owner) {
            return;
        }
        if let Ok(file) = result {
            if let Some(path) = file.path() {
                save_setting(&s, discovery::Change::Set(field, Some(path)));
            }
        }
    };
    if folder {
        gtk::FileDialog::new().select_folder(
            Some(&state.window),
            None::<&gio::Cancellable>,
            completion,
        );
    } else {
        gtk::FileDialog::new().open(Some(&state.window), None::<&gio::Cancellable>, completion);
    }
}
pub(super) fn connect_settings(state: &Rc<State>, tool: gtk::Button, project: gtk::Button) {
    for (button, field, folder) in [
        (tool, discovery::Field::Runtime, false),
        (project, discovery::Field::Engine, true),
    ] {
        let weak = Rc::downgrade(state);
        button.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                choose_setting(&s, field, folder);
            }
        });
    }
}
impl State {
    pub(super) fn prepare_runtime(
        self: &Rc<Self>,
        owner: Owner,
        text: String,
        variant: &'static str,
    ) {
        let config = self.hub.config.borrow().clone();
        let lang = self.lang();
        let (Some(tool), Some(project)) = (config.runtime, config.engine) else {
            self.status.set_text(lang.text(
                "Tool4D und ein Engine-Projekt mit MacroRun wählen.",
                "Choose Tool4D and an engine project with MacroRun.",
            ));
            return;
        };
        let Some(name) = owner.path.file_name().and_then(|n| n.to_str()) else {
            self.status.set_text(lang.text(
                "Der Methodenname muss UTF-8 sein.",
                "The method name must be UTF-8.",
            ));
            return;
        };
        let method = core::normalized_method_name(name);
        if method == "00_DM_Info" || method.starts_with("Compiler_") {
            self.status.set_text(lang.text("00_DM_Info und Compiler_*-Methoden sind vom Komplettieren ausgenommen und bleiben unverändert.","00_DM_Info and Compiler_* methods are excluded from completion and remain unchanged."));
            return;
        }
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let process_cancel = fastra_process::Cancellation::default();
        *self.process_cancel.borrow_mut() = process_cancel.clone();
        let diff_cancel = fastra_diff::Cancellation::default();
        *self.diff_cancel.borrow_mut() = diff_cancel.clone();
        let generation = self.generation.get();
        self.running.set(true);
        self.prepare.set_sensitive(false);
        self.status.set_text(lang.text("Makrolauf wartet oder läuft isoliert (höchstens 60 Sekunden). Änderungen erst nach vollständiger Diff-Vorschau übernehmen.","Macro run is queued or running in isolation (at most 60 seconds). Apply changes only after the complete diff preview."));
        // Die Queue fordert auf dem GTK-Thread eine frische Lease-Prüfung unmittelbar vor dem Start an.
        let (tx, rx) = std::sync::mpsc::channel::<std::sync::mpsc::Sender<bool>>();
        let watch_owner = owner.clone();
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(20), move || {
            let Some(s) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if s.generation.get() != generation || !s.running.get() {
                return glib::ControlFlow::Break;
            }
            let valid = s.window.is_visible()
                && s.hub
                    .ui
                    .upgrade()
                    .is_some_and(|ui| current(&ui, &watch_owner));
            while let Ok(reply) = rx.try_recv() {
                let _ = reply.send(valid);
            }
            if !valid {
                s.invalidate();
                s.prepare.set_sensitive(true);
                s.status.set_text(lang.text(
                    "Dokument, Auswahl, Fenster oder Projekt geändert. Makrolauf abgebrochen.",
                    "Document, selection, window or project changed. Macro run cancelled.",
                ));
                return glib::ControlFlow::Break;
            }
            glib::ControlFlow::Continue
        });
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                let should_start = || {
                    let (reply, answer) = std::sync::mpsc::channel();
                    if tx.send(reply).is_err() {
                        return false;
                    }
                    loop {
                        if cancel.check().is_err() {
                            return false;
                        }
                        match answer.recv_timeout(Duration::from_millis(20)) {
                            Ok(valid) => return valid,
                            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return false,
                            Err(_) => {}
                        }
                    }
                };
                let outcome = engine::execute(engine::Query {
                    runtime: &tool,
                    engine: &project,
                    original: &text,
                    variant,
                    method: &method,
                    cancel: &cancel,
                    process_cancel: &process_cancel,
                    should_start: &should_start,
                })?;
                match outcome {
                    engine::Outcome::Unchanged => Ok(None),
                    engine::Outcome::Changed(result) => {
                        let caret = owner.selection.0.min(result.chars().count() as i32);
                        build_preview(
                            owner,
                            text,
                            result,
                            caret,
                            generation,
                            &cancel,
                            &diff_cancel,
                            lang,
                        )
                        .map(Some)
                    }
                }
            },
            move |result| {
                let Some(s) = weak.upgrade() else { return };
                if s.generation.get() != generation {
                    return;
                }
                s.running.set(false);
                s.prepare.set_sensitive(true);
                match result {
                    Ok(Some(preview)) => {
                        if !s.window.is_visible()
                            || !s
                                .hub
                                .ui
                                .upgrade()
                                .is_some_and(|ui| current(&ui, &preview.owner))
                        {
                            s.status.set_text(lang.text(
                                "Vorschau veraltet. Erneut vorbereiten.",
                                "Preview is stale. Prepare again.",
                            ));
                            return;
                        }
                        s.before.buffer().set_text(&preview.before);
                        s.after.buffer().set_text(&preview.after);
                        *s.preview.borrow_mut() = Some(preview);
                        s.apply.set_sensitive(true);
                        s.notebook.set_current_page(Some(1));
                        s.status.set_text(lang.text("Vollständigen Diff prüfen. Erst Übernehmen ändert den gebundenen Editor.","Review the complete diff. Only Apply changes the bound editor."));
                    }
                    Ok(None) => s.status.set_text(lang.text(
                        "Keine Änderungen – die Methode ist bereits vollständig.",
                        "No changes – the method is already complete.",
                    )),
                    Err(e) => s.status.set_text(&failure(lang, &e)),
                }
            },
        );
    }
}
#[allow(clippy::too_many_arguments)]
pub(super) fn build_preview(
    owner: Owner,
    text: String,
    result: String,
    caret: i32,
    generation: u64,
    cancel: &Cancellation,
    diff_cancel: &fastra_diff::Cancellation,
    lang: Language,
) -> Result<Preview, String> {
    text_limits::validate(&text, lang)?;
    text_limits::validate(&result, lang)?;
    if result.len() > core::Limits::default().output_bytes {
        return Err("Macro result limit: 8 MiB".into());
    }
    let comparison = fastra_diff::Comparison::compare(
        fastra_diff::TextSnapshot {
            document_id: "before".into(),
            revision: owner.revision,
            text: text.clone(),
        },
        fastra_diff::TextSnapshot {
            document_id: "after".into(),
            revision: owner.revision,
            text: result.clone(),
        },
        generation,
        Default::default(),
        Default::default(),
        diff_cancel,
    )
    .map_err(|e| format!("{e:?}"))?;
    let (mut before, mut after) = (String::new(), String::new());
    for row in comparison.rows() {
        cancel.check().map_err(|e| e.to_string())?;
        let marker = match row.kind {
            fastra_diff::RowKind::Unchanged => " ",
            fastra_diff::RowKind::Added => "+",
            fastra_diff::RowKind::Removed => "−",
            fastra_diff::RowKind::Changed => "~",
        };
        for (side, line, out) in [
            (true, row.left_line, &mut before),
            (false, row.right_line, &mut after),
        ] {
            if let Some(line) = line {
                out.push_str(&format!(
                    "{line:>5} {marker} {}{}\n",
                    comparison.content(side, line).unwrap_or_default(),
                    if row.terminators_differ {
                        " ↵≠"
                    } else {
                        ""
                    }
                ));
            } else {
                out.push('\n');
            }
        }
        if before.len() + after.len() > 4 * 1024 * 1024 {
            return Err("Complete diff display limit: 4 MiB; preview not truncated".into());
        }
    }
    Ok(Preview {
        owner,
        original: text,
        result,
        caret,
        before,
        after,
    })
}

#[cfg(test)]
mod validation_tests {
    use super::*;
    fn owner() -> Owner {
        Owner {
            document: 1,
            path: "/fixture/Method.4dm".into(),
            revision: 1,
            generation: 1,
            project: None,
            selection: (0, 0),
            pane:(0,0,0,0),
        }
    }
    #[test]
    fn changed_outputs_and_inputs_are_checked_by_editor_limits_before_diff() {
        let original = "// unchanged original\nFutureCommand:C9999()\n";
        for result in [
            "visible\0hidden".into(),
            "x".repeat(fastra_document::TEXT_SECTION_BYTES + 1),
        ] {
            let checked = build_preview(
                owner(),
                original.into(),
                result,
                0,
                1,
                &Cancellation::default(),
                &fastra_diff::Cancellation::default(),
                Language(false),
            );
            assert!(checked.is_err());
        }
        assert!(build_preview(
            owner(),
            "input\0hidden".into(),
            "valid result\n".into(),
            0,
            1,
            &Cancellation::default(),
            &fastra_diff::Cancellation::default(),
            Language(true)
        )
        .is_err());
        assert!(build_preview(
            owner(),
            "valid input\n".into(),
            format!("{}\n", "é".repeat(fastra_document::TEXT_SECTION_BYTES / 2)),
            0,
            1,
            &Cancellation::default(),
            &fastra_diff::Cancellation::default(),
            Language(false)
        )
        .is_ok());
    }
}
