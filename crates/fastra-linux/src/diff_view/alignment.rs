use super::*;
use std::collections::HashMap;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq)]
struct LayoutSignature {
    widths: [i32; 2],
    wrap: gtk::WrapMode,
    render: u64,
    font_serials: [u32; 2],
}
#[derive(Default)]
pub(super) struct Alignment {
    generation: Cell<u64>,
    signature: Cell<Option<LayoutSignature>>,
    padding: RefCell<Vec<[i32; 2]>>,
    tags: [RefCell<HashMap<i32, gtk::TextTag>>; 2],
    pending: Cell<bool>,
}
impl Alignment {
    pub fn clear(&self, view: &view::View) {
        self.pending.set(false);
        self.generation.set(self.generation.get().wrapping_add(1));
        self.signature.set(None);
        self.padding.borrow_mut().clear();
        for (side, tags) in self.tags.iter().enumerate() {
            let buffer = view.texts[side].buffer();
            for tag in tags.borrow_mut().drain().map(|(_, tag)| tag) {
                buffer.tag_table().remove(&tag);
            }
        }
    }
    pub fn request(view: &Rc<view::View>) {
        if !view.ready.get()
            || view
                .data
                .borrow()
                .as_ref()
                .is_none_or(|data| data.blocks.is_empty())
        {
            return;
        }
        let signature = LayoutSignature {
            widths: view.texts.each_ref().map(|text| text.width()),
            wrap: view.texts[0].wrap_mode(),
            render: view.render.get(),
            font_serials: view
                .texts
                .each_ref()
                .map(|text| text.pango_context().serial()),
        };
        if signature.widths.iter().any(|width| *width <= 0)
            || view.alignment.signature.replace(Some(signature)) == Some(signature)
        {
            return;
        }
        let generation = view.alignment.generation.get().wrapping_add(1);
        view.alignment.pending.set(true);
        view.alignment.generation.set(generation);
        let owner = Rc::downgrade(view);
        let mut index = 0;
        glib::idle_add_local(move || {
            let Some(view) = owner
                .upgrade()
                .filter(|v| v.alignment.generation.get() == generation && v.ready.get())
            else {
                return glib::ControlFlow::Break;
            };
            let data = view.data.borrow();
            let Some(data) = data.as_ref() else {
                return glib::ControlFlow::Break;
            };
            let count = data.columns[0].lines.len();
            let started = Instant::now();
            let mut padding = view.alignment.padding.borrow_mut();
            padding.resize(count, [0, 0]);
            while index < count {
                let natural: [i32; 2] = std::array::from_fn(|side| {
                    let iter = view.texts[side]
                        .buffer()
                        .iter_at_offset(data.columns[side].lines[index].display.start as i32);
                    // Außerhalb des sichtbaren Ausschnitts kann GTK noch eine
                    // einzeilige Schätzhöhe liefern. Erst das tatsächliche
                    // Textlayout anfordern, dann die volle Umbruchhöhe messen.
                    let _ = view.texts[side].iter_location(&iter);
                    let (_, height) = view.texts[side].line_yrange(&iter);
                    height - padding[index][side]
                });
                let maximum = natural[0].max(natural[1]);
                for side in 0..2 {
                    let extra = maximum - natural[side];
                    let old = padding[index][side];
                    if extra == old {
                        continue;
                    }
                    let buffer = view.texts[side].buffer();
                    let line = &data.columns[side].lines[index];
                    let a = buffer.iter_at_offset(line.display.start as i32);
                    let b = buffer.iter_at_offset(line.display.end as i32 + 1);
                    let mut tags = view.alignment.tags[side].borrow_mut();
                    if let Some(tag) = tags.get(&old) {
                        buffer.remove_tag(tag, &a, &b);
                    }
                    if extra > 0 {
                        let tag = tags.entry(extra).or_insert_with(|| {
                            buffer
                                .create_tag(None, &[("pixels-below-lines", &(4 + extra))])
                                .unwrap()
                        });
                        buffer.apply_tag(tag, &a, &b);
                    }
                    padding[index][side] = extra;
                }
                index += 1;
                if started.elapsed() >= Duration::from_millis(3) {
                    return glib::ControlFlow::Continue;
                }
            }
            view.alignment.pending.set(false);
            folding::Folding::redraw(&view);
            glib::ControlFlow::Break
        });
    }
    #[cfg(debug_assertions)]
    pub fn test_pending(&self) -> bool {
        self.pending.get()
    }
}
