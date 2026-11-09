use super::*;
use fastra_core::hit_extraction::{Options, Quoting};

pub(super) fn open(surface: &Rc<Surface>) {
    let (Some(pane), Some(ui)) = (surface.pane.upgrade(), surface.ui.upgrade()) else {
        return;
    };
    let lang = pane.lang;
    let owner = pane.root.root().and_downcast::<gtk::Window>().unwrap();
    let window = gtk::Window::builder()
        .title(lang.text("Treffer extrahieren", "Extract matches"))
        .transient_for(&owner)
        .destroy_with_parent(true)
        .modal(true)
        .default_width(460)
        .default_height(334)
        .build();
    window.add_css_class("fastra-owned-review");
    chrome::dialog::decorate(
        &window,
        lang.text("Treffer extrahieren", "Extract matches"),
        lang,
    );
    let root = git_view::column();
    root.add_css_class("extraction-dialog");
    let group = gtk::Box::new(gtk::Orientation::Vertical, 0);
    group.add_css_class("settings-group");
    let separator = gtk::DropDown::from_strings(&[
        lang.text("Zeilenumbruch", "Newline"),
        lang.text("Komma", "Comma"),
        lang.text("Semikolon", "Semicolon"),
        "Tab",
        lang.text("Eigenes", "Custom"),
    ]);
    let custom = gtk::Entry::builder().text(" | ").max_length(256).build();
    custom.set_visible(false);
    let dest = gtk::DropDown::from_strings(&[
        lang.text("Neues Dokument", "New document"),
        lang.text("Zwischenablage", "Clipboard"),
    ]);
    let quote = gtk::DropDown::from_strings(&[
        lang.text("Keine Anführungszeichen", "No quotes"),
        lang.text("Nur wenn nötig", "When needed"),
        lang.text("Immer doppelte Anführungszeichen", "Always double quotes"),
    ]);
    let dedup = gtk::Switch::new();
    let replace = gtk::Switch::new();
    replace.set_active(!ui.replace.text().is_empty());
    for (title, control) in [
        (
            lang.text("Trennzeichen", "Separator"),
            separator.upcast_ref::<gtk::Widget>(),
        ),
        (lang.text("Ziel", "Destination"), dest.upcast_ref()),
        ("Quoting", quote.upcast_ref()),
        (
            lang.text("Duplikate entfernen", "Remove duplicates"),
            dedup.upcast_ref(),
        ),
        (
            lang.text(
                "Ersetzungsmuster auf Treffer anwenden",
                "Apply replacement pattern to matches",
            ),
            replace.upcast_ref(),
        ),
    ] {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        row.add_css_class("settings-row");
        let label = gtk::Label::new(Some(title));
        label.set_xalign(0.);
        label.set_hexpand(true);
        row.append(&label);
        control.set_valign(gtk::Align::Center);
        control.update_property(&[gtk::accessible::Property::Label(title)]);
        row.append(control);
        group.append(&row);
    }
    root.append(&group);
    root.append(&custom);
    let field = custom.downgrade();
    separator.connect_selected_notify(move |value| {
        if let Some(field) = field.upgrade() {
            field.set_visible(value.selected() == 4);
        }
    });
    let status = git_view::label("");
    status.set_visible(false);
    root.append(&status);
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let close = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
    let extract = gtk::Button::with_label(lang.text("Extrahieren", "Extract"));
    actions.append(&close);
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    actions.append(&spacer);
    actions.append(&extract);
    root.append(&actions);
    window.set_child(Some(&root));
    let weak = window.downgrade();
    close.connect_clicked(move |_| {
        if let Some(window) = weak.upgrade() {
            window.close();
        }
    });
    let job = Cancellation::default();
    let closing = job.clone();
    window.connect_close_request(move |_| {
        closing.cancel();
        glib::Propagation::Proceed
    });
    let owner = Rc::downgrade(surface);
    let target = window.downgrade();
    let ui = Rc::downgrade(&ui);
    extract.connect_clicked(move |button| {
        let (Some(surface), Some(window), Some(ui)) =
            (owner.upgrade(), target.upgrade(), ui.upgrade())
        else {
            return;
        };
        if !surface.available() {
            status.set_visible(true);
            status.set_text(lang.text(
                "Trefferbasis geändert. Erneut suchen; nichts extrahiert.",
                "Matches changed. Search again; nothing extracted.",
            ));
            return;
        }
        let Some(pane) = surface.pane.upgrade() else {
            return;
        };
        let use_replacement = replace.is_active();
        let destination = dest.selected();
        let entries: Vec<_> = surface
            .rows
            .borrow()
            .iter()
            .filter_map(|row| {
                if let Row::Match {
                    item,
                    hit,
                    start,
                    end,
                    ..
                } = row
                {
                    Some((
                        pane.items.borrow()[*item].preview.clone(),
                        *hit,
                        *start,
                        *end,
                    ))
                } else {
                    None
                }
            })
            .collect();
        let options = Options {
            separator: match separator.selected() {
                0 => "\n".into(),
                1 => ",".into(),
                2 => ";".into(),
                3 => "\t".into(),
                _ => custom.text().to_string(),
            },
            append_newline: separator.selected() == 0,
            quoting: match quote.selected() {
                1 => Quoting::WhenNeeded,
                2 => Quoting::Always,
                _ => Quoting::None,
            },
            deduplicate: dedup.is_active(),
        };
        let generation = surface.generation.get();
        let basis_cancel = surface.cancel.borrow().clone();
        let cancel = job.clone();
        button.set_sensitive(false);
        let owner = Rc::downgrade(&surface);
        let target = window.downgrade();
        let button = button.downgrade();
        let status = status.downgrade();
        let ui = Rc::downgrade(&ui);
        git_view::background(
            move || {
                let mut bytes = 0usize;
                let mut values = Vec::new();
                for (preview, hit, start, end) in entries {
                    cancel.check().map_err(|e| e.to_string())?;
                    basis_cancel.check().map_err(|e| e.to_string())?;
                    let value = if use_replacement {
                        &preview.matches()[hit].replacement
                    } else {
                        &preview.source()[start..end]
                    };
                    bytes = bytes.saturating_add(value.len());
                    if bytes > 16 * 1024 * 1024 {
                        return Err("Extraction limit: 16 MiB".into());
                    }
                    values.push(value.to_owned());
                }
                let text = fastra_core::hit_extraction::content(
                    &values,
                    &options,
                    16 * 1024 * 1024,
                    &cancel,
                )
                .map_err(|e| e.to_string())?;
                if destination != 1 {
                    crate::text_limits::validate(&text, lang)?;
                }
                Ok(text)
            },
            move |result| {
                let (Some(surface), Some(window)) =
                    (owner.upgrade(), target.upgrade().filter(|w| w.is_visible()))
                else {
                    return;
                };
                if let Some(button) = button.upgrade() {
                    button.set_sensitive(true);
                }
                if surface.generation.get() != generation || !surface.available() {
                    if let Some(status) = status.upgrade() {
                        status.set_visible(true);
                        status.set_text(lang.text(
                            "Trefferbasis geändert. Nichts extrahiert.",
                            "Matches changed. Nothing extracted.",
                        ));
                    }
                    return;
                }
                match result {
                    Ok(text) => {
                        if destination == 1 {
                            surface.list.clipboard().set_text(&text);
                        } else if let Some(ui) = ui.upgrade() {
                            ui.add_document(lang.text("Treffer", "Matches"), &text);
                            if let Some(doc) = ui.active() {
                                doc.buffer.set_modified(true);
                            }
                        }
                        window.close();
                    }
                    Err(error) => {
                        if let Some(status) = status.upgrade() {
                            status.set_visible(true);
                            status.set_text(&format!(
                                "{}: {error}",
                                lang.text("Extraktion nicht möglich", "Cannot extract matches")
                            ));
                        }
                    }
                }
            },
        );
    });
    let target = window.downgrade();
    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed(move |_, key, _, _| {
        if key == gtk::gdk::Key::Escape {
            if let Some(window) = target.upgrade() {
                window.close();
            }
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    window.add_controller(keys);
    window.present();
}
