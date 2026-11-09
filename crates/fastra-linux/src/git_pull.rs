//! Expliziter nativer Pull; Editorpuffer bleiben bis zum geschützten Reload erhalten.
use super::{git_fetch, git_view as support, project_view, watch, Language, Ui};
use gtk::{glib, prelude::*};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::{Rc, Weak},
    sync::mpsc,
    time::Duration,
};
static PENDING: AtomicUsize = AtomicUsize::new(0);
pub(super) fn pending() -> bool {
    PENDING.load(Ordering::SeqCst) != 0
}
pub(super) fn can_close(ui: &Ui) -> bool {
    if !pending() {
        return true;
    }
    ui.status.set_text(ui.lang.text("Git-Pull läuft noch; Abbruch und vollständige Nachprüfung abwarten, dann erneut schließen.","Git pull is still running; wait for cancellation and the complete post-check, then close again."));
    false
}
pub(super) fn write_allowed(ui: &Ui) -> bool {
    if !pending() {
        return true;
    }
    ui.status.set_text(ui.lang.text("Git-Pull und Nachprüfung laufen noch. Dateiaktion danach ausdrücklich erneut starten.","Git pull and its post-check are still running. Explicitly retry the file action afterwards."));
    false
}
struct Pending {
    _hold: Option<gtk::gio::ApplicationHoldGuard>,
}
impl Drop for Pending {
    fn drop(&mut self) {
        assert!(PENDING.fetch_sub(1, Ordering::SeqCst) > 0);
    }
}
fn background<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
    done: impl FnOnce(Result<T, String>) + 'static,
) {
    PENDING.fetch_add(1, Ordering::SeqCst);
    let pending = Pending {
        _hold: gtk::gio::Application::default().map(|app| app.hold()),
    };
    support::background(work, move |result| {
        let finish = move || {
            let _pending = pending;
            done(result);
        };
        #[cfg(debug_assertions)]
        if let Some(root) = std::env::var_os("FASTRA_GIT_PULL_RECEIPT_TEST_DIR") {
            let root = std::path::PathBuf::from(root);
            if root.join("pause-main").exists() {
                assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                std::fs::write(
                    root.join("ready-main"),
                    b"worker and postscan finished; Main receipt pending",
                )
                .unwrap();
                let mut finish = Some(finish);
                let started = std::time::Instant::now();
                glib::timeout_add_local(Duration::from_millis(20), move || {
                    assert!(started.elapsed() < Duration::from_secs(35));
                    if root.join("release-main").exists() {
                        finish.take().unwrap()();
                        glib::ControlFlow::Break
                    } else {
                        glib::ControlFlow::Continue
                    }
                });
                return;
            }
        }
        finish();
    });
}
thread_local! {static DIALOGS:RefCell<Vec<Weak<State>>>=const{RefCell::new(Vec::new())};}
pub(super) fn invalidate_owner(ui: &Ui) {
    DIALOGS.with_borrow_mut(|all| {
        all.retain(|w| {
            let Some(s) = w.upgrade() else {
                return false;
            };
            if s.ui.upgrade().is_some_and(|u| std::ptr::eq(u.as_ref(), ui)) {
                s.owner_changed();
            }
            true
        })
    });
}
struct Loaded {
    repository: fastra_git::Repository,
    identity: (u64, u64),
}
pub(super) struct State {
    ui: Weak<Ui>,
    window: gtk::Window,
    program: PathBuf,
    path: PathBuf,
    owner: RefCell<Option<git_fetch::Owner>>,
    loaded: RefCell<Option<Loaded>>,
    basis: gtk::Label,
    target: gtk::DropDown,
    branch: gtk::Entry,
    strategy: gtk::DropDown,
    targets: RefCell<Vec<Vec<u8>>>,
    changing: Cell<bool>,
    reload: gtk::Button,
    prepare: gtk::Button,
    approved: gtk::CheckButton,
    start: gtk::Button,
    cancel: gtk::Button,
    status: gtk::Label,
    output: gtk::TextView,
    preview: RefCell<Option<fastra_git::PullPreview>>,
    cancellation: RefCell<fastra_git::Cancellation>,
    generation: Cell<u64>,
    job: Cell<Option<u64>>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.cancellation.get_mut().cancel();
    }
}
fn refreshed(owner: Option<Rc<Ui>>, root: &std::path::Path, identity: (u64, u64)) {
    let Some(mut windows) = super::application_lifecycle::ordinary_windows() else {
        let root = root.to_owned();
        glib::idle_add_local_once(move || refreshed(owner, &root, identity));
        return;
    };
    if let Some(owner) = owner {
        if !windows.iter().any(|window| Rc::ptr_eq(window, &owner)) {
            windows.push(owner);
        }
    }
    for ui in windows {
        watch::recheck_after_git(&ui, root);
    }
    git_fetch::refreshed(root, identity);
}
fn policy() -> fastra_git::Policy {
    fastra_git::Policy {
        stdout_bytes: 4 * 1024 * 1024,
        stderr_bytes: 128 * 1024,
        timeout: Duration::from_secs(30),
        ..Default::default()
    }
}
fn visible(bytes: &[u8]) -> String {
    support::bytes(bytes).chars().flat_map(|c|if(c.is_control()&&!matches!(c,'\n'|'\t'))||matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}'){c.escape_default().collect::<Vec<_>>()}else{vec![c]}).collect()
}
fn error(e: fastra_git::Error, lang: Language) -> String {
    visible(support::error(e, lang).as_bytes())
}
fn output(out: &fastra_git::GitOutput) -> String {
    format!("{}{}", visible(&out.stdout), visible(&out.stderr))
}
fn state_text(state: &fastra_git::SwitchState, lang: Language) -> String {
    format!(
        "HEAD · {}\n{}\n\n{}\n{}\n\n{}\n{}\n\n{}\n{}",
        state
            .status
            .value
            .branch
            .as_deref()
            .map(visible)
            .unwrap_or_else(|| lang.text("Losgelöst", "Detached").into()),
        state
            .status
            .value
            .head_oid
            .as_deref()
            .map(visible)
            .unwrap_or_else(|| "—".into()),
        lang.text("Status (Git Porcelain)", "Status (Git porcelain)"),
        state
            .status
            .output
            .stdout
            .split(|b| *b == 0)
            .map(|record| visible(record).replace('\n', "\\n").replace('\t', "\\t"))
            .collect::<Vec<_>>()
            .join("\n")
            + &visible(&state.status.output.stderr),
        lang.text("Index gegen HEAD", "Index against HEAD"),
        output(&state.staged),
        lang.text("Arbeitsdateien gegen Index", "Working files against index"),
        output(&state.working)
    )
}
impl State {
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |u| u.lang)
    }
    fn document_jobs_idle(ui: &Ui) -> bool {
        !ui.close_committed.get()
            && !super::close_protocol::active(ui)
            && ui.documents.try_borrow().is_ok_and(|docs| {
                docs.iter().all(|doc| {
                    !doc.saving.get()
                        && !doc.close_pending.get()
                        && !doc
                            .rich
                            .borrow()
                            .as_ref()
                            .is_some_and(|rich| rich.active.get() || rich.pending())
                        && !doc
                            .hex_editor
                            .borrow()
                            .as_ref()
                            .is_some_and(|hex| hex.pending())
                })
            })
    }
    fn available(ui: &Ui) -> bool {
        !super::asset_io::pending()
            && !super::folder::any_busy()
            && Self::document_jobs_idle(ui)
            && super::application_lifecycle::ordinary_windows().is_some_and(|windows| {
                windows
                    .iter()
                    .all(|window| Self::document_jobs_idle(window))
            })
    }
    fn blocked(&self) -> &'static str {
        self.lang().text("Laufenden Datei-/Speicher-/Schließvorgang zuerst abschließen und Rich-Text in den Quellmodus übernehmen. Danach neu laden.","Finish file, save or close operations and return rich text to source mode first. Then reload.")
    }
    fn owned(&self) -> bool {
        self.window.is_visible()
            && self.ui.upgrade().is_some_and(|ui| {
                self.owner
                    .borrow()
                    .as_ref()
                    .is_some_and(|owner| owner.current(&ui))
                    && Self::available(&ui)
            })
    }
    fn controls(&self) {
        let busy = self.job.get().is_some();
        let ready = !busy && self.owned() && self.loaded.borrow().is_some();
        self.reload.set_sensitive(!busy);
        self.target.set_sensitive(ready);
        self.branch.set_sensitive(ready);
        self.strategy.set_sensitive(ready);
        self.prepare.set_sensitive(
            ready
                && self
                    .targets
                    .borrow()
                    .get(self.target.selected() as usize)
                    .is_some(),
        );
        self.approved
            .set_sensitive(ready && self.preview.borrow().is_some());
        self.start
            .set_sensitive(ready && self.preview.borrow().is_some() && self.approved.is_active());
        self.cancel.set_sensitive(busy);
    }
    fn invalidate(&self, message: &str) {
        self.cancellation.borrow().cancel();
        self.generation.set(self.generation.get().wrapping_add(1));
        self.preview.borrow_mut().take();
        self.approved.set_active(false);
        self.output.buffer().set_text("");
        self.status.set_text(message);
        self.controls();
    }
    fn owner_changed(&self) {
        if self.owner.borrow_mut().take().is_some() {
            self.loaded.borrow_mut().take();
            let message = if self.ui.upgrade().is_some_and(|ui| !Self::available(&ui)) {
                self.blocked()
            } else {
                self.lang().text(
                    "Fenster, Dokument oder Projekt geändert. Neu laden.",
                    "Window, document or project changed. Reload.",
                )
            };
            self.invalidate(message);
        }
    }
    fn begin(&self, message: &str) -> (u64, fastra_git::Cancellation) {
        self.invalidate(message);
        let c = fastra_git::Cancellation::default();
        *self.cancellation.borrow_mut() = c.clone();
        let id = self.generation.get();
        self.job.set(Some(id));
        self.controls();
        (id, c)
    }
    fn finished(&self, id: u64) -> bool {
        if self.job.get() == Some(id) {
            self.job.set(None);
        }
        self.controls();
        self.generation.get() == id && self.owned()
    }
    fn project(&self) -> Option<project_view::RootBinding> {
        self.owner
            .borrow()
            .as_ref()
            .and_then(git_fetch::Owner::project_root)
    }
    fn catalogue(&self, catalogue: Vec<Vec<u8>>) {
        self.changing.set(true);
        let mut labels = Vec::new();
        let mut targets = Vec::new();
        for remote in catalogue {
            labels.push(visible(&remote));
            targets.push(remote);
        }
        self.target.set_model(Some(&gtk::StringList::new(
            &labels.iter().map(String::as_str).collect::<Vec<_>>(),
        )));
        *self.targets.borrow_mut() = targets;
        self.target.set_selected(if labels.is_empty() {
            gtk::INVALID_LIST_POSITION
        } else {
            0
        });
        self.changing.set(false);
    }
    fn load(self: &Rc<Self>) {
        if self.job.get().is_some() {
            return;
        }
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        if !Self::available(&ui) {
            self.invalidate(self.blocked());
            return;
        }
        let owner = git_fetch::Owner::capture(&ui);
        if !owner.current(&ui) {
            return;
        }
        *self.owner.borrow_mut() = Some(owner);
        self.loaded.borrow_mut().take();
        let project = self.project();
        let (id, c) = self.begin(
            self.lang()
                .text("Remotes werden gelesen …", "Reading remotes …"),
        );
        let path = self.path.clone();
        let program = self.program.clone();
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        background(
            move || {
                if let Some(p) = project {
                    p.validate()?;
                }
                let r = fastra_git::Git::new(program)
                    .and_then(|g| g.discover(&path, policy(), &c))
                    .map_err(|e| error(e, lang))?;
                let identity = r.operation_identity().map_err(|e| error(e, lang))?;
                let cat = r.remotes(policy(), &c).map_err(|e| error(e, lang))?;
                let status = r.status(policy(), &c).map_err(|e| error(e, lang))?.value;
                let matched = status.upstream.as_ref().and_then(|up| {
                    cat.value
                        .iter()
                        .enumerate()
                        .filter(|(_, remote)| up.starts_with(&[remote.as_slice(), b"/"].concat()))
                        .max_by_key(|(_, remote)| remote.len())
                        .map(|(index, remote)| (index, up[remote.len() + 1..].to_vec()))
                });
                let (selected, branch) =
                    matched.unwrap_or_else(|| (0, status.branch.unwrap_or_default()));
                let branch = String::from_utf8(branch).map_err(|_| {
                    lang.text(
                        "Quellbranch bitte ausdrücklich eingeben.",
                        "Enter the source branch explicitly.",
                    )
                    .to_owned()
                })?;
                Ok((
                    Loaded {
                        repository: r,
                        identity,
                    },
                    cat,
                    selected,
                    branch,
                ))
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if !s.finished(id) {
                    return;
                }
                match result {
                    Ok((loaded, cat, selected, branch)) => {
                        s.basis.set_text(&format!(
                            "Repository\n{}",
                            project_view::display(loaded.repository.root())
                        ));
                        s.catalogue(cat.value);
                        s.target.set_selected(selected as u32);
                        s.branch.set_text(&branch);
                        *s.loaded.borrow_mut() = Some(loaded);
                        s.status.set_text(s.lang().text(
                            "Remote, Quellbranch und Strategie wählen; dann Quelle abrufen und Vorschau erstellen.",
                            "Choose remote, source branch and strategy; then fetch source and prepare a preview.",
                        ));
                    }
                    Err(e) => s.output.buffer().set_text(&e),
                }
                s.controls();
            },
        );
    }
    fn prepare(self: &Rc<Self>) {
        if !self.owned() || self.job.get().is_some() {
            return;
        }
        let Some(target) = self
            .targets
            .borrow()
            .get(self.target.selected() as usize)
            .cloned()
        else {
            return;
        };
        let Some((r, identity)) = self
            .loaded
            .borrow()
            .as_ref()
            .map(|l| (l.repository.clone(), l.identity))
        else {
            return;
        };
        let branch = self.branch.text().as_bytes().to_vec();
        let strategy = match self.strategy.selected() {
            1 => fastra_git::PullStrategy::Merge,
            2 => fastra_git::PullStrategy::Rebase,
            _ => fastra_git::PullStrategy::FastForwardOnly,
        };
        let project = self.project();
        let (id, c) = self.begin(self.lang().text(
            "Quelle wird abgerufen; Pullvorschau wird vorbereitet …",
            "Fetching source and preparing pull preview …",
        ));
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        let root = r.root().to_owned();
        let ui = self.ui.clone();
        background(
            move || {
                if let Some(p) = project {
                    p.validate()?;
                }
                if r.operation_identity().map_err(|e| error(e, lang))? != identity {
                    return Err(error(fastra_git::Error::StaleRepository, lang));
                }
                r.prepare_pull(target, branch, strategy, policy(), &c, &mut |_| {})
                    .map_err(|e| error(e, lang))
            },
            move |result| {
                refreshed(ui.upgrade(), &root, identity);
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if !s.finished(id) {
                    return;
                }
                match result {
                    Ok(p) => {
                        let source = format!(
                            "{}\nFETCH_HEAD · {}",
                            state_text(&p.source().files, s.lang()),
                            p.source()
                                .fetched_oid
                                .as_deref()
                                .map(visible)
                                .unwrap_or_else(|| "—".into())
                        );
                        let strategy = match p.strategy() {
                            fastra_git::PullStrategy::FastForwardOnly => {
                                s.lang().text("Nur Fast-Forward", "Fast-forward only")
                            }
                            fastra_git::PullStrategy::Merge => "Merge",
                            fastra_git::PullStrategy::Rebase => "Rebase",
                        };
                        s.output.buffer().set_text(&format!("Repository\n{}\n\nRemote · {}\n{}\nBranch · {}\n{}\n\n{}\n{}\n\n{}\n{}\n\n{}\n{}\n\n{}\n{}",
                            project_view::display(p.root()),visible(p.remote()),p.address_display(),visible(p.branch()),strategy,
                            s.lang().text("Ausgangszustand und geholte vollständige Quell-ID","Source state and complete fetched source ID"),source,
                            s.lang().text("Vollständige eingehende Commit-Patches","Complete incoming commit patches"),output(p.incoming()),
                            s.lang().text("Vollständige lokale Commit-Patches","Complete local commit patches"),output(p.local()),
                            s.lang().text("Vollständiger Commit-Unterschied HEAD → geholte Quelle (kein endgültiger Merge-/Rebase-Dateistand)","Complete commit difference HEAD → fetched source (not the final merge/rebase file state)"),output(p.delta())));
                        *s.preview.borrow_mut() = Some(p);
                        s.status.set_text(s.lang().text(
                            "Quelle, Ziel und Unterschiede prüfen und ausdrücklich bestätigen.",
                            "Review source, target and differences, then explicitly approve.",
                        ));
                    }
                    Err(e) => {
                        s.output.buffer().set_text(&e);
                        s.status.set_text(s.lang().text(
                            "Keine freigegebene Vorschau. Diagnose prüfen.",
                            "No approved preview. Review the diagnostic.",
                        ));
                    }
                }
                s.controls();
            },
        );
    }
    fn execute(self: &Rc<Self>) {
        if !self.owned() || self.job.get().is_some() || !self.approved.is_active() {
            return;
        }
        let Some(preview) = self.preview.borrow_mut().take() else {
            return;
        };
        let Some(identity) = self.loaded.borrow().as_ref().map(|l| l.identity) else {
            return;
        };
        let root = preview.root().to_owned();
        let project = self.project();
        let (id, c) = self.begin(self.lang().text("Git führt Pull aus …", "Git is pulling …"));
        let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(16);
        let weak = Rc::downgrade(self);
        let mut live = Vec::new();
        glib::timeout_add_local(Duration::from_millis(30), move || {
            let Some(s) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if s.job.get() != Some(id) || s.generation.get() != id {
                return glib::ControlFlow::Break;
            }
            while let Ok(bytes) = rx.try_recv() {
                let left = (128 * 1024usize).saturating_sub(live.len());
                live.extend_from_slice(&bytes[..bytes.len().min(left)]);
            }
            s.output.buffer().set_text(&visible(&live));
            glib::ControlFlow::Continue
        });
        let weak = Rc::downgrade(self);
        let ui = self.ui.clone();
        background(
            move || {
                if let Some(p) = project {
                    if p.validate().is_err() {
                        c.cancel();
                    }
                }
                let report = preview.execute(policy(), &c, &mut |b| {
                    let _ = tx.try_send(b.to_vec());
                });
                Ok(report)
            },
            move |result| {
                refreshed(ui.upgrade(), &root, identity);
                let Some(s) = weak.upgrade() else {
                    return;
                };
                let current = s.finished(id);
                match result {
                    Ok(report) => {
                        let reached = report.integrated();
                        let success = report.result.is_ok() && current;
                        let mut text = match report.result {
                            Ok(out) => format!("Exit 0\n{}", output(&out)),
                            Err(e) => error(e, s.lang()),
                        };
                        text.push_str(&format!(
                            "\n\nRepository\n{}\n\n",
                            project_view::display(&root)
                        ));
                        text.push_str(s.lang().text(
                            "Tatsächlich nach dem Versuch gelesen\n",
                            "Actual state read after the attempt\n",
                        ));
                        if let Err(problem) = report.integration {
                            text.push_str(&error(problem, s.lang()));
                            text.push_str("\n\n");
                        }
                        match report.state {
                            Ok(state) => {
                                text.push_str(&state_text(&state.files, s.lang()));
                                text.push_str(&format!(
                                    "\n{}: {:?}\nFETCH_HEAD: {}",
                                    s.lang().text("Laufende Git-Vorgänge", "Git operations"),
                                    state.operations,
                                    state
                                        .fetched_oid
                                        .as_deref()
                                        .map(visible)
                                        .unwrap_or_else(|| "—".into())
                                ));
                            }
                            Err(e) => text.push_str(&error(e, s.lang())),
                        }
                        text.push_str(s.lang().text("\n\nVollständiger nachgelesener Commit-Unterschied ursprünglicher HEAD → tatsächlicher HEAD (auch fremde Änderungen können enthalten sein)\n","\n\nComplete observed commit difference original HEAD → actual HEAD (may also include external changes)\n"));
                        match report.delta {
                            Ok(delta) => text.push_str(&output(&delta)),
                            Err(problem) => text.push_str(&error(problem, s.lang())),
                        }
                        s.output.buffer().set_text(&text);
                        s.loaded.borrow_mut().take();
                        s.status.set_text(if !current{s.lang().text("Ursprünglicher Pull nach Kontextwechsel beendet; Bericht gilt nur für das genannte Repository. Änderungen sind auch bei Abbruch möglich. Neu laden.","Original pull ended after context changed; this report applies only to the named repository. Changes are possible even after cancellation. Reload.")}else if success&&reached{s.lang().text("Pull abgeschlossen und Integration nachgeprüft. Offene Puffer bleiben erhalten; externe Änderungen separat prüfen. Für weiteren Pull neu laden.","Pull completed and integration checked. Open buffers retained; review external changes separately. Reload before another pull.")}else{s.lang().text("Versuch beendet; Änderungen sind auch bei Fehler oder Abbruch möglich. Tatsächlichen Zustand und offene Dateien prüfen. Neu laden.","Attempt ended; changes are possible even after errors or cancellation. Review actual state and open files. Reload.")});
                    }
                    Err(e) => s.output.buffer().set_text(&e),
                }
                s.controls();
            },
        );
    }
}
pub(super) fn open(ui: &Rc<Ui>, program: PathBuf, path: PathBuf) -> Rc<State> {
    let lang = ui.lang;
    let window = support::window(ui, lang.text("Git · Pull", "Git · Pull"), false);
    window.set_default_size(900, 820);
    window.set_size_request(640, 700);
    let root = support::column();
    let basis = support::label(&project_view::display(&path));
    basis.set_selectable(true);
    root.append(&basis);
    root.append(&support::label(lang.text("Remote", "Remote")));
    let target = support::file_dropdown();
    root.append(&target);
    root.append(&support::label(lang.text(
        "Quellbranch (ohne refs/heads/)",
        "Source branch (without refs/heads/)",
    )));
    let branch = gtk::Entry::builder().text("main").hexpand(true).build();
    root.append(&branch);
    let strategy = gtk::DropDown::from_strings(&[
        lang.text("Nur Fast-Forward", "Fast-forward only"),
        "Merge",
        "Rebase",
    ]);
    root.append(&strategy);
    root.append(&support::label(lang.text("Erst ausdrücklich Quelle abrufen (Refs/FETCH_HEAD), dann vollständige Vorschau prüfen. Pull integriert erst nach Bestätigung. Kein Force, Reset oder Autostash. Kollisionen mit ignorierten Dateien sperren die Vorschau. Ungespeicherte Editorpuffer bleiben erhalten.","Explicitly fetch source first (refs/FETCH_HEAD), then review the complete preview. Pull integrates only after approval. No force, reset or autostash. Ignored-file collisions block the preview. Unsaved editor buffers are retained.")));
    root.append(&support::label(lang.text("Die Vorschau zeigt Commit-Unterschiede und lokale Änderungen, keine atomare Zusage des späteren Dateizustands. Pull fetcht erneut; die Remotequelle kann sich nach der Vorschau ändern. Externes Git kann nach der letzten Prüfung eingreifen; Hooks und Filter können weitere Änderungen bewirken. Git kann Konflikte und Teiländerungen hinterlassen; keine automatische Rücknahme. Auch nach Fehler oder Abbruch wird der tatsächliche Zustand neu gelesen.","The preview shows commit differences and local changes, without an atomic guarantee of later file state. Pull fetches again; the remote source can change after the preview. External Git can intervene after the last check; hooks and filters can cause additional changes. Git can leave conflicts and partial changes; there is no automatic rollback. Actual state is read again even after errors or cancellation.")));
    let actions = gtk::FlowBox::new();
    actions.set_selection_mode(gtk::SelectionMode::None);
    actions.set_max_children_per_line(3);
    actions.set_min_children_per_line(1);
    actions.set_column_spacing(8);
    let reload = gtk::Button::with_label(lang.text("Remotes neu laden", "Reload remotes"));
    let prepare = gtk::Button::with_label(lang.text(
        "Quelle abrufen und Vorschau erstellen",
        "Fetch source and prepare preview",
    ));
    let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    for b in [&reload, &prepare, &cancel] {
        actions.insert(b, -1);
    }
    root.append(&actions);
    let approved = gtk::CheckButton::with_label(lang.text(
        "Quelle, Strategie, vollständige Patches und lokale Änderungen geprüft; Pull freigeben",
        "Source, strategy, complete patches and local changes reviewed; approve pull",
    ));
    if let Some(label) = approved
        .child()
        .and_then(|w| w.downcast::<gtk::Label>().ok())
    {
        label.set_wrap(true);
        label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
        label.set_xalign(0.0);
    }
    root.append(&approved);
    let start =
        gtk::Button::with_label(lang.text("Bestätigten Pull ausführen", "Execute approved pull"));
    start.add_css_class("suggested-action");
    root.append(&start);
    let status = support::label("");
    root.append(&status);
    let output = support::output();
    output.set_wrap_mode(gtk::WrapMode::WordChar);
    root.append(&support::scroll(&output));
    window.set_child(Some(&root));
    let s = Rc::new(State {
        ui: Rc::downgrade(ui),
        window: window.clone(),
        program,
        path,
        owner: RefCell::new(None),
        loaded: RefCell::new(None),
        basis,
        target,
        branch,
        strategy,
        targets: RefCell::new(Vec::new()),
        changing: Cell::new(false),
        reload,
        prepare,
        approved,
        start,
        cancel,
        status,
        output,
        preview: RefCell::new(None),
        cancellation: RefCell::new(Default::default()),
        generation: Cell::new(0),
        job: Cell::new(None),
    });
    let weak = Rc::downgrade(&s);
    s.target.connect_selected_notify(move |_| {
        if let Some(s) = weak.upgrade() {
            if !s.changing.get() {
                s.invalidate(s.lang().text(
                    "Ziel geändert. Neue Vorschau und Bestätigung erforderlich.",
                    "Target changed. Prepare and approve a new preview.",
                ));
            }
        }
    });
    let weak = Rc::downgrade(&s);
    s.branch.connect_changed(move |_| {
        if let Some(s) = weak.upgrade() {
            s.invalidate(s.lang().text(
                "Quelle geändert. Neue Vorschau erforderlich.",
                "Source changed. Prepare a new preview.",
            ));
        }
    });
    let weak = Rc::downgrade(&s);
    s.strategy.connect_selected_notify(move |_| {
        if let Some(s) = weak.upgrade() {
            s.invalidate(s.lang().text(
                "Strategie geändert. Neue Vorschau erforderlich.",
                "Strategy changed. Prepare a new preview.",
            ));
        }
    });
    let weak = Rc::downgrade(&s);
    s.reload.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.load();
        }
    });
    let weak = Rc::downgrade(&s);
    s.prepare.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.prepare();
        }
    });
    let weak = Rc::downgrade(&s);
    s.start.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.execute();
        }
    });
    let weak = Rc::downgrade(&s);
    s.approved.connect_toggled(move |_| {
        if let Some(s) = weak.upgrade() {
            s.controls();
        }
    });
    let weak = Rc::downgrade(&s);
    s.cancel.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.cancellation.borrow().cancel();
        }
    });
    let weak = Rc::downgrade(&s);
    git_fetch::observe(&window, move |_, identity| {
        if let Some(s) = weak.upgrade() {
            if s.job.get().is_none()
                && s.loaded
                    .borrow()
                    .as_ref()
                    .is_some_and(|l| l.identity == identity)
            {
                s.invalidate(s.lang().text(
                    "Repository geändert. Neu laden.",
                    "Repository changed. Reload.",
                ));
                s.loaded.borrow_mut().take();
                s.controls();
            }
        }
    });
    let weak = Rc::downgrade(&s);
    glib::timeout_add_local(Duration::from_millis(30), move || {
        let Some(s) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if s.owner.borrow().is_some() && !s.owned() {
            s.owner_changed();
        }
        glib::ControlFlow::Continue
    });
    DIALOGS.with_borrow_mut(|all| {
        all.retain(|w| w.strong_count() > 0);
        all.push(Rc::downgrade(&s));
    });
    support::hold(&window, s.clone(), |s| s.cancellation.borrow().cancel());
    window.present();
    s.load();
    s
}
#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
