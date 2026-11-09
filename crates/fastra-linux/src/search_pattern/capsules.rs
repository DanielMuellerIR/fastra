use super::*;
pub(crate) fn empty() -> gtk::ListView {
    let view = gtk::ListView::new(None::<gtk::NoSelection>, None::<gtk::SignalListItemFactory>);
    view.set_orientation(gtk::Orientation::Horizontal);
    view.add_css_class("capture-list");
    view.set_single_click_activate(false);
    view
}
pub(super) fn install(view: &gtk::ListView, field: &gtk::Entry, lang: Language) -> gtk::StringList {
    let model = gtk::StringList::new(&[]);
    let factory = gtk::SignalListItemFactory::new();
    let field = field.downgrade();
    factory.connect_setup(move |_, item| {
        let item = item.downcast_ref::<gtk::ListItem>().unwrap();
        item.set_selectable(false);
        item.set_activatable(false);
        let pill = gtk::Button::new();
        pill.add_css_class("capture-pill");
        pill.set_tooltip_text(Some(lang.text(
            "Gruppe in Ersetzung einsetzen oder ziehen",
            "Insert or drag capture into replacement",
        )));
        let index = item.downgrade();
        let field = field.clone();
        pill.connect_clicked(move |_| {
            if let (Some(item), Some(field)) = (index.upgrade(), field.upgrade()) {
                if item.position() == gtk::INVALID_LIST_POSITION {
                    return;
                }
                let token = format!("${}", item.position() + 1);
                let mut at = field.position();
                field.insert_text(&token, &mut at);
                field.set_position(at);
            }
        });
        let drag = gtk::DragSource::builder()
            .actions(gtk::gdk::DragAction::COPY)
            .build();
        let index = item.downgrade();
        drag.connect_prepare(move |_, _, _| {
            let item = index
                .upgrade()
                .filter(|i| i.position() != gtk::INVALID_LIST_POSITION)?;
            Some(gtk::gdk::ContentProvider::for_value(
                &format!("${}", item.position() + 1).to_value(),
            ))
        });
        // Der native Buttonklick darf den folgenden Drag derselben Pille
        // unter GTK 4.14 nicht durch einen alten Gestenzustand blockieren.
        let reset = drag.downgrade();
        pill.connect_clicked(move |_| {
            let reset = reset.clone();
            glib::idle_add_local_once(move || {
                if let Some(drag) = reset.upgrade() {
                    drag.reset();
                }
            });
        });
        pill.add_controller(drag);
        item.set_child(Some(&pill));
    });
    factory.connect_bind(|_, item| {
        let item = item.downcast_ref::<gtk::ListItem>().unwrap();
        let pill = item.child().unwrap().downcast::<gtk::Button>().unwrap();
        let text = item
            .item()
            .unwrap()
            .downcast::<gtk::StringObject>()
            .unwrap();
        pill.set_label(&text.string());
        if let Some(label) = pill.child().and_downcast::<gtk::Label>() {
            let attributes = gtk::pango::AttrList::new();
            let split = text.string().find(' ').unwrap_or(text.string().len());
            let mut weight = gtk::pango::AttrInt::new_weight(gtk::pango::Weight::Bold);
            weight.set_end_index(split as u32);
            attributes.insert(weight);
            let mut hint = gtk::pango::AttrInt::new_foreground_alpha(52428);
            hint.set_start_index(split as u32);
            attributes.insert(hint);
            label.set_attributes(Some(&attributes));
        }

        for color in 0..3 {
            pill.remove_css_class(&format!("capture-{color}"));
        }
        pill.add_css_class(&format!("capture-{}", item.position() % 3));
    });
    view.set_model(Some(&gtk::NoSelection::new(Some(model.clone()))));
    view.set_factory(Some(&factory));
    model
}
