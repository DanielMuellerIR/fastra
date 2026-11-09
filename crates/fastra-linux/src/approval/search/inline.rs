use super::*;

type Key = (Arc<Preview>, Vec<usize>);
pub(super) struct Strip {
    pub root: gtk::Box,
    pane: std::rc::Weak<ApprovalPane>,
    key: RefCell<Option<Key>>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
    handlers: RefCell<Vec<(glib::Object, glib::SignalHandlerId)>>,
}
impl Drop for Strip {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
        for (object, handler) in self.handlers.get_mut().drain(..) {
            object.disconnect(handler);
        }
    }
}
impl Strip {
    pub fn new(pane: &Rc<ApprovalPane>, ui: &Rc<Ui>, owner: &gtk::Window) -> Rc<Self> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 3);
        root.add_css_class("search-inline-preview");
        root.set_widget_name("fastra-inline-preview");
        root.set_visible(false);
        let state = Rc::new(Self {
            root,
            pane: Rc::downgrade(pane),
            key: RefCell::new(None),
            generation: Cell::new(0),
            cancel: RefCell::new(Cancellation::default()),
            handlers: RefCell::new(Vec::new()),
        });
        let weak = Rc::downgrade(&state);
        let handler = ui.tabs.connect_switch_page(move |_, _, _| {
            let weak = weak.clone();
            glib::idle_add_local_once(move || {
                if let Some(s) = weak.upgrade() {
                    s.refresh();
                }
            });
        });
        state
            .handlers
            .borrow_mut()
            .push((ui.tabs.clone().upcast(), handler));
        for window in [owner.clone(), ui.window.clone().upcast()] {
            let weak = Rc::downgrade(&state);
            let handler = window.connect_is_active_notify(move |_| {
                let weak = weak.clone();
                glib::idle_add_local_once(move || {
                    if let Some(s) = weak.upgrade() {
                        s.refresh();
                    }
                });
            });
            state.handlers.borrow_mut().push((window.upcast(), handler));
        }
        state
    }
    fn source(&self) -> Option<Key> {
        let pane = self.pane.upgrade()?;
        if !pane.render_ready.get() || pane.frozen.get() {
            return None;
        }
        let preview = pane.inline_source.borrow().as_ref()?()?;
        let items = pane.items.borrow();
        let item = items
            .iter()
            .position(|item| Arc::ptr_eq(&preview, &item.preview))?;
        let approved = pane.approved.borrow()[item]
            .iter()
            .enumerate()
            .filter_map(|(i, yes)| yes.then_some(i))
            .collect::<Vec<_>>();
        (!approved.is_empty()).then_some((preview, approved))
    }
    fn matches(&self, expected: &Key) -> bool {
        self.source()
            .is_some_and(|actual| Arc::ptr_eq(&actual.0, &expected.0) && actual.1 == expected.1)
    }
    pub fn refresh(self: &Rc<Self>) {
        let source = self.source();
        if source
            .as_ref()
            .zip(self.key.borrow().as_ref())
            .is_some_and(|(a, b)| Arc::ptr_eq(&a.0, &b.0) && a.1 == b.1)
        {
            return;
        }
        self.cancel.borrow().cancel();
        let generation = self.generation.get().wrapping_add(1);
        self.generation.set(generation);
        self.root.set_visible(false);
        for child in chrome::children(&self.root) {
            self.root.remove(&child);
        }
        *self.key.borrow_mut() = source.clone();
        let Some(source) = source else {
            return;
        };
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let worker = source.clone();
        let weak = Rc::downgrade(self);
        git_view::background(
            move || {
                fastra_core::inline_preview::build(&worker.0, &worker.1, &cancel)
                    .map_err(|_| "Inline preview cancelled or limited".into())
            },
            move |result| {
                let Some(s) = weak.upgrade() else {
                    return;
                };
                if s.generation.get() != generation || !s.matches(&source) {
                    return;
                }
                let Some(pane) = s.pane.upgrade() else {
                    return;
                };
                let Ok(result) = result else {
                    let label = gtk::Label::new(Some(pane.lang.text(
                        "Inline-Vorschau nicht verfügbar. „Freigaben prüfen“ zeigt die vollständigen Änderungen.",
                        "Inline preview unavailable. Review approvals shows the complete changes.")));
                    label.set_wrap(true);
                    label.set_xalign(0.);
                    label.add_css_class("search-inline-remaining");
                    s.root.append(&label);
                    s.root.set_visible(true);
                    return;
                };
                if result.rows.is_empty() {
                    return;
                }
                let title = gtk::Label::new(Some(pane.lang.text("VORSCHAU", "PREVIEW")));
                title.set_xalign(0.);
                title.add_css_class("search-inline-title");
                s.root.append(&title);
                for row in &result.rows {
                    let line = gtk::Box::new(gtk::Orientation::Horizontal, 6);
                    let number = gtk::Label::new(Some(&row.line.to_string()));
                    number.set_width_chars(4);
                    number.set_xalign(1.);
                    number.add_css_class("muted");
                    line.append(&number);
                    for (index, text) in [&row.before, &row.after].into_iter().enumerate() {
                        if index == 1 {
                            line.append(&gtk::Label::new(Some("→")));
                        }
                        let label = gtk::Label::new(Some(text));
                        label.set_xalign(0.);
                        label.set_hexpand(true);
                        label.set_width_chars(1);
                        label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
                        label.set_single_line_mode(true);
                        label.set_tooltip_text(Some(text));
                        label.add_css_class(if index == 0 {
                            "search-inline-before"
                        } else {
                            "search-inline-after"
                        });
                        line.append(&label);
                    }
                    s.root.append(&line);
                }
                let remaining = result.total_changed_lines - result.rows.len();
                if remaining > 0 {
                    let label = gtk::Label::new(Some(&format!(
                        "… {remaining} {}",
                        pane.lang.text(
                            "weitere geänderte Zeilen — „Freigaben prüfen“ zeigt alle.",
                            "more changed lines — Review approvals shows all."
                        )
                    )));
                    label.set_xalign(0.);
                    label.set_wrap(true);
                    label.add_css_class("muted");
                    label.add_css_class("search-inline-remaining");
                    s.root.append(&label);
                }
                s.root.set_visible(true);
            },
        );
    }
}
