use fastra_diff::{Cancellation, Comparison, RowKind};
use std::ops::Range;
#[derive(Clone)]
pub(super) struct Line {
    pub number: Option<usize>,
    pub display: Range<usize>,
    pub actual: Option<Range<usize>>,
    pub bytes: Range<usize>,
}
pub(super) struct Column {
    pub display: String,
    actual: String,
    pub lines: Vec<Line>,
    pub changed: Vec<Range<i32>>,
    pub gaps: Vec<Range<i32>>,
    pub emphasis: Vec<Range<i32>>,
}
fn append_span(spans: &mut Vec<Range<i32>>, range: Range<i32>) {
    if let Some(previous) = spans
        .last_mut()
        .filter(|previous| previous.end == range.start)
    {
        previous.end = range.end;
    } else {
        spans.push(range);
    }
}
impl Column {
    fn new() -> Self {
        Self {
            display: String::new(),
            actual: String::new(),
            lines: Vec::new(),
            changed: Vec::new(),
            gaps: Vec::new(),
            emphasis: Vec::new(),
        }
    }
    fn position(&self, offset: usize, next: bool) -> usize {
        if self.lines.is_empty() {
            return 0;
        }
        let index = self
            .lines
            .partition_point(|line| line.display.start <= offset)
            .saturating_sub(1);
        let line = &self.lines[index];
        if let Some(actual) = &line.actual {
            return actual.start + offset.saturating_sub(line.display.start).min(actual.len());
        }
        if next {
            self.lines[index + 1..]
                .iter()
                .find_map(|line| line.actual.as_ref().map(|r| r.start))
                .unwrap_or_else(|| self.actual.chars().count())
        } else {
            self.lines[..index]
                .iter()
                .rev()
                .find_map(|line| line.actual.as_ref().map(|r| r.end))
                .unwrap_or(0)
        }
    }
    pub fn copy(&self, selection: Range<usize>) -> String {
        if selection.is_empty() {
            return String::new();
        }
        let start = self.position(selection.start, true);
        let end = self.position(selection.end, false);
        if end <= start {
            return String::new();
        }
        self.actual.chars().skip(start).take(end - start).collect()
    }
    pub fn copy_visible(&self, selection: Range<usize>, hidden: &[Range<usize>]) -> String {
        if hidden.is_empty() {
            return self.copy(selection);
        }
        let mut output = String::new();
        let is_hidden = |index| {
            let at = hidden.partition_point(|range| range.end <= index);
            hidden.get(at).is_some_and(|range| range.contains(&index))
        };
        let last_visible = self
            .lines
            .iter()
            .enumerate()
            .rev()
            .find(|(index, line)| line.actual.is_some() && !is_hidden(*index))
            .map(|(index, _)| index);
        for (index, line) in self.lines.iter().enumerate() {
            if line.display.start >= selection.end {
                break;
            }
            if line.display.end < selection.start || line.actual.is_none() {
                continue;
            }
            if is_hidden(index) {
                continue;
            }
            let start = selection
                .start
                .saturating_sub(line.display.start)
                .min(line.display.len());
            let end = selection
                .end
                .saturating_sub(line.display.start)
                .min(line.display.len());
            output.extend(
                self.display[line.bytes.clone()]
                    .chars()
                    .skip(start)
                    .take(end - start),
            );
            if selection.start <= line.display.end
                && selection.end > line.display.end
                && last_visible.is_some_and(|last| index < last)
            {
                output.push('\n');
            }
        }
        output
    }
    fn insert_fold_controls(mut self, starts: &[usize]) -> Self {
        let positions = starts
            .iter()
            .map(|row| self.lines[*row].display.start)
            .collect::<Vec<_>>();
        let old = std::mem::take(&mut self.display);
        let mut next = starts.iter().copied().peekable();
        let mut lines = Vec::with_capacity(self.lines.len() + starts.len());
        let mut shift = 0;
        for (index, mut line) in std::mem::take(&mut self.lines).into_iter().enumerate() {
            if next.peek() == Some(&index) {
                let position = self.display.len();
                let offset = line.display.start + shift;
                lines.push(Line {
                    number: None,
                    display: offset..offset,
                    actual: None,
                    bytes: position..position,
                });
                self.display.push('\n');
                shift += 1;
                next.next();
            }
            let start = self.display.len();
            self.display.push_str(&old[line.bytes.clone()]);
            line.bytes = start..self.display.len();
            self.display.push('\n');
            line.display = line.display.start + shift..line.display.end + shift;
            lines.push(line);
        }
        self.lines = lines;
        for ranges in [&mut self.changed, &mut self.gaps, &mut self.emphasis] {
            for range in ranges {
                range.start +=
                    positions.partition_point(|position| *position <= range.start as usize) as i32;
                range.end +=
                    positions.partition_point(|position| *position < range.end as usize) as i32;
            }
        }
        self
    }
}
pub(super) struct Fold {
    pub control: usize,
    pub rows: Range<usize>,
}
pub(super) struct Presentation {
    pub columns: [Column; 2],
    pub blocks: Vec<Range<usize>>,
    pub line_counts: (usize, usize),
    pub options: fastra_diff::Options,
    pub annotated: bool,
    pub folds: Vec<Fold>,
}
impl Presentation {
    pub fn labels(&self, lang: super::Language) -> Vec<String> {
        self.blocks
            .iter()
            .map(|block| {
                let range = |side: usize| {
                    let mut numbers = self.columns[side].lines[block.clone()]
                        .iter()
                        .filter_map(|line| line.number);
                    numbers
                        .next()
                        .map(|first| (first, numbers.next_back().unwrap_or(first)))
                };
                super::result::block_label(range(0), range(1), lang)
            })
            .collect()
    }
    pub fn build(comparison: &Comparison, cancel: &Cancellation) -> Result<Self, String> {
        Self::build_inner(comparison, cancel, None)
    }
    pub fn build_exact(
        comparison: &Comparison,
        inputs: [&str; 2],
        cancel: &Cancellation,
    ) -> Result<Self, String> {
        let annotations = super::annotations::Annotations::build(comparison, inputs, cancel)?;
        Self::build_inner(comparison, cancel, Some(&annotations))
    }
    fn build_inner(
        comparison: &Comparison,
        cancel: &Cancellation,
        annotations: Option<&super::annotations::Annotations>,
    ) -> Result<Self, String> {
        let mut columns = [Column::new(), Column::new()];
        let mut offsets = [0usize; 2];
        let mut actual_offsets = [0usize; 2];
        let mut seen = [false; 2];
        for (index, row) in comparison.rows().iter().enumerate() {
            cancel.check().map_err(|e| e.to_string())?;
            let emphasis = if row.kind == RowKind::Changed {
                let left = row
                    .left_line
                    .and_then(|n| comparison.content(true, n))
                    .unwrap_or("");
                let right = row
                    .right_line
                    .and_then(|n| comparison.content(false, n))
                    .unwrap_or("");
                fastra_core::display::intraline_ranges(left, right).map_err(|e| e.to_string())?
            } else {
                Some([None, None])
            };
            for side in 0..2 {
                let column = &mut columns[side];
                let number = if side == 0 {
                    row.left_line
                } else {
                    row.right_line
                };
                let raw = number.and_then(|line| comparison.content(side == 0, line));
                let value = annotations.map_or(raw, |data| data.rows[index][side].as_deref());
                let start = offsets[side];
                let byte_start = column.display.len();
                let length = value.map_or(0, |text| text.chars().count());
                let actual = value.map(|text| {
                    if seen[side] {
                        column.actual.push('\n');
                        actual_offsets[side] += 1;
                    }
                    seen[side] = true;
                    let range = actual_offsets[side]..actual_offsets[side] + length;
                    column.actual.push_str(text);
                    actual_offsets[side] += length;
                    range
                });
                if let Some(text) = value {
                    column.display.push_str(text);
                }
                offsets[side] += length;
                let end = offsets[side];
                let byte_end = column.display.len();
                if value != raw && length > 0 {
                    column.emphasis.push(start as i32..end as i32);
                } else if let Some(range) = emphasis.as_ref().and_then(|spans| spans[side].as_ref())
                {
                    column
                        .emphasis
                        .push((start + range.start) as i32..(start + range.end) as i32);
                }
                column.display.push('\n');
                offsets[side] += 1;
                let span = start as i32..offsets[side] as i32;
                if number.is_none() {
                    append_span(&mut column.gaps, span);
                } else if annotations
                    .map_or(row.kind != RowKind::Unchanged, |data| data.changed[index])
                {
                    append_span(&mut column.changed, span);
                }
                column.lines.push(Line {
                    number,
                    display: start..end,
                    actual,
                    bytes: byte_start..byte_end,
                });
            }
        }
        let mut fold_rows = Vec::new();
        let mut index = 0;
        while index < comparison.rows().len() {
            let unchanged = |index: usize| {
                annotations.map_or(
                    comparison.rows()[index].kind == RowKind::Unchanged,
                    |data| !data.changed[index],
                )
            };
            if !unchanged(index) {
                index += 1;
                continue;
            }
            let start = index;
            while index < comparison.rows().len() && unchanged(index) {
                index += 1;
            }
            let first = start + if start == 0 { 0 } else { 3 };
            let last = index.saturating_sub(if index == comparison.rows().len() {
                0
            } else {
                3
            });
            if last >= first + 5 {
                fold_rows.push(first..last);
            }
        }
        let starts = fold_rows
            .iter()
            .map(|range| range.start)
            .collect::<Vec<_>>();
        let blocks: Vec<Range<usize>> = annotations.map_or_else(
            || {
                comparison
                    .blocks()
                    .iter()
                    .map(|block| block.rows.clone())
                    .collect()
            },
            |data| data.blocks.clone(),
        );
        Ok(Self {
            columns: columns.map(|column| column.insert_fold_controls(&starts)),
            line_counts: comparison.line_counts(),
            options: comparison.options(),
            annotated: annotations.is_some_and(|data| data.marked),
            blocks: blocks
                .into_iter()
                .map(|range| {
                    range.start + starts.partition_point(|start| *start <= range.start)
                        ..range.end + starts.partition_point(|start| *start < range.end)
                })
                .collect(),
            folds: fold_rows
                .into_iter()
                .enumerate()
                .map(|(index, range)| Fold {
                    control: range.start + index,
                    rows: range.start + index + 1..range.end + index + 1,
                })
                .collect(),
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn display(left: &str, right: &str) -> Presentation {
        let snap = |name: &str, text: &str| fastra_diff::TextSnapshot {
            document_id: name.into(),
            revision: 0,
            text: text.into(),
        };
        let cancel = Cancellation::default();
        let comparison = Comparison::compare(
            snap("left", left),
            snap("right", right),
            1,
            Default::default(),
            Default::default(),
            &cancel,
        )
        .unwrap();
        Presentation::build(&comparison, &cancel).unwrap()
    }
    #[test]
    fn copy_ignores_alignment_gaps_and_line_numbers_but_keeps_real_empty_lines() {
        let view = display("A😀\r\nend\r\n", "A😀\r\ninserted\r\nend\r\n");
        let left = &view.columns[0];
        assert_eq!(left.copy(0..left.display.chars().count()), "A😀\nend\n");
        let view = display("A\n\nB", "A\nnew\nB");
        let left = &view.columns[0];
        assert_eq!(left.copy(0..left.display.chars().count()), "A\n\nB");
    }
    #[test]
    fn native_scalar_selection_does_not_split_a_supplementary_character() {
        let view = display("A😀B", "changed");
        assert_eq!(view.columns[0].copy(1..2), "😀");
    }
    #[test]
    fn a_selected_spacer_contributes_no_text() {
        let view = display("a\nb", "a\ninserted\nb");
        let column = &view.columns[0];
        let spacer = column
            .lines
            .iter()
            .find(|line| line.number.is_none())
            .unwrap();
        assert_eq!(
            column.copy(spacer.display.start..spacer.display.start + 1),
            ""
        );
    }
    #[test]
    fn cancelled_presentation_has_no_partial_result() {
        let snap = |name: &str| fastra_diff::TextSnapshot {
            document_id: name.into(),
            revision: 0,
            text: "a\nb".into(),
        };
        let cancel = Cancellation::default();
        let c = Comparison::compare(
            snap("left"),
            snap("right"),
            1,
            Default::default(),
            Default::default(),
            &cancel,
        )
        .unwrap();
        cancel.cancel();
        assert!(Presentation::build(&c, &cancel).is_err());
    }
    #[test]
    fn context_folds_keep_three_adjacent_rows_and_copy_only_visible_real_lines() {
        let mut lines = (0..40)
            .map(|index| format!("line{index}"))
            .collect::<Vec<_>>();
        lines[20] = "old".into();
        let left = lines.join("\n");
        lines[20] = "new".into();
        let right = lines.join("\n");
        let view = display(&left, &right);
        assert_eq!(view.folds.len(), 2);
        let column = &view.columns[0];
        let all = 0..column.display.chars().count();
        assert_eq!(column.copy(all.clone()), left);
        let hidden = view
            .folds
            .iter()
            .map(|fold| fold.rows.clone())
            .collect::<Vec<_>>();
        assert_eq!(
            column.copy_visible(all.clone(), &hidden),
            "line17\nline18\nline19\nold\nline21\nline22\nline23"
        );
        assert_eq!(
            column.copy_visible(all, &hidden[1..]),
            (0..24)
                .map(|index| if index == 20 {
                    "old".into()
                } else {
                    format!("line{index}")
                })
                .collect::<Vec<_>>()
                .join("\n")
        );
        assert_eq!(column.lines[view.blocks[0].start].number, Some(21));
    }
}
