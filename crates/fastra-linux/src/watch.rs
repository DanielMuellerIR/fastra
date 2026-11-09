//! Externe Änderungen werden auf Workern gelesen und erst nach sichtbarer Freigabe übernommen.
use super::{buffer_text, git_view as support, Document, Ui};
use gtk::prelude::*;
use std::{
    cell::{Cell, RefCell},
    os::unix::fs::MetadataExt,
    rc::{Rc, Weak},
};

#[derive(Clone, Debug, PartialEq, Eq)]
struct Observation(u64, u64, u64, i64, i64, i64, i64);
fn observe(path: &std::path::Path) -> Result<Observation, String> {
    let m = std::fs::metadata(path).map_err(|e| e.to_string())?;
    if !m.is_file() {
        return Err("Not a regular file".into());
    }
    Ok(Observation(
        m.dev(),
        m.ino(),
        m.len(),
        m.mtime(),
        m.mtime_nsec(),
        m.ctime(),
        m.ctime_nsec(),
    ))
}
pub(super) struct State {
    ui: Weak<Ui>,
    doc: Weak<Document>,
    root: gtk::Box,
    message: gtk::Label,
    review: gtk::Button,
    busy: Cell<bool>,
    observation: RefCell<Option<Observation>>,
    baseline: Cell<Option<fastra_io::FileIdentity>>,
    candidate: RefCell<Option<fastra_document::TextDocument>>,
    generation: Cell<u64>,
    metadata_only: Cell<bool>,
    git_recheck: Cell<bool>,
}
impl State {
    fn check(self: &Rc<Self>) {
        self.check_scope(true);
    }
    fn check_scope(self: &Rc<Self>, active_only: bool) {
        if self.busy.get() {
            return;
        }
        let (Some(ui), Some(doc)) = (self.ui.upgrade(), self.doc.upgrade()) else {
            return;
        };
        if !ui.window.is_visible()
            || doc.is_read_only()
            || doc.saving.get()
            || (active_only && !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc)))
        {
            return;
        }
        let Some(snapshot) = doc.snapshot.borrow().clone() else {
            return;
        };
        let baseline = snapshot.file_identity();
        if self.baseline.get() != Some(baseline) {
            self.baseline.set(Some(baseline));
            self.observation.borrow_mut().take();
            self.candidate.borrow_mut().take();
            self.root.set_visible(false);
        }
        let prior = self.observation.borrow().clone();
        let path = snapshot.path();
        let encoding = doc.format.borrow().encoding();
        let weak = Rc::downgrade(self);
        self.busy.set(true);
        support::background(
            move || {
                let observation = observe(&path)?;
                if prior.as_ref() == Some(&observation) {
                    return Ok((observation, None));
                }
                let cancel = fastra_core::Cancellation::default();
                let loaded = fastra_document::Document::open(&path, Some(encoding), &cancel)
                    .map_err(|e| e.to_string())?;
                let fastra_document::Document::Text(text) = loaded else {
                    return Err("External source is no longer editable text".into());
                };
                text.verify_current(&cancel).map_err(|e| e.to_string())?;
                if text.text().contains('\0') {
                    return Err("External source contains NUL".into());
                }
                let unchanged = text
                    .snapshot()
                    .binding_digest()
                    .map_err(|e| e.to_string())?
                    == snapshot.binding_digest().map_err(|e| e.to_string())?
                    && text.snapshot().bytes() == snapshot.bytes();
                let metadata_only = text.snapshot().bytes() == snapshot.bytes();
                Ok((
                    observation,
                    if unchanged {
                        None
                    } else {
                        Some((text, metadata_only))
                    },
                ))
            },
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.busy.set(false);
                if state.git_recheck.replace(false) {
                    state.observation.borrow_mut().take();
                    state.check_scope(false);
                    return;
                }
                let Some(doc) = state.doc.upgrade() else {
                    return;
                };
                if doc.saving.get()
                    || doc.snapshot.borrow().as_ref().map(|s| s.file_identity()) != Some(baseline)
                {
                    return;
                }
                let Some(ui) = state.ui.upgrade() else { return };
                if !ui.window.is_visible() {
                    return;
                }
                match result {
                    Ok((observation, changed)) => {
                        *state.observation.borrow_mut() = Some(observation);
                        if let Some((text, metadata_only)) = changed {
                            state.metadata_only.set(metadata_only);
                            state.generation.set(state.generation.get() + 1);
                            *state.candidate.borrow_mut() = Some(text);
                            state.review.set_sensitive(true);
                            state.message.set_text(if metadata_only{ui.lang.text("Text unverändert; Dateiinformationen oder Dateibindung extern geändert. Editor bleibt bis zur Entscheidung erhalten.","Text unchanged; file metadata or source binding changed externally. Editor retained until you decide.")}else{ui.lang.text("Die Datei wurde extern geändert. Editortext bleibt bis zur Entscheidung erhalten.","The file changed externally. Editor text is retained until you decide.")});
                            state.root.set_visible(true);
                        }
                    }
                    Err(error) => {
                        state.generation.set(state.generation.get() + 1);
                        state.candidate.borrow_mut().take();
                        state.review.set_sensitive(false);
                        state.message.set_text(&format!("{}: {error}",ui.lang.text("Quelle fehlt, wurde umbenannt oder ist nicht lesbar. Editortext bleibt erhalten; keine automatische Pfadübernahme.","Source missing, renamed or unreadable. Editor text retained; no automatic path reassignment.")));
                        state.root.set_visible(true);
                    }
                }
            },
        );
    }
    fn preview(self: &Rc<Self>) {
        let (Some(ui), Some(doc)) = (self.ui.upgrade(), self.doc.upgrade()) else {
            return;
        };
        if doc.source_edits_locked() {
            self.message.set_text(ui.lang.text(
                "Zum Prüfen und Neuladen zuerst zum Quelltext wechseln.",
                "Return to source mode before reviewing and reloading.",
            ));
            return;
        }
        if doc.saving.get() {
            return;
        }
        let Some(candidate) = self.candidate.borrow_mut().take() else {
            return;
        };
        if candidate.text().len() > 4 * 1024 * 1024 || doc.buffer.char_count() > 4 * 1024 * 1024 {
            *self.candidate.borrow_mut() = Some(candidate);
            self.message.set_text(ui.lang.text(
                "Reload-Vorschau über 4 MiB. Editor erhalten; Datei separat neu öffnen.",
                "Reload preview exceeds 4 MiB. Editor retained; reopen the file separately.",
            ));
            return;
        }
        let expected_base = doc.snapshot.borrow().as_ref().map(|s| s.file_identity());
        let revision = doc.revision.get();
        let old = buffer_text(&doc.buffer);
        if old.len() > 4 * 1024 * 1024 {
            *self.candidate.borrow_mut() = Some(candidate);
            self.message.set_text(ui.lang.text(
                "Reload-Vorschau über 4 MiB. Editor erhalten; Datei separat neu öffnen.",
                "Reload preview exceeds 4 MiB. Editor retained; reopen the file separately.",
            ));
            return;
        }
        let generation = self.generation.get();
        let window = support::window(
            &ui,
            ui.lang
                .text("Externe Änderung prüfen", "Review external change"),
            true,
        );
        window.set_default_size(1000, 720);
        let root = support::column();
        root.append(&support::label(ui.lang.text("Links: aktueller Editor · Rechts: Dateistand. Neu laden ersetzt den gesamten Editortext.","Left: current editor · Right: disk version. Reload replaces the complete editor text.")));
        root.append(&support::label(&format!(
            "{} · {}",
            super::project_view::display(candidate.path()),
            super::document_view::format_text(candidate.decoded(), candidate.text(), ui.lang)
        )));
        if self.metadata_only.get() {
            root.append(&support::label(ui.lang.text("Originalbytes unverändert. Neu laden bestätigt eine neue Basis für Rechte, Zeitstempel, Zusatzattribute oder die Dateibindung.","Original bytes unchanged. Reload acknowledges a new base for permissions, timestamps, extended attributes or source binding.")));
        }
        let panes = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        for text in [&old, candidate.text()] {
            let view = support::output();
            view.buffer().set_text(text);
            let scroll = support::scroll(&view);
            scroll.set_width_request(250);
            panes.append(&scroll);
        }
        root.append(&panes);
        let consent = gtk::CheckButton::with_label(ui.lang.text(
            "Aktuellen Editortext durch die gezeigte Datei ersetzen",
            "Replace current editor text with the displayed file",
        ));
        root.append(&consent);
        let status = support::label("");
        root.append(&status);
        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let apply = gtk::Button::with_label(ui.lang.text("Neu laden", "Reload"));
        apply.set_sensitive(false);
        let keep = gtk::Button::with_label(ui.lang.text("Editor behalten", "Keep editor"));
        buttons.append(&apply);
        buttons.append(&keep);
        root.append(&buttons);
        window.set_child(Some(&root));
        let a = apply.clone();
        consent.connect_toggled(move |c| a.set_sensitive(c.is_active()));
        let candidate = Rc::new(RefCell::new(Some(candidate)));
        let weak = Rc::downgrade(self);
        let close = window.clone();
        let c = candidate.clone();
        keep.connect_clicked(move |_| {
            if let Some(state)=weak.upgrade(){if state.generation.get()==generation{
                *state.candidate.borrow_mut()=c.borrow_mut().take();
                state.message.set_text(ui.lang.text("Editor beibehalten. Externer Stand bleibt verschieden; sicheres Speichern verweigert die veraltete Basis.","Editor retained. Disk version still differs; safe save rejects the stale base."));
            }}close.close();
        });
        let weak = Rc::downgrade(self);
        let close = window.clone();
        let old = old.clone();
        let candidate_apply = candidate.clone();
        apply.connect_clicked(move |button| {
            let Some(state) = weak.upgrade() else { return };
            let (Some(ui), Some(doc)) = (state.ui.upgrade(), state.doc.upgrade()) else {
                return;
            };
            if !ui.window.is_visible()
                || state.generation.get() != generation
                || doc.revision.get() != revision
                || buffer_text(&doc.buffer) != old
                || doc.source_edits_locked()
                || doc.saving.get()
                || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
                || doc.snapshot.borrow().as_ref().map(|s| s.file_identity()) != expected_base
            {
                status.set_text(ui.lang.text(
                    "Vorschau veraltet. Editor unverändert; erneut prüfen.",
                    "Preview stale. Editor unchanged; review again.",
                ));
                return;
            }
            let Some(text) = candidate_apply.borrow_mut().take() else {
                return;
            };
            button.set_sensitive(false);
            let weak = Rc::downgrade(&state);
            let close = close.clone();
            let status = status.clone();
            let old = old.clone();
            support::background(
                move || {
                    text.verify_current(&fastra_core::Cancellation::default())
                        .map_err(|e| e.to_string())?;
                    Ok(text)
                },
                move |result| {
                    let Some(state) = weak.upgrade() else { return };
                    let (Some(ui), Some(doc)) = (state.ui.upgrade(), state.doc.upgrade()) else {
                        return;
                    };
                    match result {
                        Ok(text)
                            if ui.window.is_visible()
                                && state.generation.get() == generation
                                && doc.revision.get() == revision
                                && buffer_text(&doc.buffer) == old
                                && !doc.source_edits_locked()
                                && !doc.saving.get()
                                && ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
                                && doc.snapshot.borrow().as_ref().map(|s| s.file_identity())
                                    == expected_base =>
                        {
                            doc.buffer.begin_user_action();
                            let mut start = doc.buffer.start_iter();
                            let mut end = doc.buffer.end_iter();
                            doc.buffer.delete(&mut start, &mut end);
                            doc.buffer.insert(&mut start, text.text());
                            doc.buffer.end_user_action();
                            doc.line_endings.reset(text.text());
                            *doc.original.borrow_mut() = text.text().to_owned();
                            *doc.format.borrow_mut() = std::sync::Arc::new(text.decoded().clone());
                            *doc.snapshot.borrow_mut() = Some(text.snapshot().clone());
                            doc.buffer.set_modified(false);
                            doc.format_label
                                .set_text(&super::document_view::format_text(
                                    text.decoded(),
                                    text.text(),
                                    ui.lang,
                                ));
                            doc.update_label();
                            ui.invalidate();
                            state.baseline.set(None);
                            state.observation.borrow_mut().take();
                            state.root.set_visible(false);
                            close.close();
                        }
                        Ok(_) => status.set_text(ui.lang.text(
                            "Vorschau veraltet. Editor unverändert.",
                            "Preview stale. Editor unchanged.",
                        )),
                        Err(error) => {
                            state.observation.borrow_mut().take();
                            state.review.set_sensitive(false);
                            status.set_text(&format!(
                                "{}: {error}",
                                ui.lang.text(
                                    "Datei erneut geändert. Editor unverändert.",
                                    "File changed again. Editor unchanged."
                                )
                            ));
                        }
                    }
                },
            );
        });
        // Ein geschlossenes Vorschaufenster verliert nur seine Freigabe, niemals den Editortext.
        let weak = Rc::downgrade(self);
        let candidate = candidate.clone();
        window.connect_close_request(move |_| {
            if let Some(state) = weak.upgrade() {
                let current = state.generation.get() == generation;
                state.generation.set(state.generation.get() + 1);
                if current {
                    if let Some(text) = candidate.borrow_mut().take() {
                        *state.candidate.borrow_mut() = Some(text);
                    } else {
                        state.observation.borrow_mut().take();
                    }
                }
            }
            gtk::glib::Propagation::Proceed
        });
        window.present();
    }
}
pub(super) fn attach(ui: &Rc<Ui>, doc: &Rc<Document>) -> Rc<State> {
    let root = gtk::Box::new(gtk::Orientation::Vertical, 6);
    root.add_css_class("warning");
    let message = support::label("");
    let review = gtk::Button::with_label(
        ui.lang
            .text("Externe Änderung prüfen …", "Review external change …"),
    );
    root.append(&message);
    root.append(&review);
    root.set_visible(false);
    doc.container.prepend(&root);
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(doc),
        root,
        message,
        review: review.clone(),
        busy: Cell::new(false),
        observation: RefCell::new(None),
        baseline: Cell::new(None),
        candidate: RefCell::new(None),
        generation: Cell::new(0),
        metadata_only: Cell::new(false),
        git_recheck: Cell::new(false),
    });
    let weak = Rc::downgrade(&state);
    review.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.preview();
        }
    });
    let state2 = state.clone();
    gtk::glib::timeout_add_local(std::time::Duration::from_secs(2), move || {
        if state2.doc.upgrade().is_none()
            || state2.ui.upgrade().is_none_or(|ui| !ui.window.is_visible())
        {
            return gtk::glib::ControlFlow::Break;
        }
        state2.check();
        gtk::glib::ControlFlow::Continue
    });
    state.check();
    state
}

#[cfg(debug_assertions)]
fn descendants(widget: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
    all.push(widget.clone());
    let mut child = widget.first_child();
    while let Some(item) = child {
        descendants(&item, all);
        child = item.next_sibling();
    }
}
#[cfg(debug_assertions)]
fn controls(ui: &Ui) -> (gtk::Window, gtk::CheckButton, gtk::Button, gtk::Button) {
    let window = ui
        .window
        .application()
        .unwrap()
        .windows()
        .into_iter()
        .find(|w| w.transient_for().as_ref() == Some(ui.window.upcast_ref()))
        .expect("review window");
    let mut all = Vec::new();
    descendants(window.upcast_ref(), &mut all);
    let consent = all
        .iter()
        .find_map(|w| w.clone().downcast::<gtk::CheckButton>().ok())
        .unwrap();
    let button = |de, en| {
        all.iter()
            .filter_map(|w| w.clone().downcast::<gtk::Button>().ok())
            .find(|b| b.label().is_some_and(|t| t == de || t == en))
            .unwrap()
    };
    let apply = button("Neu laden", "Reload");
    let keep = button("Editor behalten", "Keep editor");
    (window, consent, apply, keep)
}
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    let fixture = std::path::PathBuf::from(std::env::var_os("FASTRA_PROJECT_FIXTURE").unwrap());
    let path = fixture.join("watched.txt");
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let deadline = std::time::Instant::now();
    let errored_at = Cell::new(None);
    gtk::glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
        assert!(
            deadline.elapsed() < std::time::Duration::from_secs(35),
            "watch timeout phase {}",
            phase.get()
        );
        let Some(doc) = ui.active() else {
            return gtk::glib::ControlFlow::Continue;
        };
        if doc
            .snapshot
            .borrow()
            .as_ref()
            .is_none_or(|s| s.path() != path)
        {
            return gtk::glib::ControlFlow::Continue;
        }
        let Some(state) = doc.watch.borrow().clone() else {
            return gtk::glib::ControlFlow::Continue;
        };
        if state.busy.get() {
            return gtk::glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                assert_eq!(buffer_text(&doc.buffer), "original café\r\n");
                std::fs::write(&path, doc.format.borrow().encode("disk café\r\n").unwrap())
                    .unwrap();
                state.check();
                phase.set(1);
            }
            1 => {
                if state.candidate.borrow().is_none() {
                    state.check();
                    return gtk::glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "original café\r\n");
                assert!(!doc.buffer.is_modified());
                state.review.emit_clicked();
                let (window, consent, apply, _) = controls(&ui);
                assert!(!apply.is_sensitive());
                consent.set_active(true);
                apply.emit_clicked();
                window.close();
                errored_at.set(Some(std::time::Instant::now()));
                phase.set(8);
            }
            2 => {
                if buffer_text(&doc.buffer) != "disk café\r\n" {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert!(!doc.buffer.is_modified());
                assert_eq!(
                    doc.snapshot.borrow().as_ref().unwrap().bytes(),
                    doc.format
                        .borrow()
                        .encode("disk café\r\n")
                        .unwrap()
                        .as_slice()
                );
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), "original café\r\n");
                assert!(doc.buffer.is_modified());
                std::fs::write(&path, doc.format.borrow().encode("second disk\n").unwrap())
                    .unwrap();
                state.check();
                phase.set(3);
            }
            3 => {
                if state.candidate.borrow().is_none() {
                    state.check();
                    return gtk::glib::ControlFlow::Continue;
                }
                state.review.emit_clicked();
                let (_, _, _, keep) = controls(&ui);
                keep.emit_clicked();
                assert_eq!(buffer_text(&doc.buffer), "original café\r\n");
                assert_eq!(
                    doc.snapshot.borrow().as_ref().unwrap().bytes(),
                    doc.format
                        .borrow()
                        .encode("disk café\r\n")
                        .unwrap()
                        .as_slice()
                );
                state.review.emit_clicked();
                let (window, consent, apply, _) = controls(&ui);
                let mut end = doc.buffer.end_iter();
                doc.buffer.insert(&mut end, "!");
                consent.set_active(true);
                apply.emit_clicked();
                assert_eq!(buffer_text(&doc.buffer), "original café\r\n!");
                window.close();
                phase.set(4);
            }
            4 => {
                state.review.emit_clicked();
                let (_, consent, apply, _) = controls(&ui);
                std::fs::write(&path, doc.format.borrow().encode("third disk\n").unwrap()).unwrap();
                consent.set_active(true);
                apply.emit_clicked();
                errored_at.set(Some(std::time::Instant::now()));
                phase.set(5);
            }
            5 => {
                if errored_at.get().unwrap().elapsed() < std::time::Duration::from_millis(350) {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "original café\r\n!");
                let (window, _, _, _) = controls(&ui);
                let mut all = Vec::new();
                descendants(window.upcast_ref(), &mut all);
                assert!(all
                    .iter()
                    .filter_map(|w| w.clone().downcast::<gtk::Label>().ok())
                    .any(|l| l
                        .text()
                        .contains(ui.lang.text("erneut geändert", "changed again"))));
                window.close();
                std::fs::rename(&path, fixture.join("renamed.txt")).unwrap();
                state.observation.borrow_mut().take();
                state.check();
                phase.set(6);
            }
            6 => {
                if !state.root.is_visible() || state.review.is_sensitive() {
                    state.check();
                    return gtk::glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "original café\r\n!");
                assert_eq!(doc.snapshot.borrow().as_ref().unwrap().path(), path);
                std::fs::write(
                    &path,
                    doc.format.borrow().encode("foreign replacement\n").unwrap(),
                )
                .unwrap();
                state.check();
                phase.set(7);
            }
            8 => {
                if errored_at.get().unwrap().elapsed() < std::time::Duration::from_millis(350) {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "original café\r\n");
                assert!(!doc.buffer.is_modified());
                state.check();
                phase.set(9);
            }
            9 => {
                if state.candidate.borrow().is_none() {
                    state.check();
                    return gtk::glib::ControlFlow::Continue;
                }
                state.review.emit_clicked();
                let (_, consent, apply, _) = controls(&ui);
                consent.set_active(true);
                apply.emit_clicked();
                phase.set(2);
            }
            _ => {
                if state.candidate.borrow().is_none() {
                    state.check();
                    return gtk::glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "original café\r\n!");
                assert_eq!(
                    doc.snapshot.borrow().as_ref().unwrap().bytes(),
                    doc.format
                        .borrow()
                        .encode("disk café\r\n")
                        .unwrap()
                        .as_slice()
                );
                state.review.emit_clicked();
                let (window, _, _, _) = controls(&ui);
                support::test_size(&window);
                support::finish(window, ui.clone(), "watch");
                return gtk::glib::ControlFlow::Break;
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}

#[cfg(debug_assertions)]
pub(super) fn lifetime_selftest(ui: Rc<Ui>) {
    let path = std::path::PathBuf::from(std::env::var_os("FASTRA_PROJECT_FIXTURE").unwrap())
        .join("watched.txt");
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let started = std::time::Instant::now();
    let hidden_at = Cell::new(None);
    let other = gtk::ApplicationWindow::builder()
        .application(&ui.window.application().unwrap())
        .title("Private second window")
        .build();
    gtk::glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
        assert!(started.elapsed() < std::time::Duration::from_secs(10));
        let Some(doc) = ui.active() else {
            return gtk::glib::ControlFlow::Continue;
        };
        if doc
            .snapshot
            .borrow()
            .as_ref()
            .is_none_or(|s| s.path() != path)
        {
            return gtk::glib::ControlFlow::Continue;
        }
        let state = doc.watch.borrow().clone().unwrap();
        if state.busy.get() {
            return gtk::glib::ControlFlow::Continue;
        }
        if phase.get() == 0 {
            other.present();
            ui.window.set_visible(false);
            std::fs::write(&path, "after close").unwrap();
            state.check();
            assert!(
                !state.busy.get(),
                "hidden retained Ui must not start a read"
            );
            hidden_at.set(Some(std::time::Instant::now()));
            phase.set(1);
        } else if hidden_at.get().unwrap().elapsed() > std::time::Duration::from_millis(2300) {
            assert!(state.candidate.borrow().is_none());
            assert!(!state.busy.get());
            println!("FASTRA_WATCH_LIFETIME_OK hidden-retained-owner/second-window/no-new-read");
            ui.window.application().unwrap().quit();
            return gtk::glib::ControlFlow::Break;
        }
        gtk::glib::ControlFlow::Continue
    });
}

#[cfg(debug_assertions)]
pub(super) fn metadata_selftest(ui: Rc<Ui>) {
    use std::os::unix::fs::PermissionsExt;
    let path = std::path::PathBuf::from(std::env::var_os("FASTRA_PROJECT_FIXTURE").unwrap())
        .join("watched.txt");
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let started = std::time::Instant::now();
    gtk::glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
        assert!(started.elapsed() < std::time::Duration::from_secs(15));
        let Some(doc) = ui.active() else {
            return gtk::glib::ControlFlow::Continue;
        };
        if doc
            .snapshot
            .borrow()
            .as_ref()
            .is_none_or(|s| s.path() != path)
        {
            return gtk::glib::ControlFlow::Continue;
        }
        let state = doc.watch.borrow().clone().unwrap();
        if state.busy.get() {
            return gtk::glib::ControlFlow::Continue;
        }
        if phase.get() == 0 {
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
            state.check();
            phase.set(1);
        } else {
            if state.candidate.borrow().is_none() {
                state.check();
                return gtk::glib::ControlFlow::Continue;
            }
            assert!(state.metadata_only.get());
            assert!(state.root.is_visible());
            assert_eq!(buffer_text(&doc.buffer), "unchanged café\r\n");
            assert!(!doc.buffer.is_modified());
            assert_eq!(
                state
                    .candidate
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .snapshot()
                    .bytes(),
                doc.snapshot.borrow().as_ref().unwrap().bytes()
            );
            state.review.emit_clicked();
            let (window, _, _, _) = controls(&ui);
            support::test_size(&window);
            support::finish(window, ui.clone(), "watch-metadata");
            return gtk::glib::ControlFlow::Break;
        }
        gtk::glib::ControlFlow::Continue
    });
}

/// Nach jedem Git-Wechselversuch alle offenen Quellen prüfen, ohne einen Puffer zu ersetzen.
pub(super) fn recheck_after_git(ui: &Rc<Ui>, root: &std::path::Path) {
    for doc in ui.documents.borrow().iter() {
        if !doc.disk_path().is_some_and(|path|path.starts_with(root)) { continue; }
        if let Some(view) = doc.section_view.borrow().as_ref() { view.after_git_attempt(); }
        if let Some(view) = doc.visual_view.borrow().as_ref() { view.after_git_attempt(); }
        if let Some(state) = doc.watch.borrow().as_ref() {
            state.generation.set(state.generation.get().wrapping_add(1));
            state.candidate.borrow_mut().take();
            state.review.set_sensitive(false);
            state.observation.borrow_mut().take();
            if state.busy.get() { state.git_recheck.set(true); } else { state.check_scope(false); }
        }
    }
}

pub(super) fn relocated(doc: &Document) {
    if let Some(state) = doc.watch.borrow().as_ref() {
        state.generation.set(state.generation.get().wrapping_add(1));
        state.candidate.borrow_mut().take();
        state.observation.borrow_mut().take();
        state.baseline.set(None);
        state.root.set_visible(false);
    }
}
