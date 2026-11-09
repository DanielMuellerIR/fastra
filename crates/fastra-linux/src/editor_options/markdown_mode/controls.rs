use super::*;
pub(super) struct Controls {
    switch: glib::WeakRef<gtk::Switch>,
    status: glib::WeakRef<gtk::Label>,
    retry: glib::WeakRef<gtk::Button>,
    lang: crate::Language,
}
pub(super) fn install(lang: crate::Language, root: &gtk::Box) {
    let row = super::super::settings_form::row(root);
    super::super::settings_form::label(
        &row,
        lang.text(
            "Markdown im WYSIWYG-Modus bearbeiten",
            "Edit Markdown in WYSIWYG mode",
        ),
    );
    let switch = gtk::Switch::new();
    switch.set_valign(gtk::Align::Center);
    switch.set_widget_name("fastra-markdown-visual-default");
    switch.update_property(&[gtk::accessible::Property::Label(lang.text(
        "Markdown im WYSIWYG-Modus bearbeiten",
        "Edit Markdown in WYSIWYG mode",
    ))]);
    row.append(&switch);
    let status = crate::git_view::label("");
    status.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    status.set_lines(4);
    status.add_css_class("settings-feedback");
    root.append(&status);
    let retry = gtk::Button::with_label(lang.text("Erneut versuchen", "Retry"));
    retry.set_widget_name("fastra-markdown-mode-retry");
    retry.set_halign(gtk::Align::End);
    retry.add_css_class("settings-feedback");
    root.append(&retry);
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
            state.retry();
        }
    });
    state.refresh();
}
pub(super) fn feedback(state: &State, lang: crate::Language) -> String {
    if let Some(error) = state.error.borrow().as_ref() {
        let label = match error.stage {
            Stage::Load => lang.text(
                "Markdown-Standard konnte nicht geladen werden.",
                "Markdown default could not be loaded.",
            ),
            Stage::Save => lang.text(
                "Markdown-Standard angewendet, aber nicht gespeichert.",
                "Markdown default applied but not saved.",
            ),
            Stage::Change => lang.text(
                "Markdown-Modus nicht geändert.",
                "Markdown mode was not changed.",
            ),
        };
        format!("{label} {}", error.detail)
    } else if !state.loaded.get() {
        lang.text(
            "Markdown-Standard wird geladen …",
            "Loading Markdown default …",
        )
        .into()
    } else if state.transaction.get() {
        lang.text(
            "Rich-Ansichten werden synchronisiert …",
            "Synchronizing Rich views …",
        )
        .into()
    } else if state.busy.get() || state.queued.get() {
        lang.text(
            "Markdown-Standard wird gespeichert …",
            "Saving Markdown default …",
        )
        .into()
    } else {
        String::new()
    }
}
pub(super) fn refresh(state: &State) {
    let previous = state.applying.replace(true);
    state.controls.borrow_mut().retain(|controls| {
        let Some(switch) = controls.switch.upgrade() else {
            return false;
        };
        let visual = if state.transaction.get() {
            state.retry_change.get().or(state.choice.get())
        } else {
            state.choice.get()
        };
        switch.set_active(visual.unwrap_or(false));
        switch.set_sensitive(
            state.loaded.get()
                && !state.transaction.get()
                && !state.busy.get()
                && !state.queued.get(),
        );
        if let Some(status) = controls.status.upgrade() {
            let text = feedback(state, controls.lang);
            status.set_text(&text);
            status.set_tooltip_text(Some(&text));
            status.set_visible(!text.is_empty());
        }
        if let Some(retry) = controls.retry.upgrade() {
            retry.set_visible(state.error.borrow().is_some());
            retry.set_sensitive(!state.transaction.get() && !state.busy.get());
        }
        true
    });
    state.applying.set(previous);
}
