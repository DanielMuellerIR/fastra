//! Wiederaufnahme schreibt erst nach Prüfung der sichtbaren, gebundenen Originaldaten.
use super::*;
use fastra_io::{FileState, Phase, RecoveryPreview, Transaction};
use std::{collections::HashSet, path::PathBuf, sync::Arc};
struct State {
    ui: std::rc::Weak<Ui>,
    window: gtk::Window,
    path: gtk::Entry,
    raw_path: RefCell<PathBuf>,
    setting_path: Cell<bool>,
    load: gtk::Button,
    restore: gtk::Button,
    cleanup: gtk::Button,
    cancel_button: gtk::Button,
    consent: gtk::CheckButton,
    exact: gtk::CheckButton,
    status: gtk::Label,
    files: gtk::DropDown,
    before: gtk::TextView,
    after: gtk::TextView,
    before_label: gtk::Label,
    after_label: gtk::Label,
    offset: gtk::Entry,
    previous: gtk::Button,
    next: gtk::Button,
    busy: Cell<bool>,
    generation: Cell<u64>,
    render_generation: Cell<u64>,
    render_ready: Cell<bool>,
    cancel: RefCell<Cancellation>,
    transaction: RefCell<Option<Transaction>>,
    preview: RefCell<Option<Arc<RecoveryPreview>>>,
}
impl State {
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |ui| ui.lang)
    }
    fn busy(&self, value: bool) {
        self.busy.set(value);
        if let Some(row) = self.path.parent() {
            row.set_sensitive(!value);
        }
        self.path.set_sensitive(!value);
        self.load.set_sensitive(!value);
        self.files.set_sensitive(!value);
        self.exact.set_sensitive(!value);
        self.consent
            .set_sensitive(!value && self.render_ready.get());
        self.cancel_button.set_sensitive(value);
        self.previous.set_sensitive(!value);
        self.next.set_sensitive(!value);
        self.offset.set_sensitive(!value);
        self.actions();
    }
    fn actions(&self) {
        let preview = self.preview.borrow();
        let available = self.render_ready.get()
            && !self.busy.get()
            && self.consent.is_active()
            && self.transaction.borrow().is_some();
        self.restore.set_sensitive(
            available && preview.as_ref().is_some_and(|p| p.phase() != Phase::Undone),
        );
        self.cleanup.set_sensitive(
            available && preview.as_ref().is_some_and(|p| p.phase() == Phase::Undone),
        );
    }
    fn clear(&self) {
        self.cancel.borrow().cancel();
        self.generation.set(self.generation.get() + 1);
        self.render_generation.set(self.render_generation.get() + 1);
        self.render_ready.set(false);
        self.preview.borrow_mut().take();
        self.transaction.borrow_mut().take();
        self.consent.set_active(false);
        self.before.buffer().set_text("");
        self.after.buffer().set_text("");
        self.files.set_model(None::<&gtk::StringList>);
        self.actions();
    }
    fn set_path(&self, path: PathBuf) {
        *self.raw_path.borrow_mut() = path.clone();
        self.setting_path.set(true);
        self.path.set_text(&project_view::display(&path));
        self.path
            .set_tooltip_text(Some(&project_view::display(&path)));
        self.setting_path.set(false);
        self.clear();
    }
    fn load(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        self.clear();
        let generation = self.generation.get();
        let path = self.raw_path.borrow().clone();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy(true);
        self.status.set_text(self.lang().text(
            "Sicherung und alle Dateistände werden geprüft …",
            "Checking recovery data and every file state …",
        ));
        let weak = Rc::downgrade(self);
        let lang = self.lang();
        git_view::background(
            move || {
                let tx = Transaction::reopen(&path).map_err(|e| io_error_text(lang, &e))?;
                let preview = tx
                    .recovery_preview(&cancel)
                    .map_err(|e| io_error_text(lang, &e))?;
                Ok((tx, preview))
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                if !state.window.is_visible() || state.generation.get() != generation {
                    return;
                }
                state.busy(false);
                if state.cancel.borrow().check().is_err() {
                    state.status.set_text(lang.text(
                        "Prüfung abgebrochen. Dateien unverändert.",
                        "Inspection cancelled. Files unchanged.",
                    ));
                    return;
                }
                match result {
                    Ok((tx, preview)) => {
                        if let Some(ui) = state.ui.upgrade() {
                            if let Err(error) = session::remember_journal(&ui, tx.path().to_owned())
                            {
                                ui.status.set_text(&format!(
                                    "{} {error}",
                                    ui.lang.text(
                                        "Dateitransaktionsindex nicht gesichert:",
                                        "File transaction index not saved:"
                                    )
                                ));
                            }
                        }
                        *state.transaction.borrow_mut() = Some(tx);
                        state.publish(preview);
                    }
                    Err(error) => state.status.set_text(&error),
                }
            },
        );
    }
    fn publish(self: &Rc<Self>, preview: RecoveryPreview) {
        let labels: Vec<_> = preview
            .files()
            .iter()
            .map(|file| {
                format!(
                    "{} · {}",
                    project_view::display(file.path()),
                    match file.state() {
                        FileState::Original => self.lang().text("Originalstand", "Original state"),
                        FileState::Replaced => self.lang().text("ersetzt", "replaced"),
                        FileState::Conflict => self.lang().text("Konflikt", "Conflict"),
                    }
                )
            })
            .collect();
        let model = gtk::StringList::new(&labels.iter().map(String::as_str).collect::<Vec<_>>());
        let phase = preview.phase();
        *self.preview.borrow_mut() = Some(Arc::new(preview));
        self.consent.set_active(false);
        self.files.set_model(Some(&model));
        self.files.set_selected(0);
        self.offset.set_text("0");
        self.render();
        self.status.set_text(&format!(
            "{}: {} · {} {}",
            self.lang().text("Journalzustand", "Journal state"),
            phase_text(self.lang(), phase),
            labels.len(),
            self.lang().text(
                "Dateien. Beide vollständigen Fassungen vor der Freigabe prüfen.",
                "files. Review both complete versions before approval."
            )
        ));
        self.actions();
    }
    fn render(self: &Rc<Self>) {
        let Some(preview) = self.preview.borrow().clone() else {
            return;
        };
        let index = self.files.selected() as usize;
        if index >= preview.files().len() {
            return;
        }
        let Ok(offset) = self.offset.text().parse::<usize>() else {
            self.status.set_text(self.lang().text(
                "Bitte einen nichtnegativen Byteoffset eingeben.",
                "Enter a non-negative byte offset.",
            ));
            return;
        };
        self.render_generation.set(self.render_generation.get() + 1);
        self.render_ready.set(false);
        self.consent.set_sensitive(false);
        self.before.buffer().set_text("");
        self.after.buffer().set_text("");
        self.actions();
        let generation = self.render_generation.get();
        let weak = Rc::downgrade(self);
        let lang = self.lang();
        let exact = self.exact.is_active();
        git_view::background(
            move || {
                let file = &preview.files()[index];
                Ok((
                    side(file.current_bytes(), offset, lang, exact),
                    side(file.original_bytes(), offset, lang, exact),
                ))
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                if !state.window.is_visible() || state.render_generation.get() != generation {
                    return;
                }
                if let Ok(((before, before_label), (after, after_label))) = result {
                    state.render_ready.set(true);
                    state.consent.set_sensitive(!state.busy.get());
                    state.before.buffer().set_text(&before);
                    state.after.buffer().set_text(&after);
                    state.before_label.set_text(&format!(
                        "{} · {before_label}",
                        lang.text("Aktuell auf Platte", "Current on disk")
                    ));
                    state.after_label.set_text(&format!(
                        "{} · {after_label}",
                        lang.text("Original nach Rücknahme", "Original after restoration")
                    ));
                    state.actions();
                }
            },
        );
    }
    fn restore(self: &Rc<Self>) {
        if self.busy.get() || !self.render_ready.get() {
            return;
        }
        let Some(preview) = self.preview.borrow().clone() else {
            return;
        };
        if !self.consent.is_active() {
            return;
        }
        let Some(ui) = self.ui.upgrade() else { return };
        let paths: HashSet<_> = preview
            .files()
            .iter()
            .filter(|file| file.state() == FileState::Replaced)
            .map(|f| f.path().to_owned())
            .collect();
        if ui.documents.borrow().iter().any(|doc| {
            doc.snapshot
                .borrow()
                .as_ref()
                .is_some_and(|s| paths.contains(&s.path()))
                && (doc.buffer.is_modified() || doc.saving.get() || doc.is_rich_active())
        }) {
            self.status.set_text(self.lang().text("Betroffene offene Dateien zuerst speichern oder ihre Änderungen sichern. Editortext wird nicht überschrieben.","Save or preserve edits in affected open files first. Editor text will not be overwritten."));
            return;
        }
        let Some(mut tx) = self.transaction.borrow_mut().take() else {
            return;
        };
        self.preview.borrow_mut().take();
        self.render_generation.set(self.render_generation.get() + 1);
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        self.busy(true);
        let weak = Rc::downgrade(self);
        let lang = self.lang();
        git_view::background(
            move || {
                let result = tx.undo_approved(&preview, &cancel);
                drop(preview);
                let completed = result.and_then(|_| {
                    let cancel = Cancellation::default();
                    let snapshots = tx
                        .restored_snapshots(&cancel)?
                        .into_iter()
                        .filter(|snapshot| paths.contains(&snapshot.path()))
                        .collect();
                    let preview = tx.recovery_preview(&cancel)?;
                    Ok((snapshots, preview))
                });
                Ok((tx, completed))
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                if !state.window.is_visible() {
                    return;
                }
                state.consent.set_active(false);
                match result {
                    Ok((tx, completed)) => {
                        *state.transaction.borrow_mut() = Some(tx);
                        match completed {
                            Ok((snapshots, preview)) => {
                                if let Some(ui) = state.ui.upgrade() {
                                    ui.refresh_clean_documents(snapshots);
                                }
                                state.publish(preview);
                                state.status.set_text(lang.text("Originaldateien wiederhergestellt. Die Sicherung bleibt erhalten, bis Sie sie ausdrücklich entfernen.","Original files restored. Recovery data remains until you explicitly remove it."));
                            }
                            Err(error) => {
                                state.preview.borrow_mut().take();
                                state.status.set_text(&format!("{} {}",io_error_text(lang,&error),lang.text("Sicherung erhalten; vor einer weiteren Aktion neu prüfen.","Recovery data retained; inspect again before another action.")));
                            }
                        }
                    }
                    Err(error) => state.status.set_text(&error),
                }
                state.busy(false);
            },
        );
    }
    fn cleanup(self: &Rc<Self>) {
        if self.busy.get()
            || !self.render_ready.get()
            || !self.consent.is_active()
            || self
                .preview
                .borrow()
                .as_ref()
                .is_none_or(|p| p.phase() != Phase::Undone)
        {
            return;
        }
        let Some(tx) = self.transaction.borrow_mut().take() else {
            return;
        };
        let journal_path = tx.path().to_owned();
        self.preview.borrow_mut().take();
        self.busy(true);
        self.cancel_button.set_sensitive(false);
        let weak = Rc::downgrade(self);
        let lang = self.lang();
        git_view::background(
            move || {
                tx.discard(&Cancellation::default())
                    .map_err(|e| io_error_text(lang, &e))
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.busy(false);
                if result.is_ok() {
                    if let Some(ui) = state.ui.upgrade() {
                        session::forget_journal(&ui, &journal_path);
                    }
                }
                state.consent.set_active(false);
                state.before.buffer().set_text("");
                state.after.buffer().set_text("");
                state.files.set_model(None::<&gtk::StringList>);
                state.status.set_text(match &result {
                    Ok(()) => lang.text(
                        "Geprüfte Sicherung entfernt. Originaldateien unverändert.",
                        "Verified recovery data removed. Original files unchanged.",
                    ),
                    Err(error) => error,
                });
            },
        );
    }
}
fn phase_text(lang: Language, phase: Phase) -> &'static str {
    match phase {
        Phase::Prepared => lang.text("vorbereitet", "prepared"),
        Phase::Applying => lang.text("Anwendung unterbrochen", "application interrupted"),
        Phase::Applied => lang.text("angewendet", "applied"),
        Phase::Undoing => lang.text("Rücknahme unterbrochen", "restoration interrupted"),
        Phase::Undone => lang.text("Originale wiederhergestellt", "originals restored"),
    }
}
fn side(bytes: &[u8], offset: usize, lang: Language, exact: bool) -> (String, String) {
    if !exact && bytes.len() <= 4 * 1024 * 1024 {
        if let Ok(decoded) = fastra_core::encoding::decode(bytes, None) {
            if !decoded.text().contains('\0')
                && decoded.text().len() <= 4 * 1024 * 1024
                && !decoded
                    .text()
                    .split(['\r', '\n'])
                    .any(|line| line.len() > 64 * 1024)
            {
                return (
                    decoded.text().to_owned(),
                    format!(
                        "{} · {} {}",
                        document_view::format_text(&decoded, decoded.text(), lang),
                        bytes.len(),
                        lang.text("Bytes vollständig", "bytes complete")
                    ),
                );
            }
        }
    }
    let start = offset.min(bytes.len());
    let end = start.saturating_add(4096).min(bytes.len());
    let mut text = String::new();
    for (row, chunk) in bytes[start..end].chunks(16).enumerate() {
        text.push_str(&format!("{:08x}  ", start + row * 16));
        for b in chunk {
            text.push_str(&format!("{b:02x} "));
        }
        for _ in chunk.len()..16 {
            text.push_str("   ");
        }
        text.push_str(" │ ");
        for &b in chunk {
            text.push(if (32..127).contains(&b) {
                b as char
            } else {
                '.'
            });
        }
        text.push('\n');
    }
    (
        text,
        format!(
            "Hex · {start}–{end} / {} {} · {}",
            bytes.len(),
            lang.text("Bytes", "bytes"),
            lang.text(
                "alle Bereiche über Offset erreichbar",
                "all ranges available by offset"
            )
        ),
    )
}
pub fn open(ui: &Rc<Ui>) {
    open_inner(ui, None);
}
pub fn open_path(ui: &Rc<Ui>, path: PathBuf) {
    open_inner(ui, Some(path));
}
fn open_inner(ui: &Rc<Ui>, initial: Option<PathBuf>) {
    if !ui.window.is_visible() {
        return;
    }
    let lang = ui.lang;
    let window = git_view::window(
        ui,
        lang.text("Dateisicherungen wiederaufnehmen", "Resume file recovery"),
        true,
    );
    window.set_default_size(1000, 850);
    let root = git_view::column();
    let notice=git_view::label(lang.text("Wählen Sie ein von Fastra erzeugtes .fastra-transaction-Verzeichnis. Zuerst alle aktuellen und ursprünglichen Inhalte prüfen; erst die ausdrückliche Freigabe stellt Originale wieder her. Große oder binäre Daten sind vollständig über begrenzte Hexseiten erreichbar.","Choose a .fastra-transaction directory created by Fastra. Review all current and original contents first; only explicit approval restores originals. Large or binary data is fully available through bounded hex pages."));
    root.append(&notice);
    let path = gtk::Entry::builder()
        .hexpand(true)
        .placeholder_text(lang.text("Absoluter Sicherungspfad", "Absolute recovery path"))
        .build();
    let choose = gtk::Button::with_label(lang.text("Sicherung wählen …", "Choose recovery …"));
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    row.append(&path);
    row.append(&choose);
    root.append(&row);
    let controls = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(4)
        .row_spacing(4)
        .column_spacing(8)
        .build();
    let load = gtk::Button::with_label(lang.text("Vollständig prüfen", "Inspect completely"));
    let restore = gtk::Button::with_label(
        lang.text("Originaldateien wiederherstellen", "Restore original files"),
    );
    let cleanup = gtk::Button::with_label(lang.text(
        "Geprüfte Sicherung entfernen",
        "Remove verified recovery data",
    ));
    let cancel_button = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    for b in [&load, &restore, &cleanup, &cancel_button] {
        controls.insert(b, -1)
    }
    root.append(&controls);
    let status = git_view::label("");
    root.append(&status);
    let consent = gtk::CheckButton::with_label(lang.text(
        "Ich habe die vollständigen aktuellen und ursprünglichen Dateistände geprüft.",
        "I reviewed the complete current and original file states.",
    ));
    root.append(&consent);
    let files = git_view::file_dropdown();
    root.append(&files);
    let nav = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let previous = gtk::Button::with_label(lang.text("Vorheriger Bereich", "Previous range"));
    let next = gtk::Button::with_label(lang.text("Nächster Bereich", "Next range"));
    let offset = gtk::Entry::builder().text("0").width_chars(12).build();
    nav.append(&previous);
    nav.append(&gtk::Label::new(Some(
        lang.text("Byteoffset", "Byte offset"),
    )));
    nav.append(&offset);
    nav.append(&next);
    root.append(&nav);
    let exact = gtk::CheckButton::with_label(lang.text(
        "Alle Bytes exakt als Hex zeigen",
        "Show all bytes exactly as hex",
    ));
    exact.set_tooltip_text(Some(lang.text("Macht auch BOM, Unicode-Normalisierung und Zeilenenden eindeutig prüfbar. Alle Bytes sind über die Bereichsnavigation erreichbar.", "Makes BOM, Unicode normalization and line endings unambiguous. All bytes are accessible through range navigation.")));
    root.append(&exact);
    let before = git_view::output();
    let after = git_view::output();
    let before_label = git_view::label(lang.text("Aktuell auf Platte", "Current on disk"));
    let after_label =
        git_view::label(lang.text("Original nach Rücknahme", "Original after restoration"));
    let panes = gtk::Paned::new(gtk::Orientation::Horizontal);
    for (view, label, start) in [
        (&before, &before_label, true),
        (&after, &after_label, false),
    ] {
        let column = gtk::Box::new(gtk::Orientation::Vertical, 4);
        column.append(label);
        column.append(&git_view::scroll(view));
        if start {
            panes.set_start_child(Some(&column))
        } else {
            panes.set_end_child(Some(&column))
        }
    }
    git_view::balance_panes(&panes);
    panes.set_vexpand(true);
    root.append(&panes);
    window.set_child(Some(&root));
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        window: window.clone(),
        path,
        raw_path: RefCell::new(PathBuf::new()),
        setting_path: Cell::new(false),
        load,
        restore,
        cleanup,
        cancel_button,
        consent,
        exact,
        status,
        files,
        before,
        after,
        before_label,
        after_label,
        offset,
        previous,
        next,
        busy: Cell::new(false),
        generation: Cell::new(0),
        render_generation: Cell::new(0),
        render_ready: Cell::new(false),
        cancel: RefCell::new(Cancellation::default()),
        transaction: RefCell::new(None),
        preview: RefCell::new(None),
    });
    let weak = Rc::downgrade(&state);
    state.load.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.load();
        }
    });
    let weak = Rc::downgrade(&state);
    state.restore.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.restore();
        }
    });
    let weak = Rc::downgrade(&state);
    state.cleanup.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.cleanup();
        }
    });
    let weak = Rc::downgrade(&state);
    state.cancel_button.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.cancel.borrow().cancel();
        }
    });
    let weak = Rc::downgrade(&state);
    state.consent.connect_toggled(move |_| {
        if let Some(s) = weak.upgrade() {
            s.actions();
        }
    });
    let weak = Rc::downgrade(&state);
    state.exact.connect_toggled(move |_| {
        if let Some(s) = weak.upgrade() {
            s.consent.set_active(false);
            s.render();
        }
    });
    let weak = Rc::downgrade(&state);
    state.files.connect_selected_notify(move |_| {
        if let Some(s) = weak.upgrade() {
            s.offset.set_text("0");
            s.render();
        }
    });
    let weak = Rc::downgrade(&state);
    state.offset.connect_activate(move |_| {
        if let Some(s) = weak.upgrade() {
            s.render();
        }
    });
    for (button, forward) in [(&state.previous, false), (&state.next, true)] {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                let offset = s.offset.text().parse::<usize>().unwrap_or(0);
                s.offset.set_text(
                    &if forward {
                        offset.saturating_add(4096)
                    } else {
                        offset.saturating_sub(4096)
                    }
                    .to_string(),
                );
                s.render();
            }
        });
    }
    let weak = Rc::downgrade(&state);
    state.path.connect_changed(move |entry| {
        if let Some(s) = weak.upgrade() {
            if !s.setting_path.get() {
                *s.raw_path.borrow_mut() = PathBuf::from(entry.text().as_str());
            }
            s.clear();
        }
    });
    let weak = Rc::downgrade(&state);
    choose.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            let weak = Rc::downgrade(&s);
            gtk::FileDialog::new().select_folder(
                Some(&s.window),
                None::<&gio::Cancellable>,
                move |result| {
                    if let (Some(s), Ok(file)) = (weak.upgrade(), result) {
                        if !s.busy.get() && s.window.is_visible() {
                            if let Some(path) = file.path() {
                                s.set_path(path);
                            }
                        }
                    }
                },
            );
        }
    });
    let weak = Rc::downgrade(&state);
    window.connect_close_request(move |_|{if let Some(s)=weak.upgrade(){if s.busy.get(){s.cancel.borrow().cancel();s.status.set_text(s.lang().text("Vorgang wird beendet. Bitte das Ergebnis abwarten; Sicherungen bleiben erhalten.","Operation is ending. Wait for the result; recovery data is retained."));return glib::Propagation::Stop}}glib::Propagation::Proceed});
    git_view::hold(&window, state.clone(), |s| s.cancel.borrow().cancel());
    state.busy(false);
    window.present();
    if let Some(path) = initial {
        state.set_path(path);
        state.load();
    }
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_RECOVERY_SELFTEST").is_some() {
        run_selftest(state.clone());
    }
}

#[cfg(debug_assertions)]
fn run_selftest(state: Rc<State>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join(format!(
        "recovery-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&root).unwrap();
    let make = |name: &str, bytes: Vec<u8>| {
        let path = root.join(name);
        std::fs::write(&path, &bytes).unwrap();
        let c = Cancellation::default();
        let snapshot = fastra_io::Snapshot::read(&path, &c).unwrap();
        let decoded = fastra_core::encoding::decode(&bytes, None).unwrap();
        let request = SearchRequest {
            pattern: "old".into(),
            replacement: "new".into(),
            mode: SearchMode::Literal,
            case_sensitive: true,
            range: None,
        };
        let preview =
            fastra_core::preview(decoded.text(), 1, 1, &request, Limits::default(), &c).unwrap();
        let change = fastra_io::Change::from_preview(snapshot, &preview, 1, 1, &[0], &c).unwrap();
        let tx = Transaction::apply(vec![change], &c).unwrap().unwrap();
        let journal = tx.path().to_owned();
        drop(tx);
        (path, journal)
    };
    let original = vec![0xff, 0xfe, b'o', 0, b'l', 0, b'd', 0, 13, 0, 10, 0];
    let (path, journal) = make("utf16.txt", original.clone());
    let (stale, stale_journal) = make("stale.txt", b"old".to_vec());
    let ui = state.ui.upgrade().unwrap();
    ui.add_document("utf16.txt", "new\r\n");
    let doc = ui.active().unwrap();
    let snapshot = fastra_io::Snapshot::read(&path, &Cancellation::default()).unwrap();
    *doc.format.borrow_mut() =
        Arc::new(fastra_core::encoding::decode(snapshot.bytes(), None).unwrap());
    *doc.snapshot.borrow_mut() = Some(snapshot);
    state.path.set_text(stale_journal.to_str().unwrap());
    state.load.emit_clicked();
    git_view::test_size(&state.window);
    let painted = Cell::new(None);
    let stage = Cell::new(0);
    let start = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(60),
            "Recovery test timed out at {}: {}",
            stage.get(),
            state.status.text()
        );
        if state.busy.get() {
            return glib::ControlFlow::Continue;
        }
        match stage.get() {
            0 => {
                if !state.render_ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&state.before.buffer()), "new");
                if std::env::var_os("FASTRA_TOOL_SCREENSHOTS").is_some() {
                    let since = painted.get().unwrap_or_else(|| {
                        let now = std::time::Instant::now();
                        painted.set(Some(now));
                        now
                    });
                    if since.elapsed() < Duration::from_millis(300) {
                        return glib::ControlFlow::Continue;
                    }
                    git_view::capture(&state.window, "file-recovery");
                }

                assert_eq!(buffer_text(&state.after.buffer()), "old");
                assert!(!state.restore.is_sensitive());
                state.exact.set_active(true);
                assert!(!state.render_ready.get());
                assert!(!state.consent.is_active());
                stage.set(10);
            }
            10 => {
                if !state.render_ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(buffer_text(&state.before.buffer()).contains("6e 65 77"));
                assert!(buffer_text(&state.after.buffer()).contains("6f 6c 64"));
                state.exact.set_active(false);
                stage.set(11);
            }
            11 => {
                if !state.render_ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&state.before.buffer()), "new");
                std::fs::write(&stale, "EXTERNAL").unwrap();
                state.consent.set_active(true);
                state.restore.emit_clicked();
                stage.set(1);
            }
            1 => {
                assert!(state.preview.borrow().is_none());
                assert_eq!(std::fs::read(&stale).unwrap(), b"EXTERNAL");
                assert!(stale_journal.exists());
                state.path.set_text(journal.to_str().unwrap());
                state.load.emit_clicked();
                stage.set(2);
            }
            2 => {
                if !state.render_ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&state.before.buffer()), "new\r\n");
                assert_eq!(buffer_text(&state.after.buffer()), "old\r\n");
                doc.buffer.begin_user_action();
                doc.buffer.insert_at_cursor("dirty");
                doc.buffer.end_user_action();
                state.consent.set_active(true);
                state.restore.emit_clicked();
                assert!(!state.busy.get());
                assert!(state.preview.borrow().is_some());
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), "new\r\n");
                doc.buffer.set_modified(false);
                state.restore.emit_clicked();
                stage.set(3);
            }
            3 => {
                if !state.render_ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    state.preview.borrow().as_ref().unwrap().phase(),
                    Phase::Undone
                );
                assert_eq!(std::fs::read(&path).unwrap(), original);
                assert_eq!(buffer_text(&doc.buffer), "old\r\n");
                assert_eq!(
                    doc.format.borrow().encoding(),
                    fastra_core::encoding::Encoding::Utf16Le
                );
                assert!(!doc.buffer.is_modified());
                assert!(journal.exists());
                assert!(!state.cleanup.is_sensitive());
                state.consent.set_active(true);
                state.cleanup.emit_clicked();
                assert!(!state.cancel_button.is_sensitive());
                stage.set(4);
            }
            _ => {
                assert!(!journal.exists());
                assert_eq!(std::fs::read(&path).unwrap(), original);
                assert_eq!(std::fs::read(&stale).unwrap(), b"EXTERNAL");
                eprintln!("FASTRA_RECOVERY_SELFTEST_OK full-bound-preview/consent/stale-refused/dirty-editor-refused/utf16-bom/exact-editor-refresh/explicit-cleanup/exact-hex-display");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
        }
        glib::ControlFlow::Continue
    });
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn nul_and_long_lines_use_complete_bounded_hex_pages() {
        let data = vec![0; 9000];
        let (text, label) = side(&data, 4096, Language(false), false);
        assert!(!text.contains('\0'));
        assert!(label.contains("4096–8192 / 9000"));
        assert_eq!(text.lines().count(), 256);
        assert!(side("é\r\n".as_bytes(), 0, Language(false), true)
            .0
            .contains("c3 a9 0d 0a"));
        assert!(side("e\u{301}\n".as_bytes(), 0, Language(false), true)
            .0
            .contains("65 cc 81 0a"));
        assert!(side(&vec![b'x'; 65537], 0, Language(false), false)
            .1
            .starts_with("Hex"));
    }
}
