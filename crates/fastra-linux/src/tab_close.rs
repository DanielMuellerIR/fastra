use super::{hex_editor, session, Document, Ui};
use gtk::{gio, prelude::*};
#[cfg(debug_assertions)]
use gtk::glib;
use std::rc::Rc;

mod file_drag;

fn position(ui: &Ui, doc: &Rc<Document>) -> Option<usize> {
    ui.documents
        .borrow()
        .iter()
        .position(|d| Rc::ptr_eq(d, doc))
}
fn current(ui: &Ui, doc: &Rc<Document>) -> bool {
    ui.window.is_visible() && position(ui, doc).is_some()
}
fn release(doc: &Document) {
    doc.close_pending.set(false);
    if let Some(editor) = doc.rich.borrow().as_ref() {
        editor.release();
    }
}
pub(super) fn remember_active(ui: &Ui) {
    let Some(doc) = ui.active() else { return };
    let mut history = ui.tab_mru.borrow_mut();
    history.retain(|item| item.upgrade().is_some_and(|d| !Rc::ptr_eq(&d, &doc)));
    history.push(Rc::downgrade(&doc));
}
pub(super) fn header(ui: &Rc<Ui>, doc: &Rc<Document>) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let label = gtk::Label::new(None);
    doc.label.bind_property("label", &label, "label").sync_create().build();
    label.set_max_width_chars(32);
    row.set_valign(gtk::Align::Center);
    label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    file_drag::install(ui, doc, &row);
    if doc.read_source.borrow().is_some() {
        let lock = gtk::Image::from_icon_name("changes-prevent-symbolic");
        lock.set_pixel_size(12);
        lock.set_tooltip_text(Some(ui.lang.text("Schreibgeschützter Text", "Read-only text")));
        row.append(&lock);
    }
    let select = gtk::Button::builder().child(&label).has_frame(false).build();
    select.add_css_class("tab-select");
    super::tab_comparison::install_selection(ui, doc, &select, &row);
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    select.connect_clicked(move |_| {
        if let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) { super::tab_comparison::activate(&ui, &doc); }
    });
    row.append(&select);
    let label = ui.lang.text("Tab schließen", "Close tab");
    let close = gtk::Button::builder()
        .icon_name("window-close-symbolic")
        .has_frame(false)
        .tooltip_text(label)
        .build();
    close.set_size_request(18, 22);
    close.set_valign(gtk::Align::Center);
    close.update_property(&[gtk::accessible::Property::Label(label)]);
    super::tab_close_others::menu(ui, doc, &row);
    row.append(&close);
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    close.connect_clicked(move |_| {
        if let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) {
            request(&ui, &doc);
        }
    });
    row
}
pub(super) fn active(ui: &Rc<Ui>) {
    if let Some(doc) = ui.active() {
        request(ui, &doc);
    }
}
pub(super) fn request(ui: &Rc<Ui>, doc: &Rc<Document>) {
    if !current(ui, doc) {
        return;
    }
    if super::close_protocol::active(ui) || ui.window_close_dialog.get() || ui.documents.borrow().iter().any(|d| d.close_pending.get()) {
        ui.status.set_text(ui.lang.text(
            "Die laufende Tab-Schließentscheidung zuerst abschließen.",
            "Finish the pending tab close decision first.",
        ));
        return;
    }
    if ui.documents.borrow().len() == 1 {
        ui.window.close();
        return;
    }
    if doc.saving.get() {
        ui.status.set_text(ui.lang.text(
            "Speichern zuerst abschließen lassen; der Tab bleibt offen.",
            "Wait for saving to finish; the tab stays open.",
        ));
        return;
    }
    if hex_editor::prevent_document_close(ui, doc) {
        return;
    }
    doc.close_pending.set(true);
    let editor = doc.rich.borrow().clone().filter(|e| e.active.get());
    if let Some(editor) = editor {
        let weak_ui = Rc::downgrade(ui);
        let doc = doc.clone();
        editor.synchronize(
            true,
            Box::new(move |ok| {
                if let Some(ui) = weak_ui.upgrade().filter(|ui| current(ui, &doc)) {
                    if ok {
                        confirm(&ui, &doc);
                    } else {
                        release(&doc);
                    }
                } else {
                    release(&doc);
                }
            }),
        );
    } else {
        confirm(ui, doc);
    }
}
fn confirm(ui: &Rc<Ui>, doc: &Rc<Document>) {
    if !current(ui, doc) || doc.saving.get() || hex_editor::prevent_document_close(ui, doc) {
        release(doc);
        return;
    }
    if !doc.buffer.is_modified() {
        finish(ui, doc);
        return;
    }
    let revision = doc.revision.get();
    let dialog = gtk::AlertDialog::builder()
        .message(ui.lang.text(
            "Änderungen in diesem Tab sichern?",
            "Save changes in this tab?",
        ))
        .detail(doc.label.text())
        .buttons([
            ui.lang.text("Abbrechen", "Cancel"),
            ui.lang
                .text("Ohne Speichern schließen", "Close without saving"),
            ui.lang.text("Speichern und schließen", "Save and close"),
        ])
        .cancel_button(0)
        .default_button(2)
        .build();
    let weak_ui = Rc::downgrade(ui);
    let doc = doc.clone();
    dialog.choose(Some(&ui.window), None::<&gio::Cancellable>, move |result| {
        let Some(ui) = weak_ui.upgrade().filter(|ui| current(ui, &doc)) else {
            release(&doc);
            return;
        };
        if doc.revision.get() != revision || doc.saving.get() {
            release(&doc);
            ui.status.set_text(ui.lang.text(
                "Tab inzwischen geändert. Schließen erneut wählen; nichts verworfen.",
                "The tab changed meanwhile. Request Close again; nothing discarded.",
            ));
            return;
        }
        match result {
            Ok(1) => finish(&ui, &doc),
            Ok(2) => save_and_close(&ui, &doc, false),
            _ => release(&doc),
        }
    });
}
fn finish(ui: &Rc<Ui>, doc: &Rc<Document>) {
    if !current(ui, doc) || doc.saving.get() || hex_editor::prevent_document_close(ui, doc) {
        release(doc);
        return;
    }
    let Some(index) = position(ui, doc) else {
        release(doc);
        return;
    };
    // Der letzte Tab bleibt bis zur gemeinsamen Fensterentscheidung vollständig erhalten.
    if ui.documents.borrow().len() <= 1 {
        release(doc);
        ui.status.set_text(ui.lang.text(
            "Fensterzustand geändert. Schließen erneut wählen.",
            "The window changed. Request Close again.",
        ));
        return;
    }
    let prior = ui.active().filter(|d| !Rc::ptr_eq(d, doc));
    let next = prior.or_else(|| {
        ui.tab_mru
            .borrow()
            .iter()
            .rev()
            .filter_map(std::rc::Weak::upgrade)
            .find(|d| !Rc::ptr_eq(d, doc) && position(ui, d).is_some())
    });
    ui.invalidate();
    hex_editor::close_document(doc);
    if let Some(editor) = doc.rich.borrow().as_ref() {
        editor.active.set(false);
    }
    release(doc);
    ui.documents.borrow_mut().remove(index);
    ui.tabs.remove_page(Some(index as u32));
    ui.tab_mru
        .borrow_mut()
        .retain(|d| d.upgrade().is_some_and(|d| !Rc::ptr_eq(&d, doc)));
    if let Some(next) = next {
        if let Some(index) = position(ui, &next) {
            ui.tabs.set_current_page(Some(index as u32));
        }
    }
    remember_active(ui);
    session::changed(ui);
    ui.refresh_save();
    if let Some(doc) = ui.active() {
        if let Some(editor) = doc.rich.borrow().as_ref().filter(|e| e.active.get()) {
            editor.view.grab_focus();
        } else {
            focus_source(doc.container.upcast_ref());
        }
    }
}
pub(super) fn remove_approved_others(
    ui: &Rc<Ui>,
    keep: &Rc<Document>,
    candidates: &[Rc<Document>],
) {
    // Keine Ereignisschleife zwischen gemeinsamer Freigabe und den einzelnen GTK-Entfernungen.
    ui.invalidate();
    for doc in candidates {
        let index = position(ui, doc).expect("bound tab during synchronous close");
        hex_editor::close_document(doc);
        if let Some(editor) = doc.rich.borrow().as_ref() {
            editor.active.set(false);
        }
        release(doc);
        ui.documents.borrow_mut().remove(index);
        ui.tabs.remove_page(Some(index as u32));
    }
    ui.tab_mru
        .borrow_mut()
        .retain(|item| item.upgrade().is_some_and(|doc| Rc::ptr_eq(&doc, keep)));
    if let Some(index) = position(ui, keep) {
        ui.tabs.set_current_page(Some(index as u32));
    }
    remember_active(ui);
    session::changed(ui);
    ui.refresh_save();
    focus(ui, keep);
}
pub(super) fn activate(ui: &Ui, doc: &Rc<Document>) {
    if let Some(index) = position(ui, doc) {
        ui.tabs.set_current_page(Some(index as u32));
    }
}
pub(super) fn focus(_ui: &Ui, doc: &Rc<Document>) {
    if let Some(editor) = doc
        .rich
        .borrow()
        .as_ref()
        .filter(|editor| editor.active.get())
    {
        editor.view.grab_focus();
    } else {
        focus_source(doc.container.upcast_ref());
    }
}
fn focus_source(widget: &gtk::Widget) -> bool {
    if let Some(view) = widget
        .downcast_ref::<sourceview5::View>()
        .filter(|view| view.is_mapped())
    {
        return view.grab_focus();
    }
    let mut child = widget.first_child();
    while let Some(item) = child {
        if focus_source(&item) {
            return true;
        }
        child = item.next_sibling();
    }
    false
}
fn save_and_close(ui: &Rc<Ui>, doc: &Rc<Document>, window: bool) {
    if !current(ui, doc) || doc.saving.get() || doc.is_read_only() {
        release(doc);
        return;
    }
    doc.close_pending.set(true);
    let save_before = doc.revision.get();
    let weak_ui = Rc::downgrade(ui);
    let doc = doc.clone();
    ui.save_document_ready_done(doc.clone(), Box::new(move |outcome| {
        let Some(ui) = weak_ui.upgrade().filter(|ui| current(ui, &doc)) else {
            release(&doc); return;
        };
        if !matches!(outcome, super::close_protocol::SaveOutcome::Saved { before, after }
            if before == save_before && after == doc.revision.get()) {
            release(&doc); super::rich_editor::release_all(&ui);return;
        }
        if window {
            release(&doc);
            if ui.documents.borrow().len() == 1 { ui.window.close(); }
        } else { finish(&ui, &doc); }
    }));
}


#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
mod drag_gui_test;
#[cfg(debug_assertions)]
mod view_drag_gui_test;
#[cfg(debug_assertions)]
pub(super) fn selftest(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_TAB_FILE_DRAG_VIEWS_SELFTEST").is_some() {
        view_drag_gui_test::run(ui);
    } else if std::env::var_os("FASTRA_TAB_FILE_DRAG_SELFTEST").is_some() {
        drag_gui_test::run(ui);
    } else if std::env::var_os("FASTRA_TAB_CLOSE_OTHERS_SELFTEST").is_some() {
        super::tab_close_others::selftest(ui);
    } else {
        gui_test::run(ui);
    }
}
