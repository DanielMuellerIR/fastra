use super::*;
#[cfg(debug_assertions)]
thread_local! { static LIVE: Cell<usize> = const { Cell::new(0) }; }
#[cfg(debug_assertions)]
pub(super) fn live_count() -> usize {
    LIVE.with(Cell::get)
}
struct State {
    ui: std::rc::Weak<Ui>,
    doc: std::rc::Weak<Document>,
    label: glib::WeakRef<gtk::Label>,
    reopen: glib::WeakRef<gtk::Button>,
    busy: Cell<bool>,
    changed: Cell<bool>,
}
#[cfg(debug_assertions)]
impl Drop for State {
    fn drop(&mut self) {
        LIVE.with(|count| count.set(count.get() - 1));
    }
}
pub(super) fn attach(ui: &Rc<Ui>, doc: &Rc<Document>, label: &gtk::Label, reopen: &gtk::Button) {
    #[cfg(debug_assertions)]
    LIVE.with(|count| count.set(count.get() + 1));
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(doc),
        label: label.downgrade(),
        reopen: reopen.downgrade(),
        busy: Cell::new(false),
        changed: Cell::new(false),
    });
    glib::timeout_add_local(Duration::from_secs(1), move || {
        let (Some(ui), Some(doc)) = (state.ui.upgrade(), state.doc.upgrade()) else {
            return glib::ControlFlow::Break;
        };
        if ui.close_committed.get()
            || !ui
                .documents
                .borrow()
                .iter()
                .any(|open| Rc::ptr_eq(open, &doc))
        {
            return glib::ControlFlow::Break;
        }
        if state.busy.get()
            || state.changed.get()
            || !ui.window.is_visible()
            || doc.close_pending.get()
            || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
        {
            return glib::ControlFlow::Continue;
        }
        let Some(source) = doc.read_source.borrow().clone() else {
            return glib::ControlFlow::Break;
        };
        state.busy.set(true);
        let owner = Rc::downgrade(&state);
        let expected = source.clone();
        git_view::background(
            move || Ok(source.verify_identity(&Cancellation::default()).is_err()),
            move |result| {
                let Some(state) = owner.upgrade() else {
                    return;
                };
                state.busy.set(false);
                let (Some(ui), Some(doc), Some(label), Some(reopen)) = (
                    state.ui.upgrade(),
                    state.doc.upgrade(),
                    state.label.upgrade(),
                    state.reopen.upgrade(),
                ) else {
                    return;
                };
                if !ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|open| Rc::ptr_eq(open, &doc))
                    || doc
                        .read_source
                        .borrow()
                        .as_ref()
                        .is_none_or(|source| !Arc::ptr_eq(source, &expected))
                {
                    return;
                }
                if !matches!(result, Ok(false)) {
                    state.changed.set(true);
                    label.set_text(ui.lang.text("Quelle geändert oder nicht mehr lesbar. Die angezeigte Fassung bleibt erhalten.", "Source changed or became unreadable. The displayed version is retained."));
                    label.add_css_class("warning");
                    reopen.set_visible(true);
                }
            },
        );
        glib::ControlFlow::Continue
    });
}
