use super::{lexical, Mask, MAX_SOURCE_BYTES};
use crate::{icu, Cancellation, Error, Limits};
use std::{collections::HashMap, ops::Range, sync::OnceLock};
mod classes;
#[derive(Clone, Copy)]
pub enum TokenTransform {
    Detokenize,
    TokenizeCommands,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Command,
    Constant,
    Other,
}
struct Catalog {
    symbols: HashMap<&'static str, (Kind, Option<&'static str>)>,
    max_words: usize,
}
fn catalog() -> &'static Catalog {
    static TABLE: OnceLock<Catalog> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut symbols = HashMap::new();
        let mut max_words = 1;
        for line in include_str!("catalog.tsv")
            .lines()
            .filter(|l| !l.starts_with('#'))
        {
            let mut parts = line.split('\t');
            let kind = parts.next().unwrap();
            let name = parts.next().unwrap();
            let id = parts.next().filter(|id| !id.is_empty());
            max_words = max_words.max(name.split(' ').filter(|w| !w.is_empty()).count());
            symbols.entry(name).or_insert((
                match kind {
                    "C" => Kind::Command,
                    "K" => Kind::Constant,
                    _ => Kind::Other,
                },
                id,
            ));
        }
        Catalog { symbols, max_words }
    })
}
fn at(source: &str, index: usize) -> Option<char> {
    source.get(index..)?.chars().next()
}
fn word(c: char) -> bool {
    c == '_' || classes::properties(c) & 3 != 0
}
fn start(c: char) -> bool {
    c == '_' || classes::properties(c) & 1 != 0
}
fn number(c: char) -> bool {
    classes::properties(c) & 2 != 0
}
fn decimal(c: char) -> bool {
    classes::properties(c) & 8 != 0
}
fn space(c: char) -> bool {
    classes::properties(c) & 4 != 0
}
fn phrase_end(source: &str, from: usize, cancel: &Cancellation) -> Result<usize, Error> {
    let mut i = from;
    let mut last = from;
    let mut steps = 0usize;
    while let Some(c) = at(source, i) {
        if steps & 1023 == 0 {
            cancel.check()?;
        }
        steps += 1;
        if word(c) {
            i += c.len_utf8();
            last = i;
        } else if c == ' ' && at(source, i + 1).is_some_and(word) {
            i += 1;
        } else {
            break;
        }
    }
    Ok(last)
}
fn table_end(source: &str, from: usize, cancel: &Cancellation) -> Result<Option<usize>, Error> {
    let mut saw = false;
    for (step, (offset, c)) in source[from..].char_indices().enumerate() {
        if step & 1023 == 0 {
            cancel.check()?;
        }
        if c == ']' {
            return Ok(saw.then_some(from + offset + 1));
        }
        if word(c) {
            saw = true;
        } else if !matches!(c, ' ' | ':' | '$' | '<' | '>') {
            return Ok(None);
        }
    }
    Ok(None)
}
struct Token {
    range: Range<usize>,
    kind: Kind,
    id: Option<&'static str>,
}
fn classify(
    source: &str,
    from: usize,
    end: usize,
    field: bool,
    dot: bool,
    cancel: &Cancellation,
    boundaries_of_graphemes: &[bool],
) -> Result<Option<Token>, Error> {
    let table = catalog();
    let mut boundaries = Vec::new();
    let mut last_space = true;
    for (step, (offset, c)) in source[from..end].char_indices().enumerate() {
        if boundaries.len() >= table.max_words {
            break;
        }
        if step & 1023 == 0 {
            cancel.check()?;
        }
        if c == ' ' {
            if !last_space {
                boundaries.push(from + offset);
            }
            last_space = true;
        } else {
            last_space = false;
        }
    }
    if boundaries.len() < table.max_words {
        boundaries.push(end);
    }
    let first = *boundaries.first().unwrap_or(&end);
    let mut look = first;
    while at(source, look) == Some(' ') {
        if look & 1023 == 0 {
            cancel.check()?;
        }
        look += 1;
    }
    if dot {
        return Ok((at(source, look) == Some('(')).then_some(Token {
            range: from..first,
            kind: Kind::Other,
            id: None,
        }));
    }
    if let Some(&name_end) = boundaries.last() {
        if at(source, name_end) == Some(':') {
            let marker = at(source, name_end + 1);
            if matches!(marker, Some('C' | 'K')) {
                let mut tail = name_end + 2;
                while let Some(c) =
                    at(source, tail).filter(|c| number(*c) || (marker == Some('K') && *c == ':'))
                {
                    tail += c.len_utf8();
                }
                if tail > name_end + 2 {
                    return Ok(Some(Token {
                        range: from..tail,
                        kind: if marker == Some('C') {
                            Kind::Command
                        } else {
                            Kind::Constant
                        },
                        id: None,
                    }));
                }
            }
        }
    }
    if field {
        return Ok(Some(Token {
            range: from..first,
            kind: Kind::Other,
            id: None,
        }));
    }
    for &boundary in boundaries.iter().rev() {
        cancel.check()?;
        if boundaries_of_graphemes[from] && boundaries_of_graphemes[boundary] {
            if let Some(&(kind, id)) = table
                .symbols
                .get(source[from..boundary].to_lowercase().as_str())
            {
                return Ok(Some(Token {
                    range: from..boundary,
                    kind,
                    id,
                }));
            }
        }
    }
    let mut result = first;
    if (!boundaries_of_graphemes[from]
        || !boundaries_of_graphemes[first]
        || all_numbers(&source[from..first], cancel)?)
        && at(source, first) == Some('.')
        && at(source, first + 1).is_some_and(number)
    {
        result += 1;
        while let Some(c) = at(source, result).filter(|c| number(*c)) {
            if result & 1023 == 0 {
                cancel.check()?;
            }
            result += c.len_utf8();
        }
    }
    Ok(Some(Token {
        range: from..result,
        kind: Kind::Other,
        id: None,
    }))
}
fn valid_suffix(value: &str, cancel: &Cancellation) -> Result<bool, Error> {
    let mut chars = value.chars();
    if chars.next() != Some(':') {
        return Ok(false);
    }
    let Some(marker @ ('C' | 'K')) = chars.next() else {
        return Ok(false);
    };
    let mut digits = 0;
    let mut colon = false;
    for (index, c) in chars.enumerate() {
        if index & 1023 == 0 {
            cancel.check()?;
        }
        if decimal(c) {
            digits += 1;
        } else if marker == 'K' && c == ':' && !colon && digits > 0 {
            colon = true;
            digits = 0;
        } else {
            return Ok(false);
        }
    }
    Ok(digits > 0)
}
fn all_numbers(value: &str, cancel: &Cancellation) -> Result<bool, Error> {
    for (index, c) in value.chars().enumerate() {
        if index & 1023 == 0 {
            cancel.check()?;
        }
        if !number(c) {
            return Ok(false);
        }
    }
    Ok(true)
}

fn keyword_positions(
    source: &str,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Vec<usize>, Error> {
    let mut regex = icu::Regex::new(r"\bvar\b|#declare\b", source, false, limits, cancel)?;
    let mut positions = Vec::new();
    let mut chars = source.char_indices();
    let mut units = 0;
    let mut byte = 0;
    while let Some(groups) = regex.next().map_err(|error| {
        if cancel.check().is_err() {
            Error::Cancelled
        } else {
            error
        }
    })? {
        if positions.len() >= limits.max_matches {
            return Err(Error::Limit);
        }
        let location = groups[0].ok_or(Error::InvalidRange)?.location;
        while units < location {
            let (offset, c) = chars.next().ok_or(Error::InvalidRange)?;
            units += c.len_utf16();
            byte = offset + c.len_utf8();
        }
        if units != location {
            return Err(Error::InvalidRange);
        }
        positions.push(byte);
    }
    Ok(positions)
}
struct DeclarationLines {
    start: usize,
    end: usize,
    key: Option<usize>,
    index: usize,
    keywords: Vec<usize>,
}
impl DeclarationLines {
    fn is_type(&mut self, source: &str, at: usize, cancel: &Cancellation) -> Result<bool, Error> {
        while at >= self.end {
            self.start = self.end;
            self.end = source.len() + 1;
            for (step, (offset, c)) in source[self.start..].char_indices().enumerate() {
                if step & 1023 == 0 {
                    cancel.check()?;
                }
                if matches!(c, '\r' | '\n' | '\u{85}' | '\u{2028}' | '\u{2029}') {
                    self.end = self.start + offset + c.len_utf8();
                    break;
                }
            }
            while self.index < self.keywords.len() && self.keywords[self.index] < self.start {
                self.index += 1;
            }
            self.key = self
                .keywords
                .get(self.index)
                .copied()
                .filter(|key| *key < self.end);
        }
        if !self.key.is_some_and(|key| key < at) {
            return Ok(false);
        }
        let mut cursor = at;
        while cursor > self.start {
            if cursor & 1023 == 0 {
                cancel.check()?;
            }
            let c = source[..cursor].chars().next_back().unwrap();
            if !space(c) {
                break;
            }
            cursor -= c.len_utf8();
        }
        Ok(cursor > self.start && source.as_bytes()[cursor - 1] == b':')
    }
}
fn append(output: &mut String, value: &str, limit: usize) -> Result<(), Error> {
    if value.len() > limit.saturating_sub(output.len()) {
        return Err(Error::Limit);
    }
    output.push_str(value);
    Ok(())
}
pub fn transform_tokens(
    source: &str,
    mode: TokenTransform,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<String, Error> {
    transform(source, mode, limits, cancel, None, None)
}

/// Lernt Suffixe mit demselben Scanner wie die vorhandene Detokenisierung.
pub fn learned_suffixes(
    source: &str,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<HashMap<String, String>, Error> {
    let mut learned = HashMap::new();
    transform(
        source,
        TokenTransform::Detokenize,
        limits,
        cancel,
        None,
        Some(&mut learned),
    )?;
    Ok(learned)
}

/// Gelernte Konstanten und unbekannte Symbole gehen vor bekannten Befehlsnummern.
pub fn retokenize(
    source: &str,
    learned: &HashMap<String, String>,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<String, Error> {
    transform(
        source,
        TokenTransform::TokenizeCommands,
        limits,
        cancel,
        Some(learned),
        None,
    )
}
fn transform(
    source: &str,
    mode: TokenTransform,
    limits: Limits,
    cancel: &Cancellation,
    learned: Option<&HashMap<String, String>>,
    mut collecting: Option<&mut HashMap<String, String>>,
) -> Result<String, Error> {
    let mut candidates: HashMap<&str, Vec<(&str, &str)>> = HashMap::new();
    if let Some(learned) = learned {
        if learned.len() > limits.max_matches {
            return Err(Error::Limit);
        }
        for (name, suffix) in learned {
            cancel.check()?;
            if name.is_empty() || !valid_suffix(suffix, cancel)? {
                return Err(Error::InvalidRange);
            }
            candidates
                .entry(name.split(' ').next().unwrap())
                .or_default()
                .push((name, suffix));
        }
        for bucket in candidates.values_mut() {
            bucket.sort_by(|a, b| {
                b.0.encode_utf16()
                    .count()
                    .cmp(&a.0.encode_utf16().count())
                    .then_with(|| a.0.cmp(b.0))
            });
        }
    }
    cancel.check()?;
    if source.len() > MAX_SOURCE_BYTES.min(limits.max_text_bytes) {
        return Err(Error::Limit);
    }
    let mask =
        lexical::mask(source, lexical::StringPolicy::UntilLf, cancel).map_err(|e| match e {
            super::Error::Cancelled => Error::Cancelled,
            _ => Error::Limit,
        })?;
    let mut boundaries_of_graphemes = vec![false; source.len() + 1];
    boundaries_of_graphemes[0] = true;
    let mut boundary = 0;
    icu::walk_graphemes(source, |grapheme| {
        cancel.check()?;
        boundary += grapheme.len();
        boundaries_of_graphemes[boundary] = true;
        Ok(())
    })?;
    let keywords = if matches!(mode, TokenTransform::TokenizeCommands) {
        keyword_positions(source, limits, cancel)?
    } else {
        Vec::new()
    };
    let mut declarations = DeclarationLines {
        start: 0,
        end: 0,
        key: None,
        index: 0,
        keywords,
    };
    let mut output = String::new();
    let mut copied = 0;
    let mut index = 0;
    let mut field = false;
    let mut dot = false;
    let mut cached_end = 0;
    let mut count = 0usize;
    while index < source.len() {
        cancel.check()?;
        if mask[index] != Mask::Code {
            let kind = mask[index];
            while index < source.len() && mask[index] == kind {
                if index & 1023 == 0 {
                    cancel.check()?;
                }
                index += 1;
            }
            field = false;
            continue;
        }
        let c = at(source, index).ok_or(Error::InvalidRange)?;
        if c.len_utf16() > 1 {
            index += c.len_utf8();
            continue;
        }
        if c == '[' {
            if let Some(end) = table_end(source, index + 1, cancel)? {
                index = end;
                field = true;
                continue;
            }
        }
        let local = c == '$' && at(source, index + 1).is_some_and(|c| start(c) || number(c));
        let inter = source[index..].starts_with("<>") && at(source, index + 2).is_some_and(start);
        if local || inter {
            index = phrase_end(source, index + if local { 1 } else { 2 }, cancel)?;
            field = false;
            continue;
        }
        if start(c) || number(c) {
            count += 1;
            if count > limits.max_matches {
                return Err(Error::Limit);
            }
            if index >= cached_end {
                cached_end = phrase_end(source, index, cancel)?;
            }
            let token = classify(
                source,
                index,
                cached_end,
                field,
                dot,
                cancel,
                &boundaries_of_graphemes,
            )?;
            if let Some(token) = token {
                let value = &source[token.range.clone()];
                let mut learned_match = None;
                if learned.is_some()
                    && !dot
                    && !field
                    && !value.contains(':')
                    && !all_numbers(value, cancel)?
                    && !declarations.is_type(source, token.range.start, cancel)?
                {
                    let token_name = value.to_lowercase();
                    if let Some(bucket) = candidates.get(token_name.split(' ').next().unwrap_or(""))
                    {
                        for &(name, suffix) in bucket {
                            cancel.check()?;
                            if !name.starts_with(&token_name) {
                                continue;
                            }
                            // Case-Faltung kann die Bytezahl ändern; die Grenze wird über die echte Quelle ermittelt.
                            let mut end = token.range.start;
                            let mut expected = name.chars();
                            for c in source[token.range.start..].chars() {
                                if end >= cached_end {
                                    break;
                                }
                                end += c.len_utf8();
                                if !c.to_lowercase().all(|lower| expected.next() == Some(lower)) {
                                    break;
                                }
                                if expected.clone().next().is_none() {
                                    if at(source, end).is_none_or(|c| !word(c)) {
                                        learned_match = Some((end, suffix));
                                    }
                                    break;
                                }
                            }
                            if learned_match.is_some() {
                                break;
                            }
                        }
                    }
                }
                if let Some((end, suffix)) = learned_match {
                    append(&mut output, &source[copied..end], limits.max_output_bytes)?;
                    append(&mut output, suffix, limits.max_output_bytes)?;
                    copied = end;
                    index = end;
                    field = false;
                    dot = false;
                    continue;
                }
                match mode {
                    TokenTransform::Detokenize
                        if matches!(token.kind, Kind::Command | Kind::Constant) =>
                    {
                        if let Some(colon) = value.find(':') {
                            if valid_suffix(&value[colon..], cancel)? {
                                if !boundaries_of_graphemes[token.range.start]
                                    || !boundaries_of_graphemes[token.range.end]
                                {
                                    return Err(Error::InvalidRange);
                                }
                                if let Some(ref mut collecting) = collecting {
                                    collecting.insert(
                                        value[..colon].to_lowercase(),
                                        value[colon..].to_owned(),
                                    );
                                }
                                append(
                                    &mut output,
                                    &source[copied..token.range.start + colon],
                                    limits.max_output_bytes,
                                )?;
                                copied = token.range.end;
                            }
                        }
                    }
                    TokenTransform::TokenizeCommands
                        if token.kind == Kind::Command && !value.contains(':') =>
                    {
                        if let Some(id) = token.id {
                            if !declarations.is_type(source, token.range.start, cancel)? {
                                append(
                                    &mut output,
                                    &source[copied..token.range.end],
                                    limits.max_output_bytes,
                                )?;
                                append(&mut output, ":C", limits.max_output_bytes)?;
                                append(&mut output, id, limits.max_output_bytes)?;
                                copied = token.range.end;
                            }
                        }
                    }
                    _ => (),
                }
                index = token.range.end;
            } else {
                index = cached_end;
            }
            field = false;
            dot = false;
            continue;
        }
        if c == '.' {
            dot = true;
        } else if !c.is_whitespace() {
            field = false;
            dot = false;
        }
        index += c.len_utf8();
    }
    append(&mut output, &source[copied..], limits.max_output_bytes)?;
    cancel.check()?;
    Ok(output)
}

pub(super) fn completion_properties(c: char) -> u8 {
    classes::properties(c)
}

pub(super) fn target_keyword(name: &str) -> bool { catalog().symbols.get(name).is_some_and(|(kind,_)| *kind == Kind::Other) }
pub(super) fn target_builtin(name: &str) -> bool { catalog().symbols.get(name).is_some_and(|(kind,_)| *kind != Kind::Constant) }

pub(super) fn folding_keyword(source: &str, cancel: &Cancellation) -> Result<String, Error> {
    if !source.chars().next().is_some_and(start) {
        return Ok(String::new());
    }
    let end = phrase_end(source, 0, cancel)?;
    let mut boundaries = vec![false; source.len() + 1];
    boundaries[0] = true;
    let mut at = 0;
    icu::walk_graphemes(source, |grapheme| {
        cancel.check()?;
        at += grapheme.len();
        boundaries[at] = true;
        Ok(())
    })?;
    let Some(token) = classify(source, 0, end, false, false, cancel, &boundaries)? else {
        return Ok(String::new());
    };
    let phrase = source[token.range].to_lowercase();
    if (token.kind == Kind::Other && target_keyword(&phrase))
        || (token.kind == Kind::Command && matches!(phrase.as_str(), "begin sql" | "end sql"))
    {
        Ok(phrase)
    } else {
        Ok(String::new())
    }
}
pub(super) fn folding_space(c: char) -> bool {
    space(c)
}
