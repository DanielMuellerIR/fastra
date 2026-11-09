use super::*;

type Basis = (u64, usize, i32, i32, bool);

pub(super) fn install(
    doc: &Rc<Document>,
    label: &gtk::Label,
    selection: &gtk::Label,
    lang: Language,
) -> Rc<dyn Fn()> {
    let generation = Rc::new(Cell::new(0u64));
    let basis = Rc::new(Cell::new(None::<Basis>));
    let cancellation = Rc::new(RefCell::new(Cancellation::default()));
    let request: Rc<dyn Fn()> = Rc::new({
        let weak = Rc::downgrade(doc);
        let label = label.downgrade();
        let selection = selection.downgrade();
        let generation = generation.clone();
        let basis = basis.clone();
        let cancellation = cancellation.clone();
        move || {
            let (Some(doc), Some(label)) = (weak.upgrade(), label.upgrade()) else {
                return;
            };
            if !label.is_mapped() {
                return;
            }
            let buffer = source_panes::buffer(&doc);
            let rich = doc
                .rich_toggle
                .borrow()
                .as_ref()
                .is_some_and(|toggle| toggle.is_active());
            let selected = if rich {
                None
            } else {
                buffer.selection_bounds()
            };
            let (start, end) = selected.unwrap_or_else(|| buffer.bounds());
            let from = start.offset();
            let stop = end.offset();
            let current = (
                doc.revision.get(),
                buffer.as_ptr() as usize,
                from,
                stop,
                selected.is_some(),
            );
            if basis.get() == Some(current) {
                return;
            }
            basis.set(Some(current));
            cancellation.borrow().cancel();
            let cancel = Cancellation::default();
            *cancellation.borrow_mut() = cancel.clone();
            let expected = generation.get().wrapping_add(1);
            generation.set(expected);
            label.set_text("— / — / —");
            label.set_tooltip_text(Some(
                lang.text("Statistik wird berechnet …", "Calculating statistics …"),
            ));
            if let Some(selection) = selection.upgrade() {
                selection.set_visible(selected.is_some());
            }
            let label = label.downgrade();
            let weak = weak.clone();
            let generation = generation.clone();
            // Den GTK-Puffer begrenzt kopieren; Graphemzählung und ICU laufen
            // danach im Worker. Neue Eingaben verwerfen Kopie und Ergebnis.
            glib::timeout_add_local_once(Duration::from_millis(50), move || {
                let mut offset = from;
                let mut text = String::new();
                glib::idle_add_local(move || {
                    if cancel.check().is_err() || generation.get() != expected {
                        return glib::ControlFlow::Break;
                    }
                    let (Some(_doc), Some(output)) = (weak.upgrade(), label.upgrade()) else {
                        return glib::ControlFlow::Break;
                    };
                    if !output.is_mapped() {
                        return glib::ControlFlow::Break;
                    }
                    if offset < stop {
                        let end = (offset + 4096).min(stop);
                        text.push_str(&buffer.text(
                            &buffer.iter_at_offset(offset),
                            &buffer.iter_at_offset(end),
                            true,
                        ));
                        offset = end;
                        if text.len() > fastra_document::EDITABLE_BYTES {
                            output.set_tooltip_text(Some(lang.text(
                                "Statistik überschreitet die Texteditorgrenze.",
                                "Statistics exceed the text editor limit.",
                            )));
                            return glib::ControlFlow::Break;
                        }
                    }
                    if offset < stop {
                        return glib::ControlFlow::Continue;
                    }
                    let text = std::mem::take(&mut text);
                    let cancel = cancel.clone();
                    let label = label.clone();
                    let generation = generation.clone();
                    git_view::background(
                        move || {
                            fastra_core::text_statistics::count(&text, &cancel)
                                .map_err(|error| error.to_string())
                        },
                        move |result| {
                            let Some(label) = label
                                .upgrade()
                                .filter(|label| label.is_mapped() && generation.get() == expected)
                            else {
                                return;
                            };
                            match result {
                                Ok(counts) => {
                                    let value = format!(
                                        "{} / {} / {}",
                                        counts.characters, counts.words, counts.lines
                                    );
                                    label.set_text(&value);
                                    label.set_tooltip_text(Some(&format!(
                                        "{value}\n{}",
                                        lang.text(
                                            "Zeichen / Wörter / Zeilen",
                                            "Characters / words / lines"
                                        )
                                    )));
                                }
                                Err(error) => {
                                    let reason = format!(
                                        "{}: {error}",
                                        lang.text(
                                            "Statistik nicht berechnet",
                                            "Could not calculate statistics"
                                        )
                                    );
                                    label.set_tooltip_text(Some(&reason));
                                }
                            }
                        },
                    );
                    glib::ControlFlow::Break
                });
            });
        }
    });
    for buffer in &doc.source_panes.borrow().as_ref().unwrap().buffers {
        let refresh = request.clone();
        buffer.connect_changed(move |_| refresh());
        let refresh = request.clone();
        buffer.connect_mark_set(move |_, _, mark| {
            if matches!(mark.name().as_deref(), Some("insert" | "selection_bound")) {
                refresh();
            }
        });
    }
    if let Some(toggle) = doc.rich_toggle.borrow().as_ref() {
        let refresh = request.clone();
        toggle.connect_toggled(move |_| refresh());
    }
    let refresh = request.clone();
    label.connect_map(move |_| refresh());
    label.connect_unmap(move |_| {
        cancellation.borrow().cancel();
        generation.set(generation.get().wrapping_add(1));
        basis.set(None);
    });
    request
}
