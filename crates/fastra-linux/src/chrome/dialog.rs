use super::*;

pub(crate) fn decorate(window: &gtk::Window, title: &str, lang: Language) {
    decorate_with_accessory(window, title, lang, None);
}
pub(crate) fn decorate_with_accessory(
    window: &gtk::Window,
    title: &str,
    lang: Language,
    accessory: Option<&gtk::Widget>,
) {
    super::theme_widget(window);
    window.set_title(Some(title));
    window.add_css_class("fastra-tool");
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    header.add_css_class("dialog-titlebar");
    let controls = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    controls.add_css_class("traffic-controls");
    controls.set_width_request(76);
    for (class, name, symbol, action) in [
        (
            "close",
            lang.text("Schließen", "Close"),
            "window-close-symbolic",
            0,
        ),
        (
            "minimize",
            lang.text("Minimieren", "Minimize"),
            "window-minimize-symbolic",
            1,
        ),
        (
            "maximize",
            lang.text("Vergrößern", "Maximize"),
            "window-maximize-symbolic",
            2,
        ),
    ] {
        let button = gtk::Button::from_icon_name(symbol);
        button.add_css_class(class);
        button.set_valign(gtk::Align::Center);
        button.set_tooltip_text(Some(name));
        button.update_property(&[gtk::accessible::Property::Label(name)]);
        let weak = window.downgrade();
        button.connect_clicked(move |_| {
            if let Some(window) = weak.upgrade() {
                match action {
                    0 => window.close(),
                    1 => window.minimize(),
                    _ => {
                        if window.is_maximized() {
                            window.unmaximize();
                        } else {
                            window.maximize();
                        }
                    }
                }
            }
        });
        controls.append(&button);
    }
    header.append(&controls);
    let label = gtk::Label::new(Some(title));
    label.set_hexpand(true);
    label.set_single_line_mode(true);
    label.set_wrap(false);
    let weak_title = label.downgrade();
    window.connect_title_notify(move |window| {
        if let Some(label) = weak_title.upgrade() {
            label.set_text(window.title().as_deref().unwrap_or(""));
        }
    });
    label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    header.append(&label);
    let balance = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    balance.set_width_request(76);
    balance.set_halign(gtk::Align::End);
    if let Some(accessory) = accessory {
        balance.append(accessory);
    }
    header.append(&balance);
    let handle = gtk::WindowHandle::new();
    handle.set_child(Some(&header));
    window.set_titlebar(Some(&handle));
}
