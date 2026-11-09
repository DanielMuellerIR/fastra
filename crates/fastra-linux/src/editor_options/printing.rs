use super::*;
use gtk::gio;
mod controls;
mod store;
use store::Changes;
pub(crate) use store::Values;

struct State {
    values: Cell<Values>,
    loaded: Cell<bool>,
    busy: Cell<bool>,
    updating: Cell<bool>,
    pending: Cell<Option<Changes>>,
    error: RefCell<Option<String>>,
    app: RefCell<glib::WeakRef<gtk::Application>>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
    forms: RefCell<Vec<controls::Form>>,
    feedback: RefCell<Vec<controls::Feedback>>,
}
thread_local! { static STATE: Rc<State> = Rc::new(State {
    values: Cell::new(Values::default()), loaded: Cell::new(false), busy: Cell::new(false),
    updating: Cell::new(false), pending: Cell::new(None), error: RefCell::new(None),
    app: RefCell::new(glib::WeakRef::new()), hold: RefCell::new(None),
    forms: RefCell::new(Vec::new()), feedback: RefCell::new(Vec::new()),
}); }
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
            move || root.and_then(|root| store::load(&root)),
            move |result| {
                let Some(state) = owner.upgrade() else { return };
                state.busy.set(false);
                match result {
                    Ok(values) => {
                        state.values.set(values);
                        state.loaded.set(true);
                        state.error.borrow_mut().take();
                    }
                    Err(error) => {
                        *state.error.borrow_mut() = Some(error);
                    }
                }
                state.refresh();
                state.hold.borrow_mut().take();
            },
        );
    }
    fn choose(self: &Rc<Self>, changes: Changes) {
        if !self.loaded.get() || self.updating.get() {
            return;
        }
        let value = changes.apply(self.values.get());
        if value == self.values.get() && self.pending.get().is_none() {
            return;
        }
        self.values.set(value);
        let mut pending = self.pending.take().unwrap_or_default();
        pending.merge(changes);
        self.pending.set(Some(pending));
        self.error.borrow_mut().take();
        self.refresh();
        self.save();
    }
    fn save(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(changes) = self.pending.take() else {
            return;
        };
        self.busy.set(true);
        self.retain_app();
        self.refresh();
        let root = config_root();
        let owner = Rc::downgrade(self);
        crate::git_view::background(
            move || root.and_then(|root| store::save(&root, changes)),
            move |result| {
                let Some(state) = owner.upgrade() else { return };
                state.busy.set(false);
                match result {
                    Ok(values) => {
                        state.values.set(
                            state
                                .pending
                                .get()
                                .map_or(values, |pending| pending.apply(values)),
                        );
                        state.error.borrow_mut().take();
                        state.refresh();
                        if state.pending.get().is_some() {
                            state.save();
                        } else {
                            state.hold.borrow_mut().take();
                        }
                    }
                    Err(error) => {
                        let mut retained = changes;
                        if let Some(newer) = state.pending.take() {
                            retained.merge(newer);
                        }
                        state.pending.set(Some(retained));
                        *state.error.borrow_mut() = Some(error);
                        state.refresh();
                        state.hold.borrow_mut().take();
                    }
                }
            },
        );
    }
    fn retry(self: &Rc<Self>) {
        if self.loaded.get() {
            self.save();
        } else {
            self.load();
        }
    }
}
pub(crate) fn install(app: &gtk::Application) {
    let state = state();
    *state.app.borrow_mut() = app.downgrade();
    state.load();
}
pub(crate) fn values(lang: crate::Language) -> Result<Values, String> {
    let state = state();
    if let Some(error) = state.error.borrow().as_ref() {
        return Err(format!("{}: {error}", lang.text(
            "Druckeinstellungen konnten nicht geladen oder gespeichert werden. In den Einstellungen erneut versuchen",
            "Print preferences could not be loaded or saved. Retry in Settings",
        )));
    }
    if !state.loaded.get() || state.busy.get() || state.pending.get().is_some() {
        return Err(lang
            .text(
                "Druckeinstellungen werden noch geladen oder gespeichert. Bitte erneut drucken.",
                "Print preferences are still loading or saving. Please print again.",
            )
            .into());
    }
    Ok(state.values.get())
}
pub(crate) fn line_numbers(value: bool) {
    state().choose(Changes {
        line_numbers: Some(value),
        ..Changes::default()
    });
}
pub(crate) fn header_footer(value: bool) {
    state().choose(Changes {
        header_footer: Some(value),
        ..Changes::default()
    });
}
pub(crate) fn syntax_colors(value: bool) {
    state().choose(Changes {
        syntax_colors: Some(value),
        ..Changes::default()
    });
}
pub(super) fn form(lang: crate::Language, root: &gtk::Box) {
    controls::form(&state(), lang, root);
}
pub(crate) fn feedback(lang: crate::Language, root: &gtk::Box) {
    controls::feedback(&state(), lang, root);
}
pub(super) fn commit_forms() {
    controls::commit(&state());
}
pub(super) fn pending() -> bool {
    let state = state();
    state.loaded.get() && state.busy.get()
        || state.pending.get().is_some() && state.error.borrow().is_none()
}
pub(super) fn can_close(ui: &Ui) -> bool {
    if !pending() {
        return true;
    }
    ui.status.set_text(ui.lang.text(
        "Druckeinstellungen werden noch gespeichert. Schließen danach erneut wählen.",
        "Print preferences are still being saved. Request close again after completion.",
    ));
    false
}
#[cfg(debug_assertions)]
pub(crate) fn observation() -> serde_json::Value {
    let state = state();
    serde_json::json!({"loaded":state.loaded.get(),"busy":state.busy.get(),"error":state.error.borrow().as_deref(),"values":state.values.get()})
}
