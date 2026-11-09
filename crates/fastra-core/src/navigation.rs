//! Zeilen-/Spaltensprünge nach dem bestehenden Swift-Vertrag, ohne GTK oder Dateizugriff.
use crate::{Cancellation, Error};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Position {
    pub line: usize,
    pub column: Option<usize>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Destination {
    pub utf16_offset: usize,
    pub character_offset: usize,
    pub rounded_to_scalar: bool,
}
fn whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}
pub fn parse(input: &str) -> Option<Position> {
    if input.len() > 256 {
        return None;
    }
    let mut parts = input.trim_matches(whitespace).split(':');
    fn number(s: &str) -> Option<usize> {
        let n = usize::try_from(s.trim_matches(whitespace).parse::<i64>().ok()?).ok()?;
        (n > 0).then_some(n)
    }
    let line = number(parts.next()?)?;
    let column = match parts.next() {
        Some(value) => Some(number(value)?),
        None => None,
    };
    if parts.next().is_some() {
        return None;
    }
    Some(Position { line, column })
}
fn terminator(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}
pub fn destination(
    text: &str,
    position: Position,
    cancel: &Cancellation,
) -> Result<Destination, Error> {
    if text.len() > 32 * 1024 * 1024 {
        return Err(Error::Limit);
    }
    cancel.check()?;
    let mut line = 1usize;
    let mut units = 0usize;
    let mut characters = 0usize;
    let mut chars = text.chars().peekable();
    let mut next_check = 4096;
    let requested_line = position.line.max(1);
    while line < requested_line {
        let Some(c) = chars.next() else {
            cancel.check()?;
            return Ok(Destination {
                utf16_offset: units,
                character_offset: characters,
                rounded_to_scalar: false,
            });
        };
        units += c.len_utf16();
        characters += 1;
        if characters >= next_check {
            cancel.check()?;
            next_check = characters.saturating_add(4096);
        }
        if terminator(c) {
            if c == '\r' && chars.peek() == Some(&'\n') {
                chars.next();
                units += 1;
                characters += 1;
            }
            line += 1;
        }
    }
    let wanted = position.column.unwrap_or(1).max(1) - 1;
    let mut accepted = 0usize;
    while let Some(&c) = chars.peek() {
        if terminator(c) {
            break;
        }
        let width = c.len_utf16();
        if accepted.saturating_add(width) > wanted {
            cancel.check()?;
            return Ok(Destination {
                utf16_offset: units,
                character_offset: characters,
                rounded_to_scalar: accepted < wanted,
            });
        }
        chars.next();
        accepted += width;
        units += width;
        characters += 1;
        if characters >= next_check {
            cancel.check()?;
            next_check = characters.saturating_add(4096);
        }
    }
    cancel.check()?;
    Ok(Destination {
        utf16_offset: units,
        character_offset: characters,
        rounded_to_scalar: false,
    })
}
