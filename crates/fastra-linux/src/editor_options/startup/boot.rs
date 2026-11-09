use super::*;
use std::collections::VecDeque;

pub(super) enum Request {
    Activate,
    Open(Vec<gio::File>),
}
#[derive(Default)]
pub(super) struct Boot {
    pub factory: RefCell<Option<WindowFactory>>,
    loaded: Cell<bool>,
    started: Cell<bool>,
    restoring: Cell<bool>,
    generation: Cell<u64>,
    requests: RefCell<VecDeque<Request>>,
    windows: RefCell<VecDeque<store::Window>>,
    prepared: RefCell<VecDeque<PendingWindow>>,
    cancel: RefCell<Option<crate::viewer::Cancellation>>,
    active_ui: RefCell<Weak<Ui>>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
}
pub(super) fn request(state: &Rc<State>, app: &gtk::Application, request: Request) {
    crate::application_lifecycle::abort_quit();
    state.boot.requests.borrow_mut().push_back(request);
    if state.boot.loaded.get() {
        begin(state, app);
    }
}
pub(super) fn loaded(state: &Rc<State>, windows: Vec<store::Window>) {
    if !state.boot.loaded.replace(true) {
        *state.boot.windows.borrow_mut() = windows.into();
    }
    if let Some(app) = state.app.borrow().upgrade() {
        begin(state, &app);
    }
}
fn create(state: &State, app: &gtk::Application) -> Rc<Ui> {
    let factory = state.boot.factory.borrow().clone().unwrap();
    let ui = factory(app);
    if let Some(error) = state.error.borrow().as_ref() {
        ui.status.set_text(&format!(
            "{}: {error}",
            ui.lang.text(
                "Startzustand nicht geladen; Einstellungen prüfen",
                "Startup state not loaded; check Settings"
            )
        ));
    }
    ui
}
fn begin(state: &Rc<State>, app: &gtk::Application) {
    if state.boot.restoring.get() || state.boot.requests.borrow().is_empty() {
        return;
    }
    if !state.boot.started.replace(true) && !state.boot.windows.borrow().is_empty() {
        state.boot.restoring.set(true);
        *state.boot.hold.borrow_mut() = Some(app.hold());
        if matches!(
            state.boot.requests.borrow().front(),
            Some(Request::Activate)
        ) {
            state.boot.requests.borrow_mut().pop_front();
        }
        // Alle Fenster vor dem ersten Dateiworker anlegen: Ein späterer Load
        // darf dem Nutzer nicht plötzlich ein neues Vorderfenster aufziehen.
        let records: Vec<_> = state.boot.windows.borrow_mut().drain(..).collect();
        for record in records {
            let ui = create(state, app);
            let pristine = ui.active().map(|doc| Rc::downgrade(&doc));
            if let Some(project) = record.project.as_ref() {
                crate::project_view::open_path(&ui, store::path(project));
            }
            super::position::restore(&ui.window, &record);
            if record.maximized {
                ui.window.maximize();
            }
            state.boot.prepared.borrow_mut().push_back(PendingWindow {
                ui: Rc::downgrade(&ui),
                record,
                pristine,
                expected: Stamp::capture(&ui),
            });
        }
        next_window(state, state.boot.generation.get());
        return;
    }
    loop {
        let request = state.boot.requests.borrow_mut().pop_front();
        let Some(request) = request else { break };
        let ui = create(state, app);
        if let Request::Open(files) = request {
            crate::desktop_open::open_files(&ui, &files);
        }
    }
}
pub(super) fn cancel(state: &Rc<State>) {
    state
        .boot
        .generation
        .set(state.boot.generation.get().wrapping_add(1));
    state.boot.restoring.set(false);
    state.boot.started.set(true);
    state.boot.requests.borrow_mut().clear();
    state.boot.windows.borrow_mut().clear();
    state.boot.prepared.borrow_mut().clear();
    if let Some(cancel) = state.boot.cancel.borrow_mut().take() {
        cancel.cancel();
    }
    state.boot.hold.borrow_mut().take();
    *state.boot.active_ui.borrow_mut() = Weak::new();
}
pub(super) fn interrupt(state: &State, ui: &Ui) {
    if state
        .boot
        .active_ui
        .borrow()
        .upgrade()
        .is_some_and(|current| std::ptr::eq(ui, Rc::as_ptr(&current)))
    {
        if let Some(cancel) = state.boot.cancel.borrow().as_ref() {
            cancel.cancel();
        }
    }
}
fn next_window(state: &Rc<State>, generation: u64) {
    if !state.boot.restoring.get() || state.boot.generation.get() != generation {
        return;
    }
    let prepared = state.boot.prepared.borrow_mut().pop_front();
    let Some(PendingWindow {
        ui,
        record,
        pristine,
        expected,
    }) = prepared
    else {
        state.boot.restoring.set(false);
        state.boot.hold.borrow_mut().take();
        if let Some(app) = state.app.borrow().upgrade() {
            begin(state, &app);
        }
        return;
    };
    let Some(ui) = ui.upgrade().filter(|ui| expected.current(ui)) else {
        next_window(state, generation);
        return;
    };
    *state.boot.active_ui.borrow_mut() = Rc::downgrade(&ui);
    let job = Rc::new(Job {
        state: Rc::downgrade(state),
        ui: Rc::downgrade(&ui),
        generation,
        record,
        index: Cell::new(0),
        expected: RefCell::new(expected),
        pristine,
    });
    job.next();
}
struct PendingWindow {
    ui: Weak<Ui>,
    record: store::Window,
    pristine: Option<Weak<Document>>,
    expected: Stamp,
}
struct Member {
    document: Weak<Document>,
    revision: u64,
    path: Option<PathBuf>,
    dirty: bool,
    saving: bool,
}
struct Stamp {
    epoch: u64,
    documents: Vec<Member>,
    active: Option<Weak<Document>>,
}
impl Stamp {
    fn capture(ui: &Ui) -> Self {
        Self {
            epoch: ui.startup_restore_epoch.get(),
            active: ui.active().map(|doc| Rc::downgrade(&doc)),
            documents: ui
                .documents
                .borrow()
                .iter()
                .map(|doc| Member {
                    document: Rc::downgrade(doc),
                    revision: doc.revision.get(),
                    path: doc.disk_path(),
                    dirty: doc.buffer.is_modified(),
                    saving: doc.saving.get(),
                })
                .collect(),
        }
    }
    fn current(&self, ui: &Ui) -> bool {
        let docs = ui.documents.borrow();
        ui.window.is_visible()
            && self.epoch == ui.startup_restore_epoch.get()
            && docs.len() == self.documents.len()
            && docs.iter().zip(&self.documents).all(|(doc, member)| {
                member
                    .document
                    .upgrade()
                    .is_some_and(|prior| Rc::ptr_eq(doc, &prior))
                    && doc.revision.get() == member.revision
                    && doc.disk_path() == member.path
                    && doc.buffer.is_modified() == member.dirty
                    && doc.saving.get() == member.saving
            })
            && match (&self.active, ui.active()) {
                (None, None) => true,
                (Some(old), Some(now)) => old.upgrade().is_some_and(|old| Rc::ptr_eq(&old, &now)),
                _ => false,
            }
    }
}
struct Job {
    state: Weak<State>,
    ui: Weak<Ui>,
    generation: u64,
    record: store::Window,
    index: Cell<usize>,
    expected: RefCell<Stamp>,
    pristine: Option<Weak<Document>>,
}
impl Job {
    fn next(self: &Rc<Self>) {
        let Some(state) = self.state.upgrade().filter(|state| {
            state.boot.restoring.get() && state.boot.generation.get() == self.generation
        }) else {
            return;
        };
        let Some(ui) = self
            .ui
            .upgrade()
            .filter(|ui| self.expected.borrow().current(ui))
        else {
            self.finish(false);
            return;
        };
        let Some(raw) = self.record.documents.get(self.index.get()) else {
            self.finish(true);
            return;
        };
        let path = store::path(raw);
        let worker_path = path.clone();
        let cancel = crate::viewer::Cancellation::default();
        *state.boot.cancel.borrow_mut() = Some(cancel.clone());
        let lang = ui.lang;
        let job = self.clone();
        #[cfg(debug_assertions)]
        let index = self.index.get();
        crate::git_view::background(
            move || {
                let loaded = crate::viewer::load(&worker_path, None, &cancel)
                    .map_err(|error| error.message(lang.0))?;
                #[cfg(debug_assertions)]
                if let Ok(mode) = std::env::var("FASTRA_STARTUP_SELFTEST") {
                    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
                    let hold = root.join("hold-startup-load");
                    if hold.exists()
                        && !root.join("startup-worker-ready").exists()
                        && (mode != "interrupt-typing" || index == 1)
                    {
                        std::fs::write(root.join("startup-worker-ready"), store::raw(&worker_path))
                            .map_err(|error| error.to_string())?;
                        while hold.exists() {
                            cancel.core().check().map_err(|error| error.to_string())?;
                            std::thread::sleep(std::time::Duration::from_millis(10));
                        }
                    }
                }
                Ok(loaded)
            },
            move |result| {
                let Some(state) = job.state.upgrade().filter(|state| {
                    state.boot.restoring.get() && state.boot.generation.get() == job.generation
                }) else {
                    return;
                };
                state.boot.cancel.borrow_mut().take();
                let Some(ui) = job
                    .ui
                    .upgrade()
                    .filter(|ui| job.expected.borrow().current(ui))
                else {
                    job.finish(false);
                    return;
                };
                match result {
                    Ok(loaded) => {
                        ui.display_loaded_path(path, loaded, None);
                    }
                    Err(error) => ui.status.set_text(&format!(
                        "{}: {}: {error}",
                        lang.text("Datei nicht wiederhergestellt", "File not restored"),
                        crate::project_view::display(&path)
                    )),
                }
                job.index.set(job.index.get() + 1);
                *job.expected.borrow_mut() = Stamp::capture(&ui);
                if job.index.get() == job.record.documents.len() {
                    job.finish(true);
                } else {
                    glib::idle_add_local_once(move || job.next());
                }
            },
        );
    }
    fn finish(&self, complete: bool) {
        let Some(state) = self.state.upgrade().filter(|state| {
            state.boot.restoring.get() && state.boot.generation.get() == self.generation
        }) else {
            return;
        };
        if complete {
            if let Some(ui) = self
                .ui
                .upgrade()
                .filter(|ui| self.expected.borrow().current(ui))
            {
                if ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|doc| doc.disk_path().is_some())
                {
                    if let Some(pristine) = self
                        .pristine
                        .as_ref()
                        .and_then(Weak::upgrade)
                        .filter(|doc| crate::chrome::is_pristine(doc))
                    {
                        let index = ui
                            .documents
                            .borrow()
                            .iter()
                            .position(|doc| Rc::ptr_eq(doc, &pristine));
                        if let Some(index) = index {
                            ui.documents.borrow_mut().remove(index);
                            ui.tabs.remove_page(Some(index as u32));
                        }
                    }
                }
                if let Some(active) = &self.record.active {
                    let index = ui.documents.borrow().iter().position(|doc| {
                        doc.disk_path().as_deref() == Some(store::path(active).as_path())
                    });
                    if let Some(index) = index {
                        ui.tabs.set_current_page(Some(index as u32));
                    }
                }
                if let Some(doc) = ui.active() {
                    crate::tab_close::focus(&ui, &doc);
                }
            }
        }
        *state.boot.active_ui.borrow_mut() = Weak::new();
        next_window(&state, self.generation);
    }
}

#[cfg(debug_assertions)]
pub(super) fn observation(state: &State) -> serde_json::Value {
    serde_json::json!({"loaded":state.loaded.get(),"busy":state.busy.get(),"restore":state.restore.get(),"restoring":state.boot.restoring.get(),"queued":state.boot.requests.borrow().len(),"error":state.error.borrow().as_deref()})
}
