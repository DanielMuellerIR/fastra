//! Explizite reine Leseabfragen an eine separat bereitgestellte, netzisolierte 4D-Runtime.
use super::four_d_runtime::{self as runtime, Diagnostic, Operation, Response, SourceIndex};
use super::*;
use std::{path::PathBuf, rc::Weak};
struct State {
    ui: Weak<Ui>,
    doc: Weak<Document>,
    window: gtk::Window,
    path_entry: gtk::Entry,
    path: RefCell<Option<PathBuf>>,
    setting_path: Cell<bool>,
    status: gtk::Label,
    list: gtk::ListBox,
    list_scroll: gtk::ScrolledWindow,
    details: gtk::TextView,
    diagnose: gtk::Button,
    signature: gtk::Button,
    cancel_button: gtk::Button,
    project: RefCell<Option<project_view::Binding>>,
    revision: Cell<u64>,
    generation: Cell<u64>,
    running: Cell<bool>,
    core_cancel: RefCell<Cancellation>,
    process_cancel: RefCell<fastra_process::Cancellation>,
    diagnostics: RefCell<Vec<Diagnostic>>,
    index: RefCell<Option<SourceIndex>>,
}
fn visible(text: &str) -> String {
    text.chars()
        .flat_map(|c| {
            if (c == '\n' || c == '\t' || !c.is_control()) && !matches!(c,'\\'|'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}') {
                vec![c]
            } else {
                c.escape_default().collect()
            }
        })
        .collect()
}
fn message(lang: Language, e: &runtime::Error) -> String {
    use runtime::ErrorKind::*;
    let label = match e.kind {
        Cancelled => lang.text("Abgebrochen", "Cancelled"),
        Unavailable => lang.text("Isolation nicht verfügbar", "Isolation unavailable"),
        Layout => lang.text(
            "Runtime oder App-Paket unvollständig",
            "Runtime or application package incomplete",
        ),
        Source => lang.text(
            "4D-Projektquelle erforderlich",
            "4D project source required",
        ),
        Stale => lang.text(
            "Gespeicherte Dateibasis geändert; neu prüfen",
            "Saved file basis changed; check again",
        ),
        Limit => lang.text("Sichere Abfragegrenze erreicht", "Safe query limit reached"),
        Protocol => lang.text(
            "Unvollständige oder ungültige LSP-Antwort",
            "Incomplete or invalid LSP response",
        ),
        NoDiagnostics => lang.text(
            "Keine verwertbaren vollständigen Diagnosen",
            "No usable complete diagnostics",
        ),
        Isolation => lang.text(
            "Sichere Isolation fehlgeschlagen; kein ungeschützter Start",
            "Safe isolation failed; no unprotected launch",
        ),
        Process => lang.text(
            "tool4d konnte die Abfrage nicht abschließen",
            "tool4d could not complete the query",
        ),
        Io => lang.text(
            "Lokale Quelle oder Runtime konnte nicht geprüft werden",
            "Could not verify local source or runtime",
        ),
        Panic => lang.text("Abfrage kontrolliert beendet", "Query ended safely"),
        Busy => lang.text(
            "Bereits zwei Runtime-Abfragen aktiv",
            "Two runtime queries already active",
        ),
    };
    format!("{label}: {}", visible(&e.detail))
}
impl State {
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |u| u.lang)
    }
    fn owner(&self) -> Option<(Rc<Ui>, Rc<Document>)> {
        let ui = self.ui.upgrade()?;
        let doc = self.doc.upgrade()?;
        if !self.window.is_visible()
            || !ui.window.is_visible()
            || doc.source_edits_locked()
            || !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
        {
            return None;
        }
        Some((ui, doc))
    }
    fn current(&self) -> bool {
        self.owner()
            .is_some_and(|(_, d)| d.revision.get() == self.revision.get())
            && self
                .project
                .borrow()
                .as_ref()
                .is_some_and(|b| b.is_current())
    }
    fn actions(&self) {
        self.diagnose.set_sensitive(!self.running.get());
        self.signature.set_sensitive(!self.running.get());
        self.cancel_button.set_sensitive(self.running.get());
    }
    fn stop(&self) {
        self.core_cancel.borrow().cancel();
        self.process_cancel.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
        self.diagnostics.borrow_mut().clear();
        self.index.borrow_mut().take();
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        self.details.buffer().set_text("");
        self.list_scroll.set_visible(true);
        self.actions();
    }
    fn stale(&self) {
        self.status.set_text(self.lang().text("Tab, Revision, Rich-Sperre oder Projekt geändert. Neu prüfen; kein fremdes Dokument wird geöffnet.","Tab, revision, Rich lock or project changed. Check again; no other document is opened."));
    }
    fn set_path(&self, path: PathBuf) {
        self.stop();
        self.setting_path.set(true);
        self.path_entry.set_text(&project_view::display(&path));
        self.setting_path.set(false);
        *self.path.borrow_mut() = Some(path);
        self.status.set_text(self.lang().text(
            "Runtime gewählt. Erst die sichtbare Abfrage startet sie isoliert.",
            "Runtime selected. Only an explicit query launches it in isolation.",
        ));
    }
    fn run(self: &Rc<Self>, operation: Operation) {
        if self.running.get() {
            return;
        }
        let Some((ui, doc)) = self.owner() else {
            self.stale();
            return;
        };
        let Some(path) = self.path.borrow().clone() else {
            self.status.set_text(self.lang().text(
                "tool4d zuerst auswählen. Es wird nichts installiert oder heruntergeladen.",
                "Choose tool4d first. Nothing is installed or downloaded.",
            ));
            return;
        };
        let Some(binding) = project_view::current_binding(&ui) else {
            self.status.set_text(self.lang().text(
                "Zuerst im Projektbaum ein vollständiges 4D-Projekt wählen.",
                "Choose a complete 4D project in the project tree first.",
            ));
            return;
        };
        let Some(snapshot) = doc.snapshot.borrow().clone() else {
            self.status.set_text(self.lang().text("Nur gespeicherte 4D-Methoden im gewählten Projekt; der aktuelle ungespeicherte Text bleibt im Editor.","Saved 4D methods in the selected project only; current unsaved text stays in the editor."));
            return;
        };
        if doc.buffer.char_count() as usize > runtime::MAX_SOURCE {
            self.status.set_text(self.lang().text(
                "LSP-Quellgrenze: 1 MiB UTF-8.",
                "LSP source limit: 1 MiB UTF-8.",
            ));
            return;
        }
        let source = buffer_text(&doc.buffer);
        if source.len() > runtime::MAX_SOURCE {
            self.status.set_text(self.lang().text(
                "LSP-Quellgrenze: 1 MiB UTF-8.",
                "LSP source limit: 1 MiB UTF-8.",
            ));
            return;
        }
        self.stop();
        self.revision.set(doc.revision.get());
        let generation = self.generation.get();
        let Some(target)=source_panes::capture(&doc) else{return};
        let cursor=target.buffer.cursor_position() as usize;
        let core = Cancellation::default();
        let process = fastra_process::Cancellation::default();
        *self.core_cancel.borrow_mut() = core.clone();
        *self.process_cancel.borrow_mut() = process.clone();
        let work = match binding.work(&core) {
            Ok(w) => w,
            Err(e) => {
                self.status.set_text(&e);
                return;
            }
        };
        *self.project.borrow_mut() = Some(binding.clone());
        let root = binding.root.path.clone();
        let root_identity = binding.root.identity();
        let token = glib::uuid_string_random().to_string();
        self.running.set(true);
        self.actions();
        self.status.set_text(self.lang().text(
            "Isolierte lokale LSP-Abfrage läuft … Abbrechen beendet nur die eigene Prozessgruppe.",
            "Isolated local LSP query running … Cancel stops only its owned process group.",
        ));
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                work.validate()?;
                let result = runtime::execute(runtime::Query {
                    runtime_path: &path,
                    root: &root,
                    root_identity,
                    snapshot: &snapshot,
                    source: &source,
                    operation,
                    cursor,
                    token,
                    cancel: &core,
                    process_cancel: &process,
                });
                work.validate()?;
                let result = result.and_then(|response| {
                    SourceIndex::new(&source, &core).map(|index| (response, index))
                });
                Ok(result)
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                s.running.set(false);
                s.actions();
                if s.generation.get() != generation {
                    return;
                }
                if !s.current() || !binding.is_current() {
                    s.stop();
                    s.stale();
                    return;
                }
                if matches!(operation, Operation::Signature)
                    && s.doc
                        .upgrade()
                        .is_none_or(|d|!target.valid(&d)||target.buffer.cursor_position() as usize != cursor)
                {
                    s.status.set_text(s.lang().text(
                        "Cursor geändert. Parameterhilfe erneut anfordern.",
                        "Cursor changed. Request signature help again.",
                    ));
                    return;
                }
                match result {
                    Ok(Ok((response, index))) => s.render(response, index, operation),
                    Ok(Err(e)) => s.status.set_text(&message(s.lang(), &e)),
                    Err(e) => s.status.set_text(&format!(
                        "{}: {e}",
                        s.lang().text(
                            "Projektbasis geändert oder Hintergrundfehler",
                            "Project basis changed or background failure"
                        )
                    )),
                };
            },
        );
    }
    fn render(self: &Rc<Self>, response: Response, index: SourceIndex, operation: Operation) {
        let cleanup_forced = response.cleanup_forced;
        self.list_scroll
            .set_visible(matches!(operation, Operation::Diagnostics));
        *self.index.borrow_mut() = Some(index);
        match operation {
            Operation::Diagnostics => {
                let count = response.diagnostics.len();
                *self.diagnostics.borrow_mut() = response.diagnostics;
                let generation = self.generation.get();
                let diagnostics = self.diagnostics.borrow().clone();
                for (i, d) in diagnostics.iter().enumerate() {
                    let valid = self
                        .index
                        .borrow()
                        .as_ref()
                        .and_then(|m| m.span(d.range))
                        .is_some();
                    let (line, column) = self
                        .index
                        .borrow()
                        .as_ref()
                        .and_then(|m| m.display_position(d.range.start))
                        .map(|(a, b)| (a as u64, b as u64))
                        .unwrap_or((
                            u64::from(d.range.start.line) + 1,
                            u64::from(d.range.start.character) + 1,
                        ));
                    let label = gtk::Label::new(Some(&format!(
                        "{}:{} · {} · {}{}",
                        line,
                        column,
                        match d.severity {
                            1 => self.lang().text("Fehler", "Error"),
                            2 => self.lang().text("Warnung", "Warning"),
                            3 => self.lang().text("Information", "Information"),
                            _ => self.lang().text("Hinweis", "Hint"),
                        },
                        visible(&d.message).chars().take(160).collect::<String>(),
                        if valid {
                            ""
                        } else {
                            self.lang()
                                .text(" [ungültiger Bereich]", " [invalid range]")
                        }
                    )));
                    label.set_xalign(0.);
                    label.set_ellipsize(gtk::pango::EllipsizeMode::End);
                    label.set_max_width_chars(100);
                    let button = gtk::Button::new();
                    button.set_child(Some(&label));
                    button.set_sensitive(valid);
                    button.set_tooltip_text(Some(&visible(&d.message)));
                    let weak = Rc::downgrade(self);
                    button.connect_clicked(move |_| {
                        if let Some(s) = weak.upgrade() {
                            s.navigate(i, generation);
                        }
                    });
                    self.list.append(&button);
                }
                self.status.set_text(&format!(
                    "{} {count} · tool4d {} · {}",
                    self.lang().text(
                        "Vollständige Dokumentdiagnosen:",
                        "Complete document diagnostics:"
                    ),
                    visible(&response.server),
                    self.lang().text(
                        "Nur gebundener Quelltab; keine Compiler-/Projektvollprüfung.",
                        "Bound source tab only; no full compiler/project check."
                    )
                ));
            }
            Operation::Signature => {
                let mut output = String::new();
                for signature in &response.signatures {
                    output.push_str(&visible(&signature.label));
                    if let Some(n) = signature.active_parameter {
                        output.push_str(&format!(
                            "\n{} {}",
                            self.lang()
                                .text("Aktueller Parameter:", "Current parameter:"),
                            n.saturating_add(1)
                        ));
                    }
                    output.push_str("\n\n");
                    output.push_str(&visible(&signature.documentation));
                    output.push_str("\n\n");
                }
                let cut = output.chars().count() > 16000;
                let mut display: String = output.chars().take(16000).collect();
                if cut {
                    display.push_str(
                        self.lang()
                            .text("\n[… Anzeige gekürzt …]", "\n[… display shortened …]"),
                    );
                }
                self.details.buffer().set_text(&display);
                self.status.set_text(if response.signatures.is_empty(){self.lang().text("Keine Parameterhilfe an dieser Position.","No signature help at this position.")}else{self.lang().text("Parameterhilfe für die gebundene Cursor-/Quellfassung. Nur Textanzeige; keine Änderung.","Signature help for the bound cursor/source version. Plain text only; no edits.")});
            }
        }
        if cleanup_forced {
            self.status.set_text(&format!(
                "{}\n{}",
                self.status.text(),
                self.lang().text(
                    "Runtime nach vollständiger Antwort kontrolliert beendet.",
                    "Runtime stopped safely after its complete response."
                )
            ));
        }
    }
    fn navigate(&self, i: usize, generation: u64) {
        if generation != self.generation.get() || !self.current() {
            self.stale();
            return;
        }
        let Some((_, doc)) = self.owner() else {
            return;
        };
        let found = self.diagnostics.borrow().get(i).cloned();
        let Some(found) = found else {
            return;
        };
        let span = self
            .index
            .borrow()
            .as_ref()
            .and_then(|m| m.span(found.range));
        let Some(span) = span else {
            return;
        };
        if doc.folded.borrow().is_some() {
            self.status.set_text(
                self.lang()
                    .text("Zuerst alle Zeilen entfalten.", "Unfold all lines first."),
            );
            return;
        }
        self.details.buffer().set_text(&visible(&found.message));
        let Some(target)=source_panes::capture(&doc).filter(|target|target.valid(&doc)) else{return};
        let start=target.buffer.iter_at_offset(span.start as i32);let end=target.buffer.iter_at_offset(span.end as i32);
        target.buffer.select_range(&start,&end);let mut start=start;target.view.scroll_to_iter(&mut start,0.15,true,0.,0.3);target.view.grab_focus();
    }
}
#[cfg(debug_assertions)]
fn widgets(widget: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
    all.push(widget.clone());
    let mut child = widget.first_child();
    while let Some(w) = child {
        widgets(&w, all);
        child = w.next_sibling();
    }
}
pub(super) fn open(ui: &Rc<Ui>) {
    let Some(doc) = ui.active() else {
        return;
    };
    if ui.source_edit_allowed(&doc) {
        open_for(ui, &doc);
    }
}
#[allow(deprecated)]
fn open_for(ui: &Rc<Ui>, doc: &Rc<Document>) -> Rc<State> {
    let window = git_view::window(
        ui,
        ui.lang.text(
            "4D · Isolierte Diagnosen (tool4d)",
            "4D · Isolated diagnostics (tool4d)",
        ),
        false,
    );
    window.set_default_size(900, 760);
    let root = git_view::column();
    root.append(&git_view::label(&format!("{} · {}",doc.name,ui.lang.text("Separates tool4d erforderlich. Keine Installation, Downloads, Quelländerungen oder Methoden-/Makroausführung.","Separate tool4d required. No installation, downloads, source edits or method/macro execution."))));
    root.append(&git_view::label(ui.lang.text("Aktueller ungespeicherter Text nur über lokale Pipes an den isolierten Worker. Projekt/Runtime schreibgeschützt; kein externer Netzwerkzugriff. Quelle höchstens 1 MiB, 200 Diagnosen, Runtime-Prozessfrist 25 Sekunden.","Current unsaved text goes only through local pipes to the isolated worker. Project/runtime read-only; no external network access. At most 1 MiB source, 200 diagnostics, runtime process deadline 25 seconds.")));
    let mut intro = root.first_child();
    while let Some(child) = intro {
        if let Some(label) = child.downcast_ref::<gtk::Label>() {
            label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
            label.set_max_width_chars(95);
        }
        intro = child.next_sibling();
    }
    let path_entry = gtk::Entry::builder()
        .hexpand(true)
        .max_length(4096)
        .width_chars(12)
        .max_width_chars(30)
        .placeholder_text(ui.lang.text(
            "Lokales tool4d-Programm auswählen",
            "Choose the local tool4d executable",
        ))
        .build();
    let choose = gtk::Button::with_label(ui.lang.text("tool4d wählen …", "Choose tool4d …"));
    choose.set_halign(gtk::Align::Start);
    let path_line = gtk::Box::new(gtk::Orientation::Vertical, 6);
    path_line.append(&path_entry);
    path_line.append(&choose);
    root.append(&path_line);
    let actions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(4)
        .column_spacing(6)
        .row_spacing(6)
        .build();
    let project = gtk::Button::with_label(ui.lang.text("Projektbaum …", "Project tree …"));
    let diagnose = gtk::Button::with_label(ui.lang.text("Dokument prüfen", "Check document"));
    let signature =
        gtk::Button::with_label(ui.lang.text("Parameter am Cursor", "Parameters at cursor"));
    let cancel_button = gtk::Button::with_label(ui.lang.text("Abbrechen", "Cancel"));
    for button in [&project, &diagnose, &signature, &cancel_button] {
        actions.insert(button, -1);
    }
    root.append(&actions);
    let status = git_view::label(ui.lang.text(
        "Runtime und Projekt auswählen, dann die Abfrage ausdrücklich starten.",
        "Choose runtime and project, then explicitly start the query.",
    ));
    status.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    status.set_max_width_chars(95);
    status.set_selectable(true);
    root.append(&status);
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    let list_scroll = git_view::scroll(&list);
    root.append(&list_scroll);
    let details = git_view::output();
    details.set_wrap_mode(gtk::WrapMode::WordChar);
    let scroll = git_view::scroll(&details);
    scroll.set_min_content_height(130);
    root.append(&scroll);
    window.set_child(Some(&root));
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(doc),
        window: window.clone(),
        path_entry: path_entry.clone(),
        path: RefCell::new(None),
        setting_path: Cell::new(false),
        status,
        list,
        list_scroll,
        details,
        diagnose: diagnose.clone(),
        signature: signature.clone(),
        cancel_button: cancel_button.clone(),
        project: RefCell::new(None),
        revision: Cell::new(doc.revision.get()),
        generation: Cell::new(0),
        running: Cell::new(false),
        core_cancel: RefCell::new(Cancellation::default()),
        process_cancel: RefCell::new(fastra_process::Cancellation::default()),
        diagnostics: RefCell::new(Vec::new()),
        index: RefCell::new(None),
    });
    for (button, operation) in [
        (diagnose, Operation::Diagnostics),
        (signature, Operation::Signature),
    ] {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                s.run(operation);
            }
        });
    }
    let weak = Rc::downgrade(&state);
    cancel_button.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.stop();
            s.status.set_text(s.lang().text(
                "Abgebrochen. Keine alten oder teilweisen Ergebnisse.",
                "Cancelled. No old or partial results.",
            ));
        }
    });
    let weak = Rc::downgrade(ui);
    project.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            project_view::open(&ui);
        }
    });
    let weak = Rc::downgrade(&state);
    path_entry.connect_changed(move |entry| {
        if let Some(s) = weak.upgrade() {
            if !s.setting_path.get() {
                s.stop();
                *s.path.borrow_mut() = Some(PathBuf::from(entry.text().as_str()));
                s.status.set_text(s.lang().text(
                    "Runtimepfad geändert. Abfrage erneut starten.",
                    "Runtime path changed. Start a new query.",
                ));
            }
        }
    });
    let weak = Rc::downgrade(&state);
    choose.connect_clicked(move |_| {
        let Some(s) = weak.upgrade() else {
            return;
        };
        let dialog = gtk::FileChooserNative::builder()
            .title(
                s.lang()
                    .text("Lokales tool4d wählen", "Choose local tool4d"),
            )
            .transient_for(&s.window)
            .action(gtk::FileChooserAction::Open)
            .modal(true)
            .accept_label(s.lang().text("Auswählen", "Select"))
            .cancel_label(s.lang().text("Abbrechen", "Cancel"))
            .build();
        let weak = Rc::downgrade(&s);
        dialog.connect_response(move |dialog, response| {
            if response == gtk::ResponseType::Accept {
                if let Some(s) = weak.upgrade() {
                    if s.owner().is_some() {
                        if let Some(path) = dialog.file().and_then(|f| f.path()) {
                            s.set_path(path);
                        }
                    }
                }
            }
            dialog.destroy();
        });
        dialog.show();
    });
    let weak = Rc::downgrade(&state);
    doc.buffer.connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            s.stop();
            s.stale();
        }
    });
    let weak = Rc::downgrade(&state);
    ui.tabs.connect_switch_page(move |_, _, _| {
        if let Some(s) = weak.upgrade() {
            s.stop();
            s.stale();
        }
    });
    let holder = Rc::new(RefCell::new(Some(state.clone())));
    let close = holder.clone();
    window.connect_close_request(move |_| {
        if let Some(s) = close.borrow_mut().take() {
            s.stop();
        }
        glib::Propagation::Proceed
    });
    window.connect_visible_notify(move |w| {
        if !w.is_visible() {
            if let Some(s) = holder.borrow_mut().take() {
                s.stop();
            }
        }
    });
    let weak = Rc::downgrade(&state);
    ui.window.connect_visible_notify(move |w| {
        if !w.is_visible() {
            if let Some(s) = weak.upgrade() {
                s.stop();
                s.window.close();
            }
        }
    });
    let weak = Rc::downgrade(&state);
    glib::timeout_add_local(Duration::from_millis(100), move || {
        let Some(s) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if !s.window.is_visible() {
            return glib::ControlFlow::Break;
        }
        if (s.running.get() || s.index.borrow().is_some())
            && (s.owner().is_none() || s.project.borrow().as_ref().is_some_and(|b| !b.is_current()))
        {
            s.stop();
            s.stale();
        }
        glib::ControlFlow::Continue
    });
    let weak = Rc::downgrade(&state);
    git_view::background(
        || Ok(runtime::discover()),
        move |found| {
            if let Some(s) = weak.upgrade() {
                if s.window.is_visible() && s.path.borrow().is_none() {
                    if let Ok(Some(path)) = found {
                        s.set_path(path);
                    }
                }
            }
        },
    );
    state.actions();
    window.present();
    state
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
