//! Gemeinsamer, begrenzter Vergleichskern; Transfer liefert nur einen neuen Host-Text.
#[cfg(target_os = "linux")]
pub mod folder;
mod myers;
mod report;
use std::{
    collections::HashMap,
    ops::Range,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Cancelled,
    Limit(&'static str),
    Stale,
    InvalidBlock,
    OverlappingBlocks,
    InvalidRange,
    NoChange,
    Io(String),
    Internal(&'static str),
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
#[derive(Debug, Clone, Default)]
pub struct Cancellation(Arc<AtomicBool>);
impl Cancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
    pub fn check(&self) -> Result<(), Error> {
        if self.0.load(Ordering::Relaxed) {
            Err(Error::Cancelled)
        } else {
            Ok(())
        }
    }
}
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub max_text_bytes: usize,
    pub max_lines: usize,
    pub max_gap_lines: usize,
    pub max_work: u64,
    pub max_memory_bytes: usize,
    pub max_output_bytes: usize,
    pub max_report_bytes: usize,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            max_text_bytes: 32 * 1024 * 1024,
            max_lines: 200_000,
            max_gap_lines: 30_000,
            max_work: 50_000_000,
            max_memory_bytes: 512 * 1024 * 1024,
            max_output_bytes: 32 * 1024 * 1024,
            max_report_bytes: 64 * 1024 * 1024,
        }
    }
}
impl Limits {
    fn check(self) -> Result<(), Error> {
        let max = Self::default();
        if self.max_text_bytes > max.max_text_bytes
            || self.max_lines > max.max_lines
            || self.max_gap_lines > max.max_gap_lines
            || self.max_work > max.max_work
            || self.max_memory_bytes > max.max_memory_bytes
            || self.max_output_bytes > max.max_output_bytes
            || self.max_report_bytes > max.max_report_bytes
        {
            return Err(Error::Limit("invalid diff limits"));
        }
        Ok(())
    }
}
pub(crate) struct Budget<'a> {
    remaining: u64,
    cancel: &'a Cancellation,
    #[cfg(test)]
    entered: Option<&'a AtomicBool>,
}
impl Budget<'_> {
    fn spend(&mut self, work: u64) -> Result<(), Error> {
        #[cfg(test)]
        if let Some(entered) = self.entered {
            entered.store(true, Ordering::Release);
        }
        self.cancel.check()?;
        self.remaining = self
            .remaining
            .checked_sub(work)
            .ok_or(Error::Limit("diff work"))?;
        Ok(())
    }
}
#[derive(Debug, Clone, Copy, Default)]
pub struct Options {
    pub ignore_trailing_whitespace: bool,
    pub ignore_all_whitespace: bool,
    pub ignore_blank_lines: bool,
    pub ignore_case: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextSnapshot {
    pub document_id: String,
    pub revision: u64,
    pub text: String,
}
#[derive(Debug, Clone)]
struct Line {
    content: Range<usize>,
    terminator: Range<usize>,
    virtual_final: bool,
    utf16_content: Range<usize>,
    utf16_terminator: Range<usize>,
}
fn lines(text: &str, limits: Limits, budget: &mut Budget<'_>) -> Result<Vec<Line>, Error> {
    if text.len() > limits.max_text_bytes {
        return Err(Error::Limit("text bytes"));
    }
    let mut result = Vec::new();
    let mut start = 0;
    let mut unit = 0;
    let mut unit_start = 0;
    let mut iterator = text.char_indices().peekable();
    while let Some((offset, c)) = iterator.next() {
        budget.spend(1)?;
        let content_end_unit = unit;
        unit += c.len_utf16();
        if matches!(c, '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}') {
            if result.len() >= limits.max_lines
                || result.len().saturating_add(1).saturating_mul(384) > limits.max_memory_bytes
            {
                return Err(Error::Limit("line count"));
            }
            let mut end = offset + c.len_utf8();
            if c == '\r' && iterator.peek().is_some_and(|(_, next)| *next == '\n') {
                iterator.next();
                end += 1;
                unit += 1;
            }
            result.push(Line {
                content: start..offset,
                terminator: offset..end,
                virtual_final: false,
                utf16_content: unit_start..content_end_unit,
                utf16_terminator: content_end_unit..unit,
            });
            start = end;
            unit_start = unit;
        }
    }
    if result.len() >= limits.max_lines
        || result.len().saturating_add(1).saturating_mul(384) > limits.max_memory_bytes
    {
        return Err(Error::Limit("line count or memory"));
    }
    result.push(Line {
        content: start..text.len(),
        terminator: text.len()..text.len(),
        virtual_final: !text.is_empty() && start == text.len(),
        utf16_content: unit_start..unit,
        utf16_terminator: unit..unit,
    });
    Ok(result)
}
fn key(
    line: &str,
    options: Options,
    budget: &mut Budget<'_>,
    max_bytes: usize,
) -> Result<String, Error> {
    let mut filtered = String::new();
    let input = if options.ignore_trailing_whitespace && !options.ignore_all_whitespace {
        line.trim_end_matches(char::is_whitespace)
    } else {
        line
    };
    for c in input.chars() {
        budget.spend(1)?;
        if !options.ignore_all_whitespace || !c.is_whitespace() {
            filtered.push(c);
        }
    }
    let filtered = if options.ignore_case {
        let mut lower = String::new();
        for c in filtered.chars() {
            budget.spend(1)?;
            for mapped in c.to_lowercase() {
                if lower
                    .len()
                    .checked_add(mapped.len_utf8())
                    .filter(|n| *n <= max_bytes)
                    .is_none()
                {
                    return Err(Error::Limit("case key bytes"));
                }
                lower.push(mapped);
            }
        }
        lower
    } else {
        filtered
    };
    // Die Bibliothek sortiert einen Nichtstarter-Lauf intern in einem Schritt.
    // Vorher begrenzen, damit auch dieser Schritt kurz und speicherbegrenzt bleibt.
    let mut combining_run = 0usize;
    for c in filtered.chars() {
        budget.spend(1)?;
        unicode_normalization::char::decompose_canonical(c, |decomposed| {
            if unicode_normalization::char::canonical_combining_class(decomposed) == 0 {
                combining_run = 0;
            } else {
                combining_run += 1;
            }
        });
        if combining_run > 4096 {
            return Err(Error::Limit("normalization combining run"));
        }
    }
    let mut result = String::new();
    for c in filtered.nfc() {
        budget.spend(1)?;
        if result
            .len()
            .checked_add(c.len_utf8())
            .filter(|n| *n <= max_bytes)
            .is_none()
        {
            return Err(Error::Limit("comparison key bytes"));
        }
        result.push(c);
    }
    Ok(result)
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowKind {
    Unchanged,
    Changed,
    Removed,
    Added,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub id: usize,
    /// Zeilennummern beginnen bei 1, wie im Editor.
    pub left_line: Option<usize>,
    pub right_line: Option<usize>,
    pub kind: RowKind,
    pub ignored_blank: bool,
    pub terminators_differ: bool,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockKind {
    Changed,
    OnlyLeft,
    OnlyRight,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    pub id: usize,
    pub rows: Range<usize>,
    pub kind: BlockKind,
}
type EncodedLines = (Vec<u32>, Vec<usize>, Vec<bool>);
#[derive(Debug)]
pub struct Comparison {
    left: Arc<TextSnapshot>,
    right: Arc<TextSnapshot>,
    generation: u64,
    left_lines: Vec<Line>,
    right_lines: Vec<Line>,
    rows: Vec<Row>,
    blocks: Vec<Block>,
    limits: Limits,
    options: Options,
}
impl Comparison {
    pub fn compare(
        left: TextSnapshot,
        right: TextSnapshot,
        generation: u64,
        options: Options,
        limits: Limits,
        cancel: &Cancellation,
    ) -> Result<Self, Error> {
        cancel.check()?;
        limits.check()?;
        if left.document_id.is_empty()
            || right.document_id.is_empty()
            || left.document_id.len() > 4096
            || right.document_id.len() > 4096
        {
            return Err(Error::Limit("source identifier"));
        }
        let mut budget = Budget {
            remaining: limits.max_work,
            cancel,
            #[cfg(test)]
            entered: None,
        };
        let left_lines = lines(&left.text, limits, &mut budget)?;
        let right_lines = lines(&right.text, limits, &mut budget)?;
        let count = left_lines
            .len()
            .checked_add(right_lines.len())
            .ok_or(Error::Limit("line count"))?;
        // Konservative Vorabgrenze für Kopien, Schlüssel, Maps, Suchvektoren, Rows und Blöcke.
        let estimate = left
            .text
            .len()
            .checked_add(right.text.len())
            .and_then(|n| n.checked_mul(8))
            .and_then(|n| count.checked_mul(384).and_then(|m| n.checked_add(m)))
            .ok_or(Error::Limit("diff memory"))?;
        if estimate > limits.max_memory_bytes {
            return Err(Error::Limit("diff memory"));
        }
        let mut aliases: HashMap<String, u32> = HashMap::new();
        let mut key_bytes = 0usize;
        let mut encode =
            |text: &str, lines: &[Line], budget: &mut Budget<'_>| -> Result<EncodedLines, Error> {
                let mut ids = Vec::new();
                let mut indexes = Vec::new();
                let mut blank = Vec::with_capacity(lines.len());
                for (index, line) in lines.iter().enumerate() {
                    budget.spend(1)?;
                    let content = &text[line.content.clone()];
                    let is_blank = content.chars().all(char::is_whitespace);
                    blank.push(is_blank);
                    if options.ignore_blank_lines && is_blank {
                        continue;
                    }
                    let key = key(
                        content,
                        options,
                        budget,
                        limits.max_memory_bytes.saturating_sub(key_bytes),
                    )?;
                    let id = if let Some(id) = aliases.get(&key) {
                        *id
                    } else {
                        let id =
                            u32::try_from(aliases.len()).map_err(|_| Error::Limit("key count"))?;
                        key_bytes = key_bytes
                            .checked_add(key.len())
                            .ok_or(Error::Limit("key bytes"))?;
                        aliases.insert(key, id);
                        id
                    };
                    ids.push(id);
                    indexes.push(index);
                }
                Ok((ids, indexes, blank))
            };
        let (a, ai, ablank) = encode(&left.text, &left_lines, &mut budget)?;
        let (b, bi, bblank) = encode(&right.text, &right_lines, &mut budget)?;
        let mut prefix = 0;
        while prefix < a.len().min(b.len()) && a[prefix] == b[prefix] {
            budget.spend(1)?;
            prefix += 1;
        }
        let mut suffix = 0;
        while suffix < a.len().min(b.len()) - prefix
            && a[a.len() - 1 - suffix] == b[b.len() - 1 - suffix]
        {
            budget.spend(1)?;
            suffix += 1;
        }
        let (removed, inserted) = myers::changes(
            &a[prefix..a.len() - suffix],
            &b[prefix..b.len() - suffix],
            limits.max_gap_lines,
            &mut budget,
        )?;
        let mut r = vec![false; left_lines.len()];
        let mut ins = vec![false; right_lines.len()];
        for offset in removed {
            budget.spend(1)?;
            *r.get_mut(ai[prefix + offset])
                .ok_or(Error::Internal("removed offset"))? = true;
        }
        for offset in inserted {
            budget.spend(1)?;
            *ins.get_mut(bi[prefix + offset])
                .ok_or(Error::Internal("inserted offset"))? = true;
        }
        let mut rows = Vec::with_capacity(count);
        let (mut i, mut j) = (0, 0);
        let mut append = |i: Option<usize>, j: Option<usize>, kind, ignored| {
            let terminators_differ = match (i, j) {
                (Some(i), Some(j)) => {
                    left.text[left_lines[i].terminator.clone()]
                        != right.text[right_lines[j].terminator.clone()]
                }
                _ => false,
            };
            rows.push(Row {
                id: rows.len(),
                left_line: i.map(|n| n + 1),
                right_line: j.map(|n| n + 1),
                kind,
                ignored_blank: ignored,
                terminators_differ,
            });
        };
        while i < left_lines.len() || j < right_lines.len() {
            budget.spend(1)?;
            if options.ignore_blank_lines && i < left_lines.len() && ablank[i] {
                if j < right_lines.len() && bblank[j] {
                    append(Some(i), Some(j), RowKind::Unchanged, true);
                    i += 1;
                    j += 1;
                } else {
                    append(Some(i), None, RowKind::Unchanged, true);
                    i += 1;
                }
                continue;
            }
            if options.ignore_blank_lines && j < right_lines.len() && bblank[j] {
                append(None, Some(j), RowKind::Unchanged, true);
                j += 1;
                continue;
            }
            let mut nr = 0;
            while i + nr < r.len() && r[i + nr] {
                budget.spend(1)?;
                nr += 1;
            }
            let mut ni = 0;
            while j + ni < ins.len() && ins[j + ni] {
                budget.spend(1)?;
                ni += 1;
            }
            if nr == 0 && ni == 0 {
                if i >= left_lines.len() || j >= right_lines.len() {
                    return Err(Error::Internal("unmatched alignment tail"));
                }
                append(Some(i), Some(j), RowKind::Unchanged, false);
                i += 1;
                j += 1;
            } else {
                for n in 0..nr.max(ni) {
                    budget.spend(1)?;
                    append(
                        (n < nr).then_some(i + n),
                        (n < ni).then_some(j + n),
                        if n < nr && n < ni {
                            RowKind::Changed
                        } else if n < nr {
                            RowKind::Removed
                        } else {
                            RowKind::Added
                        },
                        false,
                    );
                }
                i += nr;
                j += ni;
            }
        }
        let mut blocks = Vec::new();
        let mut start = None;
        for index in 0..=rows.len() {
            budget.spend(1)?;
            if index < rows.len() && rows[index].kind != RowKind::Unchanged {
                start.get_or_insert(index);
            } else if let Some(first) = start.take() {
                let all_left = rows[first..index]
                    .iter()
                    .all(|r| r.kind == RowKind::Removed);
                let all_right = rows[first..index].iter().all(|r| r.kind == RowKind::Added);
                blocks.push(Block {
                    id: blocks.len(),
                    rows: first..index,
                    kind: if all_left {
                        BlockKind::OnlyLeft
                    } else if all_right {
                        BlockKind::OnlyRight
                    } else {
                        BlockKind::Changed
                    },
                });
            }
        }
        Ok(Self {
            left: Arc::new(left),
            right: Arc::new(right),
            generation,
            left_lines,
            right_lines,
            rows,
            blocks,
            limits,
            options,
        })
    }
    pub fn options(&self) -> Options {
        self.options
    }
    pub fn rows(&self) -> &[Row] {
        &self.rows
    }
    pub fn blocks(&self) -> &[Block] {
        &self.blocks
    }
    pub fn line_counts(&self) -> (usize, usize) {
        (self.left_lines.len(), self.right_lines.len())
    }
    pub fn byte_identical(&self) -> bool {
        self.left.text == self.right.text
    }
    pub fn content(&self, left: bool, number: usize) -> Option<&str> {
        if left {
            self.left_lines
                .get(number.checked_sub(1)?)
                .map(|l| &self.left.text[l.content.clone()])
        } else {
            self.right_lines
                .get(number.checked_sub(1)?)
                .map(|l| &self.right.text[l.content.clone()])
        }
    }
    fn current(
        &self,
        left: &TextSnapshot,
        right: &TextSnapshot,
        generation: u64,
    ) -> Result<(), Error> {
        if &*self.left != left || &*self.right != right || self.generation != generation {
            Err(Error::Stale)
        } else {
            Ok(())
        }
    }
}
mod transfer;
pub use transfer::{Direction, Replacement, TransferPlan, TransferResult, Utf16Range};
