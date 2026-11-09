//! Unabhängige Quellauswahlen und gebundene Befehlsziele.
use super::*;
use std::rc::Weak;
mod byte_buffer;
mod commit_query;
#[cfg(debug_assertions)]
mod commit_gate;
mod delete_query;
#[cfg(debug_assertions)]
mod delete_gate;
#[cfg(debug_assertions)]
mod autoindent_gate;
mod primary;
mod view;
fn native_input_enabled() -> bool {
    std::env::var_os("FASTRA_NATIVE_RUNTIME").is_some()
        && fastra_process::host::is_active().unwrap_or(false)
}
pub(super) fn native_preflight_ready() -> bool {
    commit_query::available() && delete_query::available() && view::native_return_ready()
}
pub(super) struct Panes {
    pub(super) buffers: [sourceview5::Buffer; 2],
    views: [glib::WeakRef<sourceview5::View>; 2],
    doc: Weak<Document>,
    ui: Weak<Ui>,
    busy: Cell<bool>,
    history: Cell<bool>,
    active: Cell<usize>,
    epoch: Cell<u64>,
    window_epoch: Cell<u64>,
    owner_group: Cell<bool>,
    app_handler: RefCell<Option<(glib::WeakRef<gtk::Application>, glib::SignalHandlerId)>>,
    window_handler: RefCell<Option<(glib::WeakRef<gtk::ApplicationWindow>, glib::SignalHandlerId)>>,
    selections: [Cell<u64>; 2],
    primary_offers: [glib::WeakRef<gtk::gdk::ContentProvider>; 2],
}
impl Panes {
    pub(super) fn secondary(buffer: &sourceview5::Buffer) -> sourceview5::Buffer {
        let other = new_buffer(Some(&buffer.tag_table()));
        other.set_enable_undo(false);
        other.set_text(&buffer_text(buffer));
        other.set_enable_undo(buffer.enables_undo());
        other.set_max_undo_levels(buffer.max_undo_levels());
        other.set_modified(buffer.is_modified());
        other.set_language(buffer.language().as_ref());
        other
    }
    pub(super) fn install(
        ui: &Rc<Ui>,
        doc: &Rc<Document>,
        views: [&sourceview5::View; 2],
    ) -> Rc<Self> {
        let this = Rc::new(Self {
            buffers: views.map(|v| v.buffer().downcast::<sourceview5::Buffer>().unwrap()),
            views: views.map(|v| v.downgrade()),
            doc: Rc::downgrade(doc),
            ui: Rc::downgrade(ui),
            busy: Cell::new(false),
            history: Cell::new(false),
            active: Cell::new(0),
            epoch: Cell::new(0),
            window_epoch: Cell::new(0),
            owner_group: Cell::new(window_group(ui)),
            app_handler: RefCell::new(None),
            window_handler: RefCell::new(None),
            selections: [Cell::new(0), Cell::new(0)],
            primary_offers: [glib::WeakRef::new(), glib::WeakRef::new()],
        });
        for (index, view) in views.iter().enumerate() {
            let buffer = &this.buffers[index];
            commit_query::install(view, ui);
            let weak = Rc::downgrade(&this);
            buffer.connect_mark_set(move |_, _, mark| {
                if matches!(mark.name().as_deref(), Some("insert" | "selection_bound")) {
                    if let Some(p) = weak.upgrade() {
                        p.selections[index].set(p.selections[index].get().wrapping_add(1));
                        if let (Some(doc), Some(view)) = (p.doc.upgrade(), p.views[index].upgrade())
                        {
                            primary::changed(
                                &doc,
                                &view,
                                &p.buffers[index],
                                &p.primary_offers[index],
                            );
                        }
                    }
                }
            });
            let weak = Rc::downgrade(&this);
            view.connect_editable_notify(move |_| {
                if let Some(p) = weak.upgrade() {
                    p.epoch.set(p.epoch.get().wrapping_add(1));
                }
            });
            let weak = Rc::downgrade(&this);
            view.connect_state_flags_changed(move |v, _| {
                if !v.is_sensitive() {
                    if let Some(p) = weak.upgrade() {
                        p.epoch.set(p.epoch.get().wrapping_add(1));
                    }
                }
            });
            let weak = Rc::downgrade(&this);
            view.connect_unmap(move |_| {
                if let Some(p) = weak.upgrade() {
                    p.epoch.set(p.epoch.get().wrapping_add(1));
                }
            });

            let weak = Rc::downgrade(&this);
            buffer.connect_insert_text(move |buffer, at, text| {
                let Some(this) = weak.upgrade() else { return };
                if this.busy.get() {
                    return;
                }
                if this.doc.upgrade().is_none_or(|d| {
                    index == 1 && (d.close_pending.get() || d.source_edits_locked())
                }) {
                    buffer.stop_signal_emission_by_name("insert-text");
                    return;
                }
                this.busy.set(true);
                let peer = &this.buffers[1 - index];
                peer.insert(&mut peer.iter_at_offset(at.offset()), text);
                this.busy.set(false);
            });
            let weak = Rc::downgrade(&this);
            buffer.connect_delete_range(move |buffer, start, end| {
                let Some(this) = weak.upgrade() else { return };
                if this.busy.get() {
                    return;
                }
                if this.doc.upgrade().is_none_or(|d| {
                    index == 1 && (d.close_pending.get() || d.source_edits_locked())
                }) {
                    buffer.stop_signal_emission_by_name("delete-range");
                    return;
                }
                this.busy.set(true);
                let peer = &this.buffers[1 - index];
                peer.delete(
                    &mut peer.iter_at_offset(start.offset()),
                    &mut peer.iter_at_offset(end.offset()),
                );
                this.busy.set(false);
            });
            let weak = Rc::downgrade(&this);
            buffer.connect_begin_user_action(move |_| {
                if let Some(this) = weak.upgrade() {
                    if !this.busy.replace(true) {
                        this.buffers[1 - index].begin_user_action();
                        this.busy.set(false);
                    }
                }
            });
            let weak = Rc::downgrade(&this);
            buffer.connect_end_user_action(move |_| {
                if let Some(this) = weak.upgrade() {
                    if !this.busy.replace(true) {
                        this.buffers[1 - index].end_user_action();
                        this.busy.set(false);
                    }
                }
            });
            let weak = Rc::downgrade(&this);
            buffer.connect_undo(move |b| {
                if let Some(this) = weak.upgrade() {
                    this.history(b, index, false);
                }
            });
            let weak = Rc::downgrade(&this);
            buffer.connect_redo(move |b| {
                if let Some(this) = weak.upgrade() {
                    this.history(b, index, true);
                }
            });
            let weak = Rc::downgrade(&this);
            view.connect_buffer_notify(move |_| {
                if let Some(p) = weak.upgrade() {
                    p.epoch.set(p.epoch.get().wrapping_add(1));
                }
            });
            let weak = Rc::downgrade(&this);
            view.connect_has_focus_notify(move |v| {
                if let Some(this) = weak.upgrade() {
                    if v.has_focus() && this.active.replace(index) != index {
                        this.epoch.set(this.epoch.get().wrapping_add(1));
                        if let Some(doc) = this.doc.upgrade() {
                            if let Some(chrome) = doc.chrome.borrow().as_ref() { (chrome.refresh_context)(); }
                        }
                    }
                }
            });
        }
        if let Some(app) = ui.window.application() {
            let weak = Rc::downgrade(&this);
            let handler = app.connect_active_window_notify(move |_| {
                if let Some(this) = weak.upgrade() {
                    if let Some(ui) = this.ui.upgrade() {
                        let group = window_group(&ui);
                        if this.owner_group.replace(group) != group {
                            this.window_epoch
                                .set(this.window_epoch.get().wrapping_add(1));
                        }
                    }
                }
            });
            *this.app_handler.borrow_mut() = Some((app.downgrade(), handler));
        }

        let weak = Rc::downgrade(&this);
        doc.buffer.connect_modified_changed(move |buffer| {
            if let Some(p) = weak.upgrade() {
                if !p.history.get() {
                    p.buffers[1].set_modified(buffer.is_modified());
                }
            }
        });
        let weak = Rc::downgrade(&this);
        doc.buffer.connect_language_notify(move |b| {
            if let Some(this) = weak.upgrade() {
                this.buffers[1].set_language(b.language().as_ref());
            }
        });
        let weak = Rc::downgrade(&this);
        doc.buffer.connect_enable_undo_notify(move |b| {
            if let Some(this) = weak.upgrade() {
                this.buffers[1].set_enable_undo(b.enables_undo());
            }
        });
        this
    }
    fn history(&self, buffer: &sourceview5::Buffer, _index: usize, redo: bool) {
        if self.history.get() {
            return;
        }
        buffer.stop_signal_emission_by_name(if redo { "redo" } else { "undo" });
        if self
            .doc
            .upgrade()
            .is_none_or(|doc| doc.close_pending.get() || doc.source_edits_locked())
            || self.views[self.active.get()]
                .upgrade()
                .is_none_or(|view| !view.is_editable() || !view.is_sensitive())
        {
            return;
        }
        let index = self.active.get();
        let other = &self.buffers[1 - index];
        let a = other.create_mark(None, &other.iter_at_mark(&other.get_insert()), false);
        let b = other.create_mark(None, &other.iter_at_mark(&other.selection_bound()), true);
        self.history.set(true);
        self.busy.set(true);
        for b in &self.buffers {
            if redo {
                b.redo();
            } else {
                b.undo();
            }
        }
        other.select_range(&other.iter_at_mark(&a), &other.iter_at_mark(&b));
        other.delete_mark(&a);
        other.delete_mark(&b);
        self.busy.set(false);
        self.history.set(false);
        self.buffers[1].set_modified(self.buffers[0].is_modified());
        assert_eq!(
            buffer_text(&self.buffers[0]),
            buffer_text(&self.buffers[1]),
            "SPLIT NOGO native history diverged"
        );
    }
    pub(super) fn owns(&self, view: &sourceview5::View) -> bool {
        self.views.iter().enumerate().any(|(i, v)| {
            v.upgrade().as_ref() == Some(view)
                && view.buffer() == self.buffers[i].clone().upcast::<gtk::TextBuffer>()
        })
    }
}

#[cfg(debug_assertions)]
mod gate;
#[cfg(debug_assertions)]
mod input_gate;
#[cfg(debug_assertions)]
mod paste_gate;
#[cfg(debug_assertions)]
mod resource_gate;
#[cfg(debug_assertions)]
mod target_gate;
#[cfg(debug_assertions)]
pub(super) fn run(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_AUTOINDENT_GATE_CASE").is_some(){autoindent_gate::run(ui);return;}
    if std::env::var_os("FASTRA_DELETE_GATE_CASE").is_some(){delete_gate::run(ui);return;}
    if std::env::var_os("FASTRA_COMMIT_GATE_CASE").is_some(){commit_gate::run(ui);return;}

    if std::env::var_os("FASTRA_SUBCLASS_COUNT_GATE").is_some(){byte_buffer::count_gate(ui);return;}

    if std::env::var_os("FASTRA_SPLIT_INPUT_CASE").is_some() {
        input_gate::run(ui);
        return;
    }
    if std::env::var_os("FASTRA_SPLIT_RESOURCE_GATE").is_some() {
        resource_gate::run(ui);
    } else if std::env::var_os("FASTRA_SPLIT_TARGET_CASE").is_some() {
        target_gate::run(ui);
    } else if std::env::var_os("FASTRA_SPLIT_PASTE_CASE").is_some() {
        paste_gate::run(ui);
    } else {
        gate::run(ui);
    }
}

pub(super) fn reset(doc: &Document, begin: bool) {
    if let Some(panes) = doc.source_panes.borrow().as_ref() {
        if begin {
            panes.buffers[1].begin_irreversible_action();
        } else {
            panes.buffers[1].end_irreversible_action();
        }
    }
}

#[derive(Clone)]
pub(super) struct Target {
    ui: Weak<Ui>,
    pub(super) view: sourceview5::View,
    pub(super) buffer: sourceview5::Buffer,
    doc: Weak<Document>,
    index: usize,
    epoch: u64,
    selection: u64,
    window_epoch: u64,
    revision: u64,
}
impl Target {
    pub(super) fn valid(&self, doc: &Document) -> bool {
        self.valid_document(doc)
            && doc
                .source_panes
                .borrow()
                .as_ref()
                .is_some_and(|p| p.selections[self.index].get() == self.selection)
    }
    pub(super) fn valid_document(&self, doc: &Document) -> bool {
        self.valid_window(doc) && self.view.is_editable() && self.same_pane(doc)
    }
    pub(super) fn valid_document_for_reading(&self, doc: &Document) -> bool {
        self.valid_window(doc) && self.same_source_pane(doc)
    }
    pub(super) fn valid_for_reading(&self, doc: &Document) -> bool {
        self.valid_document_for_reading(doc)
            && doc.source_panes.borrow().as_ref()
                .is_some_and(|panes| panes.selections[self.index].get() == self.selection)
    }
    fn valid_window(&self, doc: &Document) -> bool {
        self.ui.upgrade().is_some_and(|ui| {
            owner_window(&ui)
                && !ui.window_close_dialog.get()
                && !ui.close_committed.get()
                && !close_protocol::active(&ui)
                && ui
                    .active()
                    .is_some_and(|owner| std::ptr::eq(owner.as_ref(), doc))
        }) && doc
            .source_panes
            .borrow()
            .as_ref()
            .is_some_and(|p| p.window_epoch.get() == self.window_epoch)
            && self.view.is_sensitive()
    }
    pub(super) fn same_pane(&self, doc: &Document) -> bool {
        self.same_source_pane(doc) && !doc.source_edits_locked()
    }
    pub(super) fn same_pane_for_reading(&self, doc: &Document) -> bool {
        self.same_source_pane(doc)
    }
    fn same_source_pane(&self, doc: &Document) -> bool {
        self.doc
            .upgrade()
            .is_some_and(|owner| std::ptr::eq(owner.as_ref(), doc))
            && !doc.close_pending.get()
            && doc.has_source_text()
            && !doc.is_rich_active()
            && doc.revision.get() == self.revision
            && self.view.is_mapped()
            && self.view.buffer() == self.buffer.clone().upcast::<gtk::TextBuffer>()
            && doc.source_panes.borrow().as_ref().is_some_and(|p| {
                p.active.get() == self.index && p.epoch.get() == self.epoch && p.owns(&self.view)
            })
    }
    pub(super) fn offsets(&self) -> (i32, i32) {
        self.buffer
            .selection_bounds()
            .map(|(a, b)| (a.offset(), b.offset()))
            .unwrap_or_else(|| {
                let at = self.buffer.cursor_position();
                (at, at)
            })
    }
}
pub(super) fn capture(doc: &Document) -> Option<Target> {
    let held = doc.source_panes.borrow();
    let p = held.as_ref()?;
    let index = p.active.get();
    let view = p.views[index].upgrade().filter(|v| v.is_mapped())?;
    Some(Target {
        ui: p.ui.clone(),
        view,
        buffer: p.buffers[index].clone(),
        doc: p.doc.clone(),
        index,
        epoch: p.epoch.get(),
        selection: p.selections[index].get(),
        window_epoch: p.window_epoch.get(),
        revision: doc.revision.get(),
    })
}
pub(super) fn buffer(doc: &Document) -> sourceview5::Buffer {
    doc.source_panes
        .borrow()
        .as_ref()
        .map(|p| p.buffers[p.active.get()].clone())
        .unwrap_or_else(|| doc.buffer.clone())
}
pub(super) fn search_caret(doc: &Document, offset: Option<i32>) {
    if let Some(panes) = doc.source_panes.borrow().as_ref() {
        for view in panes.views.iter().filter_map(glib::WeakRef::upgrade) {
            if let Some(view) = view.downcast_ref::<self::view::View>() { view.set_search_caret(offset); }
        }
    }
}
pub(super) fn split(doc: &Document, enabled: bool) {
    if let Some(p) = doc.source_panes.borrow().as_ref() {
        p.epoch.set(p.epoch.get().wrapping_add(1));
        if !enabled {
            p.active.set(0);
        }
    }
}
pub(super) fn stamp(doc: &Document) -> Option<(usize, u64, u64, u64)> {
    let held = doc.source_panes.borrow();
    let p = held.as_ref()?;
    let i = p.active.get();
    Some((
        p.buffers[i].as_ptr() as usize,
        p.epoch.get(),
        p.selections[i].get(),
        p.window_epoch.get(),
    ))
}
// Nur der tatsächlich veränderte Bereich bewegt die nativen Marks der anderen Pane.
pub(super) fn replace_result(buffer: &sourceview5::Buffer, result: &str) {
    let source = buffer_text(buffer);
    if source == result {
        return;
    }
    let prefix = source
        .chars()
        .zip(result.chars())
        .take_while(|(a, b)| a == b)
        .map(|(a, _)| a.len_utf8())
        .sum::<usize>();
    let suffix = source[prefix..]
        .chars()
        .rev()
        .zip(result[prefix..].chars().rev())
        .take_while(|(a, b)| a == b)
        .map(|(a, _)| a.len_utf8())
        .sum::<usize>();
    let start = source[..prefix].chars().count() as i32;
    let end = source[..source.len() - suffix].chars().count() as i32;
    buffer.begin_user_action();
    let mut a = buffer.iter_at_offset(start);
    let mut b = buffer.iter_at_offset(end);
    if start != end {
        buffer.delete(&mut a, &mut b);
    }
    if prefix < result.len() - suffix {
        buffer.insert(&mut a, &result[prefix..result.len() - suffix]);
    }
    buffer.end_user_action();
}

#[cfg(debug_assertions)]
pub(super) fn delay_reply() {
    if std::env::var_os("FASTRA_SPLIT_REPLY_DELAY").is_some() {
        assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
        std::thread::sleep(Duration::from_millis(500));
    }
}

// Kanonische interne Rich-/Save-Rezepte bleiben erlaubt. Die zweite Quelle darf
// außerhalb eines gerade gespiegelten Deltas ausschließlich ihren lebenden Owner ändern.
pub(super) fn guard(ui: &Rc<Ui>, doc: &Rc<Document>, view: &sourceview5::View) {
    let allowed: Rc<dyn Fn() -> bool> = {
        let ui = Rc::downgrade(ui);
        let doc = Rc::downgrade(doc);
        let view = view.downgrade();
        Rc::new(move || {
            let (Some(ui), Some(doc), Some(view)) = (ui.upgrade(), doc.upgrade(), view.upgrade())
            else {
                return false;
            };
            if doc
                .source_panes
                .borrow()
                .as_ref()
                .is_some_and(|p| p.busy.get())
            {
                return true;
            }
            !doc.source_edits_locked()
                && !doc.close_pending.get()
                && !ui.window_close_dialog.get()
                && !ui.close_committed.get()
                && !close_protocol::active(&ui)
                && view.is_mapped()
                && view.is_editable()
                && view.is_sensitive()
                && ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
        })
    };
    let test = allowed.clone();
    view.buffer().connect_insert_text(move |b, _, _| {
        if !test() {
            b.stop_signal_emission_by_name("insert-text");
        }
    });
    view.buffer().connect_delete_range(move |b, _, _| {
        if !allowed() {
            b.stop_signal_emission_by_name("delete-range");
        }
    });
}

fn owner_window(ui: &Ui) -> bool {
    if !ui.window.is_visible() {
        return false;
    }
    let Some(mut window) = focused_window(ui) else {
        return false;
    };
    for _ in 0..16 {
        if window == ui.window.clone().upcast::<gtk::Window>() {
            return true;
        }
        let Some(parent) = window.transient_for() else {
            return false;
        };
        window = parent;
    }
    false
}

fn focused_window(ui: &Ui) -> Option<gtk::Window> {
    // GtkApplication merkt das zuletzt fokussierte Fenster. Beim Wechsel in
    // ein eigenes Suchfenster kann dieser Wert noch auf dem inaktiven Editor
    // stehen; maßgeblich ist der tatsächliche Fokus genau eines App-Fensters.
    let app = ui.window.application()?;
    let windows = app.windows();
    // Freigabedialoge gehören zum Suchfenster, werden aber nicht zusätzlich
    // bei GtkApplication angemeldet: Ihr Abmelden würde kurzzeitig die
    // aktive Fenstergruppe verlieren und eine unveränderte Vorschau entwerten.
    let reviews = gtk::Window::list_toplevels().into_iter().filter_map(|widget| widget.downcast::<gtk::Window>().ok()).filter(|window| {
        if !window.has_css_class("fastra-owned-review") { return false; }
        let mut parent = window.transient_for();
        for _ in 0..16 { let Some(current) = parent else { return false; }; if current == ui.window.clone().upcast::<gtk::Window>() { return true; } parent = current.transient_for(); }
        false
    });
    let active: Vec<_> = windows.into_iter().chain(reviews).filter(|window| window.is_visible() && window.is_active()).collect();
    // GTK kann den aktiven Besitzer auch während eines eigenen modalen
    // Dialogs aktiv melden. Nur dessen tiefstes aktives Kind ist das Ziel;
    // zwei voneinander unabhängige aktive Fenster bleiben mehrdeutig.
    let mut targets = active.iter().filter(|window| !active.iter().any(|other| {
        if other == *window { return false; }
        let mut parent = other.transient_for();
        for _ in 0..16 { let Some(current) = parent else { return false; }; if current == **window { return true; } parent = current.transient_for(); }
        false
    }));
    let window = targets.next()?.clone();
    targets.next().is_none().then_some(window)
}
pub(super) fn focused_is(ui: &Ui, window: &gtk::Window) -> bool {
    focused_window(ui).as_ref() == Some(window)
}

impl Drop for Panes {
    fn drop(&mut self) {
        if let Some((app, id)) = self.app_handler.get_mut().take() {
            if let Some(app) = app.upgrade() {
                app.disconnect(id);
            }
        }
        if let Some((window, id)) = self.window_handler.get_mut().take() {
            if let Some(window) = window.upgrade() {
                window.disconnect(id);
            }
        }
    }
}

fn window_group(ui: &Ui) -> bool {
    let Some(mut window) = ui.window.application().and_then(|app| app.active_window()) else {
        return false;
    };
    for _ in 0..16 {
        if window == ui.window.clone().upcast::<gtk::Window>() {
            return true;
        }
        let Some(parent) = window.transient_for() else {
            return false;
        };
        window = parent;
    }
    false
}
#[cfg(debug_assertions)]
impl Target {
    pub(super) fn trace(&self, doc: &Document) -> String {
        let p = doc.source_panes.borrow();
        format!(
            "mapped={} editable={} sensitive={} owner={} pane={:?} revision={}/{}",
            self.view.is_mapped(),
            self.view.is_editable(),
            self.view.is_sensitive(),
            self.ui.upgrade().is_some_and(|u| owner_window(&u)),
            p.as_ref().map(|p| (
                p.active.get(),
                p.epoch.get(),
                p.selections[self.index].get(),
                p.window_epoch.get(),
                self.index,
                self.epoch,
                self.selection,
                self.window_epoch
            )),
            doc.revision.get(),
            self.revision
        )
    }
}

pub(super) fn source_view(buffer: &sourceview5::Buffer) -> sourceview5::View {
    view::View::new(buffer).upcast()
}
#[cfg(debug_assertions)]
pub(super) fn bind_view(view: &sourceview5::View, buffer: &impl IsA<gtk::TextBuffer>) {
    if let Some(own) = view.downcast_ref::<self::view::View>() {
        own.bind(buffer);
    } else {
        view.set_buffer(Some(buffer));
    }
}

pub(super) fn new_buffer(table:Option<&gtk::TextTagTable>)->sourceview5::Buffer {
    if native_input_enabled() && commit_query::available(){byte_buffer::Buffer::new(table).upcast()}else{sourceview5::Buffer::new(table)}
}

pub(super) fn bind_folding(view: &sourceview5::View, folds: &Rc<folding::Folds>, index: usize) {
    if let Some(own) = view.downcast_ref::<self::view::View>() { own.bind_folding(folds, index); }
}
