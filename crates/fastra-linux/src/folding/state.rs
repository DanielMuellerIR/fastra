use super::*;
impl Folds {
    pub(crate) fn snapshot(
        &self,
        index: usize,
        view: &sourceview5::View,
        snapshot: &gtk::Snapshot,
    ) {
        marker::snapshot(self, index, view, snapshot);
    }
    pub(super) fn closed_ranges(&self, index: usize) -> Vec<Range<i32>> {
        let mut ranges = self.closed[index]
            .borrow()
            .iter()
            .map(Closed::range)
            .collect::<Vec<_>>();
        ranges.sort_unstable_by(|a, b| a.start.cmp(&b.start).then_with(|| b.end.cmp(&a.end)));
        ranges
    }
    pub(super) fn outer_ranges(&self, index: usize) -> Vec<Range<i32>> {
        let mut end = -1;
        self.closed_ranges(index)
            .into_iter()
            .filter(|r| {
                if r.start >= end {
                    end = r.end;
                    true
                } else {
                    false
                }
            })
            .collect()
    }
    pub(super) fn is_closed(&self, index: usize, region: &Region) -> bool {
        self.closed_keys[index]
            .borrow()
            .contains(&(region.characters.start as i32, region.characters.end as i32))
    }
    pub(super) fn set(&self, index: usize, region: &Region, collapsed: bool) {
        let range = region.characters.start as i32..region.characters.end as i32;
        if self.is_closed(index, region) == collapsed {
            return;
        }
        self.tag_dirty[index].set(true);
        if collapsed {
            let buffer = &self.buffers[index];
            let head = buffer.cursor_position();
            if head > range.start && head < range.end {
                buffer.place_cursor(&buffer.iter_at_offset(range.start));
            }
            self.closed[index]
                .borrow_mut()
                .push(Closed::new(buffer, range));
        } else {
            self.closed[index]
                .borrow_mut()
                .retain(|c| c.range() != range);
        }
    }
    pub(super) fn toggle(&self, index: usize, region: &Region, children: bool) {
        if !self.allowed() || !self.ready.get() {
            return;
        }
        let collapsed = !self.is_closed(index, region);
        let regions = if children {
            self.regions
                .borrow()
                .iter()
                .filter(|r| {
                    r.characters.start >= region.characters.start
                        && r.characters.end <= region.characters.end
                })
                .cloned()
                .collect::<Vec<_>>()
        } else {
            vec![region.clone()]
        };
        for region in regions.iter().rev() {
            self.set(index, region, collapsed);
        }
        self.render();
    }
    pub(crate) fn expand(&self, index: usize) {
        if !self.closed[index].borrow().is_empty() {
            self.tag_dirty[index].set(true);
            self.closed[index].borrow_mut().clear();
        }
        self.render();
    }
    pub(super) fn before_edit(&self, index: usize, edit: Range<i32>) {
        self.invalidate();
        let before = self.closed[index].borrow().len();
        self.closed[index].borrow_mut().retain(|closed| {
            let r = closed.range();
            if edit.is_empty() {
                !(r.start <= edit.start && edit.start <= r.end)
            } else {
                edit.start >= r.end || edit.end <= r.start
            }
        });
        if before != self.closed[index].borrow().len() {
            self.tag_dirty[index].set(true);
        }
        self.render();
    }
    pub(super) fn reveal(&self, index: usize) {
        if self.rendering.get() {
            return;
        }
        let buffer = &self.buffers[index];
        let a = buffer.cursor_position();
        let b = buffer.iter_at_mark(&buffer.selection_bound()).offset();
        let before = self.closed[index].borrow().len();
        self.closed[index].borrow_mut().retain(|c| {
            let r = c.range();
            !(r.start < a && a < r.end || r.start < b && b < r.end)
        });
        if before != self.closed[index].borrow().len() {
            self.tag_dirty[index].set(true);
            self.render();
        }
    }
    pub(crate) fn copy(&self, index: usize, cut: bool) -> bool {
        if self.closed[index].borrow().is_empty() {
            return false;
        }
        let Some(view) = self.views[index]
            .upgrade()
            .filter(|v| v.is_mapped() && v.is_sensitive())
        else {
            return false;
        };
        let buffer = &self.buffers[index];
        let Some((mut a, mut b)) = buffer.selection_bounds() else {
            return false;
        };
        if cut
            && (!view.is_editable()
                || self
                    .ui
                    .upgrade()
                    .zip(self.doc.upgrade())
                    .is_none_or(|(ui, doc)| !ui.source_edit_allowed(&doc)))
        {
            return true;
        }
        let text = buffer.text(&a, &b, true);
        view.clipboard().set_text(text.as_str());
        if cut {
            buffer.begin_user_action();
            buffer.delete(&mut a, &mut b);
            buffer.end_user_action();
        }
        true
    }
    pub(crate) fn reveal_delete(&self, index: usize, _count: i32) -> bool {
        if self.buffers[index].selection_bounds().is_some() {
            return false;
        }
        let caret = self.buffers[index].cursor_position();
        let before = self.closed[index].borrow().len();
        self.closed[index].borrow_mut().retain(|closed| {
            let r = closed.range();
            !(r.start <= caret && caret <= r.end)
        });
        let changed = before != self.closed[index].borrow().len();
        if changed {
            self.tag_dirty[index].set(true);
            self.render();
        }
        changed
    }
    pub(super) fn render(&self) {
        if self.rendering.replace(true) {
            return;
        }
        let allowed = self.allowed();
        for (index, buffer) in self.buffers.iter().enumerate() {
            if self.ready.get() {
                *self.closed_keys[index].borrow_mut() = self.closed[index]
                    .borrow()
                    .iter()
                    .map(|c| {
                        let r = c.range();
                        (r.start, r.end)
                    })
                    .collect();
            }
            if self.tag_dirty[index].replace(false) {
                let (a, b) = buffer.bounds();
                buffer.remove_tag(&self.tags[index], &a, &b);
                for range in self.outer_ranges(index) {
                    if range.start < range.end && range.end <= buffer.char_count() {
                        buffer.apply_tag(
                            &self.tags[index],
                            &buffer.iter_at_offset(range.start),
                            &buffer.iter_at_offset(range.end),
                        );
                    }
                }
            }
            if let Some(d) = &self.gutters.borrow()[index] {
                d.sync(self, index, allowed);
            }
            if let Some(view) = self.views[index].upgrade() {
                view.queue_draw();
            }
        }
        self.buttons[0]
            .set_sensitive(allowed && self.ready.get() && !self.regions.borrow().is_empty());
        self.buttons[1]
            .set_sensitive(allowed && self.ready.get() && !self.regions.borrow().is_empty());
        self.buttons[2].set_sensitive(allowed && !self.closed[self.index()].borrow().is_empty());
        self.rendering.set(false);
    }
    pub(super) fn at_line(&self, line: i32) -> Option<Region> {
        if !self.ready.get() || !self.allowed() {
            return None;
        }
        self.lines
            .borrow()
            .get(&line)
            .and_then(|i| self.regions.borrow().get(*i).cloned())
    }
}
pub(crate) fn expand_all(doc: &Document) {
    if let Some(f) = doc.syntax_folds.borrow().as_ref() {
        f.expand(0);
        f.expand(1);
    }
}
