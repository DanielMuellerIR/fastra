//! Gemeinsame Tabentscheidung: erst alle Antworten sammeln, dann synchron entfernen.
use super::{
    close_protocol::{self, Abort, Permit, TabSelection, Ticket},
    tab_close, Document, Ui,
};
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

struct Attempt {
    ui: Rc<Ui>,
    keep: Rc<Document>,
    members: Vec<Rc<Document>>,
    previous: Option<Rc<Document>>,
    live: Cell<bool>,
    drift: Cell<bool>,
    activating: Cell<bool>,
    committing: Cell<bool>,
    ticket: RefCell<Option<Rc<Ticket>>>,
    handlers: RefCell<Vec<(glib::Object, glib::SignalHandlerId)>>,
}
impl Drop for Attempt {
    fn drop(&mut self) {
        for (object, handler) in self.handlers.get_mut().drain(..) {
            object.disconnect(handler);
        }
        if self.live.get() {
            if let Some(ticket) = self.ticket.get_mut().take() {
                ticket.cancel();
            }
        }
    }
}
impl Attempt {
    fn current(&self) -> bool {
        if !self.live.get() || self.drift.get() || !self.ui.window.is_visible() {
            return false;
        }
        let docs = self.ui.documents.borrow();
        docs.len() == self.members.len()
            && self.ui.tabs.n_pages() as usize == docs.len()
            && docs
                .iter()
                .zip(&self.members)
                .enumerate()
                .all(|(index, (now, prior))| {
                    Rc::ptr_eq(now, prior)
                        && self.ui.tabs.nth_page(Some(index as u32)).as_ref()
                            == Some(now.container.upcast_ref())
                })
            && docs.iter().any(|doc| Rc::ptr_eq(doc, &self.keep))
    }
    fn activate(&self, doc: &Rc<Document>) {
        self.activating.set(true);
        tab_close::activate(&self.ui, doc);
        self.activating.set(false);
    }
    fn changed(self: &Rc<Self>) {
        if self.activating.get() || self.committing.get() || !self.live.get() {
            return;
        }
        self.drift.set(true);
        let weak = Rc::downgrade(self);
        // Notebooksignale laufen vor dessen Standardhandler; erst danach die alte Aktivierung herstellen.
        glib::idle_add_local_once(move || {
            if let Some(this) = weak.upgrade() {
                this.abort(Abort::Stale);
            }
        });
    }
    fn abort(&self, reason: Abort) {
        if !self.live.replace(false) {
            return;
        }
        if let Some(ticket) = self.ticket.borrow().as_ref() {
            ticket.cancel();
        }
        if self.ui.window.is_visible() {
            if let Some(previous) = &self.previous {
                self.activate(previous);
                if matches!(reason, Abort::Cancelled | Abort::Stale) {
                    tab_close::focus(&self.ui, previous);
                }
            }
            match reason {
                Abort::Cancelled=>self.ui.status.set_text(self.ui.lang.text("Andere Tabs bleiben geöffnet; Schließen abgebrochen.","Other tabs remain open; Close cancelled.")),
                Abort::Stale=>self.ui.status.set_text(self.ui.lang.text("Tabs oder Dokumentzustand inzwischen geändert. Kein Tab geschlossen; erneut prüfen.","Tabs or document state changed. No tab closed; review again.")),
                Abort::Blocked|Abort::Failed=>{}
            }
        }
    }
    fn ready(self: &Rc<Self>, result: Result<Permit, Abort>) {
        let permit = match result {
            Ok(permit) => Rc::new(permit),
            Err(reason) => {
                self.abort(reason);
                return;
            }
        };
        let this = self.clone();
        // Den letzten Dialog erst vollständig abbauen lassen; anschließend erneut alle Bindungen prüfen.
        glib::idle_add_local_once(move || {
            if !this.current() || !permit.documents_valid() {
                permit.cancel();
                this.abort(Abort::Stale);
                return;
            }
            if !permit.valid() {
                permit.cancel();
                this.abort(Abort::Blocked);
                return;
            }
            permit.freeze();
            if !this.current() || !permit.documents_valid() {
                permit.cancel();
                this.abort(Abort::Stale);
                return;
            }
            if !permit.valid() {
                permit.cancel();
                this.abort(Abort::Blocked);
                return;
            }
            let candidates = this
                .members
                .iter()
                .filter(|doc| !Rc::ptr_eq(doc, &this.keep))
                .cloned()
                .collect::<Vec<_>>();
            this.committing.set(true);
            tab_close::remove_approved_others(&this.ui, &this.keep, &candidates);
            this.live.set(false);
            permit.cancel();
            this.ui.status.set_text(this.ui.lang.text(
                "Andere Tabs geschlossen. Der gewählte Tab bleibt geöffnet.",
                "Other tabs closed. The selected tab remains open.",
            ));
        });
    }
}
pub(super) fn request(ui: &Rc<Ui>, keep: &Rc<Document>) {
    let members = ui.documents.borrow().clone();
    if members.len() <= 1 || !members.iter().any(|doc| Rc::ptr_eq(doc, keep)) {
        return;
    }
    let attempt = Rc::new(Attempt {
        ui: ui.clone(),
        keep: keep.clone(),
        members,
        previous: ui.active(),
        live: Cell::new(true),
        drift: Cell::new(false),
        activating: Cell::new(false),
        committing: Cell::new(false),
        ticket: RefCell::new(None),
        handlers: RefCell::new(Vec::new()),
    });
    let weak = Rc::downgrade(&attempt);
    let handler = ui.tabs.connect_switch_page(move |_, _, _| {
        if let Some(this) = weak.upgrade() {
            this.changed();
        }
    });
    attempt
        .handlers
        .borrow_mut()
        .push((ui.tabs.clone().upcast(), handler));
    let weak = Rc::downgrade(&attempt);
    let handler = ui.tabs.connect_page_added(move |_, _, _| {
        if let Some(this) = weak.upgrade() {
            this.changed();
        }
    });
    attempt
        .handlers
        .borrow_mut()
        .push((ui.tabs.clone().upcast(), handler));
    let weak = Rc::downgrade(&attempt);
    let handler = ui.tabs.connect_page_removed(move |_, _, _| {
        if let Some(this) = weak.upgrade() {
            this.changed();
        }
    });
    attempt
        .handlers
        .borrow_mut()
        .push((ui.tabs.clone().upcast(), handler));
    let weak = Rc::downgrade(&attempt);
    let handler = ui.tabs.connect_page_reordered(move |_, _, _| {
        if let Some(this) = weak.upgrade() {
            this.changed();
        }
    });
    attempt
        .handlers
        .borrow_mut()
        .push((ui.tabs.clone().upcast(), handler));
    let valid = Rc::downgrade(&attempt);
    let activate = Rc::downgrade(&attempt);
    let selection = TabSelection {
        keep: Some(keep.clone()),
        valid: Rc::new(move || valid.upgrade().is_some_and(|this| this.current())),
        activate: Rc::new(move |doc| {
            if let Some(this) = activate.upgrade() {
                this.activate(doc);
            }
        }),
    };
    let done = attempt.clone();
    let ticket =
        close_protocol::prepare_tabs(ui, selection, Box::new(move |result| done.ready(result)));
    *attempt.ticket.borrow_mut() = ticket;
}
pub(super) fn menu(ui: &Rc<Ui>, doc: &Rc<Document>, row: &gtk::Box) {
    let popover = gtk::Popover::new();
    popover.set_parent(row);
    popover.set_has_arrow(false);
    let column = gtk::Box::new(gtk::Orientation::Vertical, 0);
    column.add_css_class("command-menu");
    column.add_css_class("tab-context-menu");
    let compare = gtk::Button::with_label(ui.lang.text("Dateien vergleichen…", "Compare Files…"));
    compare.set_height_request(24);
    if let Some(label) = compare.child().and_downcast::<gtk::Label>() { label.set_xalign(0.); }
    compare.set_visible(false);
    column.append(&compare);
    let divider = gtk::Separator::new(gtk::Orientation::Horizontal);
    divider.set_margin_top(4);
    divider.set_margin_bottom(4);
    divider.set_visible(false);
    column.append(&divider);
    let close = gtk::Button::with_label(ui.lang.text("Diesen Tab schließen", "Close this tab"));
    let others = gtk::Button::with_label(ui.lang.text("Andere Tabs schließen", "Close other tabs"));
    let reveal = gtk::Button::with_label(
        ui.lang
            .text("Im Dateimanager zeigen", "Show in file manager"),
    );
    reveal.set_tooltip_text(Some(ui.lang.text(
        "Die gespeicherte Datei in ihrem Ordner im Dateimanager markieren.",
        "Select the saved file in its folder in the file manager.",
    )));
    let reveal_request = Rc::new(super::file_manager::Request::default());
    for button in [&close, &others, &reveal] {
        button.set_height_request(24);
        if let Some(label) = button.child().and_downcast::<gtk::Label>() { label.set_xalign(0.); }
        column.append(button);
    }
    popover.set_child(Some(&column));
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    let weak_pop = popover.downgrade();
    compare.connect_clicked(move |_| {
        if let Some(pop) = weak_pop.upgrade() { pop.popdown(); }
        if let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) { super::tab_comparison::open_context(&ui, &doc); }
    });
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    let weak_pop = popover.downgrade();
    close.connect_clicked(move |_| {
        if let Some(pop) = weak_pop.upgrade() {
            pop.popdown();
        }
        if let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) {
            tab_close::request(&ui, &doc);
        }
    });
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    let weak_pop = popover.downgrade();
    others.connect_clicked(move |_| {
        if let Some(pop) = weak_pop.upgrade() {
            pop.popdown();
        }
        if let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) {
            request(&ui, &doc);
        }
    });
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    let weak_pop = popover.downgrade();
    let weak_button = reveal.downgrade();
    let request = reveal_request.clone();
    reveal.connect_clicked(move |_| {
        if let Some(pop) = weak_pop.upgrade() {
            pop.popdown();
        }
        let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) else {
            return;
        };
        if !ui.window.is_visible()
            || request.pending()
            || !ui
                .documents
                .borrow()
                .iter()
                .any(|now| Rc::ptr_eq(now, &doc))
        {
            return;
        }
        let Some(path) = doc.disk_path() else { return };
        if let Some(button) = weak_button.upgrade() {
            button.set_sensitive(false);
        }
        let active = ui.active().map(|doc| Rc::downgrade(&doc));
        let weak_ui = Rc::downgrade(&ui);
        let weak_doc = Rc::downgrade(&doc);
        let weak_button = weak_button.clone();
        request.show(&ui.window, &path.clone(), move |result| {
            let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) else {
                return;
            };
            let present = ui
                .documents
                .borrow()
                .iter()
                .any(|now| Rc::ptr_eq(now, &doc));
            if let Some(button) = weak_button.upgrade() {
                button.set_sensitive(present && doc.disk_path().is_some());
            }
            if !present
                || !ui.window.is_visible()
                || doc.disk_path().as_ref() != Some(&path)
                || !match (&active, ui.active()) {
                    (Some(previous), Some(current)) => previous
                        .upgrade()
                        .is_some_and(|previous| Rc::ptr_eq(&previous, &current)),
                    (None, None) => true,
                    _ => false,
                }
            {
                return;
            }
            if let Err(error) = result {
                ui.status.set_text(&format!(
                    "{}: {}",
                    ui.lang.text(
                        "Dateimanager konnte die Datei nicht zeigen",
                        "The file manager could not show the file"
                    ),
                    error.message(ui.lang)
                ));
            }
        });
    });
    let gesture = gtk::GestureClick::new();
    gesture.set_button(3);
    gesture.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    gesture.connect_pressed(move |gesture, _, x, y| {
        let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) else {
            return;
        };
        let current = ui
            .documents
            .borrow()
            .iter()
            .any(|now| Rc::ptr_eq(now, &doc));
        let idle = !close_protocol::active(&ui)
            && !ui.window_close_dialog.get()
            && !ui
                .documents
                .borrow()
                .iter()
                .any(|doc| doc.close_pending.get() || doc.saving.get());
        let pair = current && idle && super::tab_comparison::can_context(&ui, &doc);
        compare.set_visible(pair);
        divider.set_visible(pair);
        reveal.set_sensitive(current && doc.disk_path().is_some() && !reveal_request.pending());
        close.set_sensitive(current && idle);
        others.set_sensitive(current && idle && ui.documents.borrow().len() > 1);
        popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        popover.popup();
        gesture.set_state(gtk::EventSequenceState::Claimed);
    });
    row.add_controller(gesture);
}
#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    gui_test::run(ui);
}
