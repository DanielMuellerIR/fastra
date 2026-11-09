use super::*;

pub(super) fn section(root: &gtk::Box, title: &str) -> gtk::Box {
    let section = gtk::Box::new(gtk::Orientation::Vertical, 0);
    section.add_css_class("settings-section");
    let heading = crate::git_view::label(title);
    heading.add_css_class("settings-heading");
    section.append(&heading);
    let group = gtk::Box::new(gtk::Orientation::Vertical, 0);
    group.add_css_class("settings-group");
    section.append(&group);
    root.append(&section);
    group
}
pub(super) fn row(group: &gtk::Box) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    row.add_css_class("settings-row");
    if group.first_child().is_some() {
        row.add_css_class("settings-divider");
    }
    group.append(&row);
    row
}
pub(super) fn label(row: &gtk::Box, text: &str) -> gtk::Label {
    let label = crate::git_view::label(text);
    label.set_hexpand(true);
    label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    row.append(&label);
    label
}
pub(super) fn note(group: &gtk::Box, text: &str) {
    let row = row(group);
    row.add_css_class("settings-note");
    label(&row, text);
}
pub(super) fn stepper(minimum: f64, maximum: f64) -> gtk::SpinButton {
    let spin = gtk::SpinButton::with_range(minimum, maximum, 1.);
    spin.set_orientation(gtk::Orientation::Vertical);
    spin.set_valign(gtk::Align::Center);
    spin.set_focusable(true);
    spin.set_width_chars(1);
    spin.set_max_width_chars(1);
    spin.add_css_class("settings-stepper");
    // Der Wert steht wie auf dem Mac in der Zeilenbeschriftung. Die native
    // Wiederholung beim Gedrückthalten und der zugängliche Zahlenwert bleiben.
    // Die Textdelegation bleibt gemappt; Texteingaben werden unten abgefangen.
    for child in crate::chrome::children(&spin) {
        if let Some(button) = child.downcast_ref::<gtk::Button>() {
            button.set_icon_name(if button.has_css_class("up") {
                "fastra-chevron-up-symbolic"
            } else {
                "fastra-chevron-down-symbolic"
            });
        }
        if child.is::<gtk::Text>() || child.is::<gtk::Entry>() {
            child.add_css_class("settings-stepper-value");
        }
    }
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = spin.downgrade();
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        if modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK)
            && matches!(
                key,
                gtk::gdk::Key::a
                    | gtk::gdk::Key::c
                    | gtk::gdk::Key::v
                    | gtk::gdk::Key::x
                    | gtk::gdk::Key::z
                    | gtk::gdk::Key::y
            )
        {
            return glib::Propagation::Stop;
        }
        if modifiers.intersects(
            gtk::gdk::ModifierType::CONTROL_MASK
                | gtk::gdk::ModifierType::ALT_MASK
                | gtk::gdk::ModifierType::SUPER_MASK,
        ) {
            return glib::Propagation::Proceed;
        }
        let kind = match key {
            gtk::gdk::Key::Up | gtk::gdk::Key::Right => gtk::SpinType::StepForward,
            gtk::gdk::Key::Down | gtk::gdk::Key::Left => gtk::SpinType::StepBackward,
            gtk::gdk::Key::Tab
            | gtk::gdk::Key::ISO_Left_Tab
            | gtk::gdk::Key::Escape
            | gtk::gdk::Key::Return
            | gtk::gdk::Key::KP_Enter
            | gtk::gdk::Key::Page_Up
            | gtk::gdk::Key::Page_Down => return glib::Propagation::Proceed,
            _ => return glib::Propagation::Stop,
        };
        if let Some(spin) = weak.upgrade() {
            spin.spin(kind, 1.);
        }
        glib::Propagation::Stop
    });
    spin.add_controller(keys);
    spin
}

#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
pub(crate) fn run_selftest(ui: Rc<Ui>) {
    selftest::run(ui);
}
