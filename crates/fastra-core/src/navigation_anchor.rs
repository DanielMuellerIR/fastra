//! Begrenzte Sprunganker nach dem Swift-Vertrag: gleiche Zeile, dann eindeutiger Kontext.
use crate::{Cancellation, Error};
use std::{iter::Peekable, ops::Range, str::CharIndices};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Anchor {
    pub revision: u64,
    pub range: Range<usize>,
    text_length: usize,
    line: Option<String>,
    before: Option<String>,
    after: Option<String>,
    column: usize,
}
#[derive(Clone, Copy)]
struct Line<'a> {
    start: usize,
    text: &'a str,
}
struct Lines<'a> {
    source: &'a str,
    chars: Peekable<CharIndices<'a>>,
    byte: usize,
    offset: usize,
    count: usize,
    done: bool,
}
impl<'a> Lines<'a> {
    fn new(source: &'a str) -> Self {
        Self {
            source,
            chars: source.char_indices().peekable(),
            byte: 0,
            offset: 0,
            count: 0,
            done: false,
        }
    }
    fn next(&mut self, cancel: &Cancellation) -> Result<Option<Line<'a>>, Error> {
        if self.done {
            return Ok(None);
        }
        cancel.check()?;
        let start = self.offset;
        let byte = self.byte;
        while let Some((at, c)) = self.chars.next() {
            self.count += 1;
            if self.count & 1023 == 0 {
                cancel.check()?;
            }
            self.offset += c.len_utf16();
            if matches!(c, '\r' | '\n' | '\u{85}' | '\u{2028}' | '\u{2029}') {
                self.byte = at + c.len_utf8();
                if c == '\r' && self.chars.peek().is_some_and(|(_, c)| *c == '\n') {
                    self.chars.next();
                    self.byte += 1;
                    self.offset += 1;
                }
                return Ok(Some(Line {
                    start,
                    text: &self.source[byte..at],
                }));
            }
        }
        self.done = true;
        Ok(Some(Line {
            start,
            text: &self.source[byte..],
        }))
    }
}
fn bounded(text: &str) -> Option<&str> {
    (text.encode_utf16().take(1025).count() <= 1024).then_some(text)
}
fn measure(source: &str, cancel: &Cancellation) -> Result<usize, Error> {
    if source.len() > 32 * 1024 * 1024 {
        return Err(Error::Limit);
    }
    let mut length = 0;
    for (n, c) in source.chars().enumerate() {
        if n & 1023 == 0 {
            cancel.check()?;
        }
        length += c.len_utf16();
    }
    cancel.check()?;
    Ok(length)
}
impl Anchor {
    pub fn capture(
        source: &str,
        revision: u64,
        range: Range<usize>,
        cancel: &Cancellation,
    ) -> Result<Self, Error> {
        let length = measure(source, cancel)?;
        Self::capture_measured(source, revision, range, length, cancel)
    }
    pub fn from_characters(
        source: &str,
        revision: u64,
        range: Range<usize>,
        cancel: &Cancellation,
    ) -> Result<Self, Error> {
        if source.len() > 32 * 1024 * 1024 {
            return Err(Error::Limit);
        }
        let mut offset = 0;
        let mut first = None;
        let mut last = None;
        for (n, c) in source.chars().enumerate() {
            if n & 1023 == 0 {
                cancel.check()?;
            }
            if n == range.start {
                first = Some(offset);
            }
            if n == range.end {
                last = Some(offset);
            }
            offset += c.len_utf16();
        }
        let range = first.unwrap_or(offset)..last.unwrap_or(offset);
        Self::capture_measured(source, revision, range, offset, cancel)
    }
    fn capture_measured(
        source: &str,
        revision: u64,
        range: Range<usize>,
        length: usize,
        cancel: &Cancellation,
    ) -> Result<Self, Error> {
        let first = range.start.min(length);
        let range = first..range.end.min(length).max(first);
        let mut lines = Lines::new(source);
        let mut previous = None;
        let mut current = lines.next(cancel)?.ok_or(Error::InvalidRange)?;
        let after = loop {
            let next = lines.next(cancel)?;
            if let Some(next) = next.filter(|line| line.start <= first) {
                previous = Some(current);
                current = next;
            } else {
                break next;
            }
        };
        Ok(Self {
            revision,
            column: first - current.start,
            range,
            text_length: length,
            line: bounded(current.text).map(str::to_owned),
            before: previous
                .and_then(|line| bounded(line.text))
                .map(str::to_owned),
            after: after.and_then(|line| bounded(line.text)).map(str::to_owned),
        })
    }
    pub fn resolve(
        &self,
        source: &str,
        revision: u64,
        cancel: &Cancellation,
    ) -> Result<Option<Range<usize>>, Error> {
        if revision == self.revision && measure(source, cancel)? == self.text_length {
            return Ok(Some(self.range.clone()));
        }
        let Some(text) = self
            .line
            .as_deref()
            .filter(|_| source.len() <= 10 * 1024 * 1024)
        else {
            return Ok(None);
        };
        let mut lines = Lines::new(source);
        let mut previous = None;
        let mut current = lines.next(cancel)?;
        let mut matches = Vec::new();
        let mut count = 0;
        while let Some(line) = current {
            if count >= 200_000 {
                return Ok(None);
            }
            count += 1;
            let next = lines.next(cancel)?;
            if bounded(line.text) == Some(text)
                && self.column + self.range.len() <= line.text.encode_utf16().count()
            {
                matches.push((
                    line.start + self.column..line.start + self.column + self.range.len(),
                    previous.and_then(|l: Line<'_>| bounded(l.text)),
                    next.and_then(|l| bounded(l.text)),
                ));
                if matches.len() > 1000 {
                    return Ok(None);
                }
            }
            previous = Some(line);
            current = next;
        }
        if matches.len() == 1 {
            return Ok(Some(matches.remove(0).0));
        }
        let mut contextual = matches.into_iter().filter(|(_, before, after)| {
            *before == self.before.as_deref() && *after == self.after.as_deref()
        });
        let candidate = contextual.next();
        Ok(if contextual.next().is_none() {
            candidate.map(|p| p.0)
        } else {
            None
        })
    }
    pub fn resolve_characters(
        &self,
        source: &str,
        revision: u64,
        cancel: &Cancellation,
    ) -> Result<Option<Range<usize>>, Error> {
        let Some(range) = self.resolve(source, revision, cancel)? else {
            return Ok(None);
        };
        characters(source, range, cancel)
    }
}
pub fn characters(
    source: &str,
    range: Range<usize>,
    cancel: &Cancellation,
) -> Result<Option<Range<usize>>, Error> {
    if source.len() > 32 * 1024 * 1024 {
        return Err(Error::Limit);
    }
    let mut units = 0;
    let mut first = None;
    let mut n = 0;
    for c in source.chars() {
        if n & 1023 == 0 {
            cancel.check()?;
        }
        if units == range.start {
            first = Some(n);
        }
        if units == range.end {
            return Ok(first.map(|first| first..n));
        }
        if units > range.end {
            return Ok(None);
        }
        n += 1;
        units += c.len_utf16();
    }
    if units == range.start {
        first = Some(n);
    }
    Ok((units == range.end)
        .then_some(first)
        .flatten()
        .map(|first| first..n))
}
