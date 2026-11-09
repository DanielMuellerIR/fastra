use super::*;
use gtk::{gio, pango};

pub(super) enum Policy {
    Deferred,
    Held(fn() -> Option<gtk::Application>),
}
type Changed = Rc<dyn Fn(bool)>;
pub(super) struct Selection {
    pub faces: Vec<font::Face>,
    pub face: RefCell<Option<String>>,
    pub loaded: Cell<bool>,
    pub busy: Cell<bool>,
    pub queued: Cell<bool>,
    pub updating: Cell<bool>,
    pub pending: RefCell<Option<Option<String>>>,
    pub error: RefCell<Option<String>>,
    filename: &'static str,
    policy: Policy,
    pub hold: RefCell<Option<gio::ApplicationHoldGuard>>,
    changed: RefCell<Option<Changed>>,
}
impl Selection {
    pub fn new(faces: Vec<font::Face>, filename: &'static str, policy: Policy) -> Rc<Self> {
        Rc::new(Self {
            faces,
            filename,
            policy,
            face: RefCell::new(None),
            loaded: Cell::new(false),
            busy: Cell::new(false),
            queued: Cell::new(false),
            updating: Cell::new(false),
            pending: RefCell::new(None),
            error: RefCell::new(None),
            hold: RefCell::new(None),
            changed: RefCell::new(None),
        })
    }
    pub fn on_change(&self, changed: impl Fn(bool) + 'static) {
        *self.changed.borrow_mut() = Some(Rc::new(changed));
    }
    fn notify(&self, apply: bool) {
        let changed = self.changed.borrow().clone();
        if let Some(changed) = changed {
            changed(apply);
        }
    }
    pub fn description(&self) -> Option<pango::FontDescription> {
        self.faces
            .iter()
            .find(|face| Some(&face.name) == self.face.borrow().as_ref())
            .map(|face| face.description.clone())
    }
    pub fn load(self: &Rc<Self>) {
        if self.busy.replace(true) {
            return;
        }
        self.notify(false);
        let root = config_root();
        let filename = self.filename;
        let owner = Rc::downgrade(self);
        crate::git_view::background(
            move || root.and_then(|root| font::store::load_named(&root, filename)),
            move |result| {
                let Some(state) = owner.upgrade() else { return };
                state.busy.set(false);
                match result {
                    Ok(preference) => {
                        *state.face.borrow_mut() = preference.face;
                        state.loaded.set(true);
                        state.error.borrow_mut().take();
                    }
                    Err(error) => *state.error.borrow_mut() = Some(error),
                }
                state.notify(true);
            },
        );
    }
    fn retain_app(&self) {
        if self.hold.borrow().is_none() {
            if let Policy::Held(app) = self.policy {
                if let Some(app) = app() {
                    *self.hold.borrow_mut() = Some(app.hold());
                }
            }
        }
    }
    pub fn choose(self: &Rc<Self>, face: Option<String>) {
        if self.updating.get()
            || !self.loaded.get()
            || face
                .as_ref()
                .is_some_and(|name| !self.faces.iter().any(|face| face.name == *name))
        {
            return;
        }
        *self.face.borrow_mut() = face.clone();
        *self.pending.borrow_mut() = Some(face);
        self.error.borrow_mut().take();
        self.retain_app();
        if matches!(self.policy, Policy::Held(_)) {
            self.notify(true);
        }
        if self.queued.replace(true) {
            return;
        }
        let state = self.clone();
        glib::idle_add_local_once(move || {
            state.queued.set(false);
            if matches!(state.policy, Policy::Deferred) {
                state.notify(true);
            }
            state.save();
        });
    }
    pub fn save(self: &Rc<Self>) {
        if self.busy.get() || !self.loaded.get() {
            return;
        }
        let Some(face) = self.pending.borrow_mut().take() else {
            self.hold.borrow_mut().take();
            self.notify(false);
            return;
        };
        self.busy.set(true);
        self.retain_app();
        self.notify(false);
        let root = config_root();
        let filename = self.filename;
        let retry = face.clone();
        let owner = Rc::downgrade(self);
        crate::git_view::background(
            move || root.and_then(|root| font::store::save_named(&root, filename, face)),
            move |result| {
                let Some(state) = owner.upgrade() else { return };
                state.busy.set(false);
                match result {
                    Ok(()) => {
                        state.error.borrow_mut().take();
                        state.save();
                    }
                    Err(error) => {
                        if state.pending.borrow().is_none() {
                            *state.pending.borrow_mut() = Some(retry);
                        }
                        *state.error.borrow_mut() = Some(error);
                        state.hold.borrow_mut().take();
                        state.notify(false);
                    }
                }
            },
        );
    }
    pub fn sync_choice(&self, choice: &gtk::DropDown, lang: crate::Language, system: &str) -> bool {
        let current = self.face.borrow();
        let selected = current
            .as_ref()
            .and_then(|name| self.faces.iter().position(|face| face.name == *name))
            .map(|index| index + 1);
        let missing = current.is_some() && selected.is_none();
        let mut labels = vec![system.to_owned()];
        labels.extend(self.faces.iter().map(|face| face.name.clone()));
        if missing {
            labels.push(format!(
                "{}: {}",
                lang.text("Nicht verfügbar", "Unavailable"),
                current.as_ref().unwrap()
            ));
        }
        let same = choice
            .model()
            .and_downcast::<gtk::StringList>()
            .is_some_and(|model| {
                model.n_items() as usize == labels.len()
                    && labels.iter().enumerate().all(|(index, label)| {
                        model.string(index as u32).as_deref() == Some(label.as_str())
                    })
            });
        if !same {
            choice.set_model(Some(&gtk::StringList::new(
                &labels.iter().map(String::as_str).collect::<Vec<_>>(),
            )));
        }
        let index = if missing {
            labels.len() - 1
        } else {
            selected.unwrap_or(0)
        } as u32;
        if choice.selected() != index {
            choice.set_selected(index);
        }
        missing
    }
    pub fn is_pending(&self) -> bool {
        self.queued.get()
            || self.loaded.get() && self.busy.get()
            || self.pending.borrow().is_some() && self.error.borrow().is_none()
    }
}
