//! Native 4D-Vorschläge; Dateiscans nur nach explizitem Index-Refresh.
use super::*;
use fastra_core::four_d_completion::{self as core, Component, Kind, Method, Suggestions};
use std::rc::Weak;
thread_local! {
    static STATES: RefCell<Vec<Weak<State>>> = const { RefCell::new(Vec::new()) };
    static FOCUS: Cell<u64> = const { Cell::new(0) };
    static CACHES: RefCell<Vec<(Weak<Ui>, Rc<Cache>)>> = const { RefCell::new(Vec::new()) };
}
struct Cache {
    project: RefCell<Option<project_view::Binding>>,
    methods: RefCell<Vec<Method>>,
    components: RefCell<Vec<Component>>,
    generation: Cell<u64>,
    cancel: RefCell<Cancellation>,
}
impl Cache {
    fn current(&self, ui: &Rc<Ui>) -> bool {
        self.project.borrow().as_ref().is_some_and(|bound| {
            bound.is_current()
                && project_view::current_binding(ui)
                    .is_some_and(|now| now.owner_id() == bound.owner_id())
        })
    }
}
struct Pending {
    source: String,
    revision: u64,
    cursor: i32,
    project_generation: u64,
    project_id: Option<String>,
    suggestions: Suggestions,
}
struct State {
    ui: Weak<Ui>,
    doc: Weak<Document>,
    view: glib::WeakRef<sourceview5::View>,
    popup: gtk::Popover,
    list: gtk::ListBox,
    scroll: gtk::ScrolledWindow,
    status: gtk::Label,
    cache: Rc<Cache>,
    job: Cell<u64>,
    focus: Cell<u64>,
    cancel: RefCell<Cancellation>,
    pending: RefCell<Option<Pending>>,
    target: RefCell<Option<source_panes::Target>>,
    inserting: Cell<bool>,
    filtering: Cell<bool>,
}
impl Drop for State {
    fn drop(&mut self) {
        self.cancel.get_mut().cancel();
        if self.popup.parent().is_some() {
            self.popup.unparent();
        }
    }
}
fn cache(ui: &Rc<Ui>) -> Rc<Cache> {
    CACHES.with(|all| {
        let mut all = all.borrow_mut();
        all.retain(|(ui, _)| ui.strong_count() > 0);
        if let Some((_, cache)) = all
            .iter()
            .find(|(bound, _)| bound.upgrade().is_some_and(|bound| Rc::ptr_eq(&bound, ui)))
        {
            return cache.clone();
        }
        let cache = Rc::new(Cache {
            project: RefCell::new(None),
            methods: RefCell::new(Vec::new()),
            components: RefCell::new(Vec::new()),
            generation: Cell::new(0),
            cancel: RefCell::new(Cancellation::default()),
        });
        all.push((Rc::downgrade(ui), cache.clone()));
        cache
    })
}
impl State {
    fn owner(&self) -> Option<(Rc<Ui>, Rc<Document>, sourceview5::View)> {
        let ui = self.ui.upgrade()?;
        let doc = self.doc.upgrade()?;
        let view = self.view.upgrade()?;
        if !ui.window.is_visible()
            || !view.is_mapped()
            || !view.is_editable()
            || doc.source_edits_locked()
            || doc.saving.get()
            || doc.folded.borrow().is_some()
            || !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc))
            || doc
                .buffer
                .language()
                .is_none_or(|language| language.id() != "fastra-4d")
            || view.buffer().selection_bounds().is_some()
            || doc.close_pending.get()
            || !doc.source_panes.borrow().as_ref().is_some_and(|p|p.owns(&view))
            || source_panes::capture(&doc).is_none_or(|target|target.view!=view)
            || doc
                .rectangles
                .borrow()
                .iter()
                .any(|rect| rect.is_selected())
        {
            return None;
        }
        Some((ui, doc, view))
    }
    fn close(&self) {
        self.job.set(self.job.get().wrapping_add(1));
        self.cancel.borrow().cancel();
        self.pending.borrow_mut().take();
        self.target.borrow_mut().take();
        self.filtering.set(false);
        self.popup.popdown();
    }
    fn refresh(self: &Rc<Self>) {
        let Some((ui, _, _)) = self.owner() else {
            self.close();
            return;
        };
        let Some(binding) = project_view::current_binding(&ui) else {
            self.status.set_text(ui.lang.text(
                "Für Projekt-/Komponentenmethoden zuerst einen Projektbaum wählen.",
                "Choose a project tree for project/component methods.",
            ));
            return;
        };
        self.close();
        self.cache.cancel.borrow().cancel();
        self.cache.methods.borrow_mut().clear();
        self.cache.components.borrow_mut().clear();
        self.cache.project.borrow_mut().take();
        self.cache
            .generation
            .set(self.cache.generation.get().wrapping_add(1));
        let generation = self.cache.generation.get();
        let cancel = Cancellation::default();
        let work = match binding.work(&cancel) {
            Ok(work) => work,
            Err(error) => {
                ui.status.set_text(&error);
                return;
            }
        };
        *self.cache.cancel.borrow_mut() = cancel.clone();
        let root = binding.root.path.clone();
        let cache = self.cache.clone();
        let weak = Rc::downgrade(self);
        ui.status.set_text(ui.lang.text(
            "4D-Projekt und Komponenten werden gelesen …",
            "Reading 4D project and components …",
        ));
        git_view::background(
            move || {
                work.validate()?;
                let project = four_d_index::scan(&root, &cancel)?;
                let components = four_d_components::scan(&root, &cancel)?;
                work.validate()?;
                let methods = project
                    .entries
                    .into_iter()
                    .filter(|entry| {
                        entry
                            .path
                            .parent()
                            .and_then(|p| p.file_name())
                            .is_some_and(|p| p == "Methods")
                    })
                    .map(|entry| Method {
                        name: entry.name,
                        signature: four_d_components::signature_summary(&entry.signature),
                    })
                    .collect::<Vec<_>>();
                Ok((
                    methods,
                    components.methods,
                    project.warnings,
                    components.warnings,
                ))
            },
            move |result| {
                if cache.generation.get() != generation || !binding.is_current() {
                    return;
                }
                let Some(state) = weak.upgrade() else { return };
                let Some((ui, _, _)) = state.owner() else {
                    return;
                };
                match result {
                    Ok((methods, components, warnings, component_warnings)) => {
                        let detail = format!(
                            "{} {} · {} {}",
                            methods.len(),
                            ui.lang.text("Projektmethoden", "project methods"),
                            components.len(),
                            ui.lang.text("Komponentenmethoden", "component methods")
                        );
                        *cache.methods.borrow_mut() = methods;
                        *cache.components.borrow_mut() = components;
                        *cache.project.borrow_mut() = Some(binding);
                        ui.status.set_text(&format!(
                            "{detail} {} {}",
                            warnings.join(" · "),
                            component_warnings.join(" · ")
                        ));
                        state.request(true);
                    }
                    Err(error) => ui.status.set_text(&format!(
                        "{} {error}",
                        ui.lang
                            .text("4D-Index nicht übernommen:", "4D index was not adopted:")
                    )),
                }
            },
        );
    }
    fn request(self: &Rc<Self>, manual: bool) {
        if self.inserting.get() {
            return;
        }
        let open = self.filtering.get();
        self.close();
        let Some((ui, doc, view)) = self.owner() else {
            return;
        };
        self.filtering.set(open);
        if !manual && !view.has_focus() {
            return;
        }
        let Some(target)=source_panes::capture(&doc) else{return};
        let job = self.job.get();
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(
            Duration::from_millis(if manual { 0 } else { 90 }),
            move || {
                let Some(state) = weak.upgrade().filter(|state| state.job.get() == job) else {
                    return;
                };
                let Some((ui, doc, view)) = state.owner() else {
                    return;
                };
                if !manual && !view.has_focus() {
                    return;
                }
                if doc.buffer.char_count() as usize > fastra_core::four_d::MAX_SOURCE_BYTES {
                    return;
                }
                let source = buffer_text(&doc.buffer);
                let revision = doc.revision.get();
                if !target.valid(&doc){return;}
                let cursor = target.buffer.cursor_position();
                let project_id =
                    project_view::current_binding(&ui).map(|binding| binding.owner_id());
                let project_generation = state.cache.generation.get();
                let current = state.cache.current(&ui);
                let methods = if current {
                    state.cache.methods.borrow().clone()
                } else {
                    Vec::new()
                };
                let components = if current {
                    state.cache.components.borrow().clone()
                } else {
                    Vec::new()
                };
                let cancel = Cancellation::default();
                *state.cancel.borrow_mut() = cancel.clone();
                let weak = Rc::downgrade(&state);
                git_view::background(
                    move || {
                        let offset = source
                            .chars()
                            .take(cursor as usize)
                            .map(char::len_utf16)
                            .sum();
                        let suggestions = core::suggest(
                            &source,
                            fastra_core::Utf16Range {
                                location: offset,
                                length: 0,
                            },
                            manual,
                            open,
                            &methods,
                            &components,
                            &cancel,
                        )
                        .map_err(|e| e.to_string())?;
                        Ok(suggestions.map(|suggestions| Pending {
                            source,
                            revision,
                            cursor,
                            project_generation,
                            project_id,
                            suggestions,
                        }))
                    },
                    move |answer| {
                        let Some(state) = weak.upgrade().filter(|state| state.job.get() == job)
                        else {
                            return;
                        };
                        let Some((ui, doc, _)) = state.owner() else {
                            return;
                        };
                        match answer {
                            Ok(Some(pending))
                                if doc.revision.get() == revision
                                    && target.valid(&doc)
                                    && target.buffer.cursor_position() == cursor
                                    && state.cache.generation.get() == project_generation =>
                            {
                                let now = project_view::current_binding(&ui)
                                    .map(|binding| binding.owner_id());
                                if now != pending.project_id {
                                    return;
                                }
                                *state.target.borrow_mut()=Some(target.clone());
                                state.show(pending, current);
                            }
                            Ok(_) => state.filtering.set(false),
                            Err(error) if manual => ui.status.set_text(&format!(
                                "{} {error}",
                                ui.lang.text(
                                    "4D-Vorschläge nicht verfügbar:",
                                    "4D suggestions unavailable:"
                                )
                            )),
                            Err(_) => {}
                        }
                    },
                );
            },
        );
        let _ = (ui, doc);
    }
    fn show(&self, pending: Pending, index_current: bool) {
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let Some(ui) = self.ui.upgrade() else { return };
        for candidate in &pending.suggestions.items {
            let row = gtk::ListBoxRow::new();
            row.set_focusable(false);
            let column = gtk::Box::new(gtk::Orientation::Vertical, 2);
            column.set_margin_top(4);
            column.set_margin_bottom(4);
            column.set_margin_start(8);
            column.set_margin_end(8);
            let name = git_view::label(&candidate.name);
            name.add_css_class("monospace");
            column.append(&name);
            let detail = match &candidate.kind {
                Kind::Command => candidate
                    .signature
                    .clone()
                    .unwrap_or_else(|| ui.lang.text("4D-Befehl", "4D command").into()),
                Kind::Project => ui.lang.text("Projektmethode", "Project method").into(),
                Kind::Component(name) => {
                    format!("{} {name}", ui.lang.text("Komponente", "Component"))
                }
                Kind::Constant => ui.lang.text("Konstante", "Constant").into(),
            };
            let detail = if !matches!(candidate.kind, Kind::Command) {
                candidate
                    .signature
                    .as_ref()
                    .map_or(detail.clone(), |signature| {
                        format!("{detail} · {signature}")
                    })
            } else {
                detail
            };
            let detail = git_view::label(&detail);
            detail.add_css_class("dim-label");
            column.append(&detail);
            row.set_child(Some(&column));
            self.list.append(&row);
        }
        if let Some(row) = self.list.row_at_index(0) {
            self.list.select_row(Some(&row));
        }
        let adjustment = self.scroll.vadjustment();
        adjustment.set_value(adjustment.lower());
        self.status.set_text(if index_current {
            ui.lang.text(
                "↑/↓ wählen · Return/Tab oder Klick übernimmt · Esc schließt",
                "↑/↓ select · Return/Tab or click applies · Esc closes",
            )
        } else {
            ui.lang.text(
                "Befehle/Konstanten · Projektmethoden nach Index-Aktualisierung verfügbar",
                "Commands/constants · Refresh the index for project methods",
            )
        });
        let Some(view) = self.view.upgrade() else {
            return;
        };
        let iter = view.buffer().iter_at_offset(pending.cursor);
        let rectangle = view.iter_location(&iter);
        let (x, y) =
            view.buffer_to_window_coords(gtk::TextWindowType::Widget, rectangle.x(), rectangle.y());
        self.popup.set_pointing_to(Some(&gtk::gdk::Rectangle::new(
            x,
            y,
            rectangle.width().max(1),
            rectangle.height().max(1),
        )));
        *self.pending.borrow_mut() = Some(pending);
        self.filtering.set(true);
        self.popup.popup();
    }
    fn apply(&self) {
        let Some((ui, doc, view)) = self.owner() else {
            self.close();
            return;
        };
        let pending = self.pending.borrow_mut().take();
        let target=self.target.borrow_mut().take();
        let (Some(pending),Some(target))=(pending,target) else{return};
        let project_id = project_view::current_binding(&ui).map(|binding| binding.owner_id());
        if doc.revision.get() != pending.revision
            || !target.valid(&doc)
            || target.buffer.cursor_position() != pending.cursor
            || self.cache.generation.get() != pending.project_generation
            || project_id != pending.project_id
        {
            self.close();
            return;
        }
        let Some(row) = self.list.selected_row() else {
            self.close();
            return;
        };
        let Some(candidate) = pending.suggestions.items.get(row.index() as usize) else {
            self.close();
            return;
        };
        let Ok(bytes) = pending.suggestions.range.byte_range(&pending.source) else {
            self.close();
            return;
        };
        if text_limits::validate(&candidate.name, ui.lang).is_err() {
            self.close();
            return;
        }
        let start = pending.source[..bytes.start].chars().count() as i32;
        let end = pending.source[..bytes.end].chars().count() as i32;
        self.inserting.set(true);
        self.close();
        target.buffer.begin_user_action();
        let mut first = target.buffer.iter_at_offset(start);
        let mut last = target.buffer.iter_at_offset(end);
        target.buffer.delete(&mut first, &mut last);
        target.buffer.insert(&mut first, &candidate.name);
        target.buffer.place_cursor(&first);
        target.buffer.end_user_action();
        self.inserting.set(false);
        view.grab_focus();
    }
    fn move_selection(&self, delta: i32) {
        let Some(pending) = self
            .pending
            .borrow()
            .as_ref()
            .map(|p| p.suggestions.items.len())
        else {
            return;
        };
        let next = (self.list.selected_row().map_or(0, |row| row.index()) + delta)
            .clamp(0, pending as i32 - 1);
        if let Some(row) = self.list.row_at_index(next) {
            self.list.select_row(Some(&row));
            let adjustment = self.scroll.vadjustment();
            let top = row
                .compute_bounds(&self.list)
                .map_or(0., |bounds| f64::from(bounds.y()));
            let bottom = top + f64::from(row.height());
            let value = adjustment.value();
            let page = adjustment.page_size();
            if top < value {
                adjustment.set_value(top);
            } else if bottom > value + page {
                adjustment.set_value(bottom - page);
            }
            if let Some(view) = self.view.upgrade() {
                view.grab_focus();
            }
        }
    }
}
pub(super) fn install(ui: &Rc<Ui>, doc: &Rc<Document>, view: &sourceview5::View) {
    let popup = gtk::Popover::new();
    popup.set_autohide(false);
    popup.set_has_arrow(false);
    popup.set_position(gtk::PositionType::Bottom);
    popup.set_parent(view);
    let root = gtk::Box::new(gtk::Orientation::Vertical, 6);
    root.set_margin_top(8);
    root.set_margin_bottom(8);
    root.set_margin_start(8);
    root.set_margin_end(8);
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::Single);
    list.set_activate_on_single_click(true);
    let scroll = gtk::ScrolledWindow::builder()
        .child(&list)
        .min_content_width(400)
        .max_content_width(640)
        .max_content_height(320)
        .propagate_natural_height(true)
        .build();
    root.append(&scroll);
    let status = git_view::label("");
    root.append(&status);
    let refresh = gtk::Button::with_label(ui.lang.text(
        "Projekt-/Komponentenindex aktualisieren",
        "Refresh project/component index",
    ));
    refresh.set_focusable(false);
    root.append(&refresh);
    popup.set_child(Some(&root));
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        doc: Rc::downgrade(doc),
        view: view.downgrade(),
        popup,
        list,
        scroll,
        status,
        cache: cache(ui),
        job: Cell::new(0),
        focus: Cell::new(0),
        cancel: RefCell::new(Cancellation::default()),
        pending: RefCell::new(None),
        target: RefCell::new(None),
        inserting: Cell::new(false),
        filtering: Cell::new(false),
    });
    let weak = Rc::downgrade(&state);
    state.list.connect_row_activated(move |_, _| {
        if let Some(state) = weak.upgrade() {
            state.apply();
        }
    });
    let weak = Rc::downgrade(&state);
    refresh.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.refresh();
        }
    });
    let key = gtk::EventControllerKey::new();
    key.set_propagation_phase(gtk::PropagationPhase::Capture);
    let bound = state.clone();
    key.connect_key_pressed(move |_, key, _, modifiers| {
        if key == gtk::gdk::Key::space
            && modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK)
            && bound.owner().is_some()
        {
            bound.request(true);
            return glib::Propagation::Stop;
        }
        if key == gtk::gdk::Key::Escape && !bound.popup.is_visible() && bound.owner().is_some() {
            bound.request(true);
            return glib::Propagation::Stop;
        }
        if !bound.popup.is_visible() {
            return glib::Propagation::Proceed;
        }
        match key {
            gtk::gdk::Key::Escape => bound.close(),
            gtk::gdk::Key::Up => bound.move_selection(-1),
            gtk::gdk::Key::Down => bound.move_selection(1),
            gtk::gdk::Key::Return | gtk::gdk::Key::Tab => bound.apply(),
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    });
    view.add_controller(key);
    let focus = gtk::EventControllerFocus::new();
    let weak = Rc::downgrade(&state);
    focus.connect_enter(move |_| {
        if let Some(state) = weak.upgrade() {
            let value = FOCUS.with(|counter| {
                counter.set(counter.get().wrapping_add(1));
                counter.get()
            });
            state.focus.set(value);
        }
    });
    view.add_controller(focus);
    let weak = Rc::downgrade(&state);
    doc.buffer.connect_changed(move |_| {
        if let Some(state) = weak.upgrade() {
            state.request(false);
        }
    });
    let weak = Rc::downgrade(&state);
    view.buffer().connect_cursor_position_notify(move |_| {
        if let Some(state) = weak.upgrade() {
            if !state.inserting.get() {
                state.request(false);
            }
        }
    });
    let weak = Rc::downgrade(&state);
    view.connect_unmap(move |_| {
        if let Some(state) = weak.upgrade() {
            state.close();
        }
    });
    let weak = Rc::downgrade(&state);
    doc.buffer.connect_language_notify(move |_| {
        if let Some(state) = weak.upgrade() {
            state.close();
        }
    });
    let weak = Rc::downgrade(&state);
    view.buffer().connect_mark_set(move |buffer, _, mark| {
        if mark.name().as_deref() == Some("selection_bound") && buffer.selection_bounds().is_some()
        {
            if let Some(state) = weak.upgrade() {
                state.close();
            }
        }
    });
    let weak = Rc::downgrade(&state);
    ui.window.connect_visible_notify(move |window| {
        if !window.is_visible() {
            if let Some(state) = weak.upgrade() {
                state.close();
            }
        }
    });
    STATES.with(|all| {
        let mut all = all.borrow_mut();
        all.retain(|s| s.strong_count() > 0);
        all.push(Rc::downgrade(&state));
    });
}
fn active_state(ui: &Rc<Ui>) -> Option<Rc<State>> {
    STATES.with(|all| {
        all.borrow()
            .iter()
            .filter_map(Weak::upgrade)
            .filter(|state| {
                state
                    .ui
                    .upgrade()
                    .is_some_and(|owner| Rc::ptr_eq(&owner, ui))
                    && state.owner().is_some()
            })
            .max_by_key(|state| state.focus.get())
    })
}
pub(super) fn open(ui: &Rc<Ui>) {
    let state = active_state(ui);
    if let Some(state) = state {
        if let Some(view) = state.view.upgrade() {
            view.grab_focus();
        }
        state.request(true);
    } else {
        ui.status.set_text(ui.lang.text("4D-Quelltext ohne Auswahl aktivieren. Vorschläge sind in Rich-, Hex- und Nur-Lese-Ansichten gesperrt.","Activate 4D source without a selection. Suggestions are unavailable in Rich, hex and read-only views."));
    }
}
#[cfg(debug_assertions)]
mod gui_test;

#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}

pub(super) fn refresh_index(ui: &Rc<Ui>) {
    if let Some(state) = active_state(ui) {
        state.refresh();
    } else {
        ui.status.set_text(ui.lang.text(
            "4D-Quelltext ohne Auswahl aktivieren, um den Methodenindex zu aktualisieren.",
            "Activate 4D source without a selection to refresh the method index.",
        ));
    }
}
