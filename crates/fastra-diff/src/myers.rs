//! Port des vorhandenen Fastra-Myers-Diffs (Swift-Stdlib-Suchreihenfolge).
//! Lineare K-Vektoren; das gemeinsame Arbeitsbudget begrenzt auch schwierige Eingaben.
use crate::{Budget, Error};
use std::collections::HashMap;
#[derive(Clone, Copy)]
struct BoxArea {
    left: isize,
    top: isize,
    right: isize,
    bottom: isize,
}
impl BoxArea {
    fn width(self) -> isize {
        self.right - self.left
    }
    fn height(self) -> isize {
        self.bottom - self.top
    }
    fn size(self) -> isize {
        self.width() + self.height()
    }
    fn delta(self) -> isize {
        self.width() - self.height()
    }
    fn shrink(mut self, old: &[u32], new: &[u32], budget: &mut Budget<'_>) -> Result<Self, Error> {
        while self.left < self.right
            && self.top < self.bottom
            && old[self.left as usize] == new[self.top as usize]
        {
            budget.spend(1)?;
            self.left += 1;
            self.top += 1;
        }
        while self.right > self.left
            && self.bottom > self.top
            && old[(self.right - 1) as usize] == new[(self.bottom - 1) as usize]
        {
            budget.spend(1)?;
            self.right -= 1;
            self.bottom -= 1;
        }
        Ok(self)
    }
}
#[derive(Clone, Copy)]
enum Edit {
    Remove(usize),
    Insert(usize),
}
type Middle = (Option<Edit>, Option<BoxArea>);
struct Search {
    buffer: Vec<isize>,
    forward: isize,
    backward: isize,
}
impl Search {
    fn get(&self, backwards: bool, index: isize) -> isize {
        self.buffer[((if backwards {
            self.backward
        } else {
            self.forward
        }) + index) as usize]
    }
    fn set(&mut self, backwards: bool, index: isize, value: isize) {
        let index = (if backwards {
            self.backward
        } else {
            self.forward
        }) + index;
        self.buffer[index as usize] = value;
    }
    fn middle(
        &mut self,
        area: BoxArea,
        old: &[u32],
        new: &[u32],
        budget: &mut Budget<'_>,
    ) -> Result<(Option<Edit>, Option<BoxArea>), Error> {
        budget.spend(1)?;
        if area.size() <= 1 {
            return Ok((
                if area.size() == 0 {
                    None
                } else if area.width() == 1 {
                    Some(Edit::Remove(area.left as usize))
                } else {
                    Some(Edit::Insert(area.top as usize))
                },
                None,
            ));
        }
        self.set(false, 1, area.left);
        self.set(true, 1, area.bottom);
        let odd = area.delta() % 2 != 0;
        for depth in 0..=(area.size() + 1) / 2 {
            budget.spend(1)?;
            if odd {
                if let Some(found) = self.forward(area, depth, old, new, budget)? {
                    return Ok(found);
                }
                self.backward(area, depth, old, new, budget)?;
            } else {
                self.forward(area, depth, old, new, budget)?;
                if let Some(found) = self.backward(area, depth, old, new, budget)? {
                    return Ok(found);
                }
            }
        }
        Err(Error::Internal("middle snake not found"))
    }
    fn forward(
        &mut self,
        area: BoxArea,
        depth: isize,
        old: &[u32],
        new: &[u32],
        budget: &mut Budget<'_>,
    ) -> Result<Option<Middle>, Error> {
        let mut k = depth;
        while k >= -depth {
            budget.spend(1)?;
            let (mut right, left, mut bottom, insert, edit) =
                if k == -depth || k != depth && self.get(false, k - 1) < self.get(false, k + 1) {
                    let right = self.get(false, k + 1);
                    let bottom = area.top + right - area.left - k;
                    (right, right, bottom, true, bottom - 1)
                } else {
                    let left = self.get(false, k - 1);
                    let right = left + 1;
                    (right, left, area.top + right - area.left - k, false, left)
                };
            let top = if depth == 0 || right != left {
                bottom
            } else {
                bottom - 1
            };
            while right < area.right
                && bottom < area.bottom
                && old[right as usize] == new[bottom as usize]
            {
                budget.spend(1)?;
                right += 1;
                bottom += 1;
            }
            self.set(false, k, right);
            if area.delta() % 2 != 0 {
                let c = k - area.delta();
                if c >= -(depth - 1) && c < depth && bottom >= self.get(true, c) {
                    return Ok(Some((
                        Some(if insert {
                            Edit::Insert(edit as usize)
                        } else {
                            Edit::Remove(edit as usize)
                        }),
                        Some(BoxArea {
                            left,
                            top,
                            right,
                            bottom,
                        }),
                    )));
                }
            }
            k -= 2;
        }
        Ok(None)
    }
    fn backward(
        &mut self,
        area: BoxArea,
        depth: isize,
        old: &[u32],
        new: &[u32],
        budget: &mut Budget<'_>,
    ) -> Result<Option<Middle>, Error> {
        let mut c = depth;
        while c >= -depth {
            budget.spend(1)?;
            let k = c + area.delta();
            let (mut top, bottom, mut left, insert, edit) =
                if c == -depth || c != depth && self.get(true, c - 1) > self.get(true, c + 1) {
                    let top = self.get(true, c + 1);
                    let left = area.left + top - area.top + k;
                    (top, top, left, false, left)
                } else {
                    let bottom = self.get(true, c - 1);
                    let top = bottom - 1;
                    (top, bottom, area.left + top - area.top + k, true, top)
                };
            let right = if depth == 0 || top != bottom {
                left
            } else {
                left + 1
            };
            while left > area.left
                && top > area.top
                && old[(left - 1) as usize] == new[(top - 1) as usize]
            {
                budget.spend(1)?;
                left -= 1;
                top -= 1;
            }
            self.set(true, c, top);
            if area.delta() % 2 == 0 && k >= -depth && k <= depth && left <= self.get(false, k) {
                return Ok(Some((
                    Some(if insert {
                        Edit::Insert(edit as usize)
                    } else {
                        Edit::Remove(edit as usize)
                    }),
                    Some(BoxArea {
                        left,
                        top,
                        right,
                        bottom,
                    }),
                )));
            }
            c -= 2;
        }
        Ok(None)
    }
}
fn myers(
    old: &[u32],
    new: &[u32],
    budget: &mut Budget<'_>,
) -> Result<(Vec<usize>, Vec<usize>), Error> {
    let initial = BoxArea {
        left: 0,
        top: 0,
        right: old.len() as isize,
        bottom: new.len() as isize,
    }
    .shrink(old, new, budget)?;
    let size = initial.size() as usize;
    let mut search = Search {
        buffer: vec![0; (size * 2 + 1) * 2],
        forward: size as isize,
        backward: (size * 3 + 1) as isize,
    };
    let mut stack = Vec::new();
    let mut current = initial;
    let mut removed = Vec::new();
    let mut inserted = Vec::new();
    loop {
        let (edit, snake) = search.middle(current, old, new, budget)?;
        if let Some(edit) = edit {
            match edit {
                Edit::Remove(index) => removed.push(index),
                Edit::Insert(index) => inserted.push(index),
            }
        }
        if let Some(snake) = snake {
            let head = BoxArea {
                right: snake.left,
                bottom: snake.top,
                ..current
            }
            .shrink(old, new, budget)?;
            let tail = BoxArea {
                left: snake.right,
                top: snake.bottom,
                ..current
            }
            .shrink(old, new, budget)?;
            current = head;
            stack.push(tail);
        } else if let Some(next) = stack.pop() {
            current = next;
        } else {
            break;
        }
    }
    removed.sort_unstable();
    inserted.sort_unstable();
    Ok((removed, inserted))
}
fn anchors(
    old: &[u32],
    new: &[u32],
    budget: &mut Budget<'_>,
) -> Result<Vec<(usize, usize)>, Error> {
    fn unique(
        values: &[u32],
        budget: &mut Budget<'_>,
    ) -> Result<HashMap<u32, Option<usize>>, Error> {
        let mut result = HashMap::new();
        for (index, &value) in values.iter().enumerate() {
            budget.spend(1)?;
            result
                .entry(value)
                .and_modify(|v| *v = None)
                .or_insert(Some(index));
        }
        Ok(result)
    }
    let a = unique(old, budget)?;
    let b = unique(new, budget)?;
    let mut candidates = Vec::new();
    for (index, value) in old.iter().enumerate() {
        budget.spend(1)?;
        if a.get(value) == Some(&Some(index)) {
            if let Some(Some(other)) = b.get(value) {
                candidates.push((index, *other));
            }
        }
    }
    let mut tails: Vec<usize> = Vec::new();
    let mut predecessors = vec![None; candidates.len()];
    for (index, candidate) in candidates.iter().enumerate() {
        budget.spend(1)?;
        let mut lower = 0;
        let mut upper = tails.len();
        while lower < upper {
            budget.spend(1)?;
            let middle = lower + (upper - lower) / 2;
            if candidates[tails[middle]].1 < candidate.1 {
                lower = middle + 1;
            } else {
                upper = middle;
            }
        }
        if lower > 0 {
            predecessors[index] = Some(tails[lower - 1]);
        }
        if lower == tails.len() {
            tails.push(index);
        } else {
            tails[lower] = index;
        }
    }
    let mut result = Vec::new();
    let mut index = tails.last().copied();
    while let Some(current) = index {
        budget.spend(1)?;
        result.push(candidates[current]);
        index = predecessors[current];
    }
    result.reverse();
    Ok(result)
}
pub(crate) fn changes(
    old: &[u32],
    new: &[u32],
    max_gap: usize,
    budget: &mut Budget<'_>,
) -> Result<(Vec<usize>, Vec<usize>), Error> {
    if old.len() + new.len() <= max_gap {
        return myers(old, new, budget);
    }
    let mut anchors = anchors(old, new, budget)?;
    anchors.push((old.len(), new.len()));
    let mut old_start = 0;
    let mut new_start = 0;
    let mut removed = Vec::new();
    let mut inserted = Vec::new();
    for (old_end, new_end) in anchors {
        budget.spend(1)?;
        let area = BoxArea {
            left: old_start as isize,
            top: new_start as isize,
            right: old_end as isize,
            bottom: new_end as isize,
        }
        .shrink(old, new, budget)?;
        let a = area.left as usize..area.right as usize;
        let b = area.top as usize..area.bottom as usize;
        if a.is_empty() {
            inserted.extend(b);
        } else if b.is_empty() {
            removed.extend(a);
        } else {
            if a.len() + b.len() > max_gap {
                return Err(Error::Limit("unanchored diff range"));
            }
            let (r, i) = myers(&old[a.clone()], &new[b.clone()], budget)?;
            removed.extend(r.into_iter().map(|n| n + a.start));
            inserted.extend(i.into_iter().map(|n| n + b.start));
        }
        old_start = old_end + 1;
        new_start = new_end + 1;
    }
    Ok((removed, inserted))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancellation_enters_the_actual_search_before_stopping() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let entered = AtomicBool::new(false);
        let cancellation = crate::Cancellation::default();
        let a = vec![1; 14000];
        let b = vec![2; 14000];
        std::thread::scope(|scope| {
            let cancel = cancellation.clone();
            let entered = &entered;
            scope.spawn(move || {
                while !entered.load(Ordering::Acquire) {
                    std::thread::yield_now();
                }
                cancel.cancel();
            });
            let mut budget = Budget {
                remaining: 50_000_000,
                cancel: &cancellation,
                entered: Some(entered),
            };
            assert!(matches!(
                changes(&a, &b, 30_000, &mut budget),
                Err(Error::Cancelled)
            ));
        });
    }
}
