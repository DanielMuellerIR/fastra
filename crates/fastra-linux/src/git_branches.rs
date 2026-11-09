//! Reine lokale Ref-Erstellung; Arbeitsdateien und aktiver Branch werden nicht gewechselt.
use super::{git_fetch, git_view as support, project_view, Language, Ui};
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    os::unix::ffi::OsStringExt,
    path::PathBuf,
    rc::{Rc, Weak},
    time::Duration,
};
thread_local! {static DIALOGS:RefCell<Vec<Weak<State>>>=const{RefCell::new(Vec::new())};}
pub(super) fn invalidate_owner(ui: &Ui) {
    DIALOGS.with_borrow_mut(|all| {
        all.retain(|weak| {
            let Some(s) = weak.upgrade() else {
                return false;
            };
            if s.ui
                .upgrade()
                .is_some_and(|owner| std::ptr::eq(owner.as_ref(), ui))
            {
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
    list: gtk::TextView,
    source: gtk::DropDown,
    sources: RefCell<Vec<Vec<u8>>>,
    name: gtk::Entry,
    oid: gtk::Entry,
    reload: gtk::Button,
    prepare: gtk::Button,
    approved: gtk::CheckButton,
    create: gtk::Button,
    cancel_button: gtk::Button,
    output: gtk::TextView,
    status: gtk::Label,
    preview: RefCell<Option<fastra_git::BranchCreationPreview>>,
    cancellation: RefCell<fastra_git::Cancellation>,
    generation: Cell<u64>,
    job: Cell<Option<u64>>,
    changing: Cell<bool>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.cancellation.get_mut().cancel();
    }
}
fn policy() -> fastra_git::Policy {
    fastra_git::Policy {
        stdout_bytes: 512 * 1024,
        stderr_bytes: 128 * 1024,
        timeout: Duration::from_secs(15),
        ..Default::default()
    }
}
fn visible(bytes: &[u8]) -> String {
    support::bytes(bytes).chars().flat_map(|c|if(c.is_control()&&!matches!(c,'\n'|'\t'))||matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}'){c.escape_default().collect::<Vec<_>>()}else{vec![c]}).collect()
}
fn error(e: fastra_git::Error, lang: Language) -> String {
    visible(support::error(e, lang).as_bytes())
}
impl State {
    fn lang(&self) -> Language {
        self.ui.upgrade().map_or(Language(false), |ui| ui.lang)
    }
    fn owned(&self) -> bool {
        self.window.is_visible()
            && self.ui.upgrade().is_some_and(|ui| {
                self.owner
                    .borrow()
                    .as_ref()
                    .is_some_and(|owner| owner.current(&ui))
            })
    }
    fn controls(&self) {
        let busy = self.job.get().is_some();
        let ready = !busy && self.owned() && self.loaded.borrow().is_some();
        self.reload.set_sensitive(!busy);
        self.name.set_sensitive(ready);
        self.oid.set_sensitive(ready);
        self.source
            .set_sensitive(ready && !self.sources.borrow().is_empty());
        self.prepare
            .set_sensitive(ready && !self.name.text().is_empty() && !self.oid.text().is_empty());
        self.approved
            .set_sensitive(ready && self.preview.borrow().is_some());
        self.create
            .set_sensitive(ready && self.preview.borrow().is_some() && self.approved.is_active());
        self.cancel_button.set_sensitive(busy);
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
            self.invalidate(self.lang().text(
                "Fenster, Dokument oder Projekt geändert. Branchliste neu laden.",
                "Window, document or project changed. Reload branches.",
            ));
        }
    }
    fn begin(&self, message: &str) -> (u64, fastra_git::Cancellation) {
        self.invalidate(message);
        let cancel = fastra_git::Cancellation::default();
        *self.cancellation.borrow_mut() = cancel.clone();
        let id = self.generation.get();
        self.job.set(Some(id));
        self.controls();
        (id, cancel)
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
    fn sync_source(&self) {
        let oid = self.oid.text();
        let sources = self.sources.borrow();
        if sources
            .get(self.source.selected() as usize)
            .is_some_and(|source| source.as_slice() == oid.as_bytes())
        {
            return;
        }
        let selected = sources
            .iter()
            .position(|source| source.as_slice() == oid.as_bytes())
            .map(|index| index as u32)
            .unwrap_or(gtk::INVALID_LIST_POSITION);
        self.changing.set(true);
        self.source.set_selected(selected);
        self.changing.set(false);
    }
    fn catalogue(
        &self,
        value: fastra_git::ReadResult<fastra_git::LocalBranches>,
        preserve_oid: bool,
    ) {
        self.changing.set(true);
        let mut text = String::new();
        let mut labels = Vec::new();
        let mut sources = Vec::new();
        if let Some(head) = &value.value.head_oid {
            labels.push(format!(
                "{} · {}",
                self.lang().text("Aktueller Commit", "Current commit"),
                visible(head)
            ));
            sources.push(head.clone());
        }
        for branch in value.value.branches {
            let name = branch
                .full_name
                .strip_prefix(b"refs/heads/")
                .unwrap_or(&branch.full_name);
            text.push_str(&format!(
                "{} {}\n    {}\n",
                if branch.current { "●" } else { " " },
                visible(name),
                visible(&branch.oid)
            ));
            if !branch.worktree_path.is_empty() {
                text.push_str(&format!(
                    "    {}\n",
                    project_view::display(&PathBuf::from(std::ffi::OsString::from_vec(
                        branch.worktree_path
                    )))
                ));
            }
            labels.push(format!("{} · {}", visible(name), visible(&branch.oid)));
            sources.push(branch.oid);
        }
        if text.is_empty() {
            text = self
                .lang()
                .text(
                    "Keine lokalen Branches vorhanden.",
                    "No local branches exist.",
                )
                .into();
        }
        text.push_str(&visible(&value.output.stderr));
        self.list.buffer().set_text(&text);
        self.source.set_model(Some(&gtk::StringList::new(
            &labels.iter().map(String::as_str).collect::<Vec<_>>(),
        )));
        self.source.set_selected(if preserve_oid {
            sources
                .iter()
                .position(|oid| oid.as_slice() == self.oid.text().as_bytes())
                .map(|index| index as u32)
                .unwrap_or(gtk::INVALID_LIST_POSITION)
        } else if sources.is_empty() {
            gtk::INVALID_LIST_POSITION
        } else {
            0
        });
        if !preserve_oid {
            self.oid
                .set_text(&sources.first().map(|s| visible(s)).unwrap_or_default());
        }
        *self.sources.borrow_mut() = sources;
        self.changing.set(false);
        self.controls();
    }
    fn load(self: &Rc<Self>) {
        if self.job.get().is_some() {
            return;
        }
        let Some(ui) = self.ui.upgrade() else { return };
        let owner = git_fetch::Owner::capture(&ui);
        if !owner.current(&ui) {
            self.status.set_text(self.lang().text(
                "Speichervorgang beenden und erneut laden.",
                "Finish saving, then reload.",
            ));
            return;
        }
        *self.owner.borrow_mut() = Some(owner);
        self.loaded.borrow_mut().take();
        let project = self.project();
        let (id, cancel) = self.begin(self.lang().text(
            "Lokale Branches werden gelesen …",
            "Reading local branches …",
        ));
        let path = self.path.clone();
        let program = self.program.clone();
        let lang = self.lang();
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                if let Some(project) = project {
                    project.validate()?;
                }
                let repository = fastra_git::Git::new(program)
                    .and_then(|git| git.discover(&path, policy(), &cancel))
                    .map_err(|e| error(e, lang))?;
                let identity = repository
                    .operation_identity()
                    .map_err(|e| error(e, lang))?;
                let catalogue = repository
                    .local_branches(policy(), &cancel)
                    .map_err(|e| error(e, lang))?;
                if repository
                    .operation_identity()
                    .map_err(|e| error(e, lang))?
                    != identity
                {
                    return Err(error(fastra_git::Error::StaleRepository, lang));
                }
                Ok((
                    Loaded {
                        repository,
                        identity,
                    },
                    catalogue,
                ))
            },
            move |result| {
                let Some(s) = weak.upgrade() else { return };
                if !s.finished(id) {
                    return;
                }
                match result {
                    Ok((loaded, catalogue)) => {
                        s.basis.set_text(&format!(
                            "Repository\n{}",
                            project_view::display(loaded.repository.root())
                        ));
                        *s.loaded.borrow_mut() = Some(loaded);
                        s.catalogue(catalogue, false);
                        s.status.set_text(s.lang().text(
                            "Lokalen Branchnamen und Commit wählen, dann Vorschau erstellen.",
                            "Choose a local branch name and commit, then prepare a preview.",
                        ));
                    }
                    Err(e) => {
                        s.output.buffer().set_text(&e);
                        s.status.set_text(s.lang().text(
                            "Branchliste nicht verfügbar. Diagnose unten.",
                            "Branches unavailable. See the diagnostic below.",
                        ));
                    }
                }
                s.controls();
            },
        );
    }
    fn prepare(self: &Rc<Self>) {
        if !self.owned() || self.job.get().is_some() {
            return;
        }
        let Some((repository, identity)) = self
            .loaded
            .borrow()
            .as_ref()
            .map(|l| (l.repository.clone(), l.identity))
        else {
            return;
        };
        let name = self.name.text().as_bytes().to_vec();
        let oid = self.oid.text().as_bytes().to_vec();
        let project = self.project();
        let (id, cancel) = self.begin(self.lang().text(
            "Branch-Vorschau wird vorbereitet …",
            "Preparing branch preview …",
        ));
        let weak = Rc::downgrade(self);
        let lang = self.lang();
        support::background(
            move || {
                if let Some(project) = project {
                    project.validate()?;
                }
                if repository
                    .operation_identity()
                    .map_err(|e| error(e, lang))?
                    != identity
                {
                    return Err(error(fastra_git::Error::StaleRepository, lang));
                }
                repository
                    .prepare_branch_creation(name, oid, policy(), &cancel)
                    .map_err(|e| error(e, lang))
            },
            move |result| {
                let Some(s) = weak.upgrade() else { return };
                if !s.finished(id) {
                    return;
                }
                match result {
                    Ok(preview) => {
                        s.output.buffer().set_text(&format!("{}\n{}\n\n{}\n{}\n\nCommit\n{}\n{}\n\n{}\n{}",s.lang().text("Repository","Repository"),project_view::display(preview.root()),s.lang().text("Neuer lokaler Branch","New local branch"),visible(preview.name()),visible(preview.commit()),visible(preview.subject()),s.lang().text("Der Branch wird nur erstellt. Der aktive Branch, Index und Arbeitsdateien bleiben erhalten.","The branch is only created. The active branch, index and working files are retained."),visible(&preview.output().stderr)));
                        *s.preview.borrow_mut() = Some(preview);
                        s.status.set_text(s.lang().text(
                            "Vollständige Commit-ID und Namen prüfen und ausdrücklich bestätigen.",
                            "Review the complete commit ID and name, then explicitly approve.",
                        ));
                    }
                    Err(e) => {
                        s.output.buffer().set_text(&e);
                        s.status.set_text(s.lang().text(
                            "Keine freigegebene Vorschau. Diagnose unten.",
                            "No approved preview. See the diagnostic below.",
                        ));
                    }
                }
                s.controls();
            },
        );
    }
    fn create(self: &Rc<Self>) {
        if !self.owned() || self.job.get().is_some() || !self.approved.is_active() {
            return;
        }
        let Some(preview) = self.preview.borrow_mut().take() else {
            return;
        };
        let Some((repository, identity)) = self
            .loaded
            .borrow()
            .as_ref()
            .map(|l| (l.repository.clone(), l.identity))
        else {
            return;
        };
        let root = repository.root().to_owned();
        let project = self.project();
        let name = visible(preview.name());
        let oid = visible(preview.commit());
        let (id, cancel) = self.begin(
            self.lang()
                .text("Lokaler Branch wird erstellt …", "Creating local branch …"),
        );
        let weak = Rc::downgrade(self);
        support::background(
            move || {
                if let Some(project) = project {
                    project.validate()?;
                }
                let result = repository.create_branch(preview, policy(), &cancel);
                let catalogue =
                    repository.local_branches(policy(), &fastra_git::Cancellation::default());
                Ok((result, catalogue))
            },
            move |result| {
                git_fetch::refreshed(&root, identity);
                let Some(s) = weak.upgrade() else { return };
                if !s.finished(id) {
                    return;
                }
                match result {
                    Ok((result, catalogue)) => {
                        let refresh_ok = catalogue.is_ok();
                        let mut text = format!(
                            "{}: {name}\nCommit: {oid}\n\n",
                            s.lang().text("Lokaler Branch", "Local branch")
                        );
                        let succeeded = result.is_ok();
                        match result {
                            Ok(out) => {
                                text.push_str(&format!(
                                    "Exit 0\n{}{}",
                                    visible(&out.stdout),
                                    visible(&out.stderr)
                                ));
                            }
                            Err(e) => {
                                text.push_str(&error(e, s.lang()));
                            }
                        }
                        match catalogue {
                            Ok(catalogue) => s.catalogue(catalogue, true),
                            Err(e) => {
                                text.push_str("\n\n");
                                text.push_str(&error(e, s.lang()));
                            }
                        }
                        s.output.buffer().set_text(&text);
                        s.status.set_text(if succeeded&&refresh_ok{s.lang().text("Lokaler Branch erstellt. Es wurde nicht gewechselt.","Local branch created. No branch switch was performed.")}else if succeeded{s.lang().text("Branch erstellt; Liste konnte nicht aktualisiert werden. Diagnose prüfen.","Branch created; the list could not be refreshed. Review the diagnostic.")}else{s.lang().text("Auftrag beendet. Branchliste und Diagnose prüfen; veröffentlichte Branches werden nicht automatisch gelöscht.","Operation ended. Review branches and diagnostic; published branches are not automatically deleted.")});
                    }
                    Err(e) => {
                        s.output.buffer().set_text(&e);
                        s.status.set_text(s.lang().text(
                            "Branchauftrag nicht gestartet. Diagnose unten.",
                            "Branch operation did not start. See the diagnostic below.",
                        ));
                    }
                }
                s.controls();
            },
        );
    }
}
pub(super) fn open(ui: &Rc<Ui>, program: PathBuf, path: PathBuf) -> Rc<State> {
    let lang = ui.lang;
    let window = support::window(
        ui,
        lang.text("Git · Lokale Branches", "Git · Local branches"),
        false,
    );
    window.set_default_size(900, 800);
    window.set_size_request(640, 680);
    let root = support::column();
    let basis = support::label(&project_view::display(&path));
    basis.set_selectable(true);
    root.append(&basis);
    let list = support::output();
    list.set_vexpand(false);
    let list_scroll = support::scroll(&list);
    list_scroll.set_min_content_height(120);
    list_scroll.set_vexpand(false);
    root.append(&list_scroll);
    root.append(&support::label(lang.text(
        "Branch erstellen ohne Wechsel",
        "Create branch without switching",
    )));
    let name = gtk::Entry::builder()
        .hexpand(true)
        .placeholder_text(lang.text("Neuer lokaler Branchname", "New local branch name"))
        .build();
    let fields = gtk::Grid::builder()
        .column_spacing(10)
        .row_spacing(8)
        .build();
    let add_field = |row, title: &str, widget: &gtk::Widget| {
        let label = support::label(title);
        label.set_width_chars(15);
        label.set_max_width_chars(15);
        label.set_valign(gtk::Align::Center);
        fields.attach(&label, 0, row, 1, 1);
        widget.set_hexpand(true);
        fields.attach(widget, 1, row, 1, 1);
    };
    add_field(
        0,
        lang.text("Neuer Branchname", "New branch name"),
        name.upcast_ref(),
    );
    let source = support::file_dropdown();
    source.set_tooltip_text(Some(lang.text(
        "Commit aus vorhandenem lokalem Branch übernehmen",
        "Use a commit from an existing local branch",
    )));
    add_field(
        1,
        lang.text("Commitquelle", "Commit source"),
        source.upcast_ref(),
    );
    let oid = gtk::Entry::builder()
        .hexpand(true)
        .placeholder_text(lang.text(
            "Vollständige Commit-ID (40 oder 64 Hex-Zeichen)",
            "Complete commit ID (40 or 64 hexadecimal digits)",
        ))
        .build();
    add_field(2, "Commit-ID", oid.upcast_ref());
    root.append(&fields);
    root.append(&support::label(lang.text("Zum Wechseln in „Git · Lesen“ dasselbe Repository wählen und „Branch wechseln …“ öffnen. Diese Ansicht erstellt ausschließlich lokale Branches; sie wechselt und löscht sie nicht. Ungespeicherte Dokumente werden weder gespeichert noch neu geladen.","To switch branches, select the same repository in “Git · Read” and open “Switch branch …”. This view only creates local branches; it does not switch or delete them. Unsaved documents are neither saved nor reloaded.")));
    let row = gtk::FlowBox::new();
    row.set_selection_mode(gtk::SelectionMode::None);
    row.set_min_children_per_line(1);
    row.set_max_children_per_line(3);
    row.set_column_spacing(8);
    let reload = gtk::Button::with_label(lang.text("Branchliste neu laden", "Reload branches"));
    let prepare = gtk::Button::with_label(lang.text("Vorschau erstellen", "Prepare preview"));
    let cancel_button = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    for button in [&reload, &prepare, &cancel_button] {
        row.insert(button, -1);
    }
    root.append(&row);
    let approved = gtk::CheckButton::with_label(lang.text(
        "Branchname und vollständige Commit-ID geprüft",
        "Branch name and complete commit ID reviewed",
    ));
    root.append(&approved);
    let create =
        gtk::Button::with_label(lang.text("Lokalen Branch erstellen", "Create local branch"));
    create.add_css_class("suggested-action");
    root.append(&create);
    let status = support::label(lang.text(
        "Lokale Branches werden gelesen …",
        "Reading local branches …",
    ));
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
        list,
        source,
        sources: RefCell::new(Vec::new()),
        name,
        oid,
        reload,
        prepare,
        approved,
        create,
        cancel_button,
        output,
        status,
        preview: RefCell::new(None),
        cancellation: RefCell::new(Default::default()),
        generation: Cell::new(0),
        job: Cell::new(None),
        changing: Cell::new(false),
    });
    for field in [&s.name, &s.oid] {
        let weak = Rc::downgrade(&s);
        field.connect_changed(move |field| {
            if let Some(s) = weak.upgrade() {
                if !s.changing.get() {
                    if field == &s.oid {
                        s.sync_source();
                    }
                    s.invalidate(s.lang().text(
                        "Eingabe geändert. Neue Vorschau und Bestätigung erforderlich.",
                        "Input changed. Prepare and approve a new preview.",
                    ));
                }
            }
        });
    }
    let weak = Rc::downgrade(&s);
    s.source.connect_selected_notify(move |_| {
        let Some(s) = weak.upgrade() else { return };
        if s.changing.get() {
            return;
        }
        let oid = s
            .sources
            .borrow()
            .get(s.source.selected() as usize)
            .cloned();
        if let Some(oid) = oid {
            let text = visible(&oid);
            if s.oid.text().as_str() != text {
                s.oid.set_text(&text);
            }
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
    s.create.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.create();
        }
    });
    let weak = Rc::downgrade(&s);
    s.approved.connect_toggled(move |_| {
        if let Some(s) = weak.upgrade() {
            s.controls();
        }
    });
    let weak = Rc::downgrade(&s);
    s.cancel_button.connect_clicked(move |_| {
        if let Some(s) = weak.upgrade() {
            s.cancellation.borrow().cancel();
        }
    });
    let weak = Rc::downgrade(&s);
    git_fetch::observe(&window, move |_, identity| {
        if let Some(s) = weak.upgrade() {
            if s.owned()
                && s.job.get().is_none()
                && s.loaded
                    .borrow()
                    .as_ref()
                    .is_some_and(|l| l.identity == identity)
            {
                s.load();
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
