//! Historische Objekte bleiben rein lesend; keine Übernahme in Editor oder Arbeitsbaum.
use super::{git_view as support, project_view, Language, Ui};
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::{Rc, Weak},
    sync::Arc,
};
struct State {
    ui: Weak<Ui>,
    window: gtk::Window,
    root: PathBuf,
    repository_identity: Cell<Option<(u64, u64)>>,
    program: PathBuf,
    commits: gtk::DropDown,
    parents: gtk::DropDown,
    files: gtk::DropDown,
    reload: gtk::Button,
    cancel_button: gtk::Button,
    status: gtk::Label,
    graph: gtk::TextView,
    before: gtk::TextView,
    after: gtk::TextView,
    report: gtk::TextView,
    pages: gtk::Notebook,
    history: RefCell<Option<Arc<fastra_git::History>>>,
    changes: RefCell<Option<Arc<fastra_git::CommitChanges>>>,
    pair: RefCell<Option<fastra_git::HistoricalPair>>,
    changing: Cell<bool>,
    busy: Cell<bool>,
    generation: Cell<u64>,
    cancel: RefCell<fastra_git::Cancellation>,
    diff_cancel: RefCell<fastra_diff::Cancellation>,
    parent_handler: RefCell<Option<glib::SignalHandlerId>>,
    job_selection: Cell<(u32, u32, u32)>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
        self.diff_cancel.get_mut().cancel();
        if let (Some(ui), Some(id)) = (self.ui.upgrade(), self.parent_handler.get_mut().take()) {
            ui.window.disconnect(id);
        }
    }
}
fn visible(s: &str) -> String {
    s.chars().flat_map(|c|if c.is_control()&&!matches!(c,'\n'|'\t')||matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}'){c.escape_default().collect::<Vec<_>>()}else{vec![c]}).collect()
}
fn raw_path(bytes: &[u8]) -> String {
    use std::os::unix::ffi::OsStringExt;
    project_view::display(&PathBuf::from(std::ffi::OsString::from_vec(bytes.to_vec())))
}
fn blob_description(blob: &fastra_git::HistoricalBlob, lang: Language) -> String {
    let Some(oid) = &blob.oid else {
        return lang.text("nicht vorhanden", "absent").into();
    };
    if blob.mode == "160000" {
        format!(
            "{oid} · {}",
            lang.text("Gitlink; kein Blob gelesen", "Gitlink; no blob read")
        )
    } else {
        format!("{oid} · {} · {} B", blob.mode, blob.bytes.len())
    }
}
fn policy() -> fastra_git::Policy {
    fastra_git::Policy {
        stdout_bytes: 2 * 1024 * 1024,
        stderr_bytes: 64 * 1024,
        timeout: std::time::Duration::from_secs(15),
        ..Default::default()
    }
}
fn failure(e: fastra_git::Error, lang: Language) -> String {
    match e {
        fastra_git::Error::GitFailed(o)
        | fastra_git::Error::Cancelled(o)
        | fastra_git::Error::TimedOut(o)
        | fastra_git::Error::OutputLimit(o) => format!(
            "{} {:?}\n{}\n{}",
            lang.text(
                "Git-Aufruf beendet; keine vollständige Ansicht",
                "Git call ended; no complete view"
            ),
            o.exit_code,
            visible(&support::bytes(&o.stderr)),
            visible(&support::bytes(&o.stdout))
        ),
        other => format!(
            "{}: {other}",
            lang.text("Historie nicht verfügbar", "History unavailable")
        ),
    }
}
fn choices(drop: &gtk::DropDown, items: &[String]) {
    let model = gtk::StringList::new(&items.iter().map(String::as_str).collect::<Vec<_>>());
    drop.set_model(Some(&model));
    drop.set_selected(if items.is_empty() {
        gtk::INVALID_LIST_POSITION
    } else {
        0
    });
}
impl State {
    fn error(&self, text: &str) {
        self.pair.borrow_mut().take();
        self.before.buffer().set_text("");
        self.after.buffer().set_text("");
        self.report.buffer().set_text(text);
        self.pages.set_current_page(Some(2));
        self.status.set_text(self.lang().text(
            "Keine vollständige Ansicht. Vollständige Diagnose im Reiter Differenzblöcke.",
            "No complete view. Full diagnostic in the Difference blocks tab.",
        ));
    }
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |u| u.lang)
    }
    fn current(&self) -> bool {
        self.window.is_visible() && self.ui.upgrade().is_some_and(|u| u.window.is_visible())
    }
    fn busy(&self, value: bool) {
        self.busy.set(value);
        for w in [&self.commits, &self.parents, &self.files] {
            w.set_sensitive(!value);
        }
        self.reload.set_sensitive(!value);
        self.cancel_button.set_sensitive(value);
    }
    fn stop(&self) {
        self.cancel.borrow().cancel();
        self.diff_cancel.borrow().cancel();
    }
    fn job(&self) -> Option<(u64, fastra_git::Cancellation, fastra_diff::Cancellation)> {
        if self.busy.get() || !self.current() {
            return None;
        }
        self.stop();
        let cancel = fastra_git::Cancellation::default();
        let diff = fastra_diff::Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        *self.diff_cancel.borrow_mut() = diff.clone();
        let id = self.generation.get().wrapping_add(1);
        self.generation.set(id);
        self.job_selection.set((
            self.commits.selected(),
            self.parents.selected(),
            self.files.selected(),
        ));
        self.busy(true);
        self.status.set_text(
            self.lang()
                .text("Git-Objekte werden gelesen …", "Reading Git objects …"),
        );
        Some((id, cancel, diff))
    }
    fn completed(&self, id: u64) -> bool {
        if self.generation.get() != id {
            return false;
        }
        self.busy(false);
        self.current()
            && !self.cancel.borrow().is_cancelled()
            && self.job_selection.get()
                == (
                    self.commits.selected(),
                    self.parents.selected(),
                    self.files.selected(),
                )
    }
    fn load(self: &Rc<Self>) {
        let Some((id, cancel, _)) = self.job() else {
            return;
        };
        self.changes.borrow_mut().take();
        self.pair.borrow_mut().take();
        let root = self.root.clone();
        let program = self.program.clone();
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                let repo = fastra_git::Git::new(program)
                    .and_then(|g| g.discover(&root, policy(), &cancel))
                    .map_err(|e| failure(e, lang))?;
                let identity = repo.operation_identity().map_err(|e| failure(e, lang))?;
                repo.history(200, policy(), &cancel)
                    .map(|history| (identity, history))
                    .map_err(|e| failure(e, lang))
            },
            move |result| {
                let Some(s) = weak.upgrade() else { return };
                if !s.completed(id) {
                    return;
                }
                match result {
                    Ok((identity, history)) => {
                        s.repository_identity.set(Some(identity));
                        s.changing.set(true);
                        choices(
                            &s.commits,
                            &history
                                .commits
                                .iter()
                                .map(|c| {
                                    format!(
                                        "{} · {} · {}",
                                        &c.oid[..12],
                                        visible(&c.date),
                                        visible(&c.subject)
                                    )
                                })
                                .collect::<Vec<_>>(),
                        );
                        choices(&s.parents, &[]);
                        choices(&s.files, &[]);
                        s.graph.buffer().set_text(&format!(
                            "{}\n{}\n{}",
                            visible(&support::bytes(&history.graph.stdout)),
                            visible(&support::bytes(&history.graph.stderr)),
                            visible(&support::bytes(&history.metadata_output.stderr))
                        ));
                        *s.history.borrow_mut() = Some(Arc::new(history));
                        s.changing.set(false);
                        s.pages.set_current_page(Some(0));
                        s.commit();
                    }
                    Err(e) => s.error(&e),
                }
            },
        );
    }
    fn commit(self: &Rc<Self>) {
        if self.changing.get() {
            return;
        }
        let Some(history) = self.history.borrow().clone() else {
            return;
        };
        let Some(commit) = history
            .commits
            .get(self.commits.selected() as usize)
            .cloned()
        else {
            return;
        };
        self.changing.set(true);
        choices(
            &self.parents,
            &if commit.parents.is_empty() {
                vec![self
                    .lang()
                    .text(
                        "Root-Commit · leere Vorgängerseite",
                        "Root commit · empty previous side",
                    )
                    .into()]
            } else {
                commit
                    .parents
                    .iter()
                    .enumerate()
                    .map(|(i, p)| format!("{} · {}", i + 1, p))
                    .collect()
            },
        );
        self.changing.set(false);
        self.change();
    }
    fn change(self: &Rc<Self>) {
        if self.changing.get() {
            return;
        }
        let Some(history) = self.history.borrow().clone() else {
            return;
        };
        if history
            .commits
            .get(self.commits.selected() as usize)
            .is_none()
        {
            return;
        }
        let parent = self.parents.selected() as usize;
        let Some((id, cancel, _)) = self.job() else {
            return;
        };
        self.pair.borrow_mut().take();
        self.before.buffer().set_text("");
        self.after.buffer().set_text("");
        self.report.buffer().set_text("");
        self.changes.borrow_mut().take();
        let index = self.commits.selected() as usize;
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                history
                    .commit_changes(index, parent, policy(), &cancel)
                    .map_err(|e| failure(e, lang))
            },
            move |result| {
                let Some(s) = weak.upgrade() else { return };
                if !s.completed(id) {
                    return;
                }
                match result {
                    Ok(changes) => {
                        s.changing.set(true);
                        choices(
                            &s.files,
                            &changes
                                .changes()
                                .iter()
                                .map(|c| {
                                    format!(
                                        "{} · {} → {}",
                                        c.status,
                                        raw_path(c.old_path.bytes()),
                                        raw_path(c.new_path.bytes())
                                    )
                                })
                                .collect::<Vec<_>>(),
                        );
                        s.changing.set(false);
                        s.status.set_text(&format!(
                            "{} · {} {}\n{}",
                            changes.commit.oid,
                            changes.changes().len(),
                            s.lang().text(
                                "geänderte Pfade · nur historische Objekte",
                                "changed paths · historical objects only"
                            ),
                            visible(&support::bytes(&changes.output.stderr))
                        ));
                        *s.changes.borrow_mut() = Some(Arc::new(changes));
                    }
                    Err(e) => s.error(&e),
                }
            },
        );
    }
    fn file(self: &Rc<Self>) {
        if self.changing.get() {
            return;
        }
        let Some(changes) = self.changes.borrow().clone() else {
            return;
        };
        let selected = self.files.selected() as usize;
        if changes.changes().get(selected).is_none() {
            return;
        }
        let Some((id, cancel, diff_cancel)) = self.job() else {
            return;
        };
        self.pair.borrow_mut().take();
        self.before.buffer().set_text("");
        self.after.buffer().set_text("");
        self.report.buffer().set_text("");
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                let pair = changes
                    .pair(selected, policy(), &cancel)
                    .map_err(|e| failure(e, lang))?;
                let report = if let (Some(a), Some(b)) = (pair.before.text(), pair.after.text()) {
                    let comparison = fastra_diff::Comparison::compare(
                        fastra_diff::TextSnapshot {
                            document_id: pair.before.oid.clone().unwrap_or_else(|| "absent".into()),
                            revision: 0,
                            text: a.into(),
                        },
                        fastra_diff::TextSnapshot {
                            document_id: pair.after.oid.clone().unwrap_or_else(|| "absent".into()),
                            revision: 0,
                            text: b.into(),
                        },
                        id,
                        Default::default(),
                        fastra_diff::Limits {
                            max_text_bytes: 1024 * 1024,
                            max_lines: 50000,
                            max_report_bytes: 2 * 1024 * 1024,
                            max_memory_bytes: 64 * 1024 * 1024,
                            max_work: 5000000,
                            ..Default::default()
                        },
                        &diff_cancel,
                    )
                    .map_err(|e| e.to_string())?;
                    comparison
                        .report("parent blob", "commit blob", &diff_cancel)
                        .map_err(|e| e.to_string())?
                } else {
                    lang.text("Nichttextuelles Objekt: Binärdaten, ungültiges UTF-8, Symlink oder Submodul. Keine Textdifferenz vorgetäuscht.","Non-text object: binary data, invalid UTF-8, symlink or submodule. No text difference claimed.").into()
                };
                let report = format!(
                    "Commit: {}\nParent: {:?}\nAuthor: {}\nDate: {}\nSubject: {}\n{}\n{}",
                    changes.commit.oid,
                    changes.parent,
                    visible(&changes.commit.author),
                    visible(&changes.commit.date),
                    visible(&changes.commit.subject),
                    report,
                    pair.warnings
                        .iter()
                        .map(|w| visible(&support::bytes(w)))
                        .collect::<Vec<_>>()
                        .join("\n")
                );
                if report.len() > 2 * 1024 * 1024 {
                    return Err(lang
                        .text(
                            "Vollständiger Bericht überschreitet 2 MiB.",
                            "Complete report exceeds 2 MiB.",
                        )
                        .into());
                }
                Ok((pair, report))
            },
            move |result| {
                let Some(s) = weak.upgrade() else { return };
                if !s.completed(id) {
                    return;
                }
                match result {
                    Ok((pair, report)) => {
                        for (view, blob) in [(&s.before, &pair.before), (&s.after, &pair.after)] {
                            view.buffer().set_text(blob.text().unwrap_or(""));
                        }
                        s.report.buffer().set_text(&report);
                        s.status.set_text(&format!(
                            "{}: {}\n{}: {}",
                            s.lang().text("Vorher", "Before"),
                            blob_description(&pair.before, s.lang()),
                            s.lang().text("Nachher", "After"),
                            blob_description(&pair.after, s.lang())
                        ));
                        *s.pair.borrow_mut() = Some(pair);
                        s.pages.set_current_page(Some(1));
                    }
                    Err(e) => {
                        s.pair.borrow_mut().take();
                        s.before.buffer().set_text("");
                        s.after.buffer().set_text("");
                        s.report.buffer().set_text("");
                        s.error(&e);
                    }
                }
            },
        );
    }
}
pub(super) fn open(ui: &Rc<Ui>, program: PathBuf, root_path: PathBuf) {
    if !ui.window.is_visible() {
        return;
    }
    let lang = ui.lang;
    let window = support::window(
        ui,
        lang.text(
            "Git · Historie und Objektvergleich",
            "Git · History and object comparison",
        ),
        false,
    );
    window.set_default_size(960, 780);
    let root = support::column();
    root.append(&support::label(lang.text("Nur lokale Historie. Keine Dateien, Index oder Referenzen werden geändert. Bis 200 Commits/2000 Pfade; je Blob 1 MiB. Merge-Eltern ausdrücklich wählen. Kein Transfer in den Editor.","Local history only. No files, index or references are changed. Up to 200 commits/2000 paths; 1 MiB per blob. Choose merge parents explicitly. No transfer to editor.")));
    let path = support::label(&project_view::display(&root_path));
    path.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    path.set_max_width_chars(80);
    root.append(&path);
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let reload = gtk::Button::with_label(lang.text("Historie neu lesen", "Reload history"));
    let cancel_button = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    actions.append(&reload);
    actions.append(&cancel_button);
    root.append(&actions);
    let commits = support::file_dropdown();
    let parents = support::file_dropdown();
    let files = support::file_dropdown();
    for (title, drop) in [
        (lang.text("Commit", "Commit"), &commits),
        (
            lang.text("Vergleichselternteil", "Comparison parent"),
            &parents,
        ),
        (
            lang.text(
                "Geänderter Pfad · anklicken, dann Paar lesen",
                "Changed path · select, then read pair",
            ),
            &files,
        ),
    ] {
        root.append(&support::label(title));
        root.append(drop);
    }
    let read =
        gtk::Button::with_label(lang.text("Gewähltes Dateipaar lesen", "Read selected file pair"));
    root.append(&read);
    let status = support::label("");
    status.set_max_width_chars(90);
    status.set_lines(4);
    status.set_ellipsize(gtk::pango::EllipsizeMode::End);
    status.set_selectable(true);
    root.append(&status);
    let pages = gtk::Notebook::new();
    pages.set_vexpand(true);
    let graph = support::output();
    pages.append_page(
        &support::scroll(&graph),
        Some(&gtk::Label::new(Some(lang.text("Git-Graph", "Git graph")))),
    );
    let before = support::output();
    let after = support::output();
    let pair = gtk::Paned::new(gtk::Orientation::Horizontal);
    pair.set_start_child(Some(&support::scroll(&before)));
    pair.set_end_child(Some(&support::scroll(&after)));
    pair.add_tick_callback(|pane, _| {
        if pane.width() > 0 {
            pane.set_position(pane.width() / 2);
            glib::ControlFlow::Break
        } else {
            glib::ControlFlow::Continue
        }
    });
    pages.append_page(
        &pair,
        Some(&gtk::Label::new(Some(
            lang.text("Vorher / Nachher", "Before / After"),
        ))),
    );
    let report = support::output();
    pages.append_page(
        &support::scroll(&report),
        Some(&gtk::Label::new(Some(
            lang.text("Differenzblöcke", "Difference blocks"),
        ))),
    );
    root.append(&pages);
    window.set_child(Some(&root));
    let s = Rc::new(State {
        ui: Rc::downgrade(ui),
        window: window.clone(),
        root: root_path,
        repository_identity: Cell::new(None),
        program,
        commits,
        parents,
        files,
        reload: reload.clone(),
        cancel_button: cancel_button.clone(),
        status,
        graph,
        before,
        after,
        report,
        pages,
        history: RefCell::new(None),
        changes: RefCell::new(None),
        pair: RefCell::new(None),
        changing: Cell::new(false),
        busy: Cell::new(false),
        generation: Cell::new(0),
        cancel: RefCell::new(Default::default()),
        diff_cancel: RefCell::new(Default::default()),
        parent_handler: RefCell::new(None),
        job_selection: Cell::new((0, 0, 0)),
    });
    for (drop, action) in [(&s.commits, 0), (&s.parents, 1)] {
        let weak = Rc::downgrade(&s);
        drop.connect_selected_notify(move |_| {
            if let Some(s) = weak.upgrade() {
                if action == 0 {
                    s.commit();
                } else {
                    s.change();
                }
            }
        });
    }
    let weak = Rc::downgrade(&s);
    s.files.connect_selected_notify(move |_| {
        if let Some(s) = weak.upgrade() {
            if !s.changing.get() {
                s.stop();
                s.pair.borrow_mut().take();
                s.before.buffer().set_text("");
                s.after.buffer().set_text("");
                s.report.buffer().set_text("");
                s.status.set_text(s.lang().text(
                    "Dateiauswahl geändert. Gewähltes Paar ausdrücklich lesen.",
                    "File selection changed. Explicitly read the selected pair.",
                ));
            }
        }
    });
    let weak = Rc::downgrade(&s);
    read.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.file();
        }
    });
    let weak = Rc::downgrade(&s);
    reload.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.load();
        }
    });
    let weak = Rc::downgrade(&s);
    cancel_button.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.stop();
            s.status.set_text(s.lang().text(
                "Abbruch angefordert; keine alten Teilansichten werden übernommen.",
                "Cancellation requested; no stale partial view will be adopted.",
            ));
        }
    });
    let weak = Rc::downgrade(&s);
    *s.parent_handler.borrow_mut() = Some(ui.window.connect_visible_notify(move |w| {
        if !w.is_visible() {
            if let Some(s) = weak.upgrade() {
                s.stop();
                s.window.close();
            }
        }
    }));
    let weak = Rc::downgrade(&s);
    super::git_fetch::observe(&window, move |root, identity| {
        if let Some(s) = weak.upgrade() {
            if s.repository_identity.get() == Some(identity) || s.root.starts_with(root) {
                s.stop();
                s.busy(false);
                s.load();
            }
        }
    });
    support::hold(&window, s.clone(), State::stop);
    window.present();
    s.load();
    #[cfg(debug_assertions)]
    if std::env::var_os("FASTRA_GIT_HISTORY_SELFTEST").is_some() {
        gui_test::run(s);
    }
}
#[cfg(debug_assertions)]
mod gui_test;

#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::start(ui);
}
