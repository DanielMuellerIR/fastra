use super::*;
pub(super) struct Controls {
    switch: glib::WeakRef<gtk::Switch>,
    status: glib::WeakRef<gtk::Label>,
    retry: glib::WeakRef<gtk::Button>,
    lang: crate::Language,
}
pub(super) fn install(lang: crate::Language, root: &gtk::Box) {
    let group = super::super::settings_form::section(root, "Markdown");
    super::super::markdown_mode::controls(lang,&group);
    let row = super::super::settings_form::row(&group);
    super::super::settings_form::label(
        &row,
        lang.text(
            "Bei Markdown rechts anzeigen",
            "Show on the Right for Markdown",
        ),
    );
    let switch = gtk::Switch::new();
    switch.set_valign(gtk::Align::Center);
    switch.set_widget_name("fastra-markdown-preview-default");
    switch.update_property(&[gtk::accessible::Property::Label(lang.text(
        "Bei Markdown rechts anzeigen",
        "Show on the Right for Markdown",
    ))]);
    row.append(&switch);
    let status = crate::git_view::label("");
    status.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    status.set_lines(4);
    status.add_css_class("settings-feedback");
    group.append(&status);
    let retry = gtk::Button::with_label(lang.text("Erneut versuchen", "Retry"));
    retry.set_widget_name("fastra-markdown-preview-retry");
    retry.set_halign(gtk::Align::End);
    retry.add_css_class("settings-feedback");
    group.append(&retry);
    let state = state();
    state.controls.borrow_mut().push(Controls {
        switch: switch.downgrade(),
        status: status.downgrade(),
        retry: retry.downgrade(),
        lang,
    });
    let weak = Rc::downgrade(&state);
    switch.connect_active_notify(move |switch| {
        if let Some(state) = weak.upgrade() {
            state.choose(switch.is_active());
        }
    });
    let weak = Rc::downgrade(&state);
    retry.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            if state.loaded.get() {
                state.save();
            } else {
                state.load();
            }
        }
    });
    super::super::reading_font::controls(lang, &group);
    state.refresh();
}
pub(super) fn refresh(state: &State) {
    let previous = state.applying.replace(true);
    let error = state.error.borrow().clone();
    state.controls.borrow_mut().retain(|controls|{
        let Some(switch)=controls.switch.upgrade()else{return false};switch.set_active(state.shown.get());switch.set_sensitive(state.loaded.get());
        if let Some(status)=controls.status.upgrade(){
            status.set_text(if error.is_some(){controls.lang.text("Markdown-Vorgabe konnte nicht geladen oder gespeichert werden. Die vorhandene Datei bleibt erhalten.","Markdown preference could not be loaded or saved. The existing file is retained.")}
                else if !state.loaded.get(){controls.lang.text("Markdown-Vorgabe wird geladen …","Loading Markdown preference …")}
                else if state.busy.get()||state.queued.get(){controls.lang.text("Vorschau angewendet; Einstellung wird gespeichert …","Preview applied; saving preference …")}else{""});status.set_tooltip_text(error.as_deref());status.set_visible(!status.text().is_empty());
        }
        if let Some(retry)=controls.retry.upgrade(){retry.set_visible(error.is_some());retry.set_sensitive(!state.busy.get());}true
    });
    state.applying.set(previous);
}
