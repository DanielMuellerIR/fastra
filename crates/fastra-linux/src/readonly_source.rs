use crate::*;
use std::sync::Arc;
#[cfg(debug_assertions)]
mod selftest;
mod watch;
#[cfg(debug_assertions)]
pub(super) fn run_selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}

pub(super) fn add(
    ui: &Rc<Ui>,
    name: &str,
    source: Arc<fastra_document::ReadOnlyTextDocument>,
) -> Rc<Document> {
    insert(ui, name, source, true)
}

pub(super) fn append(
    ui: &Rc<Ui>,
    name: &str,
    source: Arc<fastra_document::ReadOnlyTextDocument>,
) -> Rc<Document> {
    insert(ui, name, source, false)
}

fn insert(
    ui: &Rc<Ui>,
    name: &str,
    source: Arc<fastra_document::ReadOnlyTextDocument>,
    replace_empty: bool,
) -> Rc<Document> {
    let pristine = ui
        .active()
        .filter(|doc| replace_empty && chrome::is_pristine(doc) && !doc.source_edits_locked());
    ui.add_document_with_source(name, source.text(), Some(source.clone()));
    let doc = ui.active().unwrap();
    if let Some(pristine) = pristine {
        let index = ui
            .documents
            .borrow()
            .iter()
            .position(|doc| Rc::ptr_eq(doc, &pristine));
        if let Some(index) = index {
            ui.documents.borrow_mut().remove(index);
            ui.tabs.remove_page(Some(index as u32));
        }
    }
    doc.format_label.set_text(&document_view::format_text(
        &doc.format.borrow(),
        &buffer_text(&doc.buffer),
        ui.lang,
    ));
    editor_options::restore(ui, &doc);
    if let Some(toggle) = doc.rich_toggle.borrow().as_ref() {
        toggle.set_sensitive(false);
    }
    doc.reopen.set_sensitive(true);
    let notice = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    notice.set_margin_start(8);
    notice.set_margin_end(8);
    notice.append(&gtk::Image::from_icon_name("changes-prevent-symbolic"));
    let label = gtk::Label::new(Some(
        ui.lang.text("Schreibgeschützter Text", "Read-only text"),
    ));
    label.set_xalign(0.);
    label.set_hexpand(true);
    label.set_wrap(true);
    label.set_widget_name("fastra-readonly-source-status");
    label.set_tooltip_text(Some(ui.lang.text(
        "Fastra kann diese Datei nicht sicher überschreiben. Zum Bearbeiten eine Kopie anlegen.",
        "Fastra cannot safely overwrite this file. Create a copy to edit it.",
    )));
    notice.append(&label);
    let reopen = gtk::Button::from_icon_name("view-refresh-symbolic");
    reopen.set_widget_name("fastra-readonly-source-reopen");
    reopen.set_tooltip_text(Some(ui.lang.text("Datei neu öffnen", "Reopen file")));
    reopen.set_visible(false);
    notice.append(&reopen);
    let owner = Rc::downgrade(ui);
    let document = Rc::downgrade(&doc);
    reopen.connect_clicked(move |_| {
        if let (Some(ui), Some(doc)) = (owner.upgrade(), document.upgrade()) {
            if let Some(path) = doc.disk_path() {
                ui.load_path(path);
            }
        }
    });
    let copy = gtk::Button::with_label(ui.lang.text("Als Kopie bearbeiten", "Edit a copy"));
    copy.set_widget_name("fastra-readonly-edit-copy");
    copy.set_tooltip_text(Some(ui.lang.text("Übernimmt den Text und die Kodierung in eine neue Datei. Relative Verweise bleiben unverändert; den Zielordner beim Speichern beachten.", "Copies text and encoding into a new document. Relative references stay unchanged; choose the save folder accordingly.")));
    notice.append(&copy);
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(&doc);
    copy.connect_clicked(move |_| {
        let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) else {
            return;
        };
        if !ui
            .documents
            .borrow()
            .iter()
            .any(|open| Rc::ptr_eq(open, &doc))
            || doc.close_pending.get()
        {
            return;
        }
        let text = buffer_text(&doc.buffer);
        ui.add_document(ui.lang.text("Unbenannt", "Untitled"), &text);
        let copy = ui.active().unwrap();
        *copy.format.borrow_mut() = doc.format.borrow().clone();
        copy.format_label.set_text(&document_view::format_text(
            &copy.format.borrow(),
            &text,
            ui.lang,
        ));
        copy.original.borrow_mut().clear();
        copy.buffer.set_language(doc.buffer.language().as_ref());
        copy.buffer.set_modified(true);
        copy.update_label();
        ui.refresh_save();
    });
    doc.container.prepend(&notice);
    watch::attach(ui, &doc, &label, &reopen);
    doc.update_label();
    ui.refresh_save();
    chrome::refresh(ui);
    if let Some(path) = doc.disk_path() {
        diff_view::remember_opened(ui, path);
    }
    doc
}
