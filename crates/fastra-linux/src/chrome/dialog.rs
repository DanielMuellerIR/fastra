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
    let header = gtk::CenterBox::new();
    header.add_css_class("dialog-titlebar");
    let label = gtk::Label::new(Some(title));
    label.set_single_line_mode(true);
    label.set_wrap(false);
    let weak_title = label.downgrade();
    window.connect_title_notify(move |window| {
        if let Some(label) = weak_title.upgrade() {
            label.set_text(window.title().as_deref().unwrap_or(""));
        }
    });
    label.set_ellipsize(gtk::pango::EllipsizeMode::End);
    header.set_center_widget(Some(&label));
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    if let Some(accessory) = accessory {
        actions.append(accessory);
    }
    actions.append(&super::window_controls(lang));
    header.set_end_widget(Some(&actions));
    let handle = gtk::WindowHandle::new();
    handle.set_child(Some(&header));
    window.set_titlebar(Some(&handle));
}
