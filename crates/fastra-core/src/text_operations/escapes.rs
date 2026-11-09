use super::*;
fn digit(byte: u8, radix: u32) -> Option<u32> {
    let value = match byte {
        b'0'..=b'9' => (byte - b'0') as u32,
        b'a'..=b'f' => (byte - b'a' + 10) as u32,
        b'A'..=b'F' => (byte - b'A' + 10) as u32,
        _ => return None,
    };
    (value < radix).then_some(value)
}
fn number(
    bytes: &[u8],
    start: usize,
    radix: u32,
    cancel: &Cancellation,
) -> Result<(Option<u32>, usize), Error> {
    let mut index = start;
    let mut value = Some(0u32);
    while let Some(next) = bytes.get(index).and_then(|b| digit(*b, radix)) {
        if index & 4095 == 0 {
            cancel.check()?;
        }
        value = value.and_then(|v| v.checked_mul(radix)?.checked_add(next));
        index += 1;
    }
    Ok((value, index))
}
fn hex(
    text: &str,
    index: usize,
    fixed: usize,
    cancel: &Cancellation,
) -> Result<Option<(char, usize)>, Error> {
    let bytes = text.as_bytes();
    if bytes.get(index) == Some(&b'{') {
        let (value, end) = number(bytes, index + 1, 16, cancel)?;
        if end == index + 1 || bytes.get(end) != Some(&b'}') {
            return Ok(None);
        }
        Ok(value.and_then(char::from_u32).map(|c| (c, end + 1)))
    } else {
        let Some(end) = index.checked_add(fixed).filter(|end| *end <= bytes.len()) else {
            return Ok(None);
        };
        let mut value = 0;
        for byte in &bytes[index..end] {
            let Some(digit) = digit(*byte, 16) else {
                return Ok(None);
            };
            value = value * 16 + digit;
        }
        Ok(char::from_u32(value).map(|c| (c, end)))
    }
}
fn named(name: &str) -> Option<char> {
    Some(match name {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => '\u{a0}',
        "copy" => '©',
        "reg" => '®',
        "trade" => '™',
        "mdash" => '—',
        "ndash" => '–',
        "hellip" => '…',
        "euro" => '€',
        "pound" => '£',
        "deg" => '°',
        "times" => '×',
        "divide" => '÷',
        "auml" => 'ä',
        "ouml" => 'ö',
        "uuml" => 'ü',
        "Auml" => 'Ä',
        "Ouml" => 'Ö',
        "Uuml" => 'Ü',
        "szlig" => 'ß',
        _ => return None,
    })
}
fn entity(text: &str, start: usize, cancel: &Cancellation) -> Result<Option<(char, usize)>, Error> {
    let bytes = text.as_bytes();
    let index = start + 1;
    if bytes.get(index) == Some(&b'#') {
        let mut from = index + 1;
        let radix = if matches!(bytes.get(from), Some(b'x' | b'X')) {
            from += 1;
            16
        } else {
            10
        };
        let (value, end) = number(bytes, from, radix, cancel)?;
        if end == from || bytes.get(end) != Some(&b';') {
            return Ok(None);
        }
        Ok(value.and_then(char::from_u32).map(|c| (c, end + 1)))
    } else {
        let mut end = index;
        while bytes.get(end).is_some_and(u8::is_ascii_alphanumeric) {
            if end & 4095 == 0 {
                cancel.check()?;
            }
            end += 1;
        }
        if bytes.get(end) != Some(&b';') {
            return Ok(None);
        }
        Ok(named(&text[index..end]).map(|c| (c, end + 1)))
    }
}
pub(super) fn decode(text: &str, limit: usize, cancel: &Cancellation) -> Result<String, Error> {
    let bytes = text.as_bytes();
    let mut output = String::new();
    let mut index = 0;
    while index < bytes.len() {
        cancel.check()?;
        let decoded = if bytes[index] == b'\\' {
            match bytes.get(index + 1) {
                Some(b'n') => Some(('\n', index + 2)),
                Some(b'r') => Some(('\r', index + 2)),
                Some(b't') => Some(('\t', index + 2)),
                Some(b'f') => Some(('\u{c}', index + 2)),
                Some(b'\\') => Some(('\\', index + 2)),
                Some(b'x') => hex(text, index + 2, 2, cancel)?,
                Some(b'u') => hex(text, index + 2, 4, cancel)?,
                _ => None,
            }
        } else if bytes[index] == b'&' {
            entity(text, index, cancel)?
        } else {
            None
        };
        if let Some((ch, end)) = decoded {
            let mut buffer = [0; 4];
            push_bounded(&mut output, ch.encode_utf8(&mut buffer), limit)?;
            index = end;
            continue;
        }
        if bytes[index] == b'%' {
            let mut values = Vec::new();
            let mut end = index;
            while bytes.get(end) == Some(&b'%') {
                let Some(hi) = bytes.get(end + 1).and_then(|b| digit(*b, 16)) else {
                    break;
                };
                let Some(lo) = bytes.get(end + 2).and_then(|b| digit(*b, 16)) else {
                    break;
                };
                if values.len() & 4095 == 0 {
                    cancel.check()?;
                }
                values.push((hi * 16 + lo) as u8);
                end += 3;
            }
            if !values.is_empty() {
                // Swift versucht nach einem ungültigen Lauf jeden Folgesuffix erneut.
                // Der letzte UTF-8-Fehler bestimmt denselben Ersatz in linearer Zeit.
                let mut suffix = 0;
                while let Err(error) = std::str::from_utf8(&values[suffix..]) {
                    cancel.check()?;
                    suffix += error.valid_up_to()
                        + error
                            .error_len()
                            .unwrap_or(values.len() - suffix - error.valid_up_to());
                }
                push_bounded(&mut output, &text[index..index + 3 * suffix], limit)?;
                push_bounded(
                    &mut output,
                    std::str::from_utf8(&values[suffix..]).map_err(|_| Error::InvalidRange)?,
                    limit,
                )?;
                index = end;
                continue;
            }
        }
        let ch = text[index..].chars().next().ok_or(Error::InvalidRange)?;
        let mut buffer = [0; 4];
        push_bounded(&mut output, ch.encode_utf8(&mut buffer), limit)?;
        index += ch.len_utf8();
    }
    cancel.check()?;
    Ok(output)
}
