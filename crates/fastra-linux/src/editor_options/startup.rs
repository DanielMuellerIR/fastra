use super::*;
use gtk::gio;
mod boot;
mod controls;
mod position;
mod store;
pub(crate) type WindowFactory = Rc<dyn Fn(&gtk::Application) -> Rc<Ui>>;
type CaptureDone = Box<dyn FnOnce(bool)>;

struct State {
    app: RefCell<glib::WeakRef<gtk::Application>>,
    restore: Cell<bool>,
    loaded: Cell<bool>,
    busy: Cell<bool>,
    updating: Cell<bool>,
    pending: Cell<Option<bool>>,
    error: RefCell<Option<String>>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
    controls: RefCell<Vec<controls::Controls>>,
    boot: boot::Boot,
}
thread_local! {static STATE:Rc<State>=Rc::new(State {
    app:RefCell::new(glib::WeakRef::new()), restore:Cell::new(true), loaded:Cell::new(false),
    busy:Cell::new(false), updating:Cell::new(false), pending:Cell::new(None),
    error:RefCell::new(None), hold:RefCell::new(None), controls:RefCell::new(vec![]), boot:boot::Boot::default(),
});}
fn state() -> Rc<State> {
    STATE.with(Clone::clone)
}
impl State {
    fn refresh(&self) {
        controls::refresh(self);
    }
    fn retain_app(&self) {
        if self.hold.borrow().is_none() {
            if let Some(app) = self.app.borrow().upgrade() {
                *self.hold.borrow_mut() = Some(app.hold());
            }
        }
    }
    fn load(self: &Rc<Self>) {
        if self.busy.replace(true) {
            return;
        }
        self.retain_app();
        self.refresh();
        let root = config_root();
        let owner = Rc::downgrade(self);
        crate::git_view::background(
            move || {
                root.and_then(|root| store::load(&root))
                    .map(|mut preference| {
                        preference.windows = store::available(preference.windows);
                        preference
                    })
            },
            move |result| {
                let Some(state) = owner.upgrade() else { return };
                state.busy.set(false);
                let windows = match result {
                    Ok(preference) => {
                        state.restore.set(preference.restore);
                        state.loaded.set(true);
                        state.error.borrow_mut().take();
                        if preference.restore {
                            preference.windows
                        } else {
                            vec![]
                        }
                    }
                    Err(error) => {
                        *state.error.borrow_mut() = Some(error);
                        vec![]
                    }
                };
                state.refresh();
                boot::loaded(&state, windows);
                state.hold.borrow_mut().take();
            },
        );
    }
    fn choose(self: &Rc<Self>, restore: bool) {
        if !self.loaded.get()
            || self.updating.get()
            || self.busy.get()
            || self.restore.get() == restore && self.pending.get().is_none()
        {
            return;
        }
        self.restore.set(restore);
        self.pending.set(Some(restore));
        self.error.borrow_mut().take();
        self.save();
    }
    fn save(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(restore) = self.pending.take() else {
            return;
        };
        self.busy.set(true);
        self.retain_app();
        self.refresh();
        let root = config_root();
        let owner = Rc::downgrade(self);
        crate::git_view::background(
            move || root.and_then(|root| store::choose(&root, restore)),
            move |result| {
                let Some(state) = owner.upgrade() else { return };
                state.busy.set(false);
                match result {
                    Ok(preference) => {
                        state.restore.set(preference.restore);
                        state.error.borrow_mut().take();
                    }
                    Err(error) => {
                        state.pending.set(Some(restore));
                        *state.error.borrow_mut() = Some(error);
                    }
                }
                state.refresh();
                state.hold.borrow_mut().take();
            },
        );
    }
    fn capture(self: &Rc<Self>, windows: Vec<Rc<Ui>>, done: CaptureDone) {
        if self.busy.get() || self.pending.get().is_some() {
            self.capture_failed(
                windows,
                "Startup preference is still pending; retry or keep the previous state".into(),
                done,
            );
            return;
        }
        let records: Vec<_> = windows
            .iter()
            .filter_map(|ui| {
                let documents: Vec<_> = ui
                    .documents
                    .borrow()
                    .iter()
                    .filter(|doc| doc.comparison.borrow().is_none())
                    .filter_map(|doc| doc.disk_path())
                    .map(|path| store::raw(&path))
                    .collect();
                if documents.is_empty() {
                    return None;
                }
                let active = ui
                    .active()
                    .and_then(|doc| doc.disk_path())
                    .map(|path| store::raw(&path))
                    .filter(|path| documents.contains(path));
                Some(store::Window {
                    project: crate::project_view::requested_path(ui).map(|path| store::raw(&path)),
                    documents,
                    active,
                    width: ui.window.width().max(1),
                    height: ui.window.height().max(1),
                    maximized: ui.window.is_maximized(),
                    position: position::capture(&ui.window),
                })
            })
            .collect();
        self.busy.set(true);
        self.retain_app();
        self.refresh();
        let root = config_root();
        let owner = self.clone();
        crate::git_view::background(
            move || root.and_then(|root| store::capture(&root, records)),
            move |result| {
                owner.busy.set(false);
                owner.refresh();
                owner.hold.borrow_mut().take();
                match result {
                    Ok(_) => done(true),
                    Err(error) => owner.capture_failed(windows, error, done),
                }
            },
        );
    }
    fn capture_failed(self: &Rc<Self>, windows: Vec<Rc<Ui>>, error: String, done: CaptureDone) {
        let lang = windows.first().map_or(crate::Language(false), |ui| ui.lang);
        let detail = format!("{}\n\n{error}", lang.text(
            "Der bisherige Startzustand bleibt unverändert. Ohne Aktualisierung werden beim nächsten Start möglicherweise ältere Fenster und Dateipfade geöffnet. Dokumentinhalte werden hier nicht gespeichert.",
            "The previous startup state is retained. Without updating it, the next launch may reopen older windows and file paths. Document contents are not stored here."));
        for ui in &windows {
            ui.status.set_text(&detail);
        }
        let parent = windows
            .iter()
            .find(|ui| ui.window.is_visible())
            .map(|ui| ui.window.clone());
        let dialog = gtk::AlertDialog::builder()
            .message(lang.text("Startzustand nicht gespeichert", "Startup state not saved"))
            .detail(&detail)
            .buttons([
                lang.text("Abbrechen", "Cancel"),
                lang.text("Ohne Aktualisierung beenden", "Quit without updating"),
                lang.text("Erneut versuchen", "Retry"),
            ])
            .cancel_button(0)
            .default_button(0)
            .build();
        let state = self.clone();
        dialog.choose(
            parent.as_ref(),
            None::<&gio::Cancellable>,
            move |result| match result {
                Ok(1) => done(true),
                Ok(2) => state.capture(windows, done),
                _ => done(false),
            },
        );
    }
}
pub(crate) fn install(app: &gtk::Application, factory: WindowFactory) {
    let state = state();
    *state.app.borrow_mut() = app.downgrade();
    *state.boot.factory.borrow_mut() = Some(factory);
    state.load();
}
pub(crate) fn activate(app: &gtk::Application) {
    boot::request(&state(), app, boot::Request::Activate);
}
pub(crate) fn open(app: &gtk::Application, files: &[gio::File]) {
    boot::request(&state(), app, boot::Request::Open(files.to_vec()));
}
pub(crate) fn interrupt(ui: &Ui) {
    ui.startup_restore_epoch
        .set(ui.startup_restore_epoch.get().wrapping_add(1));
    boot::interrupt(&state(), ui);
}
pub(crate) fn cancel_restoration() {
    boot::cancel(&state());
}
pub(crate) fn capture(windows: Vec<Rc<Ui>>, done: CaptureDone) {
    state().capture(windows, done);
}
pub(super) fn controls(lang: crate::Language, root: &gtk::Box) {
    controls::install(&state(), lang, root);
}
pub(super) fn pending() -> bool {
    let s = state();
    s.loaded.get() && s.busy.get() || s.pending.get().is_some() && s.error.borrow().is_none()
}
pub(super) fn can_close(ui: &Ui) -> bool {
    if !pending() {
        return true;
    }
    ui.status.set_text(ui.lang.text(
        "Starteinstellung wird noch gespeichert. Schließen danach erneut wählen.",
        "Startup preference is still being saved. Request close again after completion.",
    ));
    false
}

#[cfg(debug_assertions)]
pub(crate) fn observation() -> serde_json::Value {
    boot::observation(&state())
}

#[cfg(debug_assertions)]
pub(crate) fn observed_position(window: &gtk::ApplicationWindow) -> serde_json::Value {
    serde_json::json!(position::capture(window))
}
