//! Gemeinsame Fachlogik; keine GUI, Dateischreibvorgänge oder stillen Fallbacks.
pub mod batch;
pub mod code_explanation;
pub mod display;
pub mod encoding;
pub mod folding;
pub mod example_transformation;
pub mod hit_extraction;
pub mod go_to_target;
mod icu;
pub mod markdown_formatting;
pub mod navigation;
pub mod navigation_anchor;
pub mod regex_groups;
pub mod inline_preview;
pub mod template;
pub mod text_operations;
pub mod text_statistics;
pub mod wildcard;
pub mod xpath;

use serde::{Deserialize, Serialize};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Error {
    Regex { code: i32, offset: i32 },
    Engine(i32),
    Cancelled,
    Limit,
    InvalidRange,
    Stale,
    InvalidApproval,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}

#[derive(Clone, Default)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Utf16Range {
    pub location: usize,
    pub length: usize,
}

impl Utf16Range {
    pub fn end(self) -> Result<usize, Error> {
        self.location
            .checked_add(self.length)
            .ok_or(Error::InvalidRange)
    }
    pub fn byte_range(self, text: &str) -> Result<std::ops::Range<usize>, Error> {
        let end = self.end()?;
        let mut unit = 0;
        let mut start_byte = None;
        let mut end_byte = None;
        for (byte, c) in text
            .char_indices()
            .chain(std::iter::once((text.len(), '\0')))
        {
            if unit == self.location {
                start_byte = Some(byte);
            }
            if unit == end {
                end_byte = Some(byte);
                break;
            }
            unit += c.len_utf16();
        }
        match (start_byte, end_byte) {
            (Some(a), Some(b)) if a <= b => Ok(a..b),
            _ => Err(Error::InvalidRange),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SearchMode {
    Literal,
    Wildcard,
    Regex,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchRequest {
    pub pattern: String,
    pub replacement: String,
    pub mode: SearchMode,
    pub case_sensitive: bool,
    pub range: Option<Utf16Range>,
}

#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub max_matches: usize,
    pub max_text_bytes: usize,
    pub max_output_bytes: usize,
    pub regex_time_ms: i32,
    pub regex_stack_bytes: i32,
}
impl Limits {
    /// Begrenztes Profil für interaktive Textbefehle; Ein- und Ausgabe bleiben bei 4 MiB.
    pub fn interactive_text_operations() -> Self {
        Self {
            max_text_bytes: 4 * 1024 * 1024,
            max_output_bytes: 4 * 1024 * 1024,
            ..Self::default()
        }
    }
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            max_matches: 100_000,
            max_text_bytes: 32 * 1024 * 1024,
            max_output_bytes: 64 * 1024 * 1024,
            regex_time_ms: 100,
            regex_stack_bytes: 1024 * 1024,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Match {
    pub range: Utf16Range,
    pub captures: Vec<Option<Utf16Range>>,
    pub replacement: String,
}

#[derive(Debug)]
pub struct Preview {
    source: String,
    revision: u64,
    generation: u64,
    matches: Vec<Match>,
    max_output_bytes: usize,
}
impl Preview {
    pub fn matches(&self) -> &[Match] {
        &self.matches
    }
    pub fn source(&self) -> &str {
        &self.source
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn apply(
        &self,
        current: &str,
        revision: u64,
        generation: u64,
        approved: &[usize],
        cancel: &Cancellation,
    ) -> Result<String, Error> {
        cancel.check()?;
        if current != self.source || revision != self.revision || generation != self.generation {
            return Err(Error::Stale);
        }
        let mut previous = None;
        let mut output = String::new();
        let mut cursor = 0;
        let mut unit_cursor = 0;
        for &index in approved {
            cancel.check()?;
            if previous.is_some_and(|p| p >= index) {
                return Err(Error::InvalidApproval);
            }
            let hit = self.matches.get(index).ok_or(Error::InvalidApproval)?;
            let location = hit
                .range
                .location
                .checked_sub(unit_cursor)
                .ok_or(Error::InvalidApproval)?;
            let relative = Utf16Range {
                location,
                length: hit.range.length,
            }
            .byte_range(&current[cursor..])?;
            let bytes = relative.start + cursor..relative.end + cursor;
            let addition = bytes.start - cursor + hit.replacement.len();
            if output
                .len()
                .checked_add(addition)
                .filter(|n| *n <= self.max_output_bytes)
                .is_none()
            {
                return Err(Error::Limit);
            }
            output.push_str(&current[cursor..bytes.start]);
            output.push_str(&hit.replacement);
            cursor = bytes.end;
            unit_cursor = hit.range.end()?;
            previous = Some(index);
        }
        if output
            .len()
            .checked_add(current.len() - cursor)
            .filter(|n| *n <= self.max_output_bytes)
            .is_none()
        {
            return Err(Error::Limit);
        }
        output.push_str(&current[cursor..]);
        cancel.check()?;
        Ok(output)
    }
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct SearchFlags {
    pub whole_word: bool,
}

/// Auf der Such-Queue erzeugen und dort für mehrere Dokumente wiederverwenden.
/// ICU kopiert nur den Matcherzustand; das kompilierte Muster wird geteilt.
pub struct PreparedSearch {
    prototype: Option<icu::Regex>,
    pieces: Vec<template::Piece>,
    range: Option<Utf16Range>,
    limits: Limits,
    cancel: Cancellation,
}
impl PreparedSearch {
    pub fn new(
        request: &SearchRequest,
        flags: SearchFlags,
        limits: Limits,
        cancel: &Cancellation,
    ) -> Result<Self, Error> {
        cancel.check()?;
        if request.pattern.len() > limits.max_text_bytes.min(1024 * 1024)
            || request.replacement.len() > limits.max_output_bytes
        {
            return Err(Error::Limit);
        }
        if request.pattern.is_empty() {
            return Ok(Self {
                prototype: None,
                pieces: Vec::new(),
                range: request.range,
                limits,
                cancel: cancel.clone(),
            });
        }
        let (pattern, replacement) = match request.mode {
            SearchMode::Regex => (request.pattern.clone(), request.replacement.clone()),
            SearchMode::Literal => (
                wildcard::escape_pattern(&request.pattern),
                wildcard::escape_template(&request.replacement),
            ),
            SearchMode::Wildcard => {
                let compiled = wildcard::compile_find(&request.pattern)?;
                // Ohne wirkliche Stern-Gruppe bleibt auch der Ersetzungstext literal.
                let replacement = if compiled.star_offsets.is_empty() {
                    wildcard::escape_template(&request.replacement)
                } else {
                    wildcard::compile_replace(
                        &request.replacement,
                        Some(compiled.star_offsets.len()),
                    )?
                };
                (compiled.regex_pattern, replacement)
            }
        };
        let wrapped = if flags.whole_word {
            format!(r"\b(?:{pattern})\b")
        } else {
            pattern.clone()
        };
        let prototype = match icu::Regex::new(&wrapped, "", request.case_sensitive, limits, cancel)
        {
            Ok(regex) => regex,
            Err(error) if flags.whole_word && request.mode == SearchMode::Regex => {
                // Nur ein gültiges Original darf den Kommentarabschluss erhalten.
                // Ohne aktives x würde ein Zeilenumbruch den Suchtext verändern.
                icu::Regex::new(&pattern, "", request.case_sensitive, limits, cancel)?;
                let terminated = format!("\\b(?:{pattern}\n)\\b");
                icu::Regex::new(&terminated, "", request.case_sensitive, limits, cancel)
                    .map_err(|_| error)?
            }
            Err(error) => return Err(error),
        };
        Ok(Self {
            prototype: Some(prototype),
            pieces: template::pieces(&replacement)?,
            range: request.range,
            limits,
            cancel: cancel.clone(),
        })
    }

    pub fn preview(&self, text: &str, revision: u64, generation: u64) -> Result<Preview, Error> {
        self.cancel.check()?;
        if text.len() > self.limits.max_text_bytes {
            return Err(Error::Limit);
        }
        let Some(prototype) = &self.prototype else {
            return Ok(Preview {
                source: text.to_owned(),
                revision,
                generation,
                matches: Vec::new(),
                max_output_bytes: self.limits.max_output_bytes,
            });
        };
        let (search_text, base) = if let Some(range) = self.range {
            (&text[range.byte_range(text)?], range.location)
        } else {
            (text, 0)
        };
        // Der Textausschnitt erzwingt Foundations opake Auswahlgrenze auch
        // bei ICU-Optimierungen, die trotz opaker Region außen lesen würden.
        let mut engine = prototype.with_text(search_text)?;
        let mut matches = Vec::new();
        let mut replacement_bytes = 0usize;
        let mut capture_ranges = 0usize;
        while let Some(mut captures) = engine.next()? {
            self.cancel.check()?;
            if matches.len() >= self.limits.max_matches {
                return Err(Error::Limit);
            }
            capture_ranges = capture_ranges
                .checked_add(captures.len())
                .ok_or(Error::Limit)?;
            if capture_ranges > 1_000_000 {
                return Err(Error::Limit);
            }
            let replacement = template::replacement(
                &self.pieces,
                engine.text_units(),
                &captures,
                self.limits.max_output_bytes,
            )?;
            replacement_bytes = replacement_bytes
                .checked_add(replacement.len())
                .ok_or(Error::Limit)?;
            if replacement_bytes > self.limits.max_output_bytes {
                return Err(Error::Limit);
            }
            for range in captures.iter_mut().flatten() {
                range.location = range
                    .location
                    .checked_add(base)
                    .ok_or(Error::InvalidRange)?;
            }
            matches.push(Match {
                range: captures[0].ok_or(Error::InvalidRange)?,
                captures,
                replacement,
            });
        }
        Ok(Preview {
            source: text.to_owned(),
            revision,
            generation,
            matches,
            max_output_bytes: self.limits.max_output_bytes,
        })
    }
}

pub fn preview(
    text: &str,
    revision: u64,
    generation: u64,
    request: &SearchRequest,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Preview, Error> {
    PreparedSearch::new(request, SearchFlags::default(), limits, cancel)?
        .preview(text, revision, generation)
}

pub mod four_d;

pub mod four_d_completion;
pub mod four_d_macros;

pub mod local_control;

pub(crate) mod json_integer;
