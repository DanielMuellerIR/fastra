//! Appweite Vorschauvorgabe wie markdown.integratedPreview auf dem Mac.
use super::*;
use gtk::gio;
mod controls;
mod store;
type Owner = (Weak<Ui>, Weak<Document>);
struct State {
    shown: Cell<bool>,
    loaded: Cell<bool>,
    busy: Cell<bool>,
    queued: Cell<bool>,
    applying: Cell<bool>,
    pending: Cell<Option<bool>>,
    error: RefCell<Option<String>>,
    documents: RefCell<Vec<Owner>>,
    app: RefCell<glib::WeakRef<gtk::Application>>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
    controls: RefCell<Vec<controls::Controls>>,
}
thread_local! {static STATE:Rc<State>=Rc::new(State{shown:Cell::new(true),loaded:Cell::new(false),busy:Cell::new(false),queued:Cell::new(false),applying:Cell::new(false),pending:Cell::new(None),error:RefCell::new(None),documents:RefCell::new(Vec::new()),app:RefCell::new(glib::WeakRef::new()),hold:RefCell::new(None),controls:RefCell::new(Vec::new())});}
fn state() -> Rc<State> {
    STATE.with(Clone::clone)
}
pub(crate) fn eligible(doc: &Document) -> bool {
    doc.has_source_text()
        && doc
            .buffer
            .language()
            .is_some_and(|language| language.id() == "markdown")
}
impl State {
    fn refresh(&self) {
        controls::refresh(self);
    }
    fn set_document(&self, ui: &Rc<Ui>, doc: &Rc<Document>, shown: bool) {
        if !ui
            .documents
            .borrow()
            .iter()
            .any(|owned| Rc::ptr_eq(owned, doc))
        {
            return;
        }
        let shown = shown && eligible(doc) && !doc.is_rich_active();
        // Inaktive Tabs erhalten ihre sichtbare Vorgabe beim nächsten Map.
        // Sonst startet eine globale Wahl alle WebViews samt Renderer zugleich.
        if shown && (!doc.container.is_mapped() || !super::markdown_mode::ready_for_preview()) {
            return;
        }
        let was_applying = self.applying.replace(true);
        if let Some(toggle) = doc.markdown_toggle.borrow().as_ref() {
            toggle.set_active(shown);
        }
        self.applying.set(was_applying);
    }
    fn apply(&self) {
        let owners: Vec<_> = self
            .documents
            .borrow()
            .iter()
            .filter_map(|(ui, doc)| Some((ui.upgrade()?, doc.upgrade()?)))
            .collect();
        self.documents
            .borrow_mut()
            .retain(|(ui, doc)| ui.upgrade().is_some() && doc.upgrade().is_some());
        if self.loaded.get() {
            for (ui, doc) in owners {
                self.set_document(&ui, &doc, self.shown.get());
            }
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
            move || root.and_then(|root| store::load(&root)),
            move |result| {
                let Some(state) = weak.upgrade() else { return };
                state.busy.set(false);
                match result {
                    Ok(shown) => {
                        state.shown.set(shown);
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
    fn choose(self: &Rc<Self>, shown: bool) {
        if !self.loaded.get() || self.applying.get() {
            return;
        }
        self.shown.set(shown);
        self.pending.set(Some(shown));
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
        let Some(shown) = self.pending.take() else {
            self.hold.borrow_mut().take();
            return;
        };
        self.busy.set(true);
        self.retain_app();
        self.refresh();
        let root = config_root();
        let weak = Rc::downgrade(self);
        crate::git_view::background(
            move || root.and_then(|root| store::save(&root, shown)),
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
                            state.pending.set(Some(shown));
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
pub(crate) fn install(app: &gtk::Application) {
    let state = state();
    *state.app.borrow_mut() = app.downgrade();
    state.load();
}
pub(crate) fn owners() -> Vec<(Rc<Ui>, Rc<Document>)> {
    state()
        .documents
        .borrow()
        .iter()
        .filter_map(|(ui, doc)| Some((ui.upgrade()?, doc.upgrade()?)))
        .filter(|(ui, doc)| {
            ui.documents
                .borrow()
                .iter()
                .any(|owned| Rc::ptr_eq(owned, doc))
        })
        .collect()
}
pub(crate) fn apply_document(ui: &Rc<Ui>, doc: &Rc<Document>) {
    let state = state();
    if state.loaded.get() {
        state.set_document(ui, doc, state.shown.get());
    }
}
fn refresh_later(ui: &Rc<Ui>, doc: &Rc<Document>) {
    let ui = Rc::downgrade(ui);
    let doc = Rc::downgrade(doc);
    glib::idle_add_local_once(move || {
        if let (Some(ui), Some(doc)) = (ui.upgrade(), doc.upgrade()) {
            super::markdown_mode::apply_document(&ui, &doc);
            apply_document(&ui, &doc);
        }
    });
}
pub(crate) fn register(ui: &Rc<Ui>, doc: &Rc<Document>) {
    {
        let state = state();
        let mut documents = state.documents.borrow_mut();
        documents.retain(|(ui, doc)| ui.upgrade().is_some() && doc.upgrade().is_some());
        documents.push((Rc::downgrade(ui), Rc::downgrade(doc)));
    }
    let owner = Rc::downgrade(ui);
    let document = Rc::downgrade(doc);
    doc.container.connect_map(move |_| {
        if let (Some(ui), Some(doc)) = (owner.upgrade(), document.upgrade()) {
            refresh_later(&ui, &doc);
        }
    });
    let owner = Rc::downgrade(ui);
    let document = Rc::downgrade(doc);
    doc.buffer.connect_language_notify(move |_| {
        if let (Some(ui), Some(doc)) = (owner.upgrade(), document.upgrade()) {
            refresh_later(&ui, &doc);
        }
    });
    refresh_later(ui, doc);
}
pub(crate) fn record_toggle(ui: &Rc<Ui>, doc: &Rc<Document>) {
    let state = state();
    if state.applying.get() || !eligible(doc) || doc.is_rich_active() {
        return;
    }
    if state.loaded.get() {
        if let Some(toggle) = doc.markdown_toggle.borrow().as_ref() {
            let shown = toggle.is_active();
            state.choose(shown);
        }
    } else {
        state.set_document(ui, doc, false);
        ui.status.set_text(ui.lang.text(
            "Markdown-Vorgabe nicht geladen. In den Einstellungen erneut versuchen.",
            "Markdown preference has not loaded. Retry in Settings.",
        ));
    }
}
pub(crate) fn restore_document(ui: &Rc<Ui>, doc: &Rc<Document>, fallback: bool) {
    let state = state();
    let shown = if state.loaded.get() {
        state.shown.get()
    } else {
        fallback
    };
    state.set_document(ui, doc, shown);
}
pub(super) fn controls(lang: crate::Language, root: &gtk::Box) {
    controls::install(lang, root);
}
pub(super) fn pending() -> bool {
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
        "Markdown-Vorgabe wird noch gespeichert. Schließen danach erneut wählen.",
        "Markdown preference is still being saved. Request close again after completion.",
    ));
    false
}

#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
pub(crate) fn run_selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}
