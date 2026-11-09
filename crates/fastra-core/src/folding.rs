//! Syntaxbereiche nach den Mac-Providern; keine Textänderungen oder GUI-Zustände.
use crate::{Cancellation, Error};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    ops::Range,
    time::{Duration, Instant},
};
#[cfg(feature = "syntax-folding")]
mod syntax;
#[cfg(test)]
mod tests;
pub const MAX_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_RANGES: usize = 10_000;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Region {
    pub bytes: Range<usize>,
    pub characters: Range<u32>,
    pub utf16: Range<u32>,
    pub depth: u16,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Failure {
    Cancelled,
    Limit,
    Unavailable,
}
impl From<Error> for Failure {
    fn from(error: Error) -> Self {
        if error == Error::Cancelled {
            Self::Cancelled
        } else {
            Self::Limit
        }
    }
}
type Result<T> = std::result::Result<T, Failure>;
struct Budget<'a> {
    cancel: &'a Cancellation,
    started: Instant,
}
impl Budget<'_> {
    fn check(&self) -> Result<()> {
        self.cancel.check()?;
        if self.started.elapsed() > Duration::from_secs(3) {
            Err(Failure::Limit)
        } else {
            Ok(())
        }
    }
}
/// Unechte Einrückungsbereiche sind kein Rückfall für fehlende Grammatikpakete.
pub fn regions(text: &str, language: &str, cancel: &Cancellation) -> Result<Vec<Region>> {
    let budget = Budget {
        cancel,
        started: Instant::now(),
    };
    budget.check()?;
    if text.len() > MAX_BYTES {
        return Err(Failure::Limit);
    }
    let ranges = if language == "fourD" {
        crate::four_d::folding::ranges(text, cancel)?
    } else {
        #[cfg(feature = "syntax-folding")]
        {
            syntax::ranges(text, language, &budget)?
        }
        #[cfg(not(feature = "syntax-folding"))]
        {
            return Err(Failure::Unavailable);
        }
    };
    normalize(text, ranges, &budget)
}
/// Pipe-Ergebnisse gegen Quelle und Positionssysteme prüfen, bevor sie GTK erreichen.
pub fn validate(text: &str, regions: &[Region], cancel: &Cancellation) -> Result<bool> {
    if text.len() > MAX_BYTES || regions.len() > MAX_RANGES {
        return Err(Failure::Limit);
    }
    let budget = Budget {
        cancel,
        started: Instant::now(),
    };
    Ok(normalize(
        text,
        regions.iter().map(|r| r.bytes.clone()).collect(),
        &budget,
    )? == regions)
}

fn normalize(
    text: &str,
    mut ranges: Vec<Range<usize>>,
    budget: &Budget<'_>,
) -> Result<Vec<Region>> {
    budget.check()?;
    if ranges.len() > MAX_RANGES {
        return Err(Failure::Limit);
    }
    if ranges.is_empty() {
        return Ok(Vec::new());
    }
    let mut endpoints = BTreeMap::new();
    for r in &ranges {
        if r.start >= r.end
            || r.end > text.len()
            || !text.is_char_boundary(r.start)
            || !text.is_char_boundary(r.end)
        {
            return Err(Failure::Unavailable);
        }
        endpoints.insert(r.start, (0u32, 0u32, 0u32));
        endpoints.insert(r.end, (0u32, 0u32, 0u32));
    }
    let (mut characters, mut utf16, mut breaks) = (0u32, 0u32, 0u32);
    let mut positions = endpoints.iter_mut().peekable();
    for (byte, c) in text.char_indices() {
        if characters & 1023 == 0 {
            budget.check()?;
        }
        if let Some((_, value)) = positions.next_if(|entry| *entry.0 == byte) {
            *value = (characters, utf16, breaks);
        }
        characters += 1;
        utf16 += c.len_utf16() as u32;
        breaks += u32::from(matches!(
            c,
            '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
        ));
    }
    if let Some((_, value)) = positions.next_if(|entry| *entry.0 == text.len()) {
        *value = (characters, utf16, breaks);
    }
    ranges.retain(|r| endpoints[&r.start].2 != endpoints[&r.end].2);
    ranges.sort_unstable_by(|a, b| a.start.cmp(&b.start).then_with(|| b.end.cmp(&a.end)));
    ranges.dedup();
    let mut stack: Vec<Range<usize>> = Vec::new();
    let mut result = Vec::new();
    for range in ranges {
        budget.check()?;
        while stack.last().is_some_and(|p| range.start >= p.end) {
            stack.pop();
        }
        if stack
            .last()
            .is_some_and(|p| range.start == p.start || range.end > p.end)
        {
            continue;
        }
        if stack.len() >= 512 {
            return Err(Failure::Limit);
        }
        let (a, u, _) = endpoints[&range.start];
        let (b, v, _) = endpoints[&range.end];
        result.push(Region {
            bytes: range.clone(),
            characters: a..b,
            utf16: u..v,
            depth: stack.len() as u16 + 1,
        });
        stack.push(range);
    }
    budget.check()?;
    Ok(result)
}
