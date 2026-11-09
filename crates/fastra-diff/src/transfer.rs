use crate::{Cancellation, Comparison, Error, Line, TextSnapshot};
use std::{ops::Range, sync::Arc};
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    ToLeft,
    ToRight,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Utf16Range {
    pub location: usize,
    pub length: usize,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Replacement {
    pub bytes: Range<usize>,
    pub utf16: Utf16Range,
    pub text: String,
}
#[derive(Debug, Clone)]
pub struct TransferResult {
    pub text: String,
    pub replacements: Vec<Replacement>,
}
#[derive(Debug)]
pub struct TransferPlan {
    left: Arc<TextSnapshot>,
    right: Arc<TextSnapshot>,
    generation: u64,
    direction: Direction,
    output: String,
    replacements: Vec<Replacement>,
}
impl TransferPlan {
    pub fn output(&self) -> &str {
        &self.output
    }
    pub fn replacements(&self) -> &[Replacement] {
        &self.replacements
    }
    pub fn direction(&self) -> Direction {
        self.direction
    }
    /// Genau ein neuer Zieltext für einen gemeinsamen Host-Undo, keine Dateischreibvorgänge.
    pub fn apply(
        &self,
        left: &TextSnapshot,
        right: &TextSnapshot,
        generation: u64,
        cancel: &Cancellation,
    ) -> Result<TransferResult, Error> {
        cancel.check()?;
        if &*self.left != left || &*self.right != right || generation != self.generation {
            return Err(Error::Stale);
        }
        Ok(TransferResult {
            text: self.output.clone(),
            replacements: self.replacements.clone(),
        })
    }
}
impl Comparison {
    fn block_replacement(
        &self,
        block: usize,
        direction: Direction,
        cancel: &Cancellation,
    ) -> Result<Replacement, Error> {
        cancel.check()?;
        let block = self.blocks.get(block).ok_or(Error::InvalidBlock)?;
        let target_left = direction == Direction::ToLeft;
        let (target, source, target_lines, source_lines) = if target_left {
            (
                &self.left.text,
                &self.right.text,
                &self.left_lines,
                &self.right_lines,
            )
        } else {
            (
                &self.right.text,
                &self.left.text,
                &self.right_lines,
                &self.left_lines,
            )
        };
        let mut tn = Vec::new();
        let mut sn = Vec::new();
        for row in &self.rows[block.rows.clone()] {
            cancel.check()?;
            if let Some(number) = if target_left {
                row.left_line
            } else {
                row.right_line
            } {
                tn.push(number);
            }
            if let Some(number) = if target_left {
                row.right_line
            } else {
                row.left_line
            } {
                sn.push(number);
            }
        }
        let previous = &self.rows[..block.rows.start];
        let pt = previous
            .iter()
            .rev()
            .find_map(|r| {
                if target_left {
                    r.left_line
                } else {
                    r.right_line
                }
            })
            .unwrap_or(0);
        let ps = previous
            .iter()
            .rev()
            .find_map(|r| {
                if target_left {
                    r.right_line
                } else {
                    r.left_line
                }
            })
            .unwrap_or(0);
        fn raw(
            numbers: &[usize],
            lines: &[Line],
            previous: usize,
            text_len: usize,
        ) -> Range<usize> {
            if let (Some(first), Some(last)) = (numbers.first(), numbers.last()) {
                lines[*first - 1].content.start..lines[*last - 1].terminator.end
            } else {
                let location = lines.get(previous).map_or(text_len, |l| l.content.start);
                location..location
            }
        }
        let mut range = raw(&tn, target_lines, pt, target.len());
        let source_range = raw(&sn, source_lines, ps, source.len());
        let mut replacement = source[source_range].to_owned();
        let source_virtual = sn.len() == 1 && source_lines[sn[0] - 1].virtual_final;
        let target_virtual = tn.len() == 1 && target_lines[tn[0] - 1].virtual_final;
        if tn.is_empty() && source_virtual {
            let line = source_lines
                .get(sn[0].checked_sub(2).ok_or(Error::InvalidRange)?)
                .ok_or(Error::InvalidRange)?;
            replacement = source[line.terminator.clone()].to_owned();
        } else if sn.is_empty() && target_virtual {
            range = target_lines
                .get(tn[0].checked_sub(2).ok_or(Error::InvalidRange)?)
                .ok_or(Error::InvalidRange)?
                .terminator
                .clone();
        } else {
            if sn.is_empty()
                && range.end == target.len()
                && ps == source_lines.len()
                && ps > 0
                && source_lines[ps - 1].terminator.is_empty()
                && pt > 0
            {
                range.start = target_lines[pt - 1].terminator.start;
            }
            if !replacement.is_empty()
                && pt > 0
                && target_lines[pt - 1].terminator.is_empty()
                && target_lines[pt - 1].terminator.end == range.start
            {
                if let Some(first) = sn.first().filter(|&&n| n > 1) {
                    replacement = source[source_lines[*first - 2].terminator.clone()].to_owned()
                        + &replacement;
                }
            }
            if !replacement.is_empty() && range.end < target.len() {
                if let Some(&last) = sn.last() {
                    if !source_lines[last - 1].virtual_final
                        && source_lines[last - 1].terminator.is_empty()
                    {
                        let last = *tn.last().ok_or(Error::InvalidRange)?;
                        if target_lines[last - 1].terminator.is_empty() {
                            return Err(Error::InvalidRange);
                        }
                        replacement.push_str(&target[target_lines[last - 1].terminator.clone()]);
                    }
                }
            }
        }
        if range.start > range.end
            || range.end > target.len()
            || !target.is_char_boundary(range.start)
            || !target.is_char_boundary(range.end)
        {
            return Err(Error::InvalidRange);
        }
        fn unit_offset(lines: &[Line], byte: usize) -> Result<usize, Error> {
            let line = lines
                .get(
                    lines
                        .partition_point(|line| line.content.start <= byte)
                        .saturating_sub(1),
                )
                .ok_or(Error::InvalidRange)?;
            if byte == line.content.start {
                Ok(line.utf16_content.start)
            } else if byte == line.content.end {
                Ok(line.utf16_content.end)
            } else if byte == line.terminator.end {
                Ok(line.utf16_terminator.end)
            } else {
                Err(Error::InvalidRange)
            }
        }
        let location = unit_offset(target_lines, range.start)?;
        let end = unit_offset(target_lines, range.end)?;
        let utf16 = Utf16Range {
            location,
            length: end.checked_sub(location).ok_or(Error::InvalidRange)?,
        };
        Ok(Replacement {
            bytes: range,
            utf16,
            text: replacement,
        })
    }
    pub fn prepare_transfer(
        &self,
        left: &TextSnapshot,
        right: &TextSnapshot,
        generation: u64,
        blocks: &[usize],
        direction: Direction,
        cancel: &Cancellation,
    ) -> Result<TransferPlan, Error> {
        self.current(left, right, generation)?;
        cancel.check()?;
        if blocks.is_empty() {
            return Err(Error::NoChange);
        }
        let destination = if direction == Direction::ToLeft {
            &self.left.text
        } else {
            &self.right.text
        };
        let mut replacements = Vec::with_capacity(blocks.len().min(self.blocks.len()));
        let mut previous_block = None;
        for &id in blocks {
            cancel.check()?;
            if previous_block.is_some_and(|previous| previous >= id) {
                return Err(Error::InvalidBlock);
            }
            let change = self.block_replacement(id, direction, cancel)?;
            if let Some(previous) = replacements.last() {
                let previous: &Replacement = previous;
                if change.bytes.start < previous.bytes.end
                    || change.bytes.is_empty()
                        && previous.bytes.is_empty()
                        && change.bytes.start == previous.bytes.start
                {
                    return Err(Error::OverlappingBlocks);
                }
            }
            replacements.push(change);
            previous_block = Some(id);
        }
        let mut size = destination.len();
        for change in &replacements {
            size = size
                .checked_sub(change.bytes.len())
                .and_then(|n| n.checked_add(change.text.len()))
                .ok_or(Error::Limit("transfer output"))?;
        }
        if size > self.limits.max_output_bytes {
            return Err(Error::Limit("transfer output"));
        }
        let mut output = String::with_capacity(size);
        let mut cursor = 0;
        for change in &replacements {
            cancel.check()?;
            output.push_str(&destination[cursor..change.bytes.start]);
            output.push_str(&change.text);
            cursor = change.bytes.end;
        }
        output.push_str(&destination[cursor..]);
        if output == *destination {
            return Err(Error::NoChange);
        }
        Ok(TransferPlan {
            left: self.left.clone(),
            right: self.right.clone(),
            generation: self.generation,
            direction,
            output,
            replacements,
        })
    }
}
