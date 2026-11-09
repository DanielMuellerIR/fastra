//! Appweites Beenden sammelt erst Freigaben; kein früheres Fenster verschwindet bei Cancel.
use super::*;
use crate::close_protocol::{self, Abort, Permit};
use gtk::gdk::{Key, ModifierType};
use std::{cell::Cell, rc::Weak};
thread_local! {static COORDINATOR:RefCell<Weak<Coordinator>>=const {RefCell::new(Weak::new())};}
struct Coordinator {
    app: glib::WeakRef<gtk::Application>,
    windows: Rc<RefCell<Vec<Rc<Ui>>>>,
    attempt: RefCell<Option<Rc<Attempt>>>,
}
struct Attempt {
    owner: Weak<Coordinator>,
    windows: Vec<Rc<Ui>>,
    permits: RefCell<Vec<Rc<Permit>>>,
    live: Cell<bool>,
    startup_recorded: Cell<bool>,
    failure: Cell<Option<(usize, Abort)>>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
}
impl Attempt {
    fn current(&self) -> bool {
        self.live.get()
            && self.owner.upgrade().is_some_and(|owner| {
                let current = owner.windows.borrow();
                current.len() == self.windows.len()
                    && current
                        .iter()
                        .zip(&self.windows)
                        .all(|(now, prior)| Rc::ptr_eq(now, prior))
            })
    }
    fn abort(&self) {
        if !self.live.replace(false) {
            return;
        }
        let prepared = self.permits.borrow().clone();
        for permit in prepared {
            permit.cancel();
        }
        for (index, ui) in self.windows.iter().enumerate() {
            let ticket = ui.close_ticket.borrow().as_ref().and_then(Weak::upgrade);
            if let Some(ticket) = ticket {
                ticket.cancel();
            }
            let keep_detail = matches!(self.failure.get(),Some((origin,Abort::Failed|Abort::Blocked)) if origin==index);
            if ui.window.is_visible() && !keep_detail {
                ui.status.set_text(ui.lang.text(
                    "Beenden angehalten; alle Fenster bleiben offen.",
                    "Quit held; all windows remain open.",
                ));
            }
        }
        self.permits.borrow_mut().clear();
        self.hold.borrow_mut().take();
        if let Some(owner) = self.owner.upgrade() {
            owner.attempt.borrow_mut().take();
        }
    }
    fn prepare(self: &Rc<Self>, index: usize) {
        if !self.current() {
            self.abort();
            return;
        }
        let Some(ui) = self.windows.get(index) else {
            self.publish(0);
            return;
        };
        let this = self.clone();
        close_protocol::prepare(
            ui,
            Box::new(move |result| {
                if !this.current() {
                    this.abort();
                    return;
                }
                match result {
                    Ok(permit) => {
                        this.permits.borrow_mut().push(Rc::new(permit));
                        this.prepare(index + 1);
                    }
                    Err(error) => {
                        this.failure.set(Some((index, error)));
                        this.abort();
                    }
                }
            }),
        );
    }
    fn valid(&self) -> bool {
        !crate::asset_io::pending() && !crate::git_pull::pending()
            && !crate::editor_options::profiles_pending()
            && self.current()
            && self.permits.borrow().iter().all(|permit| permit.valid())
    }
    fn publish(self: &Rc<Self>, index: usize) {
        if !self.valid() {
            self.abort();
            return;
        }
        if index == 0 {
            for permit in self.permits.borrow().iter() {
                permit.freeze();
            }
        }
        let permit = self.permits.borrow().get(index).cloned();
        let Some(permit) = permit else {
            self.finalize(0);
            return;
        };
        let this = self.clone();
        permit.publish(Box::new(move |ok| {
            if ok {
                this.publish(index + 1);
            } else {
                this.abort();
            }
        }));
    }
    fn finalize(self: &Rc<Self>, index: usize) {
        if !self.valid() {
            self.abort();
            return;
        }
        let permit = self.permits.borrow().get(index).cloned();
        let Some(permit) = permit else {
            self.commit();
            return;
        };
        let this = self.clone();
        permit.finalize(Box::new(move |ok| {
            if ok {
                this.finalize(index + 1);
            } else {
                this.abort();
            }
        }));
    }
    fn commit(self: &Rc<Self>) {
        let pending = self.clone();
        glib::idle_add_local_once(move || pending.commit_ready());
    }
    fn commit_ready(self: &Rc<Self>) {
        if !self.valid() {
            self.abort();
            return;
        }
        let Some(owner) = self.owner.upgrade() else {
            self.abort();
            return;
        };
        let Some(app) = owner.app.upgrade() else {
            self.abort();
            return;
        };
        if !self.startup_recorded.get() {
            let this = self.clone();
            crate::editor_options::startup::capture(self.windows.clone(), Box::new(move |ok| {
                if ok && this.valid() { this.startup_recorded.set(true); this.commit(); }
                else { this.abort(); }
            }));
            return;
        }
        let permits = self.permits.borrow().clone();
        // Ab hier keine weitere Ereignisschleife zwischen Prüfung und Close-Requests.
        for permit in permits {
            permit.close();
        }
        if !owner.windows.borrow().is_empty() {
            self.abort();
            return;
        }
        self.live.set(false);
        self.cleanup(0, app);
    }
    fn cleanup(self: &Rc<Self>, index: usize, app: gtk::Application) {
        let permit = self.permits.borrow().get(index).cloned();
        let Some(permit) = permit else {
            self.hold.borrow_mut().take();
            if let Some(owner) = self.owner.upgrade() {
                owner.attempt.borrow_mut().take();
                // Open/Activate nach dem abgeschlossenen Close darf nicht verschluckt werden.
                if owner.windows.borrow().is_empty() {
                    app.quit();
                }
            }
            return;
        };
        let this = self.clone();
        permit.cleanup(Box::new(move |_ok| this.cleanup(index + 1, app)));
    }
}
impl Coordinator {
    fn request(self: &Rc<Self>) {
        crate::editor_options::startup::cancel_restoration();
        if self.attempt.borrow().is_some() {
            return;
        }
        let Some(app) = self.app.upgrade() else {
            return;
        };
        let windows = self.windows.borrow().clone();
        let mut profiles_ready = true;
        for ui in &windows {
            let ready = crate::editor_options::profiles_can_close(ui);
            profiles_ready &= ready;
        }
        if !profiles_ready {
            return;
        }
        if crate::git_pull::pending() { for ui in &windows { crate::git_pull::can_close(ui); } return; }
        if crate::asset_io::pending() {
            for ui in &windows {
                crate::asset_io::can_close(ui);
            }
            return;
        }
        if windows.iter().any(|ui| close_protocol::active(ui)) {
            for ui in &windows {
                ui.status.set_text(ui.lang.text(
                    "Laufende Schließentscheidung zuerst abschließen.",
                    "Finish the pending close decision first.",
                ));
            }
            return;
        }
        let attempt = Rc::new(Attempt {
            owner: Rc::downgrade(self),
            windows,
            permits: RefCell::new(Vec::new()),
            live: Cell::new(true),
            startup_recorded: Cell::new(false),
            failure: Cell::new(None),
            hold: RefCell::new(Some(app.hold())),
        });
        *self.attempt.borrow_mut() = Some(attempt.clone());
        attempt.prepare(0);
    }
}
/// Verborgene Fenster bleiben bis zum tatsächlichen window-removed im Inventar.
pub(crate) fn ordinary_windows()->Option<Vec<Rc<Ui>>> {COORDINATOR.with_borrow(|owner|owner.upgrade().and_then(|owner|owner.windows.try_borrow().ok().map(|windows|windows.clone())))}
pub(super) fn install(app: &gtk::Application, windows: &Rc<RefCell<Vec<Rc<Ui>>>>) {
    let coordinator = Rc::new(Coordinator {
        app: app.downgrade(),
        windows: windows.clone(),
        attempt: RefCell::new(None),
    });
    COORDINATOR.with(|slot| *slot.borrow_mut() = Rc::downgrade(&coordinator));
    let attached: Rc<RefCell<Vec<glib::WeakRef<gtk::Window>>>> = Rc::default();
    let watching: Rc<RefCell<Option<(gio::ListModel, glib::SignalHandlerId)>>> = Rc::default();
    let watcher = watching.clone();
    app.connect_window_added(move |_, window| {
        attach_window(window, &attached);
        if watcher.borrow().is_none() {
            // Auch nicht registrierte native Hilfs- und Chooserfenster gehören zu dieser App.
            let model = gtk::Window::toplevels();
            let known = attached.clone();
            let handler = model.connect_items_changed(move |model, from, _, added| {
                for index in from..from + added {
                    if let Some(window) = model.item(index).and_downcast::<gtk::Window>() {
                        attach_window(&window, &known);
                    }
                }
            });
            for index in 0..model.n_items() {
                if let Some(window) = model.item(index).and_downcast::<gtk::Window>() {
                    attach_window(&window, &attached);
                }
            }
            *watcher.borrow_mut() = Some((model, handler));
        }
    });
    app.connect_shutdown(move |_| {
        if let Some((model, handler)) = watching.borrow_mut().take() {
            model.disconnect(handler);
        }
        if let Some(attempt) = coordinator.attempt.borrow_mut().take() {
            attempt.live.set(false);
            attempt.hold.borrow_mut().take();
        }
    });
}
fn attach_window(window: &gtk::Window, attached: &Rc<RefCell<Vec<glib::WeakRef<gtk::Window>>>>) {
    let mut known = attached.borrow_mut();
    known.retain(|item| item.upgrade().is_some());
    if known
        .iter()
        .any(|item| item.upgrade().as_ref() == Some(window))
    {
        return;
    }
    known.push(window.downgrade());
    drop(known);
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    keys.connect_key_pressed(|_, key, _, modifiers| {
        if shortcut(key, modifiers) {
            request();
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    window.add_controller(keys);
}
pub(crate) fn request() {
    COORDINATOR.with(|slot| {
        if let Some(owner) = slot.borrow().upgrade() {
            owner.request();
        }
    });
}
pub(crate) fn abort() {
    COORDINATOR.with(|slot| {
        if let Some(owner) = slot.borrow().upgrade() {
            let attempt = owner.attempt.borrow().clone();
            if let Some(attempt) = attempt {
                attempt.abort();
            }
        }
    });
}
pub(crate) fn shortcut(key: Key, modifiers: ModifierType) -> bool {
    let relevant = modifiers
        & (ModifierType::CONTROL_MASK
            | ModifierType::SHIFT_MASK
            | ModifierType::ALT_MASK
            | ModifierType::SUPER_MASK);
    relevant == (ModifierType::CONTROL_MASK | ModifierType::SHIFT_MASK)
        && matches!(key, Key::q | Key::Q)
}
