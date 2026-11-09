use super::*;

pub(crate) struct Replacement {
    pub item: usize,
    pub hit: usize,
    pub ordinal: usize,
    pub preview: Arc<Preview>,
    pub range: (i32, i32),
    pub cancel: Cancellation,
    pub current: Rc<dyn Fn() -> bool>,
    pub report: Rc<dyn Fn(&str)>,
    pub finish: Rc<dyn Fn()>,
}
pub(super) fn connect(surface: &Rc<Surface>) {
    let weak = Rc::downgrade(surface);
    surface.replace.connect_clicked(move |_| {
        let Some(surface) = weak
            .upgrade()
            .filter(|s| s.available() && !s.single_busy.get())
        else {
            return;
        };
        let Some(pane) = surface.pane.upgrade() else {
            return;
        };
        let Some(handler) = pane.on_replace.borrow().clone() else {
            return;
        };
        let Some(index) = surface.selected.get() else {
            return;
        };
        let rows = surface.rows.borrow();
        let Some(Row::Match {
            item,
            hit,
            characters,
            ..
        }) = rows.get(index)
        else {
            return;
        };
        let (item, hit, range) = (*item, *hit, *characters);
        let ordinal = rows[..index]
            .iter()
            .filter(|row| matches!(row, Row::Match { .. }))
            .count();
        drop(rows);
        let preview = pane.items.borrow()[item].preview.clone();
        let job = surface.single_job.get().wrapping_add(1);
        surface.single_job.set(job);
        surface.single_busy.set(true);
        let generation = surface.generation.get();
        let ticket = surface.detail_generation.get();
        let cancel = surface.navigation_cancel.borrow().clone();
        let stopped = cancel.clone();
        let weak = Rc::downgrade(&surface);
        let current = Rc::new(move || {
            weak.upgrade().is_some_and(|s| {
                stopped.check().is_ok()
                    && s.single_job.get() == job
                    && s.generation.get() == generation
                    && s.detail_generation.get() == ticket
                    && s.available()
                    && !s.window.is_visible()
                    && s._owner.is_visible()
                    && s.ui
                        .upgrade()
                        .is_some_and(|ui| source_panes::focused_is(&ui, &s._owner))
            })
        });
        let weak = Rc::downgrade(&surface);
        let finish = Rc::new(move || {
            if let Some(s) = weak.upgrade().filter(|s| s.single_job.get() == job) {
                s.single_busy.set(false);
                s.refresh();
            }
        });
        let weak = Rc::downgrade(&surface);
        let report = Rc::new(move |message: &str| {
            if let Some(s) = weak
                .upgrade()
                .filter(|s| s.generation.get() == generation && s.detail_generation.get() == ticket)
            {
                s.navigation_message.set_text(message);
                s.navigation_message.set_visible(!message.is_empty());
            }
        });
        surface.refresh();
        handler(Replacement {
            item,
            hit,
            ordinal,
            preview,
            range,
            cancel,
            current,
            report,
            finish,
        });
    });
}
