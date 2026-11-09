use super::*;

pub(super) fn install(entry: &gtk::Entry) {
    let Some(text) = entry.delegate().and_downcast::<gtk::Text>() else {
        return;
    };
    let controllers = text.observe_controllers();
    for index in 0..controllers.n_items() {
        let Some(target) = controllers.item(index).and_downcast::<gtk::DropTarget>() else {
            continue;
        };
        target.connect_current_drop_notify(|target| {
            if target.current_drop().is_none() {
                // GTK 4.14 beendet einen Drop ohne leave. Der alte Drop-Caret
                // kann danach außerhalb eines gekürzten Feldtexts liegen.
                // Der öffentliche leave-Handler räumt ihn ohne Texteingriff auf.
                target.emit_by_name::<()>("leave", &[]);
            }
        });
    }
}
