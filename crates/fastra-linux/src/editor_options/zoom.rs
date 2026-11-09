//! Getrennte, globale Vergrößerung wie auf dem Mac; Dokumentinhalte bleiben unberührt.
use super::*;
use gtk::gio;
use webkit6::prelude::*;
mod controls;
mod keys;
mod store;
use store::Levels;
type Watcher = Rc<dyn Fn() -> bool>;
struct State {
    levels: Cell<Levels>,
    loaded: Cell<bool>,
    busy: Cell<bool>,
    queued: Cell<bool>,
    pending: Cell<Option<Levels>>,
    error: RefCell<Option<String>>,
    watchers: RefCell<Vec<Watcher>>,
    app: RefCell<glib::WeakRef<gtk::Application>>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
    window: RefCell<glib::WeakRef<gtk::Window>>,
}
thread_local! { static STATE: Rc<State> = Rc::new(State {
    levels: Cell::new(Levels::default()), loaded: Cell::new(false), busy: Cell::new(false),
    queued: Cell::new(false), pending: Cell::new(None), error: RefCell::new(None),
    watchers: RefCell::new(Vec::new()), app: RefCell::new(glib::WeakRef::new()),
    hold: RefCell::new(None), window: RefCell::new(glib::WeakRef::new()),
}); }
fn state() -> Rc<State> {
    STATE.with(Clone::clone)
}
impl State {
    fn refresh(&self) {
        // Callbacks dürfen erneut auf den gemeinsamen Zustand zugreifen.
        let watchers = self.watchers.borrow().clone();
        let expired: Vec<_> = watchers.iter().filter(|watch| !watch()).cloned().collect();
        self.watchers
            .borrow_mut()
            .retain(|watch| !expired.iter().any(|old| Rc::ptr_eq(old, watch)));
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
                    Ok(levels) => {
                        state.levels.set(levels);
                        state.loaded.set(true);
                        state.error.borrow_mut().take();
                    }
                    Err(error) => {
                        *state.error.borrow_mut() = Some(error);
                    }
                }
                state.refresh();
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
    fn choose(self: &Rc<Self>, levels: Levels) {
        if !self.loaded.get() {
            return;
        }
        self.levels.set(levels);
        self.pending.set(Some(levels));
        self.error.borrow_mut().take();
        self.retain_app();
        if self.queued.replace(true) {
            return;
        }
        let state = self.clone();
        glib::idle_add_local_once(move || {
            state.queued.set(false);
            state.refresh();
            state.save();
        });
    }
    fn save(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(levels) = self.pending.take() else {
            self.hold.borrow_mut().take();
            return;
        };
        self.busy.set(true);
        self.retain_app();
        self.refresh();
        let root = config_root();
        let weak = Rc::downgrade(self);
        crate::git_view::background(
            move || root.and_then(|root| store::save(&root, levels)),
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
                            state.pending.set(Some(levels));
                        }
                        *state.error.borrow_mut() = Some(error);
                        state.hold.borrow_mut().take();
                    }
                }
                state.refresh();
            },
        );
    }
    fn change(self: &Rc<Self>, document: bool, delta: Option<i32>) {
        let mut levels = self.levels.get();
        let (value, min, max) = if document {
            (&mut levels.document, -4, 8)
        } else {
            (&mut levels.ui, -3, 5)
        };
        *value = delta.map_or(0, |delta| (*value + delta).clamp(min, max));
        self.choose(levels);
    }
}
pub(crate) fn watch(callback: impl Fn() -> bool + 'static) {
    state().watchers.borrow_mut().push(Rc::new(callback));
}
fn scale(document: bool) -> f64 {
    let levels = state().levels.get();
    if document {
        1. + f64::from(levels.document) * 0.12
    } else {
        1. + f64::from(levels.ui) * 0.13
    }
}
// Ausschließlich unsere statischen Pixel-Schriftgrößen skalieren; Abstände und
// Dokumentrollen bleiben an derselben zentralen CSS-Quelle definiert.
fn scale_property(css: &str, property: &str, scale: f64) -> String {
    let mut output = String::new();
    let mut rest = css;
    while let Some((before, after)) = rest.split_once(property) {
        output.push_str(before);
        output.push_str(property);
        let trimmed = after.trim_start();
        let count = trimmed
            .bytes()
            .take_while(|b| b.is_ascii_digit() || *b == b'.')
            .count();
        if let Ok(value) = trimmed[..count].parse::<f64>() {
            if let Some(tail) = trimmed[count..].strip_prefix("px") {
                output.push_str(&format!(" {:.3}px", value * scale));
                rest = tail;
                continue;
            }
        }
        rest = after;
    }
    output.push_str(rest);
    output
}
pub(crate) fn ui_scale() -> f64 {
    scale(false)
}
pub(crate) fn stylesheet() -> String {
    let css = include_str!("../chrome/style.css");
    let ui = scale(false);
    let css = if ui == 1. {
        css.to_owned()
    } else {
        scale_property(
            &scale_property(css, "font-size:", ui),
            "-gtk-icon-size:",
            ui,
        )
    };
    format!(
        "{css}\n.fastra-document {{ font-size: {:.3}px; }}",
        13. * scale(true)
    )
}
pub(crate) fn install_web(view: &webkit6::WebView) {
    if let Some(settings) = webkit6::prelude::WebViewExt::settings(view) {
        settings.set_zoom_text_only(true);
    }
    view.set_zoom_level(scale(true));
    let weak = view.downgrade();
    watch(move || {
        let Some(view) = weak.upgrade() else {
            return false;
        };
        view.set_zoom_level(scale(true));
        true
    });
}
pub(crate) fn install(app: &gtk::Application) {
    let state = crate::editor_options::zoom::state();
    *state.app.borrow_mut() = app.downgrade();
    for (name, document, delta, accelerators) in [
        (
            "ui-larger",
            false,
            Some(1),
            vec!["<Control>plus", "<Control>equal", "<Control>KP_Add"],
        ),
        (
            "ui-smaller",
            false,
            Some(-1),
            vec!["<Control>minus", "<Control>KP_Subtract"],
        ),
        (
            "ui-original",
            false,
            None,
            vec!["<Control>0", "<Control>KP_0"],
        ),
        (
            "document-larger",
            true,
            Some(1),
            vec![
                "<Control><Shift>plus",
                "<Control><Shift>equal",
                "<Control><Shift>KP_Add",
            ],
        ),
        (
            "document-smaller",
            true,
            Some(-1),
            vec![
                "<Control><Shift>minus",
                "<Control>underscore",
                "<Control><Shift>KP_Subtract",
            ],
        ),
        (
            "document-original",
            true,
            None,
            vec!["<Control><Shift>0", "<Control><Shift>KP_0"],
        ),
    ] {
        let action = gio::SimpleAction::new(name, None);
        let owner = state.clone();
        action.connect_activate(move |_, _| owner.change(document, delta));
        app.add_action(&action);
        app.set_accels_for_action(&format!("app.{name}"), &accelerators);
        let weak = action.downgrade();
        watch(move || {
            let Some(action) = weak.upgrade() else {
                return false;
            };
            let state = crate::editor_options::zoom::state();
            let levels = state.levels.get();
            let (level, min, max) = if document {
                (levels.document, -4, 8)
            } else {
                (levels.ui, -3, 5)
            };
            action.set_enabled(
                state.loaded.get()
                    && match delta {
                        Some(1) => level < max,
                        Some(-1) => level > min,
                        _ => level != 0,
                    },
            );
            true
        });
    }
    let action = gio::SimpleAction::new("settings", None);
    let weak = app.downgrade();
    action.connect_activate(move |_, _| {
        if let Some(app) = weak.upgrade() {
            controls::open(&app);
        }
    });
    app.add_action(&action);
    app.set_accels_for_action("app.settings", &["<Control>comma"]);
    app.connect_window_added(|_, window| keys::install(window));
    state.load();
}
pub(crate) fn menu(ui: &Rc<Ui>, commands: &gtk::Box, popover: &gtk::Popover) {
    controls::menu(ui, commands, popover);
}
pub(super) fn pending() -> bool {
    let state = crate::editor_options::zoom::state();
    state.queued.get()
        || state.loaded.get() && state.busy.get()
        || state.pending.get().is_some() && state.error.borrow().is_none()
}
pub(super) fn can_close(ui: &Ui) -> bool {
    if !pending() {
        return true;
    }
    ui.status.set_text(ui.lang.text(
        "Größeneinstellung wird noch gespeichert. Schließen danach erneut wählen.",
        "Size preference is still being saved. Request close again after completion.",
    ));
    false
}

#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
pub(crate) fn run_selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}
