//! Gemeinsamer Controller für Unixsocket, CLI und gespeicherte Codefragen.
mod view;
use super::{code_explanation, git_view as support, Language, Ui};
use fastra_core::{local_control::*, Cancellation};
use fastra_io::local_control::{self as io, transport, Adopted, Loaded};
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
    path::{Path, PathBuf},
    rc::{Rc, Weak},
    sync::mpsc,
    time::{Duration, Instant},
};
fn language() -> Language {
    Language(
        std::env::var("LANGUAGE")
            .or_else(|_| std::env::var("LANG"))
            .unwrap_or_default()
            .starts_with("de"),
    )
}
thread_local! {static RUNTIME:RefCell<Option<Rc<RefCell<Runtime>>>>=const{RefCell::new(None)};}
enum Event {
    Interrupt(UUID),
    Closed(UUID),
    Step(UUID, usize, u64),
    Complete(UUID, UUID, u64, std::result::Result<Selection, Failure>),
}
pub(super) struct Session {
    id: UUID,
    window_id: UUID,
    document_id: RefCell<UUID>,
    window: gtk::Window,
    view: RefCell<view::View>,
    loaded: RefCell<Option<Loaded>>,
    adopted: RefCell<Option<Adopted>>,
    provenance: Option<Provenance>,
    generation: Cell<u64>,
    tokens: RefCell<Vec<Cancellation>>,
    events: Rc<RefCell<Vec<Event>>>,
    player: RefCell<Option<Rc<code_explanation::Player>>>,
    initial_job: RefCell<Option<UUID>>,
}
impl Session {
    fn interrupt(&self) {
        self.generation.set(self.generation.get() + 1);
        for token in self.tokens.borrow().iter() {
            token.cancel()
        }
        self.events
            .borrow_mut()
            .push(Event::Interrupt(self.id.clone()));
    }
    fn install(&self, loaded: Loaded, document: Option<UUID>) {
        self.view.borrow().install(&loaded);
        *self.loaded.borrow_mut() = Some(loaded);
        if let Some(id) = document {
            *self.document_id.borrow_mut() = id;
        }
    }
    fn current(&self, generation: u64) -> bool {
        self.generation.get() == generation && self.window.is_visible()
    }
    fn player_pause(&self) {
        if let Some(player) = self.player.borrow().as_ref() {
            player.control_pause();
        }
    }
    fn present(self: &Rc<Self>, job: UUID, selection: Selection) {
        let generation = self.generation.get();
        let weak = Rc::downgrade(self);
        let runtime = runtime_weak();
        let started = Instant::now();
        let mut selected = false;
        let mut confirmations = 0;
        glib::timeout_add_local(Duration::from_millis(20), move || {
            let Some(s) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if !s.current(generation) {
                s.events.borrow_mut().push(Event::Complete(
                    s.id.clone(),
                    job.clone(),
                    generation,
                    Err(Failure::new("interrupted")),
                ));
                return glib::ControlFlow::Break;
            }
            let Some(runtime) = runtime.upgrade() else {
                return glib::ControlFlow::Break;
            };
            let check = {
                let r = runtime.borrow();
                match r.state.jobs.get(&job) {
                    None => None,
                    Some(j) if j.terminal() => None,
                    Some(_) if !r.state.pending(&job, io::now()) => {
                        Some(Err(Failure::new("expired")))
                    }
                    Some(j) => {
                        let bound = j.session_id == s.id
                            && j.document_id == *s.document_id.borrow()
                            && j.sha256.as_ref() == s.loaded.borrow().as_ref().map(|l| &l.sha256)
                            && r.bindings.get(&job) == Some(&(s.id.clone(), generation));
                        Some(if bound {
                            Ok(())
                        } else {
                            Err(Failure::new("stale"))
                        })
                    }
                }
            };
            let Some(check) = check else {
                return glib::ControlFlow::Break;
            };
            if let Err(error) = check {
                s.events.borrow_mut().push(Event::Complete(
                    s.id.clone(),
                    job.clone(),
                    generation,
                    Err(error),
                ));
                return glib::ControlFlow::Break;
            }
            if started.elapsed() >= Duration::from_secs(30) {
                s.events.borrow_mut().push(Event::Complete(
                    s.id.clone(),
                    job.clone(),
                    generation,
                    Err(Failure::new("expired")),
                ));
                return glib::ControlFlow::Break;
            }
            let v = s.view.borrow();
            if !v.source.is_mapped() || v.source.width() <= 0 || v.source.height() <= 0 {
                return glib::ControlFlow::Continue;
            }
            if !selected {
                v.select(&selection);
                selected = true;
                return glib::ControlFlow::Continue;
            }
            let valid = s
                .loaded
                .borrow()
                .as_ref()
                .is_some_and(|l| v.content_matches(l, &selection));
            if !valid {
                s.events.borrow_mut().push(Event::Complete(
                    s.id.clone(),
                    job.clone(),
                    generation,
                    Err(Failure::new("interrupted")),
                ));
                return glib::ControlFlow::Break;
            }
            // GTK kann die neue Quellhöhe erst in einem späteren Layout kennen.
            // Die Auswahl bleibt gesetzt; nur der noch nicht sichtbare Zielausschnitt wird angefordert.
            if !v.selection_visible(&selection) {
                v.scroll(&selection);
                confirmations = 0;
                return glib::ControlFlow::Continue;
            }
            confirmations += 1;
            if confirmations < 3 {
                return glib::ControlFlow::Continue;
            }
            s.events.borrow_mut().push(Event::Complete(
                s.id.clone(),
                job.clone(),
                generation,
                Ok(selection.clone()),
            ));
            glib::ControlFlow::Break
        });
    }
}
struct Ordinary {
    ui: Weak<Ui>,
    id: UUID,
    documents: Vec<(Weak<super::Document>, UUID)>,
}
struct Runtime {
    application: gtk::Application,
    state: State,
    sessions: BTreeMap<UUID, Rc<Session>>,
    ordinary: Vec<Ordinary>,
    events: Rc<RefCell<Vec<Event>>>,
    tokens: BTreeMap<UUID, Cancellation>,
    bindings: BTreeMap<UUID, (UUID, u64)>,
    player_jobs: std::collections::BTreeSet<UUID>,
    _server: Option<transport::Server>,
    startup_error: Option<String>,
    deliveries: Option<mpsc::Receiver<transport::Delivery>>,
}
fn reply(runtime: &Runtime) -> Reply {
    Reply::new(Some(runtime.state.runtime_id.clone()))
}
impl Runtime {
    fn new(application: &gtk::Application) -> Self {
        let (server, deliveries, startup_error) =
            match transport::endpoint().and_then(|p| transport::Server::start(&p)) {
                Ok((server, deliveries)) => (Some(server), Some(deliveries), None),
                Err(error) => (None, None, Some(error.to_string())),
            };
        Self {
            application: application.clone(),
            state: State::new(io::uuid()),
            sessions: BTreeMap::new(),
            ordinary: Vec::new(),
            events: Rc::new(RefCell::new(Vec::new())),
            tokens: BTreeMap::new(),
            bindings: BTreeMap::new(),
            player_jobs: std::collections::BTreeSet::new(),
            _server: server,
            startup_error,
            deliveries,
        }
    }
    fn create(&mut self, request: &Request) -> Result<Rc<Session>> {
        if self.sessions.len() >= MAX_SESSIONS || self.state.jobs.len() >= MAX_JOBS {
            return Err(Failure::new("capacity"));
        }
        let id = io::uuid();
        let name = request
            .provenance
            .as_ref()
            .and_then(|p| p.hit_identity.archive_members.last())
            .map(String::as_str)
            .unwrap_or_else(|| {
                request
                    .path
                    .as_deref()
                    .and_then(|p| Path::new(p).file_name())
                    .and_then(|p| p.to_str())
                    .unwrap_or("Snapshot")
            });
        let v = view::View::new(
            &self.application,
            language(),
            name,
            request.provenance.as_ref(),
        );
        let window = v.window.clone();
        let session = Rc::new(Session {
            id: id.clone(),
            window_id: io::uuid(),
            document_id: RefCell::new(io::uuid()),
            window: window.clone(),
            view: RefCell::new(v),
            loaded: RefCell::new(None),
            adopted: RefCell::new(None),
            provenance: request.provenance.clone(),
            generation: Cell::new(0),
            tokens: RefCell::new(Vec::new()),
            events: self.events.clone(),
            player: RefCell::new(None),
            initial_job: RefCell::new(None),
        });
        view::bind(&session);
        let weak = Rc::downgrade(&session);
        window.connect_close_request(move |_| {
            if let Some(s) = weak.upgrade() {
                s.interrupt();
                s.events.borrow_mut().push(Event::Closed(s.id.clone()));
            }
            glib::Propagation::Proceed
        });
        self.sessions.insert(id, session.clone());
        window.present();
        Ok(session)
    }
    fn job(&mut self, request: &Request, s: &Rc<Session>) -> Result<Job> {
        let job = Job::new(
            io::uuid(),
            request,
            s.id.clone(),
            s.window_id.clone(),
            s.document_id.borrow().clone(),
        );
        self.state.insert(job.clone(), io::now())?;
        self.bindings
            .insert(job.id.clone(), (s.id.clone(), s.generation.get()));
        Ok(job)
    }
    fn fill(job: &mut Job, l: &Loaded) {
        job.sha256 = Some(l.sha256.clone());
        job.text_sha256 = Some(l.text_sha256.clone());
        job.byte_count = Some(l.byte_count);
        job.encoding = Some(l.encoding);
        job.bom_bytes = Some(l.bom_bytes);
    }
    fn inventory(&mut self) -> Vec<Object> {
        let mut objects = Vec::new();
        self.ordinary
            .retain(|o| o.ui.upgrade().is_some_and(|u| u.window.is_visible()));
        for ordinary in &mut self.ordinary {
            let Some(ui) = ordinary.ui.upgrade() else {
                continue;
            };
            objects.push(Object {
                id: ordinary.id.clone(),
                kind: "window".into(),
                name: ui.window.title().unwrap_or_default().into(),
                window_id: None,
                document_id: None,
                session_id: None,
                sha256: None,
                selection: None,
                provenance: None,
            });
            let documents = ui.documents.borrow();
            ordinary.documents.retain(|(w, _)| {
                w.upgrade()
                    .is_some_and(|d| documents.iter().any(|v| Rc::ptr_eq(v, &d)))
            });
            for doc in documents.iter() {
                let id = if let Some((_, id)) = ordinary
                    .documents
                    .iter()
                    .find(|(w, _)| w.upgrade().is_some_and(|d| Rc::ptr_eq(&d, doc)))
                {
                    id.clone()
                } else {
                    let id = io::uuid();
                    ordinary.documents.push((Rc::downgrade(doc), id.clone()));
                    id
                };
                objects.push(Object {
                    id,
                    kind: "document".into(),
                    name: doc
                        .disk_path()
                        .and_then(|path| {
                            path.file_name()
                                .map(|name| super::project_view::display(Path::new(name)))
                        })
                        .unwrap_or_else(|| doc.name.clone()),
                    window_id: Some(ordinary.id.clone()),
                    document_id: None,
                    session_id: None,
                    sha256: None,
                    selection: None,
                    provenance: None,
                });
            }
        }
        for s in self.sessions.values() {
            let document = s.document_id.borrow().clone();
            let hash = s.loaded.borrow().as_ref().map(|l| l.sha256.clone());
            let name = s.window.title().unwrap_or_default().to_string();
            objects.push(Object {
                id: s.window_id.clone(),
                kind: "window".into(),
                name: name.clone(),
                window_id: None,
                document_id: Some(document.clone()),
                session_id: Some(s.id.clone()),
                sha256: None,
                selection: None,
                provenance: None,
            });
            objects.push(Object {
                id: document.clone(),
                kind: "document".into(),
                name: name.clone(),
                window_id: Some(s.window_id.clone()),
                document_id: None,
                session_id: Some(s.id.clone()),
                sha256: hash.clone(),
                selection: Some(s.view.borrow().selection()),
                provenance: s.provenance.clone(),
            });
            objects.push(Object {
                id: s.id.clone(),
                kind: "session".into(),
                name,
                window_id: Some(s.window_id.clone()),
                document_id: Some(document),
                session_id: None,
                sha256: hash,
                selection: None,
                provenance: s.provenance.clone(),
            });
        }
        objects.sort_by(|a, b| a.id.cmp(&b.id));
        objects
    }
    fn execute(&mut self, request: Request) -> Reply {
        let result = self.execute_inner(&request);
        result.unwrap_or_else(|e| Reply::failure(Some(self.state.runtime_id.clone()), e))
    }
    fn execute_inner(&mut self, r: &Request) -> Result<Reply> {
        self.events();
        if let Some(reply) = self.state.prepare(r, io::now())? {
            return Ok(reply);
        }
        let mut answer = reply(self);
        match r.operation.as_str() {
            "capabilities" => {
                let c = Capabilities {
                    runtime_id: Some(self.state.runtime_id.clone()),
                    product_version: Some(env!("CARGO_PKG_VERSION").into()),
                    ..Capabilities::default()
                };
                answer.capabilities = Some(c)
            }
            "objects" => {
                answer.objects = Some(self.inventory());
                answer.jobs = Some(self.state.jobs.values().cloned().collect())
            }
            "status" => {
                answer.job = Some(
                    self.state
                        .jobs
                        .get(r.job_id.as_ref().unwrap())
                        .ok_or_else(|| Failure::new("invalidID"))?
                        .clone(),
                )
            }
            "cancel" => {
                let id = r.job_id.as_ref().unwrap();
                let session = self
                    .state
                    .jobs
                    .get(id)
                    .ok_or_else(|| Failure::new("invalidID"))?
                    .session_id
                    .clone();
                let terminal = self.state.jobs[id].terminal();
                self.state.cancel(id)?;
                if !terminal {
                    if let Some(t) = self.tokens.get(id) {
                        t.cancel()
                    }
                    if let Some(s) = self.sessions.get(&session) {
                        s.generation.set(s.generation.get() + 1);
                        s.view.borrow().failure(None);
                        if self.player_jobs.remove(id) {
                            if let Some(p) = s.player.borrow().as_ref() {
                                p.control_cancelled();
                            }
                        }
                        if self.state.jobs[id].provenance.is_some()
                            && self.state.jobs[id].adopted != Some(true)
                        {
                            s.adopted.borrow_mut().take();
                        }
                    }
                }
                answer.job = self.state.jobs.get(id).cloned()
            }
            "close" => {
                let id = r.session_id.as_ref().unwrap();
                let s = self
                    .sessions
                    .remove(id)
                    .ok_or_else(|| Failure::new("invalidID"))?;
                s.interrupt();
                s.adopted.borrow_mut().take();
                s.window.close();
            }
            "navigate" => {
                let s = self
                    .sessions
                    .get(r.session_id.as_ref().unwrap())
                    .cloned()
                    .ok_or_else(|| Failure::new("invalidID"))?;
                if *s.document_id.borrow() != *r.document_id.as_ref().unwrap() {
                    return Err(Failure::new("invalidID"));
                }
                let loaded = s
                    .loaded
                    .borrow()
                    .clone()
                    .ok_or_else(|| Failure::new("invalidID"))?;
                if Some(&loaded.sha256) != r.sha256.as_ref() {
                    return Err(Failure::new("stale"));
                }
                r.selection()
                    .validate(&loaded.text, &Cancellation::default())?;
                if self.state.jobs.len() >= MAX_JOBS {
                    return Err(Failure::new("capacity"));
                }
                s.player_pause();
                s.interrupt();
                self.events();
                let mut job = self.job(r, &s)?;
                job.sha256 = Some(loaded.sha256.clone());
                job.text_sha256 = Some(loaded.text_sha256.clone());
                let mut presenting = job.clone();
                presenting.state = "presenting".into();
                self.state.jobs.insert(job.id.clone(), presenting);
                s.present(job.id.clone(), r.selection());
                answer.job = Some(job)
            }
            "snapshot" | "sourceSnapshot" | "explanation" => {
                let s = self.create(r)?;
                let job = self.job(r, &s)?;
                answer.job = Some(job.clone());
                self.state.jobs.get_mut(&job.id).unwrap().state = "loading".into();
                let token = Cancellation::default();
                s.tokens.borrow_mut().push(token.clone());
                self.tokens.insert(job.id.clone(), token.clone());
                let request = r.clone();
                let weak = runtime_weak();
                let session = s.id.clone();
                let job_id = job.id.clone();
                let generation = s.generation.get();
                let selection = r.selection();
                support::background(
                    move || {
                        Ok(if request.operation == "explanation" {
                            io::load_explanation(
                                Path::new(request.path.as_deref().unwrap()),
                                &token,
                            )
                            .map(Payload::Explanation)
                        } else if request.operation == "sourceSnapshot" {
                            Adopted::adopt(&request, &std::env::temp_dir(), &token)
                                .map(Payload::Adopted)
                        } else {
                            io::load(&request, &token).map(Payload::Snapshot)
                        })
                    },
                    move |result| {
                        if let Some(runtime) = weak.upgrade() {
                            runtime.borrow_mut().loaded(
                                session,
                                job_id,
                                generation,
                                selection,
                                result.unwrap_or_else(|_| Err(Failure::new("sourceUnavailable"))),
                            );
                        }
                    },
                );
            }
            _ => return Err(Failure::new("unsupported")),
        }
        self.state.record(r, &answer, io::now());
        Ok(answer)
    }
    fn loaded(
        &mut self,
        session: UUID,
        job: UUID,
        generation: u64,
        selection: Selection,
        result: Result<Payload>,
    ) {
        self.events();
        let Some(s) = self
            .sessions
            .get(&session)
            .cloned()
            .filter(|s| s.current(generation))
        else {
            return;
        };
        if !self.state.jobs.get(&job).is_some_and(|j| !j.terminal()) {
            return;
        }
        if !self.state.pending(&job, io::now()) {
            self.fail(&job, Failure::new("expired"));
            return;
        }
        match result {
            Err(e) => self.fail(&job, e),
            Ok(Payload::Snapshot(l)) => {
                Self::fill(self.state.jobs.get_mut(&job).unwrap(), &l);
                s.install(l, None);
                self.state.jobs.get_mut(&job).unwrap().state = "presenting".into();
                s.present(job, selection)
            }
            Ok(Payload::Adopted(a)) => {
                Self::fill(self.state.jobs.get_mut(&job).unwrap(), &a.loaded);
                s.install(a.loaded.clone(), None);
                *s.adopted.borrow_mut() = Some(a);
                self.state.jobs.get_mut(&job).unwrap().state = "presenting".into();
                s.present(job, selection)
            }
            Ok(Payload::Explanation(p)) => {
                let initial_document = s.document_id.borrow().clone();
                match code_explanation::open_package_in(
                    &self.application,
                    p,
                    language(),
                    Some(&s.window),
                    Some(initial_document),
                    false,
                ) {
                    Err(_) => self.fail(&job, Failure::new("sourceUnavailable")),
                    Ok(player) => {
                        *s.view.borrow_mut() = view::View::from_player(&player);
                        self.player_jobs.insert(job.clone());
                        *s.initial_job.borrow_mut() = Some(job);
                        *s.player.borrow_mut() = Some(player.clone());
                        let weak = Rc::downgrade(&s);
                        player.control_bind(
                            Rc::new(move || {
                                if let Some(s) = weak.upgrade() {
                                    s.interrupt();
                                }
                            }),
                            {
                                let weak = Rc::downgrade(&s);
                                Rc::new(move |l, document| {
                                    if let Some(s) = weak.upgrade() {
                                        if s.loaded.borrow().is_some() {
                                            s.interrupt();
                                        }
                                        *s.loaded.borrow_mut() = Some(l);
                                        *s.document_id.borrow_mut() = document;
                                    }
                                })
                            },
                            {
                                let weak = Rc::downgrade(&s);
                                Rc::new(move |index| {
                                    if let Some(s) = weak.upgrade() {
                                        s.events.borrow_mut().push(Event::Step(
                                            s.id.clone(),
                                            index,
                                            s.generation.get(),
                                        ));
                                    }
                                })
                            },
                        );
                        player.control_navigate(0);
                    }
                }
            }
        }
    }
    fn fail(&mut self, id: &UUID, error: Failure) {
        if let Some(j) = self.state.jobs.get_mut(id) {
            if j.terminal() {
                return;
            }
            j.state = "failed".into();
            j.error = Some(error.clone());
            if let Some(t) = self.tokens.get(id) {
                t.cancel()
            }
            if let Some(s) = self.sessions.get(&j.session_id) {
                s.view.borrow().failure(Some(&error));
                if j.provenance.is_some() && j.adopted != Some(true) {
                    s.adopted.borrow_mut().take();
                }
                if self.player_jobs.remove(id) {
                    if let Some(p) = s.player.borrow().as_ref() {
                        p.control_finished(false);
                    }
                }
            }
        }
    }
    fn events(&mut self) {
        let events = std::mem::take(&mut *self.events.borrow_mut());
        for event in events {
            match event {
                Event::Interrupt(id) => {
                    for job in self
                        .state
                        .jobs
                        .values_mut()
                        .filter(|j| j.session_id == id && !j.terminal())
                    {
                        job.state = "cancelled".into();
                        if let Some(t) = self.tokens.get(&job.id) {
                            t.cancel()
                        }
                        if let Some(s) = self.sessions.get(&id) {
                            s.view.borrow().failure(None);
                            if job.provenance.is_some() && job.adopted != Some(true) {
                                s.adopted.borrow_mut().take();
                            }
                        }
                    }
                }
                Event::Closed(id) => {
                    if let Some(s) = self.sessions.remove(&id) {
                        s.adopted.borrow_mut().take();
                    }
                }
                Event::Complete(session, id, generation, result) => {
                    if self
                        .sessions
                        .get(&session)
                        .is_some_and(|s| s.current(generation))
                        && self.state.jobs.get(&id).is_some_and(|j| !j.terminal())
                    {
                        if !self.state.pending(&id, io::now()) {
                            self.fail(&id, Failure::new("expired"));
                            continue;
                        }
                        match result {
                            Err(e) => self.fail(&id, e),
                            Ok(selection) => {
                                let j = self.state.jobs.get_mut(&id).unwrap();
                                j.state = "ready".into();
                                j.selection = Some(selection);
                                if j.provenance.is_some() {
                                    j.adopted = Some(true)
                                }
                                if let Some(s) = self.sessions.get(&session) {
                                    s.view.borrow().ready();
                                    if self.player_jobs.remove(&id) {
                                        if let Some(p) = s.player.borrow().as_ref() {
                                            p.control_finished(true);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Event::Step(id, index, generation) => {
                    let Some(s) = self
                        .sessions
                        .get(&id)
                        .cloned()
                        .filter(|s| s.current(generation))
                    else {
                        continue;
                    };
                    let Some(p) = s.player.borrow().clone() else {
                        continue;
                    };
                    let (selection, hash) = p.control_step(index);
                    let initial = s.initial_job.borrow_mut().take();
                    if let Some(initial) = initial {
                        if !self.state.pending(&initial, io::now()) {
                            self.fail(&initial, Failure::new("expired"));
                            continue;
                        }
                        if let Some(j) = self.state.jobs.get_mut(&initial) {
                            if let Some(l) = s.loaded.borrow().as_ref() {
                                Self::fill(j, l)
                            }
                            j.document_id = s.document_id.borrow().clone();
                            j.state = "presenting".into();
                            self.bindings
                                .insert(initial.clone(), (s.id.clone(), s.generation.get()));
                            s.present(initial, selection);
                        }
                    } else {
                        let mut r = Request::new("navigate", io::uuid(), io::now());
                        r.session_id = Some(s.id.clone());
                        r.document_id = Some(s.document_id.borrow().clone());
                        r.sha256 = Some(hash);
                        r.location = Some(selection.location);
                        r.length = Some(selection.length);
                        let reply = self.execute(r);
                        if reply.error.is_some() {
                            p.control_finished(false);
                        } else if let Some(job) = reply.job {
                            self.player_jobs.insert(job.id);
                            p.control_loading();
                        }
                    }
                }
            }
        }
    }
    fn tick(&mut self) {
        self.events();
        self.state.prune(io::now());
        for (id, token) in &self.tokens {
            if !self.state.jobs.get(id).is_some_and(|j| !j.terminal()) {
                token.cancel();
            }
        }
        self.tokens
            .retain(|id, _| self.state.jobs.get(id).is_some_and(|j| !j.terminal()));
        let finished: Vec<_> = self
            .bindings
            .iter()
            .filter(|(id, _)| !self.state.jobs.get(*id).is_some_and(|j| !j.terminal()))
            .map(|(id, (session, generation))| (id.clone(), session.clone(), *generation))
            .collect();
        for (id, session, generation) in finished {
            if let Some(j) = self.state.jobs.get(&id) {
                if let Some(s) = self.sessions.get(&session) {
                    if j.state != "ready" {
                        if j.provenance.is_some() && j.adopted != Some(true) {
                            s.adopted.borrow_mut().take();
                        }
                        if s.generation.get() == generation {
                            s.generation.set(generation + 1);
                            s.view.borrow().failure(j.error.as_ref());
                            if self.player_jobs.contains(&id) {
                                if let Some(p) = s.player.borrow().as_ref() {
                                    if j.state == "cancelled" {
                                        p.control_cancelled();
                                    } else {
                                        p.control_finished(false);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            self.player_jobs.remove(&id);
            self.bindings.remove(&id);
        }
        for s in self.sessions.values() {
            s.tokens.borrow_mut().retain(|t| t.check().is_ok());
        }
        for _ in 0..16 {
            let delivery = self.deliveries.as_ref().and_then(|r| r.try_recv().ok());
            let Some(d) = delivery else { break };
            if Instant::now() >= d.deadline {
                continue;
            }
            let answer = match Request::decode(&d.request) {
                Ok(r) => self.execute(r),
                Err(e) => Reply::failure(Some(self.state.runtime_id.clone()), e),
            };
            let _ = d.reply.try_send(answer);
        }
    }
}
enum Payload {
    Snapshot(Loaded),
    Adopted(Adopted),
    Explanation(fastra_io::code_explanation::Package),
}
fn runtime_weak() -> Weak<RefCell<Runtime>> {
    RUNTIME.with(|r| r.borrow().as_ref().map(Rc::downgrade).unwrap_or_default())
}
pub(super) fn start(application: &gtk::Application) {
    RUNTIME.with(|r| {
        if r.borrow().is_some() {
            return;
        }
        let runtime = Rc::new(RefCell::new(Runtime::new(application)));
        let weak = Rc::downgrade(&runtime);
        glib::timeout_add_local(Duration::from_millis(10), move || {
            if let Some(r) = weak.upgrade() {
                r.borrow_mut().tick();
                glib::ControlFlow::Continue
            } else {
                glib::ControlFlow::Break
            }
        });
        *r.borrow_mut() = Some(runtime);
    });
    std::thread::spawn(|| io::prune_abandoned(&std::env::temp_dir()));
}
pub(super) fn service_ready() -> std::result::Result<(), String> {
    RUNTIME.with(|slot| {
        let state = slot.borrow();
        let runtime = state.as_ref().ok_or_else(|| {
            language()
                .text(
                    "Steuerungsdienst wurde nicht gestartet.",
                    "Local-control service was not started.",
                )
                .to_string()
        })?;
        let state = runtime.borrow();
        if let Some(error) = &state.startup_error {
            return Err(format!(
                "{} {error}",
                language().text(
                    "Steuerungsdienst konnte nicht gestartet werden:",
                    "Could not start local-control service:",
                )
            ));
        }
        Ok(())
    })
}
pub(super) fn register(ui: &Rc<Ui>) {
    RUNTIME.with(|r| {
        if let Some(r) = r.borrow().as_ref() {
            r.borrow_mut().ordinary.push(Ordinary {
                ui: Rc::downgrade(ui),
                id: io::uuid(),
                documents: Vec::new(),
            });
        }
    });
}
pub(super) fn shutdown() {
    RUNTIME.with(|r| {
        if let Some(runtime) = r.borrow_mut().take() {
            let mut r = runtime.borrow_mut();
            r._server.take();
            for s in r.sessions.values() {
                s.interrupt();
                s.adopted.borrow_mut().take();
                s.window.close();
            }
            r.sessions.clear();
        }
    });
}
pub(super) fn open_manifest(ui: &Rc<Ui>, path: PathBuf) {
    RUNTIME.with(|r| {
        if let Some(r) = r.borrow().as_ref() {
            let mut request = Request::new("explanation", io::uuid(), io::now());
            request.path = Some(path.to_string_lossy().into_owned());
            let answer = r.borrow_mut().execute(request);
            if let Some(error) = answer.error {
                gtk::AlertDialog::builder()
                    .message(ui.lang.text(
                        "Codefrage konnte nicht geöffnet werden",
                        "Could not open code question",
                    ))
                    .detail(view::failure_text(Some(&error), ui.lang))
                    .build()
                    .show(Some(&ui.window));
            }
        }
    });
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
