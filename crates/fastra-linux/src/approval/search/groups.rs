use super::*;
use fastra_core::{regex_groups, Utf16Range};
fn snapshot(surface: &Surface) -> Option<Arc<search_pattern::Snapshot>> {
    let ui = surface.ui.upgrade()?;
    let model = ui.search_pattern.borrow().clone()?;
    model.snapshot().filter(|s| {
        s.mode == 2
            && ui.mode.selected() == 2
            && s.text == ui.find.text()
            && s.syntax.as_ref().is_some_and(|syntax| !syntax.has_errors)
    })
}
fn active(surface: &Surface) -> Option<(Arc<Preview>, usize, String)> {
    let pane = surface.pane.upgrade()?;
    let Row::Match {
        item,
        hit,
        start,
        end,
        ..
    } = surface
        .rows
        .borrow()
        .get(surface.selected.get()?)
        .cloned()?
    else {
        return None;
    };
    let preview = pane.items.borrow().get(item)?.preview.clone();
    let text = preview.source().get(start..end)?.to_string();
    Some((preview, hit, text))
}
pub(super) fn refresh(surface: &Surface) {
    let state = snapshot(surface);
    if let Some(ui) = surface.ui.upgrade() {
        let error = ui
            .search_pattern
            .borrow()
            .as_ref()
            .and_then(|model| model.error());
        surface
            .define_group
            .set_tooltip_text(Some(error.as_deref().unwrap_or(ui.lang.text(
                "Markierten Text an RegEx-Bausteingrenzen gruppieren.",
                "Group selected text at regex element boundaries.",
            ))));
        surface
            .remove_group
            .set_tooltip_text(Some(error.as_deref().unwrap_or(ui.lang.text(
                "Die markierte Gruppe ohne Bedeutungsänderung auflösen.",
                "Ungroup the selected capture without changing its meaning.",
            ))));
    }

    let has_match = active(surface).is_some_and(|(_, _, text)| {
        surface.detail.buffer().char_count() as usize == text.chars().count()
    });
    let ready = state.is_some() && !surface.group_busy.get();
    surface
        .define_group
        .set_sensitive(ready && surface.available() && has_match);
    surface.remove_group.set_sensitive(
        ready
            && state
                .as_ref()
                .is_some_and(|s| !s.syntax.as_ref().unwrap().groups.is_empty())
            && (surface.selected.get().is_none() || !surface.available() || has_match),
    );
}
pub(super) fn connect(surface: &Rc<Surface>) {
    for (button, remove) in [
        (&surface.define_group, false),
        (&surface.remove_group, true),
    ] {
        let weak = Rc::downgrade(surface);
        button.connect_clicked(move |_| {
            if let Some(surface) = weak.upgrade() {
                run(&surface, remove);
            }
        });
    }
}
fn intersects(a: Utf16Range, b: Utf16Range) -> bool {
    if b.length == 0 {
        a.location <= b.location && b.location <= a.location + a.length
    } else {
        a.location < b.location + b.length && b.location < a.location + a.length
    }
}
fn run(surface: &Rc<Surface>, remove: bool) {
    if (!surface.available() && !remove) || surface.group_busy.get() {
        return;
    }
    let Some(snapshot) = snapshot(surface) else {
        return;
    };
    let Some(ui) = surface.ui.upgrade() else {
        return;
    };
    if !source_panes::focused_is(&ui, &surface._owner) {
        return;
    }
    let active = surface.available().then(|| active(surface)).flatten();
    let text = active
        .as_ref()
        .map(|(_, _, t)| t.clone())
        .unwrap_or_default();
    let buffer = surface.detail.buffer();
    let (a, b) = buffer
        .selection_bounds()
        .map(|(a, b)| (a.offset(), b.offset()))
        .unwrap_or_else(|| {
            let n = buffer.cursor_position();
            (n, n)
        });
    let lo = text
        .chars()
        .take(a.max(0) as usize)
        .map(char::len_utf16)
        .sum::<usize>();
    let hi = text
        .chars()
        .take(b.max(0) as usize)
        .map(char::len_utf16)
        .sum::<usize>();
    let original_selection = (a, b);
    let selection = Utf16Range {
        location: lo,
        length: hi.saturating_sub(lo),
    };
    let syntax = snapshot.syntax.as_ref().unwrap();
    let number = active
        .as_ref()
        .and_then(|(preview, hit, _)| {
            let hit = &preview.matches()[*hit];
            hit.captures
                .iter()
                .enumerate()
                .skip(1)
                .filter_map(|(n, r)| {
                    r.and_then(|r| {
                        let location = r.location.checked_sub(hit.range.location)?;
                        let range = Utf16Range {
                            location,
                            length: r.length,
                        };
                        (range.length > 0 && intersects(range, selection)).then_some(n)
                    })
                })
                .next()
        })
        .or_else(|| syntax.groups.last().map(|g| g.number));
    if !remove && active.is_none() {
        return;
    }
    let replacement = ui.replace.text().to_string();
    let original = replacement.clone();
    let pattern = snapshot.text.clone();
    let case = ui.case.is_active();
    let generation = surface.generation.get();
    let ticket = surface.detail_generation.get();
    surface.group_cancel.borrow().cancel();
    let cancel = Cancellation::default();
    *surface.group_cancel.borrow_mut() = cancel.clone();
    let current = cancel.clone();
    let weak = Rc::downgrade(surface);
    let lang = ui.lang;
    surface.group_busy.set(true);
    refresh(surface);
    git_view::background(
        move || {
            if remove {
                let Some(number) = number else {
                    return Ok(None);
                };
                regex_groups::remove(
                    number,
                    &snapshot.text,
                    snapshot.syntax.as_ref().unwrap(),
                    &replacement,
                    &cancel,
                )
                .map(|r| r.map(|r| (r.pattern, r.replacement)))
                .map_err(|e| error_text(lang, &e))
            } else {
                regex_groups::propose(
                    selection,
                    &snapshot.text,
                    snapshot.syntax.as_ref().unwrap(),
                    &text,
                    &replacement,
                    case,
                    &cancel,
                )
                .map(|r| r.map(|r| (r.pattern, r.replacement)))
                .map_err(|e| error_text(lang, &e))
            }
        },
        move |result| {
            let Some(s) = weak.upgrade().filter(|s| {
                s.generation.get() == generation && s.detail_generation.get() == ticket
            }) else {
                return;
            };
            s.group_busy.set(false);
            refresh(&s);
            let Some(ui) = s.ui.upgrade().filter(|ui| {
                current.check().is_ok()
                    && (s.available() || remove)
                    && s._owner.is_visible()
                    && source_panes::focused_is(ui, &s._owner)
                    && ui.mode.selected() == 2
                    && ui.find.text() == pattern
                    && ui.replace.text() == original
                    && ui.case.is_active() == case
                    && s.detail
                        .buffer()
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset()))
                        .unwrap_or_else(|| {
                            let at = s.detail.buffer().cursor_position();
                            (at, at)
                        })
                        == original_selection
            }) else {
                return;
            };
            match result {
                Ok(Some((pattern, replacement))) => {
                    ui.find.set_text(&pattern);
                    ui.replace.set_text(&replacement);
                }
                Ok(None) => {
                    s.navigation_message.set_text(ui.lang.text("Die Auswahl lässt sich nicht ohne Bedeutungsänderung gruppieren oder auflösen. Rückverweise, Quantifizierer, Alternativen und verwendete Ersetzungsgruppen prüfen.","This selection cannot be grouped or ungrouped without changing its meaning. Check backreferences, quantifiers, alternatives and referenced replacement groups."));
                    s.navigation_message.set_visible(true);
                }
                Err(error) => {
                    s.navigation_message.set_text(&error);
                    s.navigation_message.set_visible(true);
                }
            }
        },
    );
}
type ColorSpan = (i32, i32, usize);
fn color_plan(
    text: &str,
    base: usize,
    captures: &[(usize, Utf16Range)],
    cancel: &Cancellation,
) -> Result<Vec<ColorSpan>, fastra_core::Error> {
    use std::collections::BTreeSet;
    cancel.check()?;
    let mut positions = vec![None; text.encode_utf16().count() + 1];
    let mut at = 0;
    for (index, c) in text.chars().enumerate() {
        positions[at] = Some(index as i32);
        at += c.len_utf16();
        positions[at] = Some(index as i32 + 1);
    }
    let mut events = Vec::with_capacity(captures.len() * 2);
    for &(index, range) in captures {
        let Some(lo) = range.location.checked_sub(base) else {
            continue;
        };
        let Some(hi) = lo.checked_add(range.length) else {
            continue;
        };
        if range.length == 0
            || hi >= positions.len()
            || positions[lo].is_none()
            || positions[hi].is_none()
        {
            continue;
        }
        events.push((lo, true, index));
        events.push((hi, false, index));
    }
    events.sort_unstable();
    let mut active = BTreeSet::new();
    let mut cursor = 0;
    let mut spans = Vec::<ColorSpan>::new();
    for (position, begin, index) in events {
        cancel.check()?;
        if let Some(&color) = active.last().filter(|_| position > cursor) {
            let lo = positions[cursor].unwrap();
            let hi = positions[position].unwrap();
            let color = color % 3;
            if let Some(last) = spans
                .last_mut()
                .filter(|last| last.1 == lo && last.2 == color)
            {
                last.1 = hi;
            } else {
                spans.push((lo, hi, color));
            }
        }
        cursor = position;
        if begin {
            active.insert(index);
        } else {
            active.remove(&index);
        }
    }
    Ok(spans)
}
pub(super) fn color_captures(surface: &Surface, preview: &Preview, hit: usize) {
    let Some(hit) = preview.matches().get(hit) else {
        return;
    };
    let Some(text) = hit
        .range
        .byte_range(preview.source())
        .ok()
        .and_then(|range| preview.source().get(range))
    else {
        return;
    };
    let text = text.to_string();
    let base = hit.range.location;
    let captures = hit
        .captures
        .iter()
        .enumerate()
        .skip(1)
        .filter_map(|(index, range)| range.map(|range| (index - 1, range)))
        .collect::<Vec<_>>();
    if captures.is_empty() {
        return;
    }
    let Some(pane) = surface.pane.upgrade() else {
        return;
    };
    let Some(weak) = pane.search.borrow().as_ref().map(Rc::downgrade) else {
        return;
    };
    let generation = surface.generation.get();
    let ticket = surface.detail_generation.get();
    let cancel = surface.navigation_cancel.borrow().clone();
    git_view::background(
        move || color_plan(&text, base, &captures, &cancel).map_err(|e| e.to_string()),
        move |result| {
            let Ok(spans) = result else {
                return;
            };
            let Some(surface) = weak.upgrade().filter(|s| {
                s.generation.get() == generation && s.detail_generation.get() == ticket
            }) else {
                return;
            };
            let buffer = surface.detail.buffer();
            let table = buffer.tag_table();
            let tags = (0..3)
                .map(|index| {
                    let name = format!("capture-color-{index}");
                    table.lookup(&name).unwrap_or_else(|| {
                        let tag = gtk::TextTag::builder()
                            .name(&name)
                            .background_rgba(&search_pattern::capture_color(index))
                            .build();
                        table.add(&tag);
                        tag
                    })
                })
                .collect::<Vec<_>>();
            let mut spans = spans.into_iter();
            glib::idle_add_local(move || {
                if !weak.upgrade().is_some_and(|s| {
                    s.generation.get() == generation && s.detail_generation.get() == ticket
                }) {
                    return glib::ControlFlow::Break;
                }
                for _ in 0..64 {
                    let Some((lo, hi, color)) = spans.next() else {
                        return glib::ControlFlow::Break;
                    };
                    buffer.apply_tag(
                        &tags[color],
                        &buffer.iter_at_offset(lo),
                        &buffer.iter_at_offset(hi),
                    );
                }
                glib::ControlFlow::Continue
            });
        },
    );
}
#[cfg(test)]
mod color_tests {
    use super::*;
    #[test]
    fn nested_captures_follow_group_order_and_utf16_emoji_positions() {
        let ranges = [
            (
                0,
                Utf16Range {
                    location: 10,
                    length: 5,
                },
            ),
            (
                1,
                Utf16Range {
                    location: 12,
                    length: 2,
                },
            ),
            (
                2,
                Utf16Range {
                    location: 13,
                    length: 1,
                },
            ),
        ];
        assert_eq!(
            color_plan("🙂abc", 10, &ranges, &Cancellation::default()).unwrap(),
            [(0, 1, 0), (1, 2, 1), (2, 3, 2), (3, 4, 0)]
        );
    }
    #[test]
    fn more_than_thirty_captures_remain_colored_and_cancel_is_observed() {
        let ranges = (0..33)
            .map(|n| {
                (
                    n,
                    Utf16Range {
                        location: n,
                        length: 1,
                    },
                )
            })
            .collect::<Vec<_>>();
        let spans = color_plan(&"a".repeat(33), 0, &ranges, &Cancellation::default()).unwrap();
        assert_eq!(spans.len(), 33);
        assert_eq!(spans.last(), Some(&(32, 33, 2)));
        let cancel = Cancellation::default();
        cancel.cancel();
        assert_eq!(
            color_plan("a", 0, &ranges, &cancel),
            Err(fastra_core::Error::Cancelled)
        );
    }
}
