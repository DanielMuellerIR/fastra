use super::{chrome, diff_view, tab_close, Document, Ui};
use gtk::{glib, prelude::*};
use std::rc::{Rc, Weak};

pub(super) struct Pair {
    active: Weak<Document>,
    partner: Weak<Document>,
}
fn member(ui: &Ui, doc: &Rc<Document>) -> bool {
    ui.documents
        .borrow()
        .iter()
        .any(|item| Rc::ptr_eq(item, doc))
}
pub(super) fn ordered(ui: &Ui) -> Option<[Rc<Document>; 2]> {
    let selected = ui.comparison_pair.borrow().as_ref().and_then(|pair| {
        let active = pair.active.upgrade()?;
        let partner = pair.partner.upgrade()?;
        (ui.active().is_some_and(|doc| Rc::ptr_eq(&doc, &active))
            && !Rc::ptr_eq(&active, &partner)
            && diff_view::eligible(&active)
            && diff_view::eligible(&partner))
        .then_some((active, partner))
    });
    if let Some((active, partner)) = selected {
        let documents = ui.documents.borrow();
        let selected = documents
            .iter()
            .filter(|doc| Rc::ptr_eq(doc, &active) || Rc::ptr_eq(doc, &partner))
            .cloned()
            .collect::<Vec<_>>();
        if let Ok(pair) = selected.try_into() {
            return Some(pair);
        }
    }
    ui.comparison_pair.borrow_mut().take();
    None
}
pub(super) fn partner(ui: &Ui) -> Option<Rc<Document>> {
    ordered(ui)?
        .into_iter()
        .find(|doc| ui.active().is_none_or(|active| !Rc::ptr_eq(&active, doc)))
}
pub(super) fn page_changing(ui: &Ui, page: &gtk::Widget) {
    let different = ui.comparison_pair.borrow().as_ref().is_some_and(|pair| {
        pair.active
            .upgrade()
            .is_none_or(|active| active.container.upcast_ref::<gtk::Widget>() != page)
    });
    if different {
        clear(ui);
    }
}
pub(super) fn clear(ui: &Ui) {
    ui.comparison_pair.borrow_mut().take();
}
pub(super) fn choose(ui: &Rc<Ui>, doc: &Rc<Document>) -> bool {
    let Some(active) = ui.active().filter(|active| diff_view::eligible(active)) else {
        return false;
    };
    if !member(ui, doc) || !diff_view::eligible(doc) {
        return false;
    }
    let same =
        Rc::ptr_eq(&active, doc) || partner(ui).is_some_and(|partner| Rc::ptr_eq(&partner, doc));
    *ui.comparison_pair.borrow_mut() = (!same).then(|| Pair {
        active: Rc::downgrade(&active),
        partner: Rc::downgrade(doc),
    });
    chrome::refresh(ui);
    true
}
pub(super) fn install_selection(
    ui: &Rc<Ui>,
    doc: &Rc<Document>,
    button: &gtk::Button,
    row: &gtk::Box,
) {
    let gesture = gtk::GestureClick::new();
    gesture.set_button(1);
    gesture.set_propagation_phase(gtk::PropagationPhase::Capture);
    let owner = Rc::downgrade(ui);
    let document = Rc::downgrade(doc);
    let target = button.downgrade();
    gesture.connect_pressed(move |gesture, _, x, y| {
        let hit = target
            .upgrade()
            .zip(gesture.widget())
            .is_some_and(|(button, row)| {
                button.compute_bounds(&row).is_some_and(|bounds| {
                    bounds.contains_point(&gtk::graphene::Point::new(x as f32, y as f32))
                })
            });
        if !hit {
            return;
        }
        if gesture
            .current_event_state()
            .contains(gtk::gdk::ModifierType::SHIFT_MASK)
        {
            if let (Some(ui), Some(doc)) = (owner.upgrade(), document.upgrade()) {
                if choose(&ui, &doc) {
                    gesture.set_state(gtk::EventSequenceState::Claimed);
                }
            }
        }
    });
    // Vor dem Kindknopf abfangen, damit GTK keinen zweiten normalen Klick auslöst.
    row.add_controller(gesture);
}
pub(super) fn can_context(ui: &Ui, doc: &Rc<Document>) -> bool {
    ordered(ui).is_some_and(|pair| pair.iter().any(|item| Rc::ptr_eq(item, doc)))
}
pub(super) fn open_context(ui: &Rc<Ui>, doc: &Rc<Document>) {
    let Some(pair) = ordered(ui).filter(|pair| pair.iter().any(|item| Rc::ptr_eq(item, doc)))
    else {
        ui.status.set_text(ui.lang.text(
            "Die Vergleichsauswahl ist nicht mehr gültig. Zwei offene Text-Tabs auswählen.",
            "The comparison selection is no longer valid. Select two open text tabs.",
        ));
        return;
    };
    let _ = diff_view::open_documents(ui, pair);
}
pub(super) fn can_saved(ui: &Ui) -> bool {
    ui.active().is_some_and(|doc| {
        diff_view::eligible(&doc)
            && doc.buffer.is_modified()
            && doc.disk_path().is_some()
            && doc.hex_editor.borrow().is_none()
            && doc.rich.borrow().as_ref().is_none_or(|editor| {
                !editor.active.get() || (editor.ready_for_saved_source() && !editor.pending())
            })
    })
}
pub(super) fn refresh_saved(ui: &Ui) {
    let available = can_saved(ui);
    ui.saved_diff_tool.set_sensitive(available);
    ui.saved_diff_tool.set_tooltip_text(Some(if available {
        ui.lang.text(
            "Vergleicht den ungespeicherten Editor-Inhalt mit dem gespeicherten Stand der Datei.",
            "Compares the unsaved editor content with the saved state of the file.",
        )
    } else {
        ui.lang.text(
            "Nur aktiv, wenn der aktive Tab ungespeicherte Änderungen an einer Datei hat.",
            "Only available when the active tab has unsaved changes to a file.",
        )
    }));
}
pub(super) fn install_keys(ui: &Rc<Ui>, window: &impl IsA<gtk::Window>) {
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let owner = Rc::downgrade(ui);
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        let chord = gtk::gdk::ModifierType::CONTROL_MASK
            | gtk::gdk::ModifierType::ALT_MASK
            | gtk::gdk::ModifierType::SHIFT_MASK;
        if matches!(key, gtk::gdk::Key::d | gtk::gdk::Key::D)
            && modifiers.contains(chord)
            && !modifiers.contains(gtk::gdk::ModifierType::SUPER_MASK)
        {
            if let Some(ui) = owner
                .upgrade()
                .filter(|ui| !super::close_protocol::active(ui) && !ui.window_close_dialog.get())
            {
                let _ = diff_view::open(&ui);
            }
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    window.as_ref().add_controller(keys);
}
pub(super) fn activate(ui: &Rc<Ui>, doc: &Rc<Document>) {
    if !member(ui, doc) {
        return;
    }
    clear(ui);
    tab_close::activate(ui, doc);
    chrome::refresh(ui);
}
