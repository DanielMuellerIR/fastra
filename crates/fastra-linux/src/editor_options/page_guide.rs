use super::*;
use serde::{Deserialize, Serialize};
mod form;
pub(super) use form::{commit as commit_forms, controls as form_controls, refresh as refresh_forms};

#[derive(Clone, Copy, Default, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub(super) struct Patch {
    pub(super) column: Option<u32>,
    pub(super) visible: Option<bool>,
}
impl Patch {
    pub(super) fn empty(&self) -> bool {
        self.column.is_none() && self.visible.is_none()
    }
    pub(super) fn valid(&self) -> bool {
        self.column.is_none_or(|v| (20..=500).contains(&v))
    }
    pub(super) fn merge(&mut self, other: &Self) {
        if other.column.is_some() {
            self.column = other.column;
        }
        if other.visible.is_some() {
            self.visible = other.visible;
        }
    }
    fn factory() -> Self {
        Self {
            column: Some(80),
            visible: Some(false),
        }
    }
}
#[derive(Default)]
pub(super) struct Controls {
    spin: RefCell<Option<glib::WeakRef<gtk::SpinButton>>>,
    visible: RefCell<Option<glib::WeakRef<gtk::CheckButton>>>,
    status: RefCell<Option<glib::WeakRef<gtk::Label>>>,
}
impl Controls {
    pub(super) fn clear(&self) {
        self.spin.borrow_mut().take();
        self.visible.borrow_mut().take();
        self.status.borrow_mut().take();
    }
    pub(super) fn commit(&self) {
        if let Some(spin) = self.spin.borrow().as_ref().and_then(|w| w.upgrade()) {
            spin.update();
        }
    }
}
thread_local! {
    static CURRENT: Cell<Patch> = Cell::new(Patch::factory());
    static LOADING: Cell<bool> = const {Cell::new(false)};
    static LOADED: Cell<bool> = const {Cell::new(false)};
    static LOAD_ERROR: RefCell<Option<String>> = const {RefCell::new(None)};

}
pub(super) fn apply(state: &Options, value: Patch) {
    let updating = state.updating.replace(true);
    for view in state.views.iter().filter_map(|v| v.upgrade()) {
        view.set_right_margin_position(value.column.unwrap_or(80));
        view.set_show_right_margin(value.visible.unwrap_or(false));
    }
    if let Some(spin) = state
        .guide_controls
        .spin
        .borrow()
        .as_ref()
        .and_then(|w| w.upgrade())
    {
        spin.set_value(f64::from(value.column.unwrap_or(80)));
    }
    if let Some(button) = state
        .guide_controls
        .visible
        .borrow()
        .as_ref()
        .and_then(|w| w.upgrade())
    {
        button.set_active(value.visible.unwrap_or(false));
    }
    state.soft_wrap.invalidate();
    state.updating.set(updating);
    readiness(state);
}
fn publish(value: Patch) {
    CURRENT.with(|c| c.set(value));
    for owner in profile::owners() {
        apply(&owner, value);
    }
    form::refresh();
}
fn finish(result: Result<Patch, String>) {
    LOADING.with(|v| v.set(false));
    match result {
        Ok(stored) => {
            LOAD_ERROR.with(|error| error.borrow_mut().take());
            LOADED.with(|v| v.set(true));
            let mut value = Patch::factory();
            value.merge(&stored);
            publish(value);
        }
        Err(error) => {
            LOAD_ERROR.with(|slot| *slot.borrow_mut() = Some(error.clone()));
            for owner in profile::owners() {
                owner.report(error.clone());
            }
        }
    }
    for owner in profile::owners() {
        readiness(&owner);
    }
    form::refresh();
}
pub(super) fn install(state: &Rc<Options>) {
    apply(state, CURRENT.with(Cell::get));
    load();
}
fn load() {
    if LOADED.with(Cell::get) || LOADING.with(|v| v.replace(true)) {
        return;
    }
    for owner in profile::owners() {
        readiness(&owner);
    }
    super::super::git_view::background(
        move || profile::get_guide(&config_root()?),
        move |result| {
            #[cfg(debug_assertions)]
            if std::env::var_os("FASTRA_GUIDE_DELAY_SELFTEST").is_some() {
                assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                glib::timeout_add_local_once(std::time::Duration::from_millis(2000), move || {
                    finish(result)
                });
                return;
            }
            finish(result);
        },
    );
}
fn change(state: &Rc<Options>, patch: Patch) {
    if state.updating.get() || !patch.valid() || !LOADED.with(Cell::get) {
        return;
    }
    let mut value = CURRENT.with(Cell::get);
    value.merge(&patch);
    publish(value);
    profile::queue_guide(Some(state), patch);
}
pub(super) fn controls(state: &Rc<Options>, ui: &Ui, root: &gtk::Box) {
    load();
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    let heading = super::super::git_view::label(
        ui.lang
            .text("Darstellung in allen Fenstern", "Display in all windows"),
    );
    heading.add_css_class("heading");
    root.append(&heading);
    let status = super::super::git_view::label("");
    *state.guide_controls.status.borrow_mut() = Some(status.downgrade());
    root.append(&status);
    let visible =
        gtk::CheckButton::with_label(ui.lang.text("Seitenlinie anzeigen", "Show page guide"));
    visible.set_active(CURRENT.with(Cell::get).visible.unwrap_or(false));
    let weak = Rc::downgrade(state);
    visible.connect_toggled(move |w| {
        if let Some(state) = weak.upgrade() {
            change(
                &state,
                Patch {
                    visible: Some(w.is_active()),
                    ..Patch::default()
                },
            );
        }
    });
    *state.guide_controls.visible.borrow_mut() = Some(visible.downgrade());
    root.append(&visible);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let label =
        super::super::git_view::label(ui.lang.text("Seitenlinie: Spalte", "Page guide column"));
    label.set_hexpand(true);
    row.append(&label);
    let spin = gtk::SpinButton::with_range(20., 500., 1.);
    spin.set_widget_name("fastra-page-guide-column");
    spin.set_value(f64::from(CURRENT.with(Cell::get).column.unwrap_or(80)));
    let weak = Rc::downgrade(state);
    spin.connect_value_changed(move |w| {
        if let Some(state) = weak.upgrade() {
            change(
                &state,
                Patch {
                    column: Some(w.value_as_int() as u32),
                    ..Patch::default()
                },
            );
        }
    });
    *state.guide_controls.spin.borrow_mut() = Some(spin.downgrade());
    row.append(&spin);
    root.append(&row);
    readiness(state);
}

#[cfg(debug_assertions)]
pub(super) fn ready() -> bool {
    LOADED.with(Cell::get)
}

fn readiness(state: &Options) {
    let ready = LOADED.with(Cell::get);
    if let Some(w) = state
        .guide_controls
        .spin
        .borrow()
        .as_ref()
        .and_then(|w| w.upgrade())
    {
        w.set_sensitive(ready);
    }
    if let Some(w) = state
        .guide_controls
        .visible
        .borrow()
        .as_ref()
        .and_then(|w| w.upgrade())
    {
        w.set_sensitive(ready);
    }
    if let Some(label) = state
        .guide_controls
        .status
        .borrow()
        .as_ref()
        .and_then(|w| w.upgrade())
    {
        if let Some(ui) = state.ui.upgrade() {
            label.set_text(if LOADING.with(Cell::get) {
                ui.lang.text("Seitenlinie wird geladen …", "Loading page guide …")
            } else {
                ui.lang.text("Seitenlinie noch nicht verfügbar. Editoroptionen zum erneuten Laden wieder öffnen.", "Page guide is not available yet. Reopen editor options to load it again.")
            });
        }
        label.set_visible(!ready);
    }
}
