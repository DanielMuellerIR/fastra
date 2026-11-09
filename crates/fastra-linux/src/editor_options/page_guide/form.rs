use super::super::settings_form;
use super::*;
use crate::Language;

struct Form {
    visible: glib::WeakRef<gtk::Switch>,
    column: glib::WeakRef<gtk::SpinButton>,
    label: glib::WeakRef<gtk::Label>,
    status: glib::WeakRef<gtk::Label>,
    retry: glib::WeakRef<gtk::Button>,
    updating: Rc<Cell<bool>>,
    lang: Language,
}
thread_local! { static FORMS:RefCell<Vec<Form>>=const{RefCell::new(Vec::new())}; }
fn change(patch: Patch, updating: &Cell<bool>) {
    if updating.get() || !patch.valid() || !LOADED.with(Cell::get) {
        return;
    }
    let mut value = CURRENT.with(Cell::get);
    value.merge(&patch);
    publish(value);
    profile::queue_guide(None, patch);
}
pub(crate) fn controls(lang: Language, root: &gtk::Box) {
    load();
    let group = settings_form::section(root, lang.text("Editor", "Editor"));
    let row = settings_form::row(&group);
    settings_form::label(&row, lang.text("Seitenlinie anzeigen", "Show page guide"));
    let visible = gtk::Switch::new();
    visible.set_widget_name("fastra-global-guide-visible");
    visible.set_valign(gtk::Align::Center);
    visible.update_property(&[gtk::accessible::Property::Label(
        lang.text("Seitenlinie anzeigen", "Show page guide"),
    )]);
    row.append(&visible);
    let row = settings_form::row(&group);
    let label = settings_form::label(&row, "");
    let column = settings_form::stepper(20., 500.);
    column.set_widget_name("fastra-global-guide-column");
    column.update_property(&[gtk::accessible::Property::Label(
        lang.text("Seitenlinie: Spalte", "Page guide column"),
    )]);
    row.append(&column);
    settings_form::note(&group, lang.text("Die Seitenlinie ist eine appweite Orientierung. Soft Wrap kann pro Format unabhängig an Fensterbreite, Seitenlinie oder einer festen Spalte umbrechen.", "The page guide applies throughout the app. Each format can wrap independently at the window edge, page guide or a fixed column."));
    let status = crate::git_view::label("");
    status.add_css_class("settings-feedback");
    status.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    status.set_lines(4);
    group.append(&status);
    let retry = gtk::Button::with_label(lang.text("Erneut versuchen", "Retry"));
    retry.set_halign(gtk::Align::End);
    retry.add_css_class("settings-feedback");
    retry.set_widget_name("fastra-global-guide-retry");
    group.append(&retry);
    let updating = Rc::new(Cell::new(false));
    FORMS.with(|forms| {
        forms.borrow_mut().push(Form {
            visible: visible.downgrade(),
            column: column.downgrade(),
            label: label.downgrade(),
            status: status.downgrade(),
            retry: retry.downgrade(),
            updating: updating.clone(),
            lang,
        })
    });
    let guard = updating.clone();
    visible.connect_active_notify(move |button| {
        change(
            Patch {
                visible: Some(button.is_active()),
                ..Patch::default()
            },
            &guard,
        )
    });
    column.connect_value_changed(move |spin| {
        change(
            Patch {
                column: Some(spin.value_as_int() as u32),
                ..Patch::default()
            },
            &updating,
        )
    });
    retry.connect_clicked(|_| {
        if LOADED.with(Cell::get) {
            profile::retry();
        } else {
            load();
        }
        refresh();
    });
    refresh();
}
pub(crate) fn commit() {
    let spins = FORMS.with(|forms| {
        forms
            .borrow()
            .iter()
            .filter_map(|form| form.column.upgrade())
            .collect::<Vec<_>>()
    });
    for spin in spins {
        spin.update();
    }
}
pub(crate) fn refresh() {
    let ready = LOADED.with(Cell::get);
    let loading = LOADING.with(Cell::get);
    let value = CURRENT.with(Cell::get);
    let (writing, pending, write_error) = profile::guide_status();
    let error = LOAD_ERROR
        .with(|error| error.borrow().clone())
        .or(write_error);
    FORMS.with(|forms| forms.borrow_mut().retain(|form| {
        let (Some(visible),Some(column),Some(label),Some(status),Some(retry))=(form.visible.upgrade(),form.column.upgrade(),form.label.upgrade(),form.status.upgrade(),form.retry.upgrade()) else {return false};
        form.updating.set(true);
        visible.set_active(value.visible.unwrap_or(false));column.set_value(f64::from(value.column.unwrap_or(80)));
        visible.set_sensitive(ready);column.set_sensitive(ready);
        label.set_text(&format!("{} {}",form.lang.text("Seitenlinie: Spalte", "Page guide column"),value.column.unwrap_or(80)));
        status.set_text(if loading {form.lang.text("Seitenlinie wird geladen …","Loading page guide …")}
            else if writing {form.lang.text("Editorprofile werden gespeichert …","Saving editor profiles …")}
            else if error.is_some(){form.lang.text("Editorprofile konnten nicht geladen oder gespeichert werden. Die vorhandene Datei bleibt erhalten.","Editor profiles could not be loaded or saved. The existing file is retained.")}
            else if pending{form.lang.text("Editorprofile sind noch nicht gespeichert.","Editor profiles have not been saved yet.")}else{""});
        status.set_tooltip_text(error.as_deref());status.set_visible(!status.text().is_empty());
        retry.set_visible(error.is_some());retry.set_sensitive(!loading&&!writing);
        form.updating.set(false);true
    }));
}
