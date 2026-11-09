//! Pure Textbefehle mit UTF-16-Auswahl; keine Editor- oder Dateizugriffe.
use crate::{icu, Cancellation, Error, Limits, Utf16Range};
use std::{
    collections::{HashMap, HashSet},
    ffi::{c_char, c_void, CString},
    ptr::NonNull,
};

mod characters;
mod escapes;
mod transpose;
mod whitespace;

#[derive(Debug, Clone, Copy)]
pub struct IndentOptions {
    pub uses_tabs: bool,
    pub indent_width: usize,
    pub tab_width: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextResult {
    pub text: String,
    /// Ersetzter Bereich im ursprünglichen Text.
    pub affected_range: Utf16Range,
    pub line_count: usize,
}
/// Deterministische ICU-Root-Kollation, unabhängig von der Host-Locale.
#[derive(Debug, Clone, Copy)]
pub struct RootSortOptions {
    pub descending: bool,
    pub numeric: bool,
    pub case_sensitive: bool,
}
impl Default for RootSortOptions {
    fn default() -> Self {
        Self {
            descending: false,
            numeric: true,
            case_sensitive: false,
        }
    }
}
#[derive(Debug, Clone, Copy)]
pub enum DuplicateMode {
    KeepFirst,
    KeepDuplicates,
    RemoveAllDuplicates,
}
#[derive(Debug, Clone)]
pub enum LineOperation {
    SortRoot(RootSortOptions),
    Duplicates(DuplicateMode),
    Reverse,
    RemoveBlank,
    TrimTrailingWhitespace,
    Detab {
        tab_width: usize,
    },
    Entab {
        tab_width: usize,
    },
    ShiftRight(IndentOptions),
    ShiftLeft(IndentOptions),
    HardWrap {
        column: usize,
    },
    Prefix(String),
    Suffix(String),
    Join(String),
    AddNumbers,
    RemoveNumbers,
    Filter {
        pattern: String,
        keep_matching: bool,
        case_sensitive: bool,
    },
}
#[derive(Debug, Clone, Copy)]
pub enum CharacterOperation {
    UppercaseRoot,
    LowercaseRoot,
    NormalizeSpaces,
    ZapGremlins,
    Nfc,
    Nfd,
    StraightenQuotes,
    EducateQuotes,
    ConvertEscapes,
    StripDiacriticals,
    AddEmojiPresentation,
    RemoveEmojiPresentation,
    ExchangeCharacters,
    ExchangeWords,
    FourDDetokenize,
    FourDTokenizeCommands,
}

// Die C-Schicht kapselt ICU-Typen, Konstanten und versionierte Symbole.
unsafe extern "C" {
    fn fastra_scalar_flags(scalar: i32) -> u32;
    fn fastra_combining_class(scalar: i32) -> i32;
    fn fastra_normalize(
        source: *const u16,
        length: i32,
        dest: *mut u16,
        capacity: i32,
        nfc: i32,
        status: *mut i32,
    ) -> i32;
    fn fastra_collator_open(numeric: i32, case_sensitive: i32, status: *mut i32) -> *mut c_void;
    fn fastra_localized_collator_open(locale: *const c_char, status: *mut i32) -> *mut c_void;
    fn fastra_collator_close(collator: *mut c_void);
    fn fastra_collator_key(
        collator: *const c_void,
        source: *const u16,
        length: i32,
        result: *mut u8,
        capacity: i32,
    ) -> i32;
}
fn scalar_flags(c: char) -> u32 {
    if c.is_ascii() {
        return u32::from(c.is_ascii_alphanumeric() || c == '_');
    }
    unsafe { fastra_scalar_flags(c as i32) }
}
fn canonical_eq(a: &str, b: &str, limit: usize, cancel: &Cancellation) -> Result<bool, Error> {
    if a == b {
        return Ok(true);
    }
    cancel.check()?;
    let a = normalized(a, true, limit)?;
    cancel.check()?;
    Ok(a == normalized(b, true, limit)?)
}
fn status_ok(status: i32) -> Result<(), Error> {
    if status > 0 {
        Err(Error::Engine(status))
    } else {
        Ok(())
    }
}
fn i32_len(length: usize) -> Result<i32, Error> {
    i32::try_from(length).map_err(|_| Error::Limit)
}
fn normalized(text: &str, nfc: bool, limit: usize) -> Result<String, Error> {
    if text.is_empty() {
        return Ok(String::new());
    }
    let mut status = 0;
    let input: Vec<u16> = text.encode_utf16().collect();
    let required = unsafe {
        fastra_normalize(
            input.as_ptr(),
            i32_len(input.len())?,
            std::ptr::null_mut(),
            0,
            i32::from(nfc),
            &mut status,
        )
    };
    if status != 15 {
        status_ok(status)?;
    }
    let size = usize::try_from(required).map_err(|_| Error::Limit)?;
    if size > limit {
        return Err(Error::Limit);
    }
    let mut output = vec![0; size];
    status = 0;
    let written = unsafe {
        fastra_normalize(
            input.as_ptr(),
            i32_len(input.len())?,
            output.as_mut_ptr(),
            i32_len(size)?,
            i32::from(nfc),
            &mut status,
        )
    };
    status_ok(status)?;
    let written = usize::try_from(written).map_err(|_| Error::InvalidRange)?;
    if written > output.len() {
        return Err(Error::InvalidRange);
    }
    let output = String::from_utf16(&output[..written]).map_err(|_| Error::InvalidRange)?;
    if output.len() > limit {
        return Err(Error::Limit);
    }
    Ok(output)
}
struct Collator(NonNull<c_void>);
impl Drop for Collator {
    fn drop(&mut self) {
        unsafe {
            fastra_collator_close(self.0.as_ptr());
        }
    }
}
impl Collator {
    fn new(options: RootSortOptions) -> Result<Self, Error> {
        let mut status = 0;
        let pointer = unsafe {
            fastra_collator_open(
                i32::from(options.numeric),
                i32::from(options.case_sensitive),
                &mut status,
            )
        };
        status_ok(status)?;
        let collator = Self(NonNull::new(pointer).ok_or(Error::Engine(1))?);
        Ok(collator)
    }
    fn localized(locale: &TitlecaseLocale) -> Result<Self, Error> {
        let locale = CString::new(locale.as_str()).map_err(|_| Error::InvalidRange)?;
        let mut status = 0;
        let pointer = unsafe { fastra_localized_collator_open(locale.as_ptr(), &mut status) };
        status_ok(status)?;
        Ok(Self(NonNull::new(pointer).ok_or(Error::Engine(1))?))
    }
    fn key(&self, text: &str, remaining: usize) -> Result<Vec<u8>, Error> {
        let text: Vec<u16> = text.encode_utf16().collect();
        let size = unsafe {
            fastra_collator_key(
                self.0.as_ptr(),
                text.as_ptr(),
                i32_len(text.len())?,
                std::ptr::null_mut(),
                0,
            )
        };
        let size = usize::try_from(size).map_err(|_| Error::Limit)?;
        if size == 0 || size > remaining {
            return Err(Error::Limit);
        }
        let mut key = vec![0; size];
        let written = unsafe {
            fastra_collator_key(
                self.0.as_ptr(),
                text.as_ptr(),
                i32_len(text.len())?,
                key.as_mut_ptr(),
                i32_len(size)?,
            )
        };
        if written != size as i32 {
            return Err(Error::InvalidRange);
        }
        Ok(key)
    }
}

/// Ohne Auswahl gilt das ganze Dokument; sonst werden berührte Zeilen erweitert.
/// Der letzte Trenner bleibt bei einer Auswahl außerhalb des ersetzten Bereichs.
pub fn full_line_range(text: &str, selection: Utf16Range) -> Result<Utf16Range, Error> {
    let total = text.encode_utf16().count();
    if selection.length == 0 {
        return Ok(Utf16Range {
            location: 0,
            length: total,
        });
    }
    let end = selection.end()?.min(total);
    let start = selection.location.min(total);
    let safe = Utf16Range {
        location: start,
        length: end.saturating_sub(start),
    };
    let selected = safe.byte_range(text)?;
    let last_position = selected
        .end
        .saturating_sub(usize::from(selected.end > selected.start));
    let mut first_start = None;
    let mut line_start = 0;
    let bytes = text.as_bytes();
    let mut cursor = 0;
    let end;
    loop {
        while cursor < bytes.len() && !matches!(bytes[cursor], b'\r' | b'\n') {
            cursor += 1;
        }
        let content_end = cursor;
        if cursor < bytes.len() {
            cursor += if bytes[cursor] == b'\r' && bytes.get(cursor + 1) == Some(&b'\n') {
                2
            } else {
                1
            };
        }
        let unterminated_final_line =
            cursor == text.len() && content_end == cursor && content_end > line_start;
        if first_start.is_none()
            && (selected.start < cursor
                || line_start == text.len()
                || unterminated_final_line && selected.start == cursor)
        {
            first_start = Some(line_start);
        }
        if last_position < cursor
            || cursor == text.len() && (line_start == cursor || unterminated_final_line)
        {
            end = content_end;
            break;
        }
        line_start = cursor;
    }
    let start = first_start.ok_or(Error::InvalidRange)?;
    Ok(Utf16Range {
        location: text[..start].encode_utf16().count(),
        length: text[start..end].encode_utf16().count(),
    })
}
fn separator(text: &str) -> &str {
    if text.contains("\r\n") {
        "\r\n"
    } else if text.contains('\r') {
        "\r"
    } else {
        "\n"
    }
}
fn split_lines(text: &str, max_lines: usize, cancel: &Cancellation) -> Result<Vec<String>, Error> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut cursor = 0;
    let bytes = text.as_bytes();
    loop {
        cancel.check()?;
        while cursor < bytes.len() && !matches!(bytes[cursor], b'\r' | b'\n') {
            cursor += 1;
        }
        // Ein zusätzlicher Eintrag kann das abschließende Datei-Newline sein.
        if lines.len() > max_lines {
            return Err(Error::Limit);
        }
        lines.push(text[start..cursor].to_owned());
        if cursor == bytes.len() {
            break;
        }
        cursor += if bytes[cursor] == b'\r' && bytes.get(cursor + 1) == Some(&b'\n') {
            2
        } else {
            1
        };
        start = cursor;
    }
    Ok(lines)
}
fn finish(
    text: &str,
    range: Utf16Range,
    replacement: String,
    count: usize,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    cancel.check()?;
    let bytes = range.byte_range(text)?;
    if text[bytes.clone()] == replacement {
        return Ok(None);
    }
    let size = text
        .len()
        .checked_sub(bytes.len())
        .and_then(|n| n.checked_add(replacement.len()))
        .ok_or(Error::Limit)?;
    if size > limits.max_output_bytes {
        return Err(Error::Limit);
    }
    let mut output = String::with_capacity(size);
    output.push_str(&text[..bytes.start]);
    output.push_str(&replacement);
    output.push_str(&text[bytes.end..]);
    Ok(Some(TextResult {
        text: output,
        affected_range: range,
        line_count: count,
    }))
}
fn push_bounded(output: &mut String, value: &str, limit: usize) -> Result<(), Error> {
    if output
        .len()
        .checked_add(value.len())
        .filter(|size| *size <= limit)
        .is_none()
    {
        return Err(Error::Limit);
    }
    output.push_str(value);
    Ok(())
}

/// Stabile ICU-Sortierung nach dem expliziten Textlocale-Snapshot.
/// Numerisch, normalisiert, case-sensitiv und Kleinbuchstaben zuerst;
/// Satzzeichen zählen mit. Gleiche Schlüssel behalten ihre Eingabereihenfolge.
pub fn sort_lines_with_locale(
    text: &str,
    selection: Utf16Range,
    descending: bool,
    locale: &TitlecaseLocale,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    transform_lines_inner(
        text,
        selection,
        &LineOperation::SortRoot(RootSortOptions {
            descending,
            ..RootSortOptions::default()
        }),
        Some(locale),
        limits,
        cancel,
    )
}

pub fn transform_lines(
    text: &str,
    selection: Utf16Range,
    operation: &LineOperation,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    transform_lines_inner(text, selection, operation, None, limits, cancel)
}

fn transform_lines_inner(
    text: &str,
    selection: Utf16Range,
    operation: &LineOperation,
    sort_locale: Option<&TitlecaseLocale>,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    cancel.check()?;
    if text.len() > limits.max_text_bytes {
        return Err(Error::Limit);
    }
    if text.is_empty() {
        return Ok(None);
    }
    if matches!(operation, LineOperation::HardWrap { column: 0 }) {
        return Ok(None);
    }
    let range = full_line_range(text, selection)?;
    let block = &text[range.byte_range(text)?];
    let mut lines = split_lines(block, limits.max_matches, cancel)?;
    let final_separator = (selection.length == 0
        || matches!(operation, LineOperation::Filter { .. }))
        && lines.len() > 1
        && lines.last().is_some_and(String::is_empty);
    if final_separator {
        lines.pop();
    }
    if lines.len() > limits.max_matches {
        return Err(Error::Limit);
    }
    let mut joiner = separator(text);
    let mut preserve_final = final_separator;
    match operation {
        LineOperation::SortRoot(options) => {
            if lines.len() < 2 {
                return Ok(None);
            }
            let collator = match sort_locale {
                Some(locale) => Collator::localized(locale)?,
                None => Collator::new(*options)?,
            };
            let mut budget = limits.max_output_bytes;
            let mut keyed = Vec::with_capacity(lines.len());
            for line in lines {
                cancel.check()?;
                let key = collator.key(&line, budget)?;
                budget -= key.len();
                keyed.push((key, line));
            }
            keyed.sort_by(|a, b| {
                let order = a.0.cmp(&b.0);
                if options.descending {
                    order.reverse()
                } else {
                    order
                }
            });
            lines = keyed.into_iter().map(|(_, line)| line).collect();
        }
        LineOperation::Duplicates(mode) => {
            if lines.len() < 2 {
                return Ok(None);
            }
            let mut counts = HashMap::new();
            let mut keys = Vec::with_capacity(lines.len());
            // Swift-String-Gleichheit ist kanonisch äquivalent, nicht bytegleich.
            for line in &lines {
                cancel.check()?;
                let key = normalized(line, true, limits.max_output_bytes)?;
                *counts.entry(key.clone()).or_insert(0usize) += 1;
                keys.push(key);
            }
            let mut seen = HashSet::new();
            lines = lines
                .into_iter()
                .zip(keys)
                .filter_map(|(line, key)| {
                    let count = counts[&key];
                    let keep = match mode {
                        DuplicateMode::KeepFirst => seen.insert(key),
                        DuplicateMode::KeepDuplicates => count > 1 && seen.insert(key),
                        DuplicateMode::RemoveAllDuplicates => count == 1,
                    };
                    keep.then_some(line)
                })
                .collect();
            if lines.is_empty() {
                return Ok(None);
            }
        }
        LineOperation::Detab { .. }
        | LineOperation::Entab { .. }
        | LineOperation::ShiftRight(_)
        | LineOperation::ShiftLeft(_)
        | LineOperation::HardWrap { .. } => {
            lines = whitespace::transform(&lines, operation, separator(text), limits, cancel)?;
        }
        LineOperation::Reverse => {
            if lines.len() < 2 {
                return Ok(None);
            }
            lines.reverse();
        }
        LineOperation::RemoveBlank => {
            lines.retain(|line| !line.chars().all(is_horizontal_space));
        }
        LineOperation::TrimTrailingWhitespace => {
            for line in &mut lines {
                cancel.check()?;
                line.truncate(line.trim_end_matches([' ', '\t']).len());
            }
        }
        LineOperation::Prefix(prefix) | LineOperation::Suffix(prefix) => {
            if prefix.is_empty() {
                return Ok(None);
            }
            let growth = prefix
                .len()
                .checked_mul(lines.len())
                .and_then(|n| n.checked_add(block.len()))
                .ok_or(Error::Limit)?;
            if growth > limits.max_output_bytes {
                return Err(Error::Limit);
            }
            for line in &mut lines {
                cancel.check()?;
                *line = if matches!(operation, LineOperation::Prefix(_)) {
                    format!("{prefix}{line}")
                } else {
                    format!("{line}{prefix}")
                };
            }
        }
        LineOperation::Join(value) => {
            if lines.len() < 2 {
                return Ok(None);
            }
            joiner = value;
            preserve_final = false;
        }
        LineOperation::AddNumbers => {
            let width = lines.len().to_string().len();
            let growth = (width + 1)
                .checked_mul(lines.len())
                .and_then(|n| n.checked_add(block.len()))
                .ok_or(Error::Limit)?;
            if growth > limits.max_output_bytes {
                return Err(Error::Limit);
            }
            for (index, line) in lines.iter_mut().enumerate() {
                cancel.check()?;
                *line = format!("{:>width$} {line}", index + 1);
            }
        }
        LineOperation::RemoveNumbers => {
            for line in &mut lines {
                cancel.check()?;
                let spaces = line.bytes().take_while(|b| *b == b' ').count();
                let digits = line[spaces..]
                    .bytes()
                    .take_while(u8::is_ascii_digit)
                    .count();
                if digits > 0 {
                    let mut end = spaces + digits;
                    if line.as_bytes().get(end) == Some(&b' ') {
                        end += 1;
                    }
                    line.drain(..end);
                }
            }
        }
        LineOperation::Filter {
            pattern,
            keep_matching,
            case_sensitive,
        } => {
            if pattern.is_empty() {
                return Ok(None);
            }
            if pattern.len() > limits.max_text_bytes {
                return Err(Error::Limit);
            }
            let regex = icu::Regex::new(pattern, "", *case_sensitive, limits, cancel)?;
            let mut kept = Vec::new();
            for line in lines {
                cancel.check()?;
                let matches = regex.with_text(&line)?.next()?.is_some();
                if matches == *keep_matching {
                    kept.push(line);
                }
            }
            // Wie der Mac-Menübefehl: Ein Filter darf nicht den gesamten Inhalt unbemerkt leeren.
            if kept.is_empty() {
                return Ok(None);
            }
            lines = kept;
        }
    }
    let mut output = String::new();
    for (index, line) in lines.iter().enumerate() {
        cancel.check()?;
        if index > 0 {
            push_bounded(&mut output, joiner, limits.max_output_bytes)?;
        }
        push_bounded(&mut output, line, limits.max_output_bytes)?;
    }
    if preserve_final && !lines.is_empty() {
        push_bounded(&mut output, separator(text), limits.max_output_bytes)?;
    }
    let count = if matches!(operation, LineOperation::Join(_)) {
        1
    } else {
        lines.len()
    };
    finish(text, range, output, count, limits, cancel)
}
fn is_horizontal_space(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}
fn is_space_separator(c: char) -> bool {
    is_horizontal_space(c) && c != '\t'
}

pub fn transform_characters(
    text: &str,
    selection: Utf16Range,
    operation: CharacterOperation,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    cancel.check()?;
    if text.len() > limits.max_text_bytes {
        return Err(Error::Limit);
    }
    if text.is_empty() {
        return Ok(None);
    }
    if matches!(
        operation,
        CharacterOperation::ExchangeCharacters | CharacterOperation::ExchangeWords
    ) {
        return transpose::transform(text, selection, operation, limits, cancel);
    }
    let total = text.encode_utf16().count();
    let mut range = if selection.length == 0 {
        Utf16Range {
            location: 0,
            length: total,
        }
    } else {
        let end = selection.end()?.min(total);
        let start = selection.location.min(total);
        Utf16Range {
            location: start,
            length: end.saturating_sub(start),
        }
    };
    if range.length == 0 {
        return Ok(None);
    }
    if matches!(
        operation,
        CharacterOperation::Nfc
            | CharacterOperation::Nfd
            | CharacterOperation::AddEmojiPresentation
            | CharacterOperation::RemoveEmojiPresentation
            | CharacterOperation::FourDDetokenize
            | CharacterOperation::FourDTokenizeCommands
    ) {
        // Normalisierung erweitert Grapheme; 4D-Befehle verweigern angebrochene Grenzen.
        let mut unit = 0;
        let end = range.end()?;
        let mut expanded_start = range.location;
        let mut expanded_end = end;
        icu::walk_graphemes(text, |grapheme| {
            cancel.check()?;
            let next = unit + grapheme.encode_utf16().count();
            if unit < range.location && next > range.location {
                expanded_start = unit;
            }
            if unit < end && next > end {
                expanded_end = next;
            }
            unit = next;
            Ok(())
        })?;
        if matches!(
            operation,
            CharacterOperation::FourDDetokenize | CharacterOperation::FourDTokenizeCommands
        ) && (expanded_start != range.location || expanded_end != end)
        {
            return Err(Error::InvalidRange);
        }
        range = Utf16Range {
            location: expanded_start,
            length: expanded_end - expanded_start,
        };
    }
    let selected = &text[range.byte_range(text)?];
    let replacement = match operation {
        CharacterOperation::UppercaseRoot => icu::casing(selected, true, limits.max_output_bytes)?,
        CharacterOperation::LowercaseRoot => icu::casing(selected, false, limits.max_output_bytes)?,
        CharacterOperation::Nfc => normalized(selected, true, limits.max_output_bytes)?,
        CharacterOperation::Nfd => normalized(selected, false, limits.max_output_bytes)?,
        CharacterOperation::FourDDetokenize | CharacterOperation::FourDTokenizeCommands => {
            crate::four_d::transform_tokens(
                selected,
                if matches!(operation, CharacterOperation::FourDDetokenize) {
                    crate::four_d::TokenTransform::Detokenize
                } else {
                    crate::four_d::TokenTransform::TokenizeCommands
                },
                limits,
                cancel,
            )?
        }
        CharacterOperation::StraightenQuotes
        | CharacterOperation::EducateQuotes
        | CharacterOperation::ConvertEscapes
        | CharacterOperation::StripDiacriticals
        | CharacterOperation::AddEmojiPresentation
        | CharacterOperation::RemoveEmojiPresentation => {
            let bytes = range.byte_range(text)?;
            characters::transform(
                selected,
                text[..bytes.start].chars().next_back(),
                operation,
                limits,
                cancel,
            )?
        }
        CharacterOperation::ExchangeCharacters | CharacterOperation::ExchangeWords => {
            unreachable!()
        }
        CharacterOperation::NormalizeSpaces | CharacterOperation::ZapGremlins => {
            let mut output = String::new();
            for c in selected.chars() {
                cancel.check()?;
                let c = if matches!(operation, CharacterOperation::NormalizeSpaces)
                    && is_space_separator(c)
                {
                    ' '
                } else {
                    c
                };
                if matches!(operation, CharacterOperation::ZapGremlins)
                    && ((c <= '\u{1f}' && !matches!(c, '\t' | '\n' | '\r')) || c == '\u{7f}')
                {
                    continue;
                }
                let mut bytes = [0; 4];
                push_bounded(
                    &mut output,
                    c.encode_utf8(&mut bytes),
                    limits.max_output_bytes,
                )?;
            }
            output
        }
    };
    if matches!(operation, CharacterOperation::StripDiacriticals)
        && canonical_eq(selected, &replacement, limits.max_output_bytes, cancel)?
    {
        return Ok(None);
    }
    finish(text, range, replacement, 0, limits, cancel)
}

#[cfg(test)]
mod property_tests {
    use super::*;
    #[derive(serde::Deserialize)]
    struct Probe {
        scalar: u32,
        word: bool,
    }
    #[test]
    fn foundation_word_membership_uses_icu_categories() {
        let values: Vec<Probe> = serde_json::from_slice(include_bytes!(
            "../tests/fixtures/swift-word-properties.json"
        ))
        .unwrap();
        for value in values {
            assert_eq!(
                scalar_flags(char::from_u32(value.scalar).unwrap()) & 1 != 0,
                value.word,
                "U+{:X}",
                value.scalar
            );
        }
    }
}

/// Expliziter Text-Locale-Snapshot; weder ICU-Default noch die Oberflächensprache.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TitlecaseLocale(String);
impl TitlecaseLocale {
    /// Übernimmt die nach GTK-Initialisierung gelesene LC_CTYPE-ID, ohne setlocale zu ändern.
    pub fn from_ctype(value: &str) -> Result<Self, Error> {
        if value.is_empty()
            || value.len() > 128
            || !value
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"_.@=;-".contains(&c))
        {
            return Err(Error::InvalidRange);
        }
        let mut parts = value.splitn(2, '@');
        let base = parts.next().unwrap().split('.').next().unwrap();
        let modifier = parts.next();
        let mut id = if matches!(base, "C" | "POSIX") {
            "en_US_POSIX".to_string()
        } else {
            base.replace('-', "_")
        };
        if let Some(modifier) = modifier {
            id.push('@');
            id.push_str(modifier);
        }
        if id.is_empty()
            || !id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"_@=;".contains(&c))
        {
            return Err(Error::InvalidRange);
        }
        if !icu::known_locale(&id) {
            return Err(Error::InvalidRange);
        }
        Ok(Self(id))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

pub fn titlecase_with_locale(
    text: &str,
    selection: Utf16Range,
    locale: &TitlecaseLocale,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    cancel.check()?;
    if text.len() > limits.max_text_bytes {
        return Err(Error::Limit);
    }
    let range = if selection.length == 0 {
        Utf16Range {
            location: 0,
            length: text.encode_utf16().count(),
        }
    } else {
        selection
    };
    let bytes = range.byte_range(text)?;
    let replacement = icu::titlecase(&text[bytes], locale.as_str(), limits.max_output_bytes)?;
    finish(text, range, replacement, 0, limits, cancel)
}


/// Verwendet den expliziten Textlocale-Snapshot für die gesamte Auswahl.
pub fn case_with_locale(
    text: &str,
    selection: Utf16Range,
    uppercase: bool,
    locale: &TitlecaseLocale,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    cancel.check()?;
    if text.len() > limits.max_text_bytes {
        return Err(Error::Limit);
    }
    let range = if selection.length == 0 {
        Utf16Range { location: 0, length: text.encode_utf16().count() }
    } else { selection };
    let bytes = range.byte_range(text)?;
    let replacement = icu::casing_with_locale(&text[bytes], uppercase, locale.as_str(), limits.max_output_bytes)?;
    finish(text, range, replacement, 0, limits, cancel)
}
