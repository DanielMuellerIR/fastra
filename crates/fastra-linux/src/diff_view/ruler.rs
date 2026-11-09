use super::*;

fn marker_indices(count: usize, current: usize, maximum: usize) -> Vec<usize> {
    if count == 0 || maximum == 0 {
        return Vec::new();
    }
    if count <= maximum {
        return (0..count).collect();
    }
    if maximum == 1 {
        return vec![current.min(count - 1)];
    }
    let mut indices = (0..maximum)
        .map(|index| (index as f64 * (count - 1) as f64 / (maximum - 1) as f64).round() as usize)
        .collect::<Vec<_>>();
    if current < count && !indices.contains(&current) {
        let candidates = if maximum > 2 {
            1..maximum - 1
        } else {
            0..maximum
        };
        let replacement = candidates
            .min_by_key(|index| indices[*index].abs_diff(current))
            .unwrap();
        indices[replacement] = current;
        indices.sort_unstable();
    }
    indices
}
fn position(index: usize, count: usize) -> f64 {
    if count < 2 {
        0.5
    } else {
        index as f64 / (count - 1) as f64
    }
}
pub(super) struct Ruler {
    pub widget: gtk::Overlay,
    selection: glib::WeakRef<gtk::SingleSelection>,
    buttons: RefCell<Vec<(usize, gtk::Button)>>,
    signature: Cell<Option<(usize, usize, i32)>>,
    lang: Language,
}
impl Ruler {
    pub fn new(lang: Language, selection: &gtk::SingleSelection) -> Self {
        let widget = gtk::Overlay::new();
        widget.set_size_request(20, -1);
        widget.add_css_class("diff-ruler");
        widget.set_child(Some(&gtk::Box::new(gtk::Orientation::Vertical, 0)));
        widget.update_property(&[gtk::accessible::Property::Label(
            lang.text("Übersicht der Unterschiede", "Overview of differences"),
        )]);
        widget.set_tooltip_text(Some(lang.text(
            "Übersicht der Unterschiede; die hervorgehobene Markierung ist der aktuelle.",
            "Overview of differences; the highlighted marker is the current one.",
        )));
        Self {
            widget,
            selection: selection.downgrade(),
            buttons: Default::default(),
            signature: Cell::new(None),
            lang,
        }
    }
    pub fn update(&self, count: usize, current: usize) {
        let height = self.widget.height();
        let previous = self.signature.replace(Some((count, current, height)));
        if previous == Some((count, current, height)) {
            return;
        }
        let indices = marker_indices(count, current, 160);
        let mut buttons = self.buttons.borrow_mut();
        buttons.retain(|(index, button)| {
            if indices.binary_search(index).is_ok() {
                true
            } else {
                self.widget.remove_overlay(button);
                false
            }
        });
        for index in indices {
            if !buttons.iter().any(|(existing, _)| *existing == index) {
                let button = gtk::Button::new();
                button.add_css_class("diff-ruler-mark");
                button.set_halign(gtk::Align::Start);
                button.set_valign(gtk::Align::Start);
                button.update_property(&[gtk::accessible::Property::Label(&format!(
                    "{} {} {} {}",
                    self.lang.text("Unterschied", "Difference"),
                    index + 1,
                    self.lang.text("von", "of"),
                    count
                ))]);
                button.set_tooltip_text(Some(&format!(
                    "{} {}",
                    self.lang
                        .text("Zu Unterschied springen:", "Jump to difference:"),
                    index + 1
                )));
                let selection = self.selection.clone();
                button.connect_clicked(move |_| {
                    if let Some(selection) = selection.upgrade() {
                        if selection.selected() == index as u32 {
                            // Erneutes Anklicken soll auch ohne Auswahlwechsel zur Quelle springen.
                            selection.notify("selected");
                        } else {
                            selection.set_selected(index as u32);
                        }
                    }
                });
                self.widget.add_overlay(&button);
                self.widget.set_measure_overlay(&button, false);
                self.widget.set_clip_overlay(&button, true);
                buttons.push((index, button));
            }
        }
        buttons.sort_by_key(|(index, _)| *index);
        for (index, button) in buttons.iter() {
            if previous.is_none_or(|(old_count, _, _)| old_count != count) {
                button.update_property(&[gtk::accessible::Property::Label(&format!(
                    "{} {} {} {}",
                    self.lang.text("Unterschied", "Difference"),
                    index + 1,
                    self.lang.text("von", "of"),
                    count
                ))]);
            }
            let selected = *index == current;
            button.set_size_request(if selected { 12 } else { 8 }, 5);
            button.set_margin_start(if selected { 4 } else { 6 });
            let y = (position(*index, count) * f64::from(height))
                .clamp(4., f64::from((height - 4).max(4)));
            button.set_margin_top((y - 2.5).round().max(0.) as i32);
            if selected {
                button.add_css_class("current");
            } else {
                button.remove_css_class("current");
            }
        }
        if previous.is_none_or(|(_, old_current, _)| old_current != current) {
            if let Some((_, button)) = buttons.iter().find(|(index, _)| *index == current) {
                let button = button.downgrade();
                let widget = self.widget.downgrade();
                let selection = self.selection.clone();
                // Erst nach dem Klick umhängen; der aktuelle Marker liegt vor dichten Nachbarn.
                glib::idle_add_local_once(move || {
                    if let (Some(widget), Some(button), Some(selection)) =
                        (widget.upgrade(), button.upgrade(), selection.upgrade())
                    {
                        if selection.selected() as usize == current
                            && button.parent().as_ref() == Some(widget.upcast_ref())
                        {
                            let focused = button.has_focus();
                            widget.remove_overlay(&button);
                            widget.add_overlay(&button);
                            widget.set_measure_overlay(&button, false);
                            widget.set_clip_overlay(&button, true);
                            if focused {
                                button.grab_focus();
                            }
                        }
                    }
                });
            }
        }
    }
    #[cfg(debug_assertions)]
    pub fn test_button(&self, index: usize) -> Option<gtk::Button> {
        self.buttons
            .borrow()
            .iter()
            .find(|(i, _)| *i == index)
            .map(|(_, b)| b.clone())
    }
    #[cfg(debug_assertions)]
    pub fn test_middle(&self) -> (usize, gtk::Button) {
        let buttons = self.buttons.borrow();
        buttons[buttons.len() / 2].clone()
    }
    #[cfg(debug_assertions)]
    pub fn test_count(&self) -> usize {
        self.buttons.borrow().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ruler_matches_mac_sampling_and_retains_current_between_samples() {
        assert_eq!(marker_indices(0, 0, 160), Vec::<usize>::new());
        assert_eq!(marker_indices(1, 0, 160), vec![0]);
        assert_eq!(position(0, 1), 0.5);
        assert_eq!(marker_indices(1000, 500, 5), vec![0, 250, 500, 749, 999]);
        assert_eq!(marker_indices(1000, 513, 5), vec![0, 250, 513, 749, 999]);
        assert_eq!(marker_indices(1000, 9999, 1), vec![999]);
        for count in [159, 160, 161, 3333, 16667, 200000] {
            for current in [0, 1, count / 2, count - 2, count - 1] {
                let indices = marker_indices(count, current, 160);
                assert_eq!(indices.len(), count.min(160));
                assert_eq!(indices[0], 0);
                assert_eq!(indices[indices.len() - 1], count - 1);
                assert!(indices.contains(&current));
                assert!(indices.windows(2).all(|pair| pair[0] < pair[1]));
            }
        }
    }
}
