use super::*;
fn append(output: &mut String, c: char, limit: usize) -> Result<(), Error> {
    let mut bytes = [0; 4];
    push_bounded(output, c.encode_utf8(&mut bytes), limit)
}
fn decomposition(c: char, limit: usize) -> Result<Vec<char>, Error> {
    if scalar_flags(c) & 8 != 0 {
        let mut bytes = [0; 4];
        Ok(normalized(c.encode_utf8(&mut bytes), false, limit)?
            .chars()
            .collect())
    } else {
        Ok(vec![c])
    }
}
fn extend(c: char) -> bool {
    scalar_flags(c) & 2 != 0
}
fn priority(c: char) -> i32 {
    unsafe { fastra_combining_class(c as i32) }
}
fn strip(text: &str, limit: usize, cancel: &Cancellation) -> Result<String, Error> {
    let mut chars = text.chars().peekable();
    let mut out = String::new();
    while let Some(original) = chars.next() {
        cancel.check()?;
        if original == '\0' {
            append(&mut out, original, limit)?;
            continue;
        }
        let first = if scalar_flags(original) & 8 != 0 {
            *decomposition(original, limit)?
                .first()
                .ok_or(Error::InvalidRange)?
        } else {
            original
        };
        // Foundation faltet hier nur Roman/Griechisch/Kyrillisch, nicht pauschal alle Marks.
        let base = if first < '\u{510}' { first } else { original };
        if base < '\u{510}' {
            append(&mut out, base, limit)?;
            while chars.peek().is_some_and(|c| extend(*c)) {
                cancel.check()?;
                chars.next();
            }
            continue;
        }
        if !chars.peek().is_some_and(|c| extend(*c)) {
            append(&mut out, base, limit)?;
            continue;
        }
        let mut cluster = vec![base];
        if let Some(next) = chars.peek().copied().filter(|c| extend(*c)) {
            chars.next();
            if next > '\u{50f}' {
                cluster.extend(decomposition(next, limit)?);
            }
            // Entspricht dem begrenzten CFString-Faltpuffer; Folgereste werden neue Cluster.
            while cluster.len() < 64 {
                let Some(next) = chars.peek().copied().filter(|c| extend(*c)) else {
                    break;
                };
                cancel.check()?;
                let mapped = decomposition(next, limit)?;
                if cluster.len() + mapped.len() > 64 {
                    break;
                }
                chars.next();
                cluster.extend(mapped);
            }
            let start = cluster.iter().rposition(|c| !extend(*c)).unwrap_or(0);
            for i in start + 1..cluster.len() {
                let mut j = i;
                let current = priority(cluster[j]);
                while j > start && priority(cluster[j - 1]) > current {
                    cluster.swap(j, j - 1);
                    j -= 1;
                }
            }
        }
        for c in cluster {
            append(&mut out, c, limit)?;
        }
    }
    Ok(out)
}
pub(super) fn transform(
    text: &str,
    previous: Option<char>,
    operation: CharacterOperation,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<String, Error> {
    if matches!(operation, CharacterOperation::ConvertEscapes) {
        return super::escapes::decode(text, limits.max_output_bytes, cancel);
    }
    if matches!(operation, CharacterOperation::StripDiacriticals) {
        return strip(text, limits.max_output_bytes, cancel);
    }
    let mut output = String::new();
    let mut previous = previous;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        cancel.check()?;
        let value = match operation {
            CharacterOperation::StraightenQuotes => match c {
                '\u{201c}' | '\u{201d}' | '\u{201e}' | '\u{201f}' => '"',
                '\u{2018}' | '\u{2019}' | '\u{201a}' | '\u{201b}' => '\'',
                _ => c,
            },
            CharacterOperation::EducateQuotes => {
                let opening =
                    previous.is_none_or(|c| c.is_whitespace() || matches!(c, '(' | '[' | '{'));
                match c {
                    '"' => {
                        if opening {
                            '“'
                        } else {
                            '”'
                        }
                    }
                    '\'' => {
                        if opening {
                            '‘'
                        } else {
                            '’'
                        }
                    }
                    _ => c,
                }
            }
            CharacterOperation::AddEmojiPresentation => {
                append(&mut output, c, limits.max_output_bytes)?;
                if scalar_flags(c) & 4 != 0
                    && !matches!(chars.peek(), Some('\u{fe0e}' | '\u{fe0f}'))
                {
                    append(&mut output, '\u{fe0f}', limits.max_output_bytes)?;
                }
                previous = Some(c);
                continue;
            }
            CharacterOperation::RemoveEmojiPresentation => {
                if c == '\u{fe0f}' && previous.is_some_and(|c| scalar_flags(c) & 4 != 0) {
                    continue;
                }
                c
            }
            _ => unreachable!(),
        };
        append(&mut output, value, limits.max_output_bytes)?;
        previous = Some(c);
    }
    cancel.check()?;
    Ok(output)
}
