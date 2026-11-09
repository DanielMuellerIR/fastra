//! Globale Vorgabe und ausdrückliche Dokumentwahl bleiben voneinander getrennt.
use super::*;
use gtk::gio;
mod choice;
mod controls;
mod store;
#[derive(Clone, Copy, PartialEq, Eq)]
enum Stage {
    Load,
    Save,
    Change,
}
struct Failure {
    stage: Stage,
    detail: String,
}
struct State {
    choice: Cell<Option<bool>>,
    loaded: Cell<bool>,
    busy: Cell<bool>,
    transaction: Cell<bool>,
    queued: Cell<bool>,
    applying: Cell<bool>,
    pending: Cell<Option<bool>>,
    retry_change: Cell<Option<bool>>,
    error: RefCell<Option<Failure>>,
    app: RefCell<glib::WeakRef<gtk::Application>>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
    controls: RefCell<Vec<controls::Controls>>,
    dialog: RefCell<Option<choice::Dialog>>,
}
thread_local! {static STATE:Rc<State>=Rc::new(State{choice:Cell::new(None),loaded:Cell::new(false),busy:Cell::new(false),transaction:Cell::new(false),queued:Cell::new(false),applying:Cell::new(false),pending:Cell::new(None),retry_change:Cell::new(None),error:RefCell::new(None),app:RefCell::new(glib::WeakRef::new()),hold:RefCell::new(None),controls:RefCell::new(Vec::new()),dialog:RefCell::new(None)});}
fn state() -> Rc<State> {
    STATE.with(Clone::clone)
}
fn owners() -> Vec<(Rc<Ui>, Rc<Document>)> {
    super::markdown_preview::owners()
}
fn message(de: &'static str, en: &'static str) -> String {
    owners()
        .first()
        .map_or(crate::Language(false), |(ui, _)| ui.lang)
        .text(de, en)
        .to_owned()
}
impl State {
    fn refresh(&self) {
        controls::refresh(self);
        choice::refresh(self);
    }
    fn hold_app(&self) {
        if self.hold.borrow().is_none() {
            if let Some(app) = self.app.borrow().upgrade() {
                *self.hold.borrow_mut() = Some(app.hold());
            }
        }
    }
    fn release_if_idle(&self) {
        if !self.transaction.get()
            && !self.busy.get()
            && !self.queued.get()
            && (self.pending.get().is_none() || self.error.borrow().is_some())
        {
            self.hold.borrow_mut().take();
        }
    }
    fn apply_document(self: &Rc<Self>, ui: &Rc<Ui>, doc: &Rc<Document>) {
        if self.transaction.get() || !self.loaded.get() {
            return;
        }
        let visual = super::markdown_preview::eligible(doc)
            && !doc.is_read_only()
            && doc
                .markdown_visual_override
                .get()
                .unwrap_or(self.choice.get().unwrap_or(false));
        if visual != doc.is_rich_active()
            && (!visual || doc.container.is_mapped())
            && !doc.saving.get()
        {
            let toggle = doc.rich_toggle.borrow().clone();
            if let Some(toggle) = toggle.filter(|toggle| toggle.is_sensitive()) {
                let previous = doc.markdown_visual_programmatic.replace(true);
                toggle.set_active(visual);
                doc.markdown_visual_programmatic.set(previous);
            }
        }
        choice::offer(self, ui, doc);
    }
    fn apply(self: &Rc<Self>) {
        for (ui, doc) in owners() {
            self.apply_document(&ui, &doc);
            super::markdown_preview::apply_document(&ui, &doc);
        }
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
            move || root.and_then(|r| store::load(&r)),
            move |result| {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                state.busy.set(false);
                match result {
                    Ok(choice) => {
                        state.choice.set(choice);
                        state.loaded.set(true);
                        state.error.borrow_mut().take();
                    }
                    Err(error) => {
                        *state.error.borrow_mut() = Some(Failure {
                            stage: Stage::Load,
                            detail: error,
                        })
                    }
                }
                state.apply();
            },
        );
    }
    fn failure(&self, stage: Stage, detail: String) {
        *self.error.borrow_mut() = Some(Failure { stage, detail });
        if stage != Stage::Load {
            for (ui, _) in owners() {
                ui.status.set_text(ui.lang.text("Markdown-Standard nicht geändert oder gespeichert. Details und erneuter Versuch in den Einstellungen.","Markdown default could not be changed or saved. See Settings for details and retry."));
            }
        }
        self.release_if_idle();
        self.refresh();
    }
    fn choose(self: &Rc<Self>, visual: bool) {
        // GObject kann eine durch das Zurückstellen ausgelöste active-Meldung
        // bis hinter den ursprünglichen Notify-Callback verschieben.
        if self.choice.get() == Some(visual) {
            return;
        }

        if !self.loaded.get()
            || self.transaction.get()
            || self.busy.get()
            || self.queued.get()
            || self.applying.get()
        {
            return;
        }
        self.transaction.set(true);
        self.retry_change.set(Some(visual));
        self.error.borrow_mut().take();
        self.hold_app();
        self.refresh();
        let documents: Vec<_> = owners()
            .into_iter()
            .map(|(_, doc)| doc)
            .filter(|doc| super::markdown_preview::eligible(doc) || doc.is_rich_active())
            .collect();
        let weak = Rc::downgrade(self);
        crate::rich_editor::mode::prepare(
            &documents,
            visual,
            Box::new(move |prepared| {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                let Some(prepared) = prepared else {
                    state.transaction.set(false);
                    state.failure(Stage::Change,message("Eine Rich-Ansicht ist noch nicht synchronisiert oder ein Dokument wird gespeichert. Änderung angehalten; Inhalte bleiben erhalten.","A Rich view is not synchronized yet or a document is being saved. Change held; contents are retained."));
                    return;
                };
                let saving = owners().iter().any(|(_, doc)| {
                    super::markdown_preview::eligible(doc)
                        && !doc.is_read_only()
                        && doc.markdown_visual_override.get().is_none()
                        && doc.saving.get()
                });
                if saving || !prepared.commit_sources() {
                    drop(prepared);
                    state.transaction.set(false);
                    state.failure(Stage::Change,message("Dokument oder Rich-Aktion inzwischen geändert. Modusänderung angehalten; Inhalte bleiben erhalten.","Document or Rich action changed meanwhile. Mode change held; contents are retained."));
                    return;
                }
                state.choice.set(Some(visual));
                state.pending.set(Some(visual));
                state.retry_change.set(None);
                state.transaction.set(false);
                state.error.borrow_mut().take();
                let queue_save = !state.queued.replace(true);
                state.apply();
                drop(prepared);
                if queue_save {
                    let state = state.clone();
                    glib::idle_add_local_once(move || {
                        state.queued.set(false);
                        state.save();
                    });
                }
            }),
        );
    }
    fn save(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let Some(visual) = self.pending.take() else {
            self.release_if_idle();
            return;
        };
        self.busy.set(true);
        self.hold_app();
        self.refresh();
        let root = config_root();
        let weak = Rc::downgrade(self);
        crate::git_view::background(
            move || root.and_then(|r| store::save(&r, visual)),
            move |result| {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                state.busy.set(false);
                match result {
                    Ok(()) => {
                        state.error.borrow_mut().take();
                        state.save();
                        state.refresh();
                    }
                    Err(error) => {
                        if state.pending.get().is_none() {
                            state.pending.set(Some(visual));
                        }
                        state.failure(Stage::Save, error);
                    }
                }
            },
        );
    }
    fn retry(self: &Rc<Self>) {
        let stage = self.error.borrow().as_ref().map(|error| error.stage);
        match stage {
            Some(Stage::Load) => self.load(),
            Some(Stage::Change) => {
                if let Some(visual) = self.retry_change.get() {
                    self.choose(visual);
                }
            }
            Some(Stage::Save) => self.save(),
            None => {}
        }
    }
}
pub(crate) fn install(app: &gtk::Application) {
    let state = state();
    *state.app.borrow_mut() = app.downgrade();
    state.load();
}
pub(crate) fn apply_document(ui: &Rc<Ui>, doc: &Rc<Document>) {
    state().apply_document(ui, doc);
}
pub(crate) fn ready_for_preview() -> bool {
    let state = state();
    state.loaded.get() || state.error.borrow().is_some()
}
pub(super) fn controls(lang: crate::Language, root: &gtk::Box) {
    controls::install(lang, root);
}
pub(super) fn pending() -> bool {
    let state = state();
    state.transaction.get()
        || state.queued.get()
        || state.loaded.get() && state.busy.get()
        || state.pending.get().is_some() && state.error.borrow().is_none()
}
pub(super) fn can_close(ui: &Ui) -> bool {
    if !pending() {
        return true;
    }
    ui.status.set_text(ui.lang.text(
        "Markdown-Modus wird noch übernommen oder gespeichert. Schließen danach erneut wählen.",
        "Markdown mode is still being applied or saved. Request close again after completion.",
    ));
    false
}

pub(crate) fn toggle_document(ui: &Rc<Ui>) -> bool {
    let Some(doc) = ui
        .active()
        .filter(|doc| super::markdown_preview::eligible(doc) && !doc.is_read_only())
    else {
        return false;
    };
    if let Some(toggle) = doc
        .rich_toggle
        .borrow()
        .clone()
        .filter(|toggle| toggle.is_sensitive())
    {
        toggle.set_active(!toggle.is_active());
        return true;
    }
    false
}

#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
pub(crate) fn run_selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}
