use crate::{icu, wildcard, Error, Utf16Range};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Piece {
    UpperAll,
    LowerAll,
    UpperNext,
    LowerNext,
    End,
    Text(String),
}

pub fn pieces(template: &str) -> Result<Vec<Piece>, Error> {
    let mut result = Vec::new();
    let mut segment = String::new();
    let graphemes = icu::graphemes(template)?;
    let mut chars = graphemes.into_iter();
    while let Some(c) = chars.next() {
        if c == "\\" {
            if let Some(next) = chars.next() {
                let operator = match next {
                    "U" => Some(Piece::UpperAll),
                    "L" => Some(Piece::LowerAll),
                    "u" => Some(Piece::UpperNext),
                    "l" => Some(Piece::LowerNext),
                    "E" => Some(Piece::End),
                    _ => None,
                };
                if let Some(operator) = operator {
                    if !segment.is_empty() {
                        result.push(Piece::Text(std::mem::take(&mut segment)));
                    }
                    result.push(operator);
                } else {
                    segment.push_str(c);
                    segment.push_str(next);
                }
            } else {
                segment.push_str(c);
            }
        } else {
            segment.push_str(c);
        }
    }
    if !segment.is_empty() {
        result.push(Piece::Text(segment));
    }
    Ok(result)
}

fn append(output: &mut String, value: &str, limit: usize) -> Result<(), Error> {
    if output
        .len()
        .checked_add(value.len())
        .filter(|n| *n <= limit)
        .is_none()
    {
        return Err(Error::Limit);
    }
    output.push_str(value);
    Ok(())
}

fn expand(
    segment: &str,
    text: &[u16],
    captures: &[Option<Utf16Range>],
    limit: usize,
) -> Result<String, Error> {
    let mut output = String::new();
    let mut chars = segment.chars().peekable();
    let budget = wildcard::reference_digits(captures.len().saturating_sub(1));
    while let Some(c) = chars.next() {
        // codereview-ok: Foundation-Regex-Segmente verwerfen ein abschließendes Escape (2026-11-05).
        if c == '\\' {
            if let Some(next) = chars.next() {
                append(&mut output, next.encode_utf8(&mut [0; 4]), limit)?;
            }
        } else if c == '$' && chars.peek().is_some_and(|c| c.is_ascii_digit()) {
            let mut number = 0usize;
            for _ in 0..budget {
                if !chars.peek().is_some_and(|c| c.is_ascii_digit()) {
                    break;
                }
                number = number
                    .checked_mul(10)
                    .and_then(|v| v.checked_add(chars.next().unwrap() as usize - '0' as usize))
                    .ok_or(Error::Limit)?;
            }
            if let Some(Some(range)) = captures.get(number) {
                let units = text
                    .get(range.location..range.end()?)
                    .ok_or(Error::InvalidRange)?;
                append(
                    &mut output,
                    &String::from_utf16(units).map_err(|_| Error::InvalidRange)?,
                    limit,
                )?;
            }
        } else {
            append(&mut output, c.encode_utf8(&mut [0; 4]), limit)?;
        }
    }
    Ok(output)
}

pub(crate) fn replacement(
    parsed: &[Piece],
    text: &[u16],
    captures: &[Option<Utf16Range>],
    limit: usize,
) -> Result<String, Error> {
    let mut mode = None;
    let mut shot = None;
    let mut output = String::new();
    for piece in parsed {
        match piece {
            Piece::UpperAll => {
                mode = Some(true);
                shot = None;
            }
            Piece::LowerAll => {
                mode = Some(false);
                shot = None;
            }
            Piece::UpperNext => shot = Some(true),
            Piece::LowerNext => shot = Some(false),
            Piece::End => {
                mode = None;
                shot = None;
            }
            Piece::Text(segment) => {
                let expanded = expand(segment, text, captures, limit)?;
                if expanded.is_empty() {
                    continue;
                }
                let mut rest = expanded.as_str();
                if let Some(upper) = shot.take() {
                    let first = icu::graphemes(rest)?
                        .first()
                        .copied()
                        .ok_or(Error::InvalidRange)?;
                    append(&mut output, &icu::casing(first, upper, limit)?, limit)?;
                    rest = &rest[first.len()..];
                }
                if let Some(upper) = mode {
                    append(&mut output, &icu::casing(rest, upper, limit)?, limit)?;
                } else {
                    append(&mut output, rest, limit)?;
                }
            }
        }
    }
    Ok(output)
}
