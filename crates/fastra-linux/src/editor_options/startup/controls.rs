use super::*;
pub(super) struct Controls {
    choice: glib::WeakRef<gtk::Switch>,
    status: glib::WeakRef<gtk::Label>,
    retry: glib::WeakRef<gtk::Button>,
    lang: crate::Language,
}
pub(super) fn install(state: &Rc<State>, lang: crate::Language, root: &gtk::Box) {
    let group = super::super::settings_form::section(root, lang.text("Start", "Startup"));
    let row = super::super::settings_form::row(&group);
    let title = lang.text(
        "Zuletzt geöffnete Fenster und Dokumente wiederherstellen",
        "Restore Previously Open Windows and Documents",
    );
    super::super::settings_form::label(&row, title);
    let choice = gtk::Switch::new();
    choice.set_valign(gtk::Align::Center);
    choice.set_widget_name("fastra-startup-restore");
    choice.update_property(&[gtk::accessible::Property::Label(title)]);
    row.append(&choice);
    super::super::settings_form::note(&group, lang.text(
        "Fastra öffnet beim nächsten Start dieselben Projektfenster und gespeicherten Dokumente. Ungesicherte oder unbenannte Dokumentinhalte werden nie wiederhergestellt.",
        "On the next launch, Fastra reopens the same project windows and saved documents. Unsaved or untitled document contents are never restored."));
    let status = crate::git_view::label("");
    status.add_css_class("settings-feedback");
    group.append(&status);
    let retry = gtk::Button::with_label(lang.text("Erneut versuchen", "Retry"));
    retry.set_halign(gtk::Align::End);
    retry.set_widget_name("fastra-startup-retry");
    retry.add_css_class("settings-feedback");
    group.append(&retry);
    state.controls.borrow_mut().push(Controls {
        choice: choice.downgrade(),
        status: status.downgrade(),
        retry: retry.downgrade(),
        lang,
    });
    let owner = Rc::downgrade(state);
    choice.connect_active_notify(move |choice| {
        if let Some(state) = owner.upgrade() {
            state.choose(choice.is_active());
        }
    });
    let owner = Rc::downgrade(state);
    retry.connect_clicked(move |_| {
        if let Some(state) = owner.upgrade() {
            if state.loaded.get() {
                state.save();
            } else {
                state.load();
            }
        }
    });
    refresh(state);
}
pub(super) fn refresh(state: &State) {
    state.updating.set(true);
    state.controls.borrow_mut().retain(|controls| {
        let Some(choice) = controls.choice.upgrade() else {
            return false;
        };
        choice.set_active(state.restore.get());
        choice.set_sensitive(state.loaded.get() && !state.busy.get());
        if let Some(status) = controls.status.upgrade() {
            status.set_text(&if let Some(error) = state.error.borrow().as_ref() {
                format!(
                    "{}: {error}",
                    controls.lang.text(
                        "Starteinstellung konnte nicht geladen oder gespeichert werden",
                        "Startup preference could not be loaded or saved"
                    )
                )
            } else if state.busy.get() {
                controls
                    .lang
                    .text(
                        "Starteinstellung wird geladen oder gespeichert …",
                        "Loading or saving startup preference …",
                    )
                    .into()
            } else {
                String::new()
            });
            status.set_visible(!status.text().is_empty());
        }
        if let Some(retry) = controls.retry.upgrade() {
            retry.set_visible(state.error.borrow().is_some());
            retry.set_sensitive(!state.busy.get());
        }
        true
    });
    state.updating.set(false);
}
