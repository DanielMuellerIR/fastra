use super::*;
use gtk::gdk::{Key, ModifierType as Mods};
pub(super) fn install(window: &gtk::Window) {
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = window.downgrade();
    keys.connect_key_pressed(move |controller, key, code, modifiers| {
        if !modifiers.contains(Mods::CONTROL_MASK)
            || modifiers
                .intersects(Mods::ALT_MASK | Mods::SUPER_MASK | Mods::META_MASK | Mods::HYPER_MASK)
        {
            return glib::Propagation::Proceed;
        }
        let Some(window) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        // GTKs Accelerator-Abgleich verbraucht Shift für „+“ und verbindet damit
        // beide Zoomrollen. Die native Belegung ohne Shift erhält die physische
        // Taste auch bei Layouts, in denen Shift+0 ein „=“ ergibt.
        let base = controller
            .current_event()
            .and_then(|event| event.downcast::<gtk::gdk::KeyEvent>().ok())
            .and_then(|event| {
                gtk::prelude::WidgetExt::display(&window).translate_key(
                    code,
                    modifiers - Mods::SHIFT_MASK,
                    event.layout() as i32,
                )
            })
            .map_or(key, |translated| translated.0);
        let suffix = match base {
            Key::equal | Key::plus | Key::KP_Add => "larger",
            Key::minus | Key::KP_Subtract => "smaller",
            Key::_0 | Key::KP_0 => "original",
            _ => return glib::Propagation::Proceed,
        };
        if let Some(app) = window.application() {
            let prefix = if modifiers.contains(Mods::SHIFT_MASK) {
                "document"
            } else {
                "ui"
            };
            app.activate_action(&format!("{prefix}-{suffix}"), None);
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    window.add_controller(keys);
}
