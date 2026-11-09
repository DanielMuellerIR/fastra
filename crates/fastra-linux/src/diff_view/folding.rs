use super::*;
use std::collections::{BTreeSet, HashMap};

pub(super) struct Folding {
    pub overlays: [gtk::Overlay; 2],
    tags: [RefCell<Option<gtk::TextTag>>; 2],
    expanded: RefCell<BTreeSet<usize>>,
    buttons: RefCell<HashMap<usize, [gtk::Button; 2]>>,
    queued: Cell<bool>,
}
impl Folding {
    pub fn new(scrolls: &[gtk::ScrolledWindow; 2]) -> Self {
        Self {
            overlays: scrolls.each_ref().map(|scroll| {
                let overlay = gtk::Overlay::new();
                overlay.set_child(Some(scroll));
                overlay
            }),
            tags: Default::default(),
            expanded: Default::default(),
            buttons: Default::default(),
            queued: Cell::new(false),
        }
    }
    pub fn clear(&self, view: &view::View) {
        for (index, tag) in self.tags.iter().enumerate() {
            if let Some(tag) = tag.borrow_mut().take() {
                view.texts[index].buffer().tag_table().remove(&tag);
            }
        }
        self.expanded.borrow_mut().clear();
        for buttons in self
            .buttons
            .borrow_mut()
            .drain()
            .map(|(_, buttons)| buttons)
        {
            for (side, button) in buttons.iter().enumerate() {
                self.overlays[side].remove_overlay(button);
            }
        }
    }
    pub fn setup(&self, view: &view::View) {
        self.clear(view);
        for (side, tag) in self.tags.iter().enumerate() {
            *tag.borrow_mut() = view.texts[side]
                .buffer()
                .create_tag(None, &[("invisible", &true)]);
        }
    }
    pub fn hide(&self, view: &view::View, index: usize, hidden: bool) {
        let data = view.data.borrow();
        let Some(data) = data.as_ref() else {
            return;
        };
        let fold = &data.folds[index];
        for side in 0..2 {
            let buffer = view.texts[side].buffer();
            let a = buffer
                .iter_at_offset(data.columns[side].lines[fold.rows.start].display.start as i32);
            let b = buffer
                .iter_at_offset(data.columns[side].lines[fold.rows.end - 1].display.end as i32 + 1);
            if let Some(tag) = self.tags[side].borrow().as_ref() {
                if hidden {
                    buffer.apply_tag(tag, &a, &b);
                } else {
                    buffer.remove_tag(tag, &a, &b);
                }
            }
        }
    }
    pub fn hidden(&self, data: &presentation::Presentation) -> Vec<std::ops::Range<usize>> {
        let expanded = self.expanded.borrow();
        data.folds
            .iter()
            .enumerate()
            .filter(|(index, _)| !expanded.contains(index))
            .map(|(_, fold)| fold.rows.clone())
            .collect()
    }
    pub fn row_hidden(&self, data: &presentation::Presentation, row: usize) -> bool {
        let index = data.folds.partition_point(|fold| fold.rows.end <= row);
        data.folds.get(index).is_some_and(|fold| {
            fold.rows.contains(&row) && !self.expanded.borrow().contains(&index)
        })
    }
    pub fn redraw(view: &Rc<view::View>) {
        let lang = view.lang;
        if view.folding.queued.replace(true) {
            return;
        }
        let owner = Rc::downgrade(view);
        glib::idle_add_local_once(move || {
            let Some(view) = owner.upgrade() else {
                return;
            };
            view.folding.queued.set(false);
            if !view.ready.get() {
                return;
            }
            let data = view.data.borrow();
            let Some(data) = data.as_ref() else {
                return;
            };
            if data.blocks.is_empty() {
                return;
            }
            let rect = view.texts[0].visible_rect();
            let first = view.texts[0].line_at_y(rect.y()).0.line().max(0) as usize;
            let last = view.texts[0]
                .line_at_y(rect.y() + rect.height())
                .0
                .line()
                .max(0) as usize;
            let start = data.folds.partition_point(|fold| fold.control < first);
            let mut wanted = BTreeSet::new();
            let mut buttons = view.folding.buttons.borrow_mut();
            for (index, fold) in data
                .folds
                .iter()
                .enumerate()
                .skip(start)
                .take_while(|(_, fold)| fold.control <= last)
                .take(100)
            {
                let expanded = view.folding.expanded.borrow().contains(&index);
                let label = format!(
                    "{} {} {}",
                    if expanded { "⌄" } else { "›" },
                    fold.rows.len(),
                    lang.text("unveränderte Zeilen", "unchanged lines")
                );
                let pair = buttons.entry(index).or_insert_with(|| {
                    std::array::from_fn(|side| {
                        let button = gtk::Button::new();
                        button.add_css_class("diff-fold");
                        button.set_halign(gtk::Align::Center);
                        button.set_valign(gtk::Align::Start);
                        let owner = Rc::downgrade(&view);
                        button.connect_clicked(move |_| {
                            let owner = owner.clone();
                            glib::idle_add_local_once(move || {
                                if let Some(view) = owner.upgrade().filter(|v| v.ready.get()) {
                                    let hidden = {
                                        let mut expanded = view.folding.expanded.borrow_mut();
                                        if expanded.remove(&index) {
                                            true
                                        } else {
                                            expanded.insert(index);
                                            false
                                        }
                                    };
                                    view.alignment.clear(&view);
                                    view.folding.hide(&view, index, hidden);
                                    alignment::Alignment::request(&view);
                                    Self::redraw(&view);
                                }
                            });
                        });
                        view.folding.overlays[side].add_overlay(&button);
                        view.folding.overlays[side].set_measure_overlay(&button, false);
                        view.folding.overlays[side].set_clip_overlay(&button, true);
                        button
                    })
                });
                wanted.insert(index);
                for (side, button) in pair.iter().enumerate() {
                    let text = &view.texts[side];
                    let iter = text.buffer().iter_at_offset(
                        data.columns[side].lines[fold.control].display.start as i32,
                    );
                    let (y, _) = text.line_yrange(&iter);
                    let (_, y) = text.buffer_to_window_coords(gtk::TextWindowType::Widget, 0, y);
                    let point = text.compute_point(
                        &view.folding.overlays[side],
                        &gtk::graphene::Point::new(0., y as f32),
                    );
                    let top = point.map_or(-1, |point| point.y().round() as i32);
                    button.set_label(&label);
                    button.set_visible(top >= 0);
                    button.set_margin_top(top.max(0));
                }
            }
            buttons.retain(|index, pair| {
                if wanted.contains(index) {
                    true
                } else {
                    for (side, button) in pair.iter().enumerate() {
                        view.folding.overlays[side].remove_overlay(button);
                    }
                    false
                }
            });
        });
    }
    #[cfg(debug_assertions)]
    pub fn test_button(&self, index: usize) -> Option<gtk::Button> {
        self.buttons
            .borrow()
            .get(&index)
            .map(|pair| pair[0].clone())
    }
}
