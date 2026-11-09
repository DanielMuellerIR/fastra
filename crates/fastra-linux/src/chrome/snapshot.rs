//! Snapshotfenster folgen der Mac-Aufteilung, ohne einen schreibenden Editor anzubinden.
use super::*;
pub(crate) fn decorate(window: &gtk::Window, title: &str, lang: Language) {
    if window.titlebar().is_none() {
        super::dialog::decorate(window, title, lang);
    } else {
        window.set_title(Some(title));
    }
    window.add_css_class("fastra-snapshot");
}
pub(crate) fn header(name: &impl IsA<gtk::Widget>, status: &gtk::Label) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    row.add_css_class("snapshot-header");
    name.add_css_class("snapshot-filename");
    name.set_hexpand(true);
    name.set_halign(gtk::Align::Fill);
    status.set_xalign(1.);
    status.set_wrap(true);
    status.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    status.set_lines(3);
    status.set_max_width_chars(38);
    status.set_ellipsize(gtk::pango::EllipsizeMode::End);
    status.add_css_class("snapshot-status");
    row.append(name);
    row.append(status);
    row
}
pub(crate) fn source(view: &sourceview5::View) {
    view.set_show_line_numbers(false);
    view.set_left_margin(12);
    view.set_right_margin(12);
    view.set_top_margin(10);
    view.set_bottom_margin(10);
}
