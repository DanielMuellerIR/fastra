//! Appweite Auswahl wie NSApp.appearance; verändert keine Desktop-Einstellungen.
use super::*;
use gtk::gio;
mod controls;
mod choice;
mod store;
mod web;
use store::Mode;
pub(crate) use web::install as install_web;
type Watcher = Rc<dyn Fn() -> bool>;
struct State {
    mode: Cell<Mode>,
    loaded: Cell<bool>,
    busy: Cell<bool>,
    queued: Cell<bool>,
    applying: Cell<bool>,
    pending: Cell<Option<Mode>>,
    error: RefCell<Option<String>>,
    watchers: RefCell<Vec<Watcher>>,
    app: RefCell<glib::WeakRef<gtk::Application>>,
    settings: RefCell<glib::WeakRef<gtk::Settings>>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
    controls: RefCell<Vec<controls::Controls>>,
}
thread_local! {static STATE:Rc<State>=Rc::new(State{mode:Cell::new(Mode::System),loaded:Cell::new(false),busy:Cell::new(false),queued:Cell::new(false),applying:Cell::new(false),pending:Cell::new(None),error:RefCell::new(None),watchers:RefCell::new(Vec::new()),app:RefCell::new(glib::WeakRef::new()),settings:RefCell::new(glib::WeakRef::new()),hold:RefCell::new(None),controls:RefCell::new(Vec::new())});}
fn state() -> Rc<State> {
    STATE.with(Clone::clone)
}
impl State {
    fn refresh(&self) {
        controls::refresh(self);
    }
    fn notify(&self) {
        let watchers = self.watchers.borrow().clone();
        let expired: Vec<_> = watchers.iter().filter(|watch| !watch()).cloned().collect();
        self.watchers
            .borrow_mut()
            .retain(|watch| !expired.iter().any(|old| Rc::ptr_eq(old, watch)));
    }
    fn apply(&self) {
        if !self.applying.replace(true) {
            if let Some(settings) = self.settings.borrow().upgrade() {
                match self.mode.get().explicit() {
                    Some(dark) => settings.set_gtk_application_prefer_dark_theme(dark),
                    None => settings.reset_property("gtk-application-prefer-dark-theme"),
                }
            }
            self.applying.set(false);
        }
        self.notify();
        self.refresh();
    }
    fn load(self: &Rc<Self>) {
        if self.busy.replace(true) {
            return;
        }
        self.refresh();
        let root = config_root();
        let weak = Rc::downgrade(self);
        crate::git_view::background(
            move || root.and_then(|root| store::load(&root)),
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.busy.set(false);
                match result {
                    Ok(mode) => {
                        state.mode.set(mode);
                        state.loaded.set(true);
                        state.error.borrow_mut().take();
                    }
                    Err(error) => {
                        *state.error.borrow_mut() = Some(error);
                    }
                }
                state.apply();
            },
        );
    }
    fn retain_app(&self) {
        if self.hold.borrow().is_none() {
            if let Some(app) = self.app.borrow().upgrade() {
                *self.hold.borrow_mut() = Some(app.hold());
            }
        }
    }
    fn choose(self: &Rc<Self>, mode: Mode) {
        if !self.loaded.get() || self.applying.get() {
            return;
        }
        self.mode.set(mode);
        self.pending.set(Some(mode));
        self.error.borrow_mut().take();
        self.retain_app();
        self.apply();
        if self.queued.replace(true) {
            return;
        }
        let state = self.clone();
        glib::idle_add_local_once(move || {
            state.queued.set(false);
            state.save();
        });
    }
    fn save(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(mode) = self.pending.take() else {
            self.hold.borrow_mut().take();
            return;
        };
        self.busy.set(true);
        self.retain_app();
        self.refresh();
        let root = config_root();
        let weak = Rc::downgrade(self);
        crate::git_view::background(
            move || root.and_then(|root| store::save(&root, mode)),
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.busy.set(false);
                match result {
                    Ok(()) => {
                        state.error.borrow_mut().take();
                        state.save();
                    }
                    Err(error) => {
                        if state.pending.get().is_none() {
                            state.pending.set(Some(mode));
                        }
                        *state.error.borrow_mut() = Some(error);
                        state.hold.borrow_mut().take();
                    }
                }
                state.refresh();
            },
        );
    }
}
pub(crate) fn explicit() -> Option<bool> {
    state().mode.get().explicit()
}
pub(crate) fn dark(settings: &gtk::Settings) -> bool {
    explicit().unwrap_or_else(|| {
        settings.is_gtk_application_prefer_dark_theme()
            || std::env::var("GTK_THEME").is_ok_and(|theme| theme.ends_with(":dark"))
            || settings
                .gtk_theme_name()
                .is_some_and(|name| name.to_lowercase().contains("dark"))
    })
}
pub(crate) fn watch(callback: impl Fn() -> bool + 'static) {
    state().watchers.borrow_mut().push(Rc::new(callback));
}
pub(crate) fn install(app: &gtk::Application) {
    let state = state();
    *state.app.borrow_mut() = app.downgrade();
    let owner = state.clone();
    app.connect_startup(move |_| {
        let Some(settings) = gtk::Settings::default() else {
            return;
        };
        *owner.settings.borrow_mut() = settings.downgrade();
        for property in ["gtk-theme-name", "gtk-application-prefer-dark-theme"] {
            let weak = Rc::downgrade(&owner);
            settings.connect_notify_local(Some(property), move |_, _| {
                if let Some(state) = weak.upgrade().filter(|state| !state.applying.get()) {
                    state.notify();
                }
            });
        }
        owner.apply();
    });
    state.load();
}
pub(super) fn controls(lang: crate::Language, root: &gtk::Box) {
    controls::install(lang, root);
}
pub(crate) fn pending() -> bool {
    let state = state();
    state.queued.get()
        || state.loaded.get() && state.busy.get()
        || state.pending.get().is_some() && state.error.borrow().is_none()
}
pub(super) fn can_close(ui: &Ui) -> bool {
    if !pending() {
        return true;
    }
    ui.status.set_text(ui.lang.text(
        "Erscheinungsbild wird noch gespeichert. Schließen danach erneut wählen.",
        "Appearance preference is still being saved. Request close again after completion.",
    ));
    false
}

#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
pub(crate) fn run_selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}

pub(super) fn resize_controls(window: &gtk::Window) { controls::resize(window); }
