use super::*;
#[derive(Clone, PartialEq, Eq)]
struct Key {
    revision: u64,
    language: String,
    title: String,
    rich: Option<(String, u64)>,
}
pub(crate) struct View {
    pub root: gtk::Box,
    pub menu: gtk::MenuButton,
    pub popup: gtk::Popover,
    pub back: gtk::Button,
    pub forward: gtk::Button,
    pub(super) ui: Weak<Ui>,
    pub(super) doc: Weak<Document>,
    pub(super) history: Rc<History>,
    pub(super) rich: Option<Weak<rich_editor::RichEditor>>,
    pub(super) unfold: glib::WeakRef<gtk::Button>,
    pub(super) headings: RefCell<Vec<Heading>>,
    pub(super) ready: Cell<bool>,
    pub(super) revision: Cell<u64>,
    key: RefCell<Option<Key>>,
    job: Cell<u64>,
    cancel: RefCell<Cancellation>,
    list: gtk::ListView,
    model: gtk::StringList,
    selection: gtk::SingleSelection,
    bound: RefCell<Vec<glib::WeakRef<gtk::ListItem>>>,
    current: Cell<Option<usize>>,
    spinner: gtk::Spinner,
    message: gtk::Label,
    scroll: gtk::ScrolledWindow,
}
impl Drop for View {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
    }
}
impl View {
    pub(super) fn new(
        ui: &Rc<Ui>,
        doc: &Rc<Document>,
        unfold: &gtk::Button,
        history: Rc<History>,
    ) -> Rc<Self> {
        Self::build(ui, doc, unfold.downgrade(), history, None)
    }
    pub(crate) fn new_rich(
        ui: &Rc<Ui>,
        doc: &Rc<Document>,
        editor: &Rc<rich_editor::RichEditor>,
    ) -> Rc<Self> {
        Self::build(
            ui,
            doc,
            glib::WeakRef::new(),
            history::get(ui),
            Some(Rc::downgrade(editor)),
        )
    }
    fn build(
        ui: &Rc<Ui>,
        doc: &Rc<Document>,
        unfold: glib::WeakRef<gtk::Button>,
        history: Rc<History>,
        rich: Option<Weak<rich_editor::RichEditor>>,
    ) -> Rc<Self> {
        let root = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        root.set_widget_name("fastra-document-outline-controls");
        root.add_css_class("document-outline-controls");
        let back = chrome::icon(
            "go-previous-symbolic",
            ui.lang.text("Voriger Sprung", "Previous jump"),
        );
        let forward = chrome::icon(
            "go-next-symbolic",
            ui.lang.text("Nächster Sprung", "Next jump"),
        );
        back.set_widget_name("fastra-outline-back");
        forward.set_widget_name("fastra-outline-forward");
        let menu = gtk::MenuButton::builder()
            .icon_name("fastra-list-symbolic")
            .tooltip_text(
                ui.lang
                    .text("Dokumentgliederung anzeigen", "Show document outline"),
            )
            .build();
        menu.set_widget_name("fastra-outline-menu");
        menu.add_css_class("chrome-icon");
        menu.update_property(&[gtk::accessible::Property::Label(
            ui.lang
                .text("Dokumentgliederung anzeigen", "Show document outline"),
        )]);
        root.append(&back);
        root.append(&forward);
        root.append(&menu);
        let popup = gtk::Popover::new();
        popup.add_css_class("document-outline-popup");
        let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        content.set_size_request(292, 312);
        content.set_margin_start(14);
        content.set_margin_end(14);
        content.set_margin_top(14);
        content.set_margin_bottom(14);
        let title = gtk::Label::new(Some(ui.lang.text("Dokumentgliederung", "Document outline")));
        title.set_xalign(0.);
        title.add_css_class("document-outline-title");
        content.append(&title);
        let model = gtk::StringList::new(&[]);
        let selection = gtk::SingleSelection::new(Some(model.clone()));
        selection.set_autoselect(false);
        selection.set_can_unselect(true);
        let factory = gtk::SignalListItemFactory::new();
        let list = gtk::ListView::new(Some(selection.clone()), Some(factory.clone()));
        list.add_css_class("document-outline-list");
        list.set_single_click_activate(true);
        let scroll = gtk::ScrolledWindow::builder()
            .child(&list)
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        let spinner = gtk::Spinner::new();
        spinner.set_halign(gtk::Align::Center);
        let message = git_view::label("");
        message.add_css_class("muted");
        message.set_wrap_mode(gtk::pango::WrapMode::WordChar);
        message.set_max_width_chars(36);
        content.append(&spinner);
        content.append(&message);
        content.append(&scroll);
        popup.set_child(Some(&content));
        menu.set_popover(Some(&popup));
        let view = Rc::new(Self {
            root,
            menu,
            popup,
            back,
            forward,
            ui: Rc::downgrade(ui),
            doc: Rc::downgrade(doc),
            history: history.clone(),
            unfold,
            rich,
            headings: RefCell::new(vec![]),
            ready: Cell::new(false),
            revision: Cell::new(0),
            key: RefCell::new(None),
            job: Cell::new(0),
            cancel: RefCell::new(Cancellation::default()),
            list,
            model,
            selection,
            bound: RefCell::new(vec![]),
            current: Cell::new(None),
            spinner,
            message,
            scroll,
        });
        let weak = Rc::downgrade(&view);
        factory.connect_setup(move |_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            if let Some(view) = weak.upgrade() {
                view.bound.borrow_mut().push(item.downgrade());
            }
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            row.add_css_class("document-outline-row");
            let badge = gtk::Label::new(None);
            badge.add_css_class("outline-level");
            badge.set_valign(gtk::Align::Start);
            let text = gtk::Label::new(None);
            text.set_xalign(0.);
            text.set_wrap(true);
            text.set_wrap_mode(gtk::pango::WrapMode::WordChar);
            text.set_lines(3);
            text.set_ellipsize(gtk::pango::EllipsizeMode::End);
            text.set_width_chars(1);
            text.set_max_width_chars(36);
            text.set_hexpand(false);
            let line = gtk::Label::new(None);
            line.add_css_class("muted");
            line.set_valign(gtk::Align::Start);
            let check = gtk::Image::from_icon_name("object-select-symbolic");
            check.set_pixel_size(12);
            check.set_valign(gtk::Align::Start);
            let symbol = gtk::Image::new();
            symbol.set_pixel_size(12);
            symbol.add_css_class("outline-level");
            let badge_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
            badge_box.set_valign(gtk::Align::Start);
            badge_box.append(&badge);
            badge_box.append(&symbol);
            row.append(&badge_box);
            row.append(&text);
            row.append(&line);
            let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
            spacer.set_hexpand(true);
            row.append(&spacer);
            row.append(&check);
            item.set_child(Some(&row));
        });
        let weak = Rc::downgrade(&view);
        factory.connect_bind(move |_, item| {
            if let Some(view) = weak.upgrade() {
                view.bind(item.downcast_ref::<gtk::ListItem>().unwrap());
            }
        });
        let weak = Rc::downgrade(&view);
        view.list.connect_activate(move |_, position| {
            if let Some(view) = weak.upgrade() {
                let heading = view.headings.borrow().get(position as usize).cloned();
                if let Some(heading) = heading {
                    view.history.jump(&view, heading);
                }
            }
        });
        for (button, delta) in [(&view.back, -1), (&view.forward, 1)] {
            let weak = Rc::downgrade(&history);
            button.connect_clicked(move |_| {
                if let Some(history) = weak.upgrade() {
                    history.move_by(delta);
                }
            });
        }
        let weak = Rc::downgrade(&view);
        view.popup.connect_visible_notify(move |popup| {
            if popup.is_visible() {
                if let Some(view) = weak.upgrade() {
                    view.schedule();
                    view.follow();
                    let weak = Rc::downgrade(&view);
                    glib::timeout_add_local_once(Duration::from_millis(40), move || {
                        if let Some(view) = weak.upgrade().filter(|v| v.popup.is_visible()) {
                            if let Some(index) = view.current.get() {
                                view.selection.set_selected(index as u32);
                                view.list.scroll_to(
                                    index as u32,
                                    gtk::ListScrollFlags::FOCUS,
                                    None,
                                );
                            } else {
                                view.list.grab_focus();
                            }
                        }
                    });
                }
            }
        });
        let weak = Rc::downgrade(&view);
        doc.buffer.connect_changed(move |_| {
            if let Some(view) = weak.upgrade() {
                view.cancel.borrow().cancel();
                view.key.borrow_mut().take();
                view.job.set(view.job.get().wrapping_add(1));
                view.ready.set(false);
                // Der Dokument-Beobachter erhöht die Revision später im selben GTK-Signal.
                // Erst danach den Schlüssel lesen; ein bereits schmutziger Tab ändert seinen Titel nicht erneut.
                let weak = Rc::downgrade(&view);
                glib::idle_add_local_once(move || {
                    if let Some(view) = weak.upgrade() {
                        view.schedule();
                    }
                });
            }
        });
        let weak = Rc::downgrade(&view);
        doc.buffer.connect_language_notify(move |_| {
            if let Some(view) = weak.upgrade() {
                view.schedule();
            }
        });
        let weak = Rc::downgrade(&view);
        doc.label.connect_label_notify(move |_| {
            if let Some(view) = weak.upgrade() {
                view.schedule();
            }
        });
        let buffers = doc
            .source_panes
            .borrow()
            .as_ref()
            .map(|p| p.buffers.to_vec())
            .unwrap_or_else(|| vec![doc.buffer.clone()]);
        for buffer in buffers {
            let weak = Rc::downgrade(&view);
            buffer.connect_mark_set(move |_, _, mark| {
                if mark.name().as_deref() == Some("insert") {
                    if let Some(view) = weak.upgrade() {
                        view.follow();
                    }
                }
            });
        }
        let weak = Rc::downgrade(&view);
        view.root.connect_map(move |_| {
            if let Some(view) = weak.upgrade() {
                view.schedule();
            }
        });
        let weak = Rc::downgrade(&view);
        view.root.connect_unmap(move |_| {
            if let Some(view) = weak.upgrade() {
                view.menu.popdown();
                view.cancel.borrow().cancel();
                view.key.borrow_mut().take();
                view.job.set(view.job.get().wrapping_add(1));
                view.ready.set(false);
            }
        });
        history.views.borrow_mut().push(Rc::downgrade(&view));
        view.controls();
        view
    }
    fn bind(&self, item: &gtk::ListItem) {
        let values = self.headings.borrow();
        let Some(heading) = values.get(item.position() as usize) else {
            return;
        };
        let Some(row) = item.child() else {
            return;
        };
        let children = chrome::children(&row);
        let badge = chrome::children(&children[0]);
        let markdown = heading.kind == Kind::Markdown;
        badge[0].set_visible(markdown);
        badge[1].set_visible(!markdown);
        badge[0]
            .downcast_ref::<gtk::Label>()
            .unwrap()
            .set_text(&format!("H{}", heading.level));
        badge[1]
            .downcast_ref::<gtk::Image>()
            .unwrap()
            .set_icon_name(Some(if heading.kind == Kind::Method {
                "fastra-file-symbolic"
            } else {
                "fastra-function-symbolic"
            }));
        let prefix = match heading.kind {
            Kind::Function(fastra_core::four_d::Kind::Getter) => "get ",
            Kind::Function(fastra_core::four_d::Kind::Setter) => "set ",
            Kind::Function(fastra_core::four_d::Kind::Query) => "query ",
            Kind::Function(fastra_core::four_d::Kind::OrderBy) => "orderBy ",
            _ => "",
        };
        let lang = self.ui.upgrade().map_or(Language(false), |u| u.lang);
        let title = if heading.title.is_empty() {
            lang.text("Ohne Titel", "Untitled")
        } else {
            &heading.title
        };
        children[1]
            .downcast_ref::<gtk::Label>()
            .unwrap()
            .set_text(&format!("{prefix}{title}"));
        let line = if heading.kind == Kind::Markdown {
            String::new()
        } else {
            heading.line.to_string()
        };
        children[2].set_visible(heading.kind != Kind::Markdown);
        children[2]
            .downcast_ref::<gtk::Label>()
            .unwrap()
            .set_text(&line);
        row.set_margin_start(i32::from(heading.level.saturating_sub(1)) * 12);
        let active = self.current.get() == Some(item.position() as usize);
        if active {
            row.add_css_class("current");
        } else {
            row.remove_css_class("current");
        }
        children[4].set_visible(active);
        row.set_tooltip_text(Some(&format!("{} · {prefix}{title}", heading.line)));
    }
    pub(super) fn controls(&self) {
        let supported = self.doc.upgrade().is_some_and(|d| supported(&d));
        self.menu.set_sensitive(supported);
        self.root
            .set_visible(supported || (self.history.can_move(-1) || self.history.can_move(1)));
        self.back.set_sensitive(self.history.can_move(-1));
        self.forward.set_sensitive(self.history.can_move(1));
    }
    pub(crate) fn rich_position(&self, index: Option<usize>) {
        self.set_current(index.filter(|n| *n < self.headings.borrow().len()));
    }
    fn set_current(&self, next: Option<usize>) {
        if self.current.replace(next) != next {
            let items = self
                .bound
                .borrow()
                .iter()
                .filter_map(glib::WeakRef::upgrade)
                .collect::<Vec<_>>();
            for item in items {
                if item.item().is_some() {
                    self.bind(&item);
                }
            }
        }
    }
    pub(super) fn rich_stamp(&self) -> Option<(String, u64)> {
        self.rich.as_ref()?.upgrade()?.outline_stamp()
    }
    pub(crate) fn snapshot(&self) -> Vec<Heading> {
        if self.valid() {
            self.headings.borrow().clone()
        } else {
            vec![]
        }
    }
    pub(crate) fn valid(&self) -> bool {
        self.ready.get()
            && self.doc.upgrade().is_some_and(|doc| {
                doc.revision.get() == self.revision.get()
                    && self
                        .key
                        .borrow()
                        .as_ref()
                        .is_some_and(|key| self.backend_valid(key, &doc))
            })
    }
    fn backend_valid(&self, key: &Key, doc: &Document) -> bool {
        if self.rich.is_some() {
            doc.is_rich_active() && self.rich_stamp() == key.rich && key.rich.is_some()
        } else {
            !doc.is_rich_active()
        }
    }
    pub(crate) fn follow(self: &Rc<Self>) {
        if let Some(editor) = self.rich.as_ref().and_then(Weak::upgrade) {
            let weak = Rc::downgrade(self);
            let revision = self.revision.get();
            editor.outline_snapshot(move |snapshot| {
                if let Some(view) = weak
                    .upgrade()
                    .filter(|v| v.ready.get() && v.revision.get() == revision)
                {
                    if let Some(snapshot) =
                        snapshot.filter(|v| view.rich_stamp().as_ref() == Some(&v.stamp))
                    {
                        if snapshot.levels
                            == view
                                .headings
                                .borrow()
                                .iter()
                                .map(|h| h.level)
                                .collect::<Vec<_>>()
                        {
                            view.rich_position(snapshot.index);
                        }
                    }
                }
            });
            return;
        }
        let Some(doc) = self.doc.upgrade() else {
            return;
        };
        let next = if self.ready.get() && doc.revision.get() == self.revision.get() {
            self.headings
                .borrow()
                .partition_point(|h| h.offset <= source_panes::buffer(&doc).cursor_position())
                .checked_sub(1)
        } else {
            None
        };
        self.set_current(next);
    }
    pub(crate) fn schedule(self: &Rc<Self>) {
        self.controls();
        let (Some(ui), Some(doc)) = (self.ui.upgrade(), self.doc.upgrade()) else {
            return;
        };
        if !ui.window.is_visible()
            || !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
            || (doc.is_rich_active() != self.rich.is_some())
        {
            return;
        }
        if !supported(&doc) {
            self.cancel.borrow().cancel();
            self.key.borrow_mut().take();
            self.ready.set(true);
            self.current.set(None);
            self.headings.borrow_mut().clear();
            self.model.splice(0, self.model.n_items(), &[]);
            self.spinner.set_spinning(false);
            self.spinner.set_visible(false);
            self.menu.popdown();
            return;
        }
        let key = Key {
            revision: doc.revision.get(),
            language: language(&doc),
            title: title(&doc),
            rich: self.rich_stamp(),
        };
        if self.rich.is_some() && key.rich.is_none() {
            return;
        }
        if self.key.borrow().as_ref() == Some(&key) {
            return;
        }
        *self.key.borrow_mut() = Some(key.clone());
        self.cancel.borrow().cancel();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let job = self.job.get().wrapping_add(1);
        self.job.set(job);
        self.ready.set(false);
        self.current.set(None);
        self.headings.borrow_mut().clear();
        self.model.splice(0, self.model.n_items(), &[]);
        self.scroll.set_visible(false);
        self.message.set_visible(false);
        self.spinner.set_spinning(true);
        self.spinner.set_visible(true);
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_millis(150), move || {
            let Some(view) = weak.upgrade().filter(|v| v.job.get() == job) else {
                return;
            };
            let (Some(ui), Some(doc)) = (view.ui.upgrade(), view.doc.upgrade()) else {
                return;
            };
            if !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
                || doc.revision.get() != key.revision
                || !view.backend_valid(&key, &doc)
            {
                return;
            }
            let source = buffer_text(&doc.buffer);
            let lang = ui.lang;
            let parse_key = key.clone();
            let weak = Rc::downgrade(&view);
            git_view::background(
                move || {
                    entries(&source,&parse_key.language,&parse_key.title,&cancel).map_err(|_|lang.text("Die Gliederung ist nicht vollständig prüfbar: höchstens 10 MiB, 200.000 Zeilen, 10.000 Einträge und 16 KiB je Titel.","The outline cannot be checked completely: at most 10 MiB, 200,000 lines, 10,000 entries and 16 KiB per title.").to_owned())
                },
                move |result| {
                    let Some(view) = weak.upgrade().filter(|v| v.job.get() == job) else {
                        return;
                    };
                    let (Some(ui), Some(doc)) = (view.ui.upgrade(), view.doc.upgrade()) else {
                        return;
                    };
                    if !ui.window.is_visible()
                        || doc.revision.get() != key.revision
                        || language(&doc) != key.language
                        || title(&doc) != key.title
                        || !view.backend_valid(&key, &doc)
                        || !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
                    {
                        return;
                    }
                    view.spinner.set_spinning(false);
                    view.spinner.set_visible(false);
                    view.revision.set(key.revision);
                    view.ready.set(true);
                    match result {
                        Ok(values) => {
                            let labels =
                                (0..values.len()).map(|n| n.to_string()).collect::<Vec<_>>();
                            let refs = labels.iter().map(String::as_str).collect::<Vec<_>>();
                            *view.headings.borrow_mut() = values;
                            view.model.splice(0, 0, &refs);
                            view.scroll.set_visible(!refs.is_empty());
                            view.message.set_text(ui.lang.text(
                                "Keine Gliederungseinträge im Dokument",
                                "No outline entries in this document",
                            ));
                            view.message.set_visible(refs.is_empty());
                            view.follow();
                        }
                        Err(message) => {
                            view.message.set_text(&message);
                            view.message.set_visible(true);
                        }
                    }
                },
            );
        });
    }
}
