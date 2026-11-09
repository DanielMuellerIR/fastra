use super::*;
mod extraction;
#[cfg(debug_assertions)]
pub(crate) mod group_test;
mod groups;
mod inline;
#[cfg(debug_assertions)]
pub(crate) mod inline_test;
mod replacement;
pub(crate) use replacement::Replacement;

#[derive(Clone)]
enum Row {
    File {
        item: usize,
        title: String,
    },
    Match {
        item: usize,
        hit: usize,
        line: usize,
        column: usize,
        start: usize,
        end: usize,
        characters: (i32, i32),
        text: String,
    },
}

pub(crate) struct Navigation {
    pub item: usize,
    pub explicit: bool,
    pub preview: Arc<Preview>,
    pub range: (i32, i32),
    pub ranges: Vec<(i32, i32)>,
    pub cancel: Cancellation,
    pub current: Rc<dyn Fn() -> bool>,
    pub report: Rc<dyn Fn(&str)>,
}

pub(super) struct Surface {
    pane: std::rc::Weak<ApprovalPane>,
    disk: bool,
    ui: std::rc::Weak<Ui>,
    pub review: gtk::Button,
    pub(super) replace: gtk::Button,
    inline: Rc<inline::Strip>,
    single_busy: Cell<bool>,
    group_busy: Cell<bool>,
    group_cancel: RefCell<Cancellation>,
    define_group: gtk::Button,
    remove_group: gtk::Button,
    single_job: Cell<u64>,
    pub(super) diff: Rc<review_diff::View>,
    window: gtk::Window,
    // GTK räumt die Transient-Verbindung erst beim letzten Unref auf. Der
    // Besitzer muss dieses spätere Aufräumen auch nach destroy überleben.
    _owner: gtk::Window,
    _document_window: gtk::ApplicationWindow,
    list: gtk::ListView,
    model: gtk::StringList,
    rows: RefCell<Vec<Row>>,
    bound: RefCell<Vec<glib::WeakRef<gtk::ListItem>>>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
    ready: Cell<bool>,
    updating: Cell<bool>,
    selected: Cell<Option<usize>>,
    detail_generation: Cell<u64>,
    navigation_cancel: RefCell<Cancellation>,
    navigation_message: gtk::Label,
    message: gtk::Label,
    count: gtk::Label,
    empty: gtk::Label,
    completed: Cell<bool>,
    approved: gtk::Label,
    position: gtk::Label,
    detail_title: gtk::Label,
    detail: gtk::TextView,
    pub(super) previous: gtk::Button,
    pub(super) next: gtk::Button,
    all: gtk::Button,
    none: gtk::Button,
}
impl Drop for Surface {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
        self.group_cancel.get_mut().cancel();
        self.navigation_cancel.get_mut().cancel();
        if let Some(ui) = self.ui.upgrade() {
            search_navigation::clear_cancelled(&ui);
        }
    }
}

impl Surface {
    #[cfg(debug_assertions)]
    pub(super) fn test_loaded_hits(&self) -> u32 {
        self.model.n_items().saturating_sub(1)
    }
    pub(super) fn install(
        pane: &Rc<ApprovalPane>,
        ui: &Rc<Ui>,
        owner: &gtk::Window,
        apply: &gtk::Button,
        disk: bool,
    ) -> Rc<Self> {
        let lang = pane.lang;
        pane.root.set_spacing(4);
        let window = gtk::Window::builder()
            .title(lang.text("Freigegebene Änderungen", "Approved changes"))
            .transient_for(owner)
            .destroy_with_parent(true)
            .modal(true)
            .default_width(900)
            .default_height(650)
            .build();
        window.add_css_class("fastra-search");
        window.add_css_class("fastra-owned-review");
        window.set_size_request(620, 440);
        chrome::dialog::decorate(
            &window,
            lang.text("Freigegebene Änderungen", "Approved changes"),
            lang,
        );
        let full = git_view::column();
        full.add_css_class("search-approvals");
        let explanation = git_view::label(if disk {
            lang.text("Anwenden schreibt auf die Platte. Die vollständigen Vorher-/Nachher-Texte zeigen ausschließlich die freigegebenen Ersetzungen.", "Apply writes to disk. The complete before/after texts show only the approved replacements.")
        } else {
            lang.text("Anwenden ändert nur offene Dokumente im Speicher. Speichern erfolgt separat; jede Dokumentänderung besitzt natives Undo.", "Apply changes open documents in memory only. Save separately; each document change has native Undo.")
        });
        explanation.add_css_class("approval-explanation");
        full.append(&explanation);
        for child in chrome::children(&pane.root) {
            pane.root.remove(&child);
            full.append(&child);
        }
        if let Some(scroll) = pane.checks.ancestor(gtk::ScrolledWindow::static_type()) {
            scroll.set_visible(false);
        }
        let diff = review_diff::View::new(lang);
        let original = pane
            .before
            .ancestor(gtk::Paned::static_type())
            .unwrap()
            .downcast::<gtk::Paned>()
            .unwrap();
        let split = original.parent().unwrap().downcast::<gtk::Paned>().unwrap();
        split.set_end_child(Some(&diff.root));
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let close = gtk::Button::with_label(lang.text("Schließen", "Close"));
        let target = window.downgrade();
        close.connect_clicked(move |_| {
            if let Some(window) = target.upgrade() {
                window.close();
            }
        });
        actions.append(&close);
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        actions.append(&spacer);
        apply.set_label(lang.text("Freigegebene Änderungen anwenden", "Apply approved changes"));
        actions.append(apply);
        full.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        full.append(&actions);
        window.set_child(Some(&full));
        let review =
            gtk::Button::with_label(lang.text("Freigaben prüfen · 0", "Review approvals · 0"));
        let replace = gtk::Button::with_label(lang.text("Ersetzen", "Replace"));
        let model = gtk::StringList::new(&[]);
        let factory = gtk::SignalListItemFactory::new();
        let list = gtk::ListView::new(
            Some(gtk::NoSelection::new(Some(model.clone()))),
            Some(factory.clone()),
        );
        list.set_single_click_activate(false);
        list.add_css_class("search-hit-list");
        let message = git_view::label("");
        message.set_visible(false);
        message.add_css_class("search-feedback");
        let empty = gtk::Label::new(None);
        empty.set_widget_name("fastra-search-empty");
        empty.add_css_class("muted");
        empty.set_wrap(true);
        empty.set_justify(gtk::Justification::Center);
        empty.set_margin_start(24);
        empty.set_margin_end(24);
        empty.set_halign(gtk::Align::Center);
        empty.set_valign(gtk::Align::Center);
        empty.set_can_target(false);
        let count = gtk::Label::new(None);
        count.set_xalign(0.);
        count.set_hexpand(true);
        let approved = gtk::Label::new(None);
        approved.set_xalign(0.);
        approved.set_hexpand(true);
        approved.add_css_class("muted");
        let position = gtk::Label::new(Some("0 / 0"));
        let previous = chrome::icon(
            "go-previous-symbolic",
            lang.text("Vorheriger Treffer", "Previous match"),
        );
        let next = chrome::icon(
            "go-next-symbolic",
            lang.text("Nächster Treffer", "Next match"),
        );
        let all = gtk::Button::with_label(lang.text("Alle", "All"));
        let none = gtk::Button::with_label(lang.text("Keine", "None"));
        let detail_title = gtk::Label::new(Some(
            lang.text("Detail · kein Treffer", "Detail · no match"),
        ));
        detail_title.set_xalign(0.);
        detail_title.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        detail_title.add_css_class("search-detail-title");
        let detail = gtk::TextView::builder()
            .editable(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::None)
            .build();
        detail.set_widget_name("fastra-search-detail");
        detail.add_css_class("search-detail");
        detail.update_property(&[gtk::accessible::Property::Label(
            lang.text("Aktiver Treffer", "Active match"),
        )]);
        let navigation_message = git_view::label("");
        navigation_message.set_visible(false);
        navigation_message.add_css_class("muted");
        let state = Rc::new(Self {
            pane: Rc::downgrade(pane),
            disk,
            ui: Rc::downgrade(ui),
            review,
            replace,
            inline: inline::Strip::new(pane, ui, owner),
            single_busy: Cell::new(false),
            group_busy: Cell::new(false),
            group_cancel: RefCell::new(Cancellation::default()),
            define_group: gtk::Button::with_label(lang.text("Gruppe definieren", "Define group")),
            remove_group: gtk::Button::with_label(lang.text("Gruppe löschen", "Delete group")),
            single_job: Cell::new(0),
            diff,
            window,
            _owner: owner.clone(),
            _document_window: ui.window.clone(),
            list,
            model,
            rows: RefCell::new(Vec::new()),
            bound: RefCell::new(Vec::new()),
            generation: Cell::new(0),
            cancel: RefCell::new(Cancellation::default()),
            ready: Cell::new(false),
            updating: Cell::new(false),
            selected: Cell::new(None),
            detail_generation: Cell::new(0),
            navigation_cancel: RefCell::new(Cancellation::default()),
            navigation_message,
            message,
            count,
            empty,
            completed: Cell::new(false),
            approved,
            position,
            detail_title,
            detail,
            previous,
            next,
            all,
            none,
        });
        let top = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        top.append(&state.count);
        let copy = gtk::Button::with_label(lang.text("Treffer kopieren", "Copy matches"));
        let weak = Rc::downgrade(&state);
        copy.connect_clicked(move |_| {
            if let Some(s) = weak.upgrade() {
                s.copy_matches();
            }
        });
        top.append(&copy);
        let extract = gtk::Button::with_label(lang.text("Treffer extrahieren", "Extract matches"));
        let weak = Rc::downgrade(&state);
        extract.connect_clicked(move |_| {
            if let Some(surface) = weak.upgrade().filter(|s| s.available()) {
                extraction::open(&surface);
            }
        });
        top.append(&extract);
        top.append(&state.previous);
        top.append(&state.position);
        top.append(&state.next);
        pane.root.append(&state.inline.root);
        pane.root.append(&top);
        let approvals = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        approvals.append(&state.approved);
        approvals.append(&state.all);
        approvals.append(&state.none);
        pane.root.append(&approvals);
        let matches = gtk::Overlay::new();
        matches.set_child(Some(
            &gtk::ScrolledWindow::builder()
                .child(&state.list)
                .min_content_height(80)
                .vexpand(true)
                .build(),
        ));
        matches.add_overlay(&state.empty);
        pane.root.append(&matches);
        pane.root
            .append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        pane.root.append(&state.navigation_message);
        let detail_header = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        state.detail_title.set_hexpand(true);
        detail_header.append(&state.detail_title);
        detail_header.append(&state.define_group);
        detail_header.append(&state.remove_group);
        pane.root.append(&detail_header);
        pane.root.append(
            &gtk::ScrolledWindow::builder()
                .child(&state.detail)
                .min_content_height(28)
                .max_content_height(28)
                .hscrollbar_policy(gtk::PolicyType::External)
                .vscrollbar_policy(gtk::PolicyType::External)
                .build(),
        );
        pane.root.append(&state.message);
        let weak = Rc::downgrade(&state);
        factory.connect_setup(move |_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            if let Some(surface) = weak.upgrade() {
                surface.bound.borrow_mut().push(item.downgrade());
            }
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let check = gtk::CheckButton::new();
            let button = gtk::Button::new();
            button.set_hexpand(true);
            button.set_has_frame(false);
            let label = gtk::Label::new(None);
            label.set_xalign(0.);
            label.set_ellipsize(gtk::pango::EllipsizeMode::End);
            button.set_child(Some(&label));
            row.append(&check);
            row.append(&button);
            item.set_child(Some(&row));
            let target = item.downgrade();
            let owner = weak.clone();
            check.connect_toggled(move |check| {
                if let (Some(item), Some(s)) = (target.upgrade(), owner.upgrade()) {
                    if !s.updating.get() {
                        s.toggle(item.position() as usize, check.is_active());
                    }
                }
            });
            let target = item.downgrade();
            let owner = weak.clone();
            button.connect_clicked(move |_| {
                if let (Some(item), Some(s)) = (target.upgrade(), owner.upgrade()) {
                    s.select(item.position() as usize, true);
                }
            });
        });
        let weak = Rc::downgrade(&state);
        factory.connect_bind(move |_, item| {
            if let Some(s) = weak.upgrade() {
                s.bind(item.downcast_ref::<gtk::ListItem>().unwrap());
            }
        });
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(&state);
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            if modifiers.intersects(
                gtk::gdk::ModifierType::CONTROL_MASK
                    | gtk::gdk::ModifierType::ALT_MASK
                    | gtk::gdk::ModifierType::SUPER_MASK,
            ) {
                return glib::Propagation::Proceed;
            }
            let direction = match key {
                gtk::gdk::Key::Up => -1,
                gtk::gdk::Key::Down => 1,
                _ => return glib::Propagation::Proceed,
            };
            if let Some(s) = weak.upgrade().filter(|s| s.available()) {
                s.navigate(direction);
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        state.list.set_focusable(true);
        state.list.add_controller(keys);
        for (button, direction) in [(&state.previous, -1), (&state.next, 1)] {
            let weak = Rc::downgrade(&state);
            button.connect_clicked(move |_| {
                if let Some(s) = weak.upgrade() {
                    s.navigate(direction);
                }
            });
        }
        for (button, value) in [(&state.all, true), (&state.none, false)] {
            let weak = Rc::downgrade(&state);
            button.connect_clicked(move |_| {
                if let Some(s) = weak.upgrade() {
                    s.set_all(value);
                }
            });
        }
        let weak = Rc::downgrade(&state);
        let owner = owner.downgrade();
        state.review.connect_clicked(move |_| {
            if let (Some(s), Some(owner)) = (weak.upgrade(), owner.upgrade()) {
                if s.available() && owner.is_visible() {
                    s.window.present();
                }
            }
        });

        let weak = Rc::downgrade(&state);
        state.window.connect_close_request(move |window| {
            if weak
                .upgrade()
                .and_then(|s| s.pane.upgrade())
                .is_some_and(|p| p.frozen.get())
            {
                return glib::Propagation::Stop;
            }
            window.set_visible(false);
            glib::Propagation::Stop
        });
        let window = state.window.downgrade();
        let keys = gtk::EventControllerKey::new();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gtk::gdk::Key::Escape {
                if let Some(w) = window.upgrade() {
                    w.close();
                }
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        state.window.add_controller(keys);
        let weak = Rc::downgrade(&state);
        pane.root.connect_unmap(move |_| {
            if let Some(s) = weak.upgrade() {
                s.window.close();
            }
        });
        replacement::connect(&state);
        groups::connect(&state);
        if let Some(model) = ui.search_pattern.borrow().as_ref() {
            model.watch(pane);
        }
        let weak = Rc::downgrade(&state);
        ui.find.connect_changed(move |_| {
            let weak = weak.clone();
            glib::idle_add_local_once(move || {
                if let Some(surface) = weak.upgrade() {
                    surface.refresh_empty();
                }
            });
        });
        state.refresh();
        state
    }
    fn available(&self) -> bool {
        self.ready.get()
            && self
                .pane
                .upgrade()
                .is_some_and(|p| !p.frozen.get() && p.render_ready.get())
    }
    pub(super) fn refresh(&self) {
        let Some(pane) = self.pane.upgrade() else {
            return;
        };
        let total: usize = pane.approved.borrow().iter().map(Vec::len).sum();
        let count = pane
            .approved
            .borrow()
            .iter()
            .flatten()
            .filter(|v| **v)
            .count();
        self.count.set_text(&format!(
            "{} ({total})",
            pane.lang.text("Treffer", "Matches")
        ));
        self.approved.set_text(&format!(
            "{} {count} {} {total}",
            pane.lang.text("Freigegeben:", "Approved:"),
            pane.lang.text("von", "of")
        ));
        self.review.set_label(&format!(
            "{} · {count}",
            pane.lang.text("Freigaben prüfen", "Review approvals")
        ));
        let available = self.available();
        self.message
            .set_visible(!available && pane.render_error.get());
        if !available {
            self.message.set_text(&pane.render_status.text());
        }
        self.review.set_sensitive(available && count > 0);
        self.replace.set_sensitive(
            available
                && total > 0
                && self.selected.get().is_some()
                && !self.single_busy.get()
                && pane.on_replace.borrow().is_some()
                && (self.disk || self.ui.upgrade().is_some_and(|ui| ui.active().is_some_and(|doc| !doc.source_edits_locked()))),
        );
        self.list.set_sensitive(available);
        self.all.set_sensitive(available && count < total);
        self.none.set_sensitive(available && count > 0);
        self.previous.set_sensitive(available && total > 0);
        self.next.set_sensitive(available && total > 0);
        self.refresh_rows();
        groups::refresh(self);
        self.inline.refresh();
        self.refresh_empty();
    }
    fn refresh_empty(&self) {
        let Some(ui) = self.ui.upgrade() else {
            return;
        };
        let lang = ui.lang;
        let pattern = ui.find.text();
        let text = if pattern.is_empty() {
            lang.text("Suchausdruck eingeben…", "Enter a search expression…")
        } else if self.completed.get() {
            if self.disk {
                lang.text(
                    "Keine Treffer in den durchsuchten Ordnern.",
                    "No matches in the searched folders.",
                )
            } else {
                lang.text("Keine Treffer.", "No matches.")
            }
        } else if self.disk && !search_live::folder_ready(&pattern) {
            lang.text(
                "Mindestens 3 Zeichen für die Live-Ordner-Suche — oder „Suchen“ klicken.",
                "At least 3 characters for live folder search — or click Find.",
            )
        } else if self.disk {
            lang.text(
                "„Suchen“ klicken oder Return drücken, um die Ordner zu durchsuchen.",
                "Click Find or press Return to search the folders.",
            )
        } else {
            lang.text("Keine Treffer.", "No matches.")
        };
        self.empty.set_text(text);
        self.empty.set_visible(self.model.n_items() == 0);
    }
    pub(super) fn clear(&self) {
        self.single_job.set(self.single_job.get().wrapping_add(1));
        self.single_busy.set(false);
        self.group_busy.set(false);
        self.group_cancel.borrow().cancel();
        *self.group_cancel.borrow_mut() = Cancellation::default();
        if let (Some(ui), Some(pane)) = (self.ui.upgrade(), self.pane.upgrade()) {
            search_navigation::clear_pane(&ui, &pane.items.borrow());
        }
        self.navigation_cancel.borrow().cancel();
        self.navigation_message.set_text("");
        self.navigation_message.set_visible(false);
        self.cancel.borrow().cancel();
        self.generation.set(self.generation.get().wrapping_add(1));
        self.ready.set(false);
        self.completed.set(false);
        self.selected.set(None);
        self.detail_generation
            .set(self.detail_generation.get().wrapping_add(1));
        self.rows.borrow_mut().clear();
        self.model.splice(0, self.model.n_items(), &[]);
        self.detail.buffer().set_text("");
        self.detail_title.set_tooltip_text(None);
        self.detail.set_tooltip_text(None);
        self.message.set_text("");
        self.message.set_visible(false);
        if let Some(pane) = self.pane.upgrade() {
            self.detail_title
                .set_text(pane.lang.text("Detail · kein Treffer", "Detail · no match"));
        }
        self.position.set_text("0 / 0");
        self.window.set_visible(false);
        self.refresh();
    }
    pub(super) fn rebuild(self: &Rc<Self>) {
        self.clear();
        self.completed.set(true);
        let Some(pane) = self.pane.upgrade() else {
            return;
        };
        let items: Vec<_> = pane
            .items
            .borrow()
            .iter()
            .map(|item| (item.label.clone(), item.preview.clone()))
            .collect();
        let generation = self.generation.get();
        let cancel = Cancellation::default();
        *self.cancel.borrow_mut() = cancel.clone();
        let weak = Rc::downgrade(self);
        let short_titles = self.disk;
        git_view::background(
            move || prepare_rows(&items, short_titles, &cancel).map_err(|e| e.to_string()),
            move |result| {
                let Some(s) = weak.upgrade().filter(|s| s.generation.get() == generation) else {
                    return;
                };
                match result {
                    Ok(rows) => {
                        let labels: Vec<_> = (0..rows.len()).map(|n| n.to_string()).collect();
                        let refs: Vec<_> = labels.iter().map(String::as_str).collect();
                        *s.rows.borrow_mut() = rows;
                        s.model.splice(0, 0, &refs);
                        s.ready.set(true);
                        if let Some(pane) = s.pane.upgrade() {
                            pane.notify(true);
                        }
                        let resume = s
                            .pane
                            .upgrade()
                            .and_then(|pane| pane.resume.borrow_mut().take())
                            .filter(|resume| (resume.current)());
                        let hits = s
                            .rows
                            .borrow()
                            .iter()
                            .enumerate()
                            .filter_map(|(index, row)| {
                                matches!(row, Row::Match { .. }).then_some(index)
                            })
                            .collect::<Vec<_>>();
                        if !hits.is_empty() {
                            let ordinal = resume
                                .as_ref()
                                .map_or(0, |resume| resume.ordinal.min(hits.len() - 1));
                            s.select(hits[ordinal], resume.is_some());
                        }
                        s.refresh();
                    }
                    Err(error) => {
                        if let Some(p) = s.pane.upgrade() {
                            p.render_error.set(true);
                            p.render_status.set_text(&error);
                            p.notify(false);
                        }
                    }
                }
            },
        );
    }
    fn refresh_rows(&self) {
        let items: Vec<_> = {
            let mut bound = self.bound.borrow_mut();
            bound.retain(|item| item.upgrade().is_some());
            bound.iter().filter_map(glib::WeakRef::upgrade).collect()
        };
        for item in items {
            self.bind(&item);
        }
    }
    fn bind(&self, item: &gtk::ListItem) {
        let Some(pane) = self.pane.upgrade() else {
            return;
        };
        let rows = self.rows.borrow();
        let Some(data) = rows.get(item.position() as usize) else {
            return;
        };
        let row = item.child().unwrap().downcast::<gtk::Box>().unwrap();
        let check = row
            .first_child()
            .unwrap()
            .downcast::<gtk::CheckButton>()
            .unwrap();
        let button = row.last_child().unwrap().downcast::<gtk::Button>().unwrap();
        let label = button.child().unwrap().downcast::<gtk::Label>().unwrap();
        self.updating.set(true);
        label.set_tooltip_text(None);
        match data {
            Row::File { item, title } => {
                label.set_attributes(None);
                let approved = pane.approved.borrow();
                let values = &approved[*item];
                let count = values.iter().filter(|v| **v).count();
                check.set_active(count == values.len() && !values.is_empty());
                check.set_inconsistent(count > 0 && count < values.len());
                label.set_text(&format!(
                    "{title} ({} · {} {})",
                    values.len(),
                    count,
                    pane.lang.text("freigegeben", "approved")
                ));
                label.set_tooltip_text(Some(&pane.items.borrow()[*item].label));
                row.add_css_class("hit-file");
                row.remove_css_class("hit-selected");
            }
            Row::Match {
                item: file,
                hit,
                line,
                start,
                end,
                text,
                ..
            } => {
                check.set_widget_name(&format!("fastra-match-{file}-{hit}"));
                check.set_inconsistent(false);
                check.set_active(pane.approved.borrow()[*file][*hit]);
                let prefix = format!("{line:>4}  ");
                label.set_text(&format!("{prefix}{text}"));
                let attributes = gtk::pango::AttrList::new();
                let context = |start: usize, end: usize| {
                    let mut attr = gtk::pango::AttrInt::new_foreground_alpha(39_321);
                    attr.set_start_index(start as u32);
                    attr.set_end_index(end as u32);
                    attr
                };
                attributes.insert(context(0, prefix.len()));
                attributes.insert(context(
                    prefix.len() + (*end - *start).min(text.len()),
                    prefix.len() + text.len(),
                ));
                label.set_attributes(Some(&attributes));
                row.remove_css_class("hit-file");
                if self.selected.get() == Some(item.position() as usize) {
                    row.add_css_class("hit-selected");
                } else {
                    row.remove_css_class("hit-selected");
                }
            }
        }
        check.update_property(&[gtk::accessible::Property::Label(&label.text())]);
        self.updating.set(false);
    }
    pub(super) fn toggle(&self, index: usize, value: bool) {
        if !self.available() {
            return;
        }
        let Some(pane) = self.pane.upgrade() else {
            return;
        };
        let row = self.rows.borrow().get(index).cloned();
        let changed = match row {
            Some(Row::File { item, .. }) => {
                let mut approved = pane.approved.borrow_mut();
                let changed = approved[item].iter().any(|old| *old != value);
                approved[item].fill(value);
                changed
            }
            Some(Row::Match { item, hit, .. }) => {
                let mut approved = pane.approved.borrow_mut();
                let changed = approved[item][hit] != value;
                approved[item][hit] = value;
                changed
            }
            None => return,
        };
        if !changed {
            return;
        }
        pane.update_after();
        self.refresh();
    }
    fn set_all(&self, value: bool) {
        if !self.available() {
            return;
        }
        if let Some(pane) = self.pane.upgrade() {
            for row in pane.approved.borrow_mut().iter_mut() {
                row.fill(value);
            }
            pane.update_after();
            self.refresh();
        }
    }
    fn navigate(&self, direction: i32) {
        let rows = self.rows.borrow();
        let hits: Vec<_> = rows
            .iter()
            .enumerate()
            .filter_map(|(n, r)| matches!(r, Row::Match { .. }).then_some(n))
            .collect();
        let current = hits
            .iter()
            .position(|n| Some(*n) == self.selected.get())
            .unwrap_or(0);
        if !hits.is_empty() {
            let target = current as i32 + direction;
            let wrap = self.pane.upgrade().is_some_and(|p| p.wrap_around.get());
            let index = if wrap {
                target.rem_euclid(hits.len() as i32)
            } else {
                target.clamp(0, hits.len() as i32 - 1)
            } as usize;
            let row = hits[index];
            drop(rows);
            self.select(row, true);
        }
    }
    fn select(&self, index: usize, explicit: bool) {
        let Some(pane) = self.pane.upgrade() else {
            return;
        };
        let data = self.rows.borrow().get(index).cloned();
        let Some(Row::Match {
            item,
            hit,
            line,
            column,
            start,
            end,
            characters,
            ..
        }) = data
        else {
            return;
        };
        self.selected.set(Some(index));
        self.group_busy.set(false);
        self.group_cancel.borrow().cancel();
        *self.group_cancel.borrow_mut() = Cancellation::default();
        if let Some(ui) = self.ui.upgrade() {
            search_navigation::clear_pane(&ui, &pane.items.borrow());
        }
        let rows = self.rows.borrow();
        let position = rows[..=index]
            .iter()
            .filter(|r| matches!(r, Row::Match { .. }))
            .count();
        let total = rows
            .iter()
            .filter(|r| matches!(r, Row::Match { .. }))
            .count();
        drop(rows);
        self.position.set_text(&format!("{position} / {total}"));
        self.detail_title.set_text(&format!(
            "Detail · {} · {} {line} · {} {column}",
            if self.disk {
                file_title(&pane.items.borrow()[item].label).to_owned()
            } else {
                pane.items.borrow()[item].label.clone()
            },
            pane.lang.text("Zeile", "Line"),
            pane.lang.text("Spalte", "Column")
        ));
        self.detail_title
            .set_tooltip_text(Some(&pane.items.borrow()[item].label));
        let preview = pane.items.borrow()[item].preview.clone();
        let ticket = self.detail_generation.get().wrapping_add(1);
        self.detail_generation.set(ticket);
        self.detail.buffer().set_text("");
        groups::refresh(self);
        self.inline.refresh();
        let weak = pane.search.borrow().as_ref().map(Rc::downgrade);
        let detail_preview = preview.clone();
        let mut offset = 0;
        glib::idle_add_local(move || {
            let Some(s) = weak
                .as_ref()
                .and_then(std::rc::Weak::upgrade)
                .filter(|s| s.detail_generation.get() == ticket)
            else {
                return glib::ControlFlow::Break;
            };
            let text = &detail_preview.source()[start..end];
            append_chunk(&s.detail.buffer(), text, &mut offset);
            if offset < text.len() {
                glib::ControlFlow::Continue
            } else {
                groups::color_captures(&s, &detail_preview, hit);
                groups::refresh(&s);
                glib::ControlFlow::Break
            }
        });
        let visible = pane
            .visible
            .borrow()
            .iter()
            .position(|index| *index == item);
        if let Some(visible) = visible {
            if pane.files.selected() != visible as u32 {
                pane.files.set_selected(visible as u32);
            }
        }
        self.detail.set_tooltip_text(Some(&format!(
            "{} {}",
            pane.lang.text("Treffer", "Match"),
            hit + 1
        )));
        self.refresh_rows();
        self.list.scroll_to(
            if explicit { index as u32 } else { 0 },
            gtk::ListScrollFlags::NONE,
            None::<gtk::ScrollInfo>,
        );
        self.navigation_cancel.borrow().cancel();
        let cancel = Cancellation::default();
        *self.navigation_cancel.borrow_mut() = cancel.clone();
        self.navigation_message.set_text("");
        self.navigation_message.set_visible(false);
        let callback = pane.on_navigate.borrow().clone();
        if let Some(callback) = callback {
            let ranges = self
                .rows
                .borrow()
                .iter()
                .filter_map(|row| match row {
                    Row::Match {
                        item: found,
                        characters,
                        ..
                    } if *found == item => Some(*characters),
                    _ => None,
                })
                .take(2000)
                .collect();
            let weak = pane.search.borrow().as_ref().map(Rc::downgrade);
            let weak_report = weak.clone();
            let cancelled = cancel.clone();
            let current = Rc::new(move || {
                weak.as_ref()
                    .and_then(std::rc::Weak::upgrade)
                    .is_some_and(|s| {
                        cancelled.check().is_ok()
                            && s.ready.get()
                            && s.detail_generation.get() == ticket
                            && !s.window.is_visible()
                            && s._owner.is_visible()
                            && (!explicit
                                || s.ui
                                    .upgrade()
                                    .is_some_and(|ui| source_panes::focused_is(&ui, &s._owner)))
                            && s.pane.upgrade().is_some_and(|pane| !pane.frozen.get())
                    })
            });
            let report = Rc::new(move |message: &str| {
                if let Some(s) = weak_report
                    .as_ref()
                    .and_then(std::rc::Weak::upgrade)
                    .filter(|s| s.detail_generation.get() == ticket)
                {
                    s.navigation_message.set_text(message);
                    s.navigation_message.set_visible(!message.is_empty());
                }
            });
            callback(Navigation {
                item,
                explicit,
                preview,
                range: characters,
                ranges,
                cancel,
                current,
                report,
            });
        }
    }
    #[cfg(debug_assertions)]
    pub(super) fn test_approve_hit(&self, item: usize, hit: usize, value: bool) {
        let index = self
            .rows
            .borrow()
            .iter()
            .position(|row| matches!(row,Row::Match {item:i,hit:h,..} if *i==item && *h==hit))
            .unwrap();
        self.toggle(index, value);
    }
    pub(super) fn rows_ready(&self) -> bool {
        self.ready.get()
    }
    fn copy_matches(&self) {
        if !self.available() {
            return;
        }
        let Some(pane) = self.pane.upgrade() else {
            return;
        };
        let entries: Vec<_> = self
            .rows
            .borrow()
            .iter()
            .filter_map(|row| {
                if let Row::Match {
                    item, start, end, ..
                } = row
                {
                    Some((pane.items.borrow()[*item].preview.clone(), *start, *end))
                } else {
                    None
                }
            })
            .collect();
        let generation = self.generation.get();
        let cancel = self.cancel.borrow().clone();
        let lang = pane.lang;
        let weak = pane.search.borrow().as_ref().map(Rc::downgrade);
        git_view::background(
            move || {
                let mut text = String::new();
                for (index, (preview, start, end)) in entries.into_iter().enumerate() {
                    cancel.check().map_err(|e| e.to_string())?;
                    if text.len().saturating_add(end - start).saturating_add(1) > 16 * 1024 * 1024 {
                        return Err(lang
                            .text(
                                "Zwischenablage überschreitet 16 MiB.",
                                "Clipboard exceeds 16 MiB.",
                            )
                            .into());
                    }
                    if index > 0 {
                        text.push('\n');
                    }
                    text.push_str(&preview.source()[start..end]);
                }
                Ok(text)
            },
            move |result| {
                if let Some(s) = weak
                    .and_then(|w| w.upgrade())
                    .filter(|s| s.generation.get() == generation && s.available())
                {
                    match result {
                        Ok(text) => s.list.clipboard().set_text(&text),
                        Err(error) => {
                            s.message.set_text(&error);
                            s.message.set_visible(true);
                        }
                    }
                }
            },
        );
    }
}

fn file_title(title: &str) -> &str {
    if title.starts_with('/') {
        std::path::Path::new(title)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(title)
    } else {
        title
    }
}
fn prepare_rows(
    items: &[(String, Arc<Preview>)],
    short_titles: bool,
    cancel: &Cancellation,
) -> Result<Vec<Row>, fastra_core::Error> {
    let mut result = Vec::new();
    for (item, (title, preview)) in items.iter().enumerate() {
        if preview.matches().is_empty() {
            continue;
        }
        result.push(Row::File {
            item,
            title: if short_titles {
                file_title(title).to_owned()
            } else {
                title.clone()
            },
        });
        let mut chars = preview.source().char_indices().peekable();
        let mut units = 0;
        let mut line = 1;
        let mut column = 1;
        let mut scanned = 0usize;
        let mut boundary =
            |target: usize| -> Result<(usize, usize, usize, i32), fastra_core::Error> {
                while units < target {
                    let (_, ch) = chars.next().ok_or(fastra_core::Error::InvalidRange)?;
                    units += ch.len_utf16();
                    column += ch.len_utf16();
                    let next = chars.peek().map(|(_, ch)| *ch);
                    if matches!(ch, '\r' | '\n' | '\u{85}' | '\u{2028}' | '\u{2029}')
                        && next.is_some()
                        && !(ch == '\r' && next == Some('\n'))
                    {
                        line += 1;
                        column = 1;
                    }
                    scanned += 1;
                    if scanned & 4095 == 0 {
                        cancel.check()?;
                    }
                }
                if units != target {
                    return Err(fastra_core::Error::InvalidRange);
                }
                Ok((
                    chars
                        .peek()
                        .map_or(preview.source().len(), |(byte, _)| *byte),
                    line,
                    column,
                    i32::try_from(scanned).map_err(|_| fastra_core::Error::Limit)?,
                ))
            };
        for (hit, value) in preview.matches().iter().enumerate() {
            cancel.check()?;
            let (start, line, column, char_start) = boundary(value.range.location)?;
            let (end, _, _, char_end) = boundary(value.range.end()?)?;
            let text = preview.source()[start..]
                .split(['\r', '\n'])
                .next()
                .unwrap_or("")
                .chars()
                .take(200)
                .collect();
            result.push(Row::Match {
                item,
                hit,
                start,
                end,
                characters: (char_start, char_end),
                line,
                column,
                text,
            });
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mac_match_coordinates_keep_utf16_crlf_and_final_line_contract() {
        let preview = Arc::new(
            fastra_core::preview(
                "🙂cat\r\n猫cat\n",
                1,
                1,
                &SearchRequest {
                    pattern: "cat|\\z".into(),
                    replacement: "dog".into(),
                    mode: SearchMode::Regex,
                    case_sensitive: true,
                    range: None,
                },
                Limits::default(),
                &Cancellation::default(),
            )
            .unwrap(),
        );
        let rows = prepare_rows(
            &[("sample.txt".into(), preview)],
            false,
            &Cancellation::default(),
        )
        .unwrap();
        let positions: Vec<_> = rows
            .iter()
            .filter_map(|row| {
                if let Row::Match {
                    line,
                    column,
                    start,
                    end,
                    ..
                } = row
                {
                    Some((*line, *column, *start, *end))
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(positions, [(1, 3, 4, 7), (2, 2, 12, 15), (2, 6, 16, 16)]);
    }
}

#[cfg(debug_assertions)]
pub(crate) mod selftest;
