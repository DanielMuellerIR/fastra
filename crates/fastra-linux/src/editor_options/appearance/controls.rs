use super::*;
pub(super) struct Controls {
    choice: glib::WeakRef<super::choice::Choice>,
    buttons: Vec<(Mode, glib::WeakRef<gtk::ToggleButton>)>,
    status: glib::WeakRef<gtk::Label>,
    retry: glib::WeakRef<gtk::Button>,
    lang: crate::Language,
}
pub(super) fn install(lang: crate::Language, root: &gtk::Box) {
    let root =
        super::super::settings_form::section(root, lang.text("Erscheinungsbild", "Appearance"));
    let setting = super::super::settings_form::row(&root);
    let label = super::super::settings_form::label(&setting, lang.text("Dark Mode", "Dark mode"));
    label.set_wrap(false);
    label.set_single_line_mode(true);
    label.set_widget_name("fastra-appearance-label");
    let row = super::choice::Choice::new();
    row.set_valign(gtk::Align::Center);
    row.set_hexpand(false);
    row.content().add_css_class("settings-appearance-choice");
    row.content().add_css_class("appearance-choice");
    let mut buttons = Vec::new();
    let mut group = None::<gtk::ToggleButton>;
    for (mode, title, name) in [
        (
            Mode::System,
            lang.text("Automatisch", "Automatic"),
            "system",
        ),
        (Mode::Light, lang.text("Hell", "Light"), "light"),
        (Mode::Dark, lang.text("Dunkel", "Dark"), "dark"),
    ] {
        let button = gtk::ToggleButton::with_label(title);
        button.add_css_class("appearance-segment");
        button.set_widget_name(&format!("fastra-appearance-{name}"));
        button.set_hexpand(true);
        if let Some(first) = &group {
            button.set_group(Some(first));
        } else {
            group = Some(button.clone());
        }
        let weak = Rc::downgrade(&state());
        button.connect_toggled(move |button| {
            if let Some(state) = weak
                .upgrade()
                .filter(|state| !state.applying.get() && button.is_active())
            {
                state.choose(mode);
            }
        });
        row.append(&button);
        buttons.push((mode, button.downgrade()));
    }
    setting.append(&row);
    let help=crate::git_view::label(lang.text("„Automatisch“ folgt dem Desktop. „Hell“ und „Dunkel“ legen Fastras Erscheinungsbild unabhängig davon fest.","Automatic follows the desktop. Light and Dark set Fastra’s appearance independently."));
    help.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    let help_row = super::super::settings_form::row(&root);
    help_row.add_css_class("settings-note");
    help_row.append(&help);
    let status = crate::git_view::label("");
    status.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    status.set_lines(4);
    status.add_css_class("settings-feedback");
    root.append(&status);
    let retry = gtk::Button::with_label(lang.text("Erneut versuchen", "Retry"));
    retry.set_halign(gtk::Align::End);
    retry.add_css_class("settings-feedback");
    root.append(&retry);
    let state = state();
    state.controls.borrow_mut().push(Controls {
        choice: row.downgrade(),
        buttons,
        status: status.downgrade(),
        retry: retry.downgrade(),
        lang,
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
    state.refresh();
}
pub(super) fn refresh(state: &State) {
    let was_applying = state.applying.replace(true);
    let error = state.error.borrow().clone();
    state.controls.borrow_mut().retain(|controls|{
        let Some(status)=controls.status.upgrade()else{return false};
        for (mode,weak) in &controls.buttons{if let Some(button)=weak.upgrade(){button.set_active(*mode==state.mode.get());button.set_sensitive(state.loaded.get());}}
        status.set_text(if error.is_some(){controls.lang.text("Erscheinungsbild konnte nicht geladen oder gespeichert werden. Die vorhandene Datei bleibt erhalten.","Appearance preference could not be loaded or saved. The existing file is retained.")}
            else if !state.loaded.get(){controls.lang.text("Erscheinungsbild wird geladen …","Loading appearance preference …")}
            else if state.busy.get()||state.queued.get(){controls.lang.text("Erscheinungsbild angewendet; Einstellung wird gespeichert …","Appearance applied; saving preference …")}else{""});
        status.set_visible(!status.text().is_empty());status.set_tooltip_text(error.as_deref());
        if let Some(retry)=controls.retry.upgrade(){retry.set_visible(error.is_some());retry.set_sensitive(!state.busy.get());}true
    });
    state.applying.set(was_applying);
}

pub(super) fn resize(window: &gtk::Window) {
    let scale = super::super::zoom::ui_scale();
    let width = ((f64::from(window.default_width()) / scale).max(480.) - 160.).clamp(240., 340.);
    for controls in &state().controls.borrow()[..] {
        let Some(row) = controls.choice.upgrade() else { continue; };
        if row
            .root()
            .and_then(|root| root.downcast::<gtk::Window>().ok())
            .as_ref()
            == Some(window)
        {
            row.prefer((width * scale).round() as i32);
        }
    }
}
