use super::*;
fn width(value: usize) -> Result<(), Error> {
    if (1..=16).contains(&value) {
        Ok(())
    } else {
        Err(Error::Limit)
    }
}
fn detab(line: &str, tab: usize, limit: usize, cancel: &Cancellation) -> Result<String, Error> {
    width(tab)?;
    let mut column = 0;
    let mut out = String::new();
    icu::walk_graphemes(line, |ch| {
        cancel.check()?;
        if ch == "\t" {
            let spaces = tab - column % tab;
            push_bounded(&mut out, &" ".repeat(spaces), limit)?;
            column += spaces;
        } else {
            push_bounded(&mut out, ch, limit)?;
            column += 1;
        }
        Ok(())
    })?;
    Ok(out)
}
fn flush(
    out: &mut String,
    start: usize,
    count: usize,
    tab: usize,
    limit: usize,
) -> Result<(), Error> {
    let end = start + count;
    let mut column = start;
    while column < end {
        let next = column - column % tab + tab;
        if next > end {
            break;
        }
        push_bounded(out, "\t", limit)?;
        column = next;
    }
    push_bounded(out, &" ".repeat(end - column), limit)
}
fn entab(line: &str, tab: usize, limit: usize, cancel: &Cancellation) -> Result<String, Error> {
    width(tab)?;
    let mut out = String::new();
    let mut column = 0;
    let mut count = 0;
    let mut start = 0;
    icu::walk_graphemes(line, |ch| {
        cancel.check()?;
        if ch == " " {
            if count == 0 {
                start = column;
            }
            count += 1;
            column += 1;
        } else {
            flush(&mut out, start, count, tab, limit)?;
            count = 0;
            push_bounded(&mut out, ch, limit)?;
            column += if ch == "\t" { tab - column % tab } else { 1 };
        }
        Ok(())
    })?;
    flush(&mut out, start, count, tab, limit)?;
    Ok(out)
}
struct Wrapped<'a> {
    parts: Vec<String>,
    current: String,
    length: usize,
    leading: &'a str,
    leading_length: usize,
    width: usize,
    bytes: usize,
    separator: usize,
    limit: usize,
    max_lines: usize,
}
impl Wrapped<'_> {
    fn end_line(&mut self) -> Result<(), Error> {
        if self.current.is_empty() {
            return Ok(());
        }
        let mut line = std::mem::take(&mut self.current);
        if self.parts.is_empty() && !self.leading.is_empty() {
            let mut first = String::new();
            push_bounded(&mut first, self.leading, self.limit)?;
            push_bounded(&mut first, &line, self.limit)?;
            line = first;
        }
        if self.parts.len() >= self.max_lines {
            return Err(Error::Limit);
        }
        self.bytes = self
            .bytes
            .checked_add(line.len())
            .and_then(|n| {
                n.checked_add(if self.parts.is_empty() {
                    0
                } else {
                    self.separator
                })
            })
            .filter(|n| *n <= self.limit)
            .ok_or(Error::Limit)?;
        self.parts.push(line);
        self.length = 0;
        Ok(())
    }
    fn word(&mut self, word: &str, length: usize) -> Result<(), Error> {
        if word.is_empty() {
            return Ok(());
        }
        let available = if self.parts.is_empty() {
            self.width.saturating_sub(self.leading_length)
        } else {
            self.width
        };
        if !self.current.is_empty() && self.length + 1 + length > available {
            self.end_line()?;
        }
        if !self.current.is_empty() {
            push_bounded(&mut self.current, " ", self.limit)?;
            self.length += 1;
        }
        push_bounded(&mut self.current, word, self.limit)?;
        self.length += length;
        Ok(())
    }
}
fn wrap(
    line: &str,
    column: usize,
    separator: usize,
    limit: usize,
    max_lines: usize,
    cancel: &Cancellation,
) -> Result<Vec<String>, Error> {
    let mut length = 0;
    let mut leading_length = 0;
    let mut leading_bytes = 0;
    let mut leading = true;
    icu::walk_graphemes(line, |ch| {
        cancel.check()?;
        length += 1;
        if leading && (ch == " " || ch == "\t") {
            leading_length += 1;
            leading_bytes += ch.len();
        } else {
            leading = false;
        }
        Ok(())
    })?;
    if length <= column || leading_bytes == line.len() {
        return Ok(vec![line.into()]);
    }
    let body = &line[leading_bytes..];
    let mut state = Wrapped {
        parts: Vec::new(),
        current: String::new(),
        length: 0,
        leading: &line[..leading_bytes],
        leading_length,
        width: column,
        bytes: 0,
        separator,
        limit,
        max_lines,
    };
    let mut start = None;
    let mut offset = 0;
    let mut word_length = 0;
    icu::walk_graphemes(body, |ch| {
        cancel.check()?;
        if ch == " " || ch == "\t" {
            if let Some(start) = start.take() {
                state.word(&body[start..offset], word_length)?;
            }
            word_length = 0;
        } else {
            if start.is_none() {
                start = Some(offset);
            }
            word_length += 1;
        }
        offset += ch.len();
        Ok(())
    })?;
    if let Some(start) = start {
        state.word(&body[start..], word_length)?;
    }
    state.end_line()?;
    Ok(state.parts)
}
pub(super) fn transform(
    lines: &[String],
    op: &LineOperation,
    separator: &str,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Vec<String>, Error> {
    let mut output = Vec::new();
    let mut bytes = 0usize;
    for line in lines {
        cancel.check()?;
        let remaining = limits.max_output_bytes.saturating_sub(bytes);
        let values = match op {
            LineOperation::Detab { tab_width } => vec![detab(line, *tab_width, remaining, cancel)?],
            LineOperation::Entab { tab_width } => vec![entab(line, *tab_width, remaining, cancel)?],
            LineOperation::ShiftRight(profile) => {
                width(profile.indent_width)?;
                width(profile.tab_width)?;
                let prefix = if profile.uses_tabs {
                    "\t".into()
                } else {
                    " ".repeat(profile.indent_width)
                };
                let mut out = String::new();
                push_bounded(&mut out, &prefix, remaining)?;
                push_bounded(&mut out, line, remaining)?;
                vec![out]
            }
            LineOperation::ShiftLeft(profile) => {
                width(profile.indent_width)?;
                width(profile.tab_width)?;
                let step = if profile.uses_tabs {
                    profile.tab_width
                } else {
                    profile.indent_width
                };
                let count = if line.starts_with('\t') {
                    1
                } else {
                    line.bytes().take(step).take_while(|c| *c == b' ').count()
                };
                vec![line[count..].into()]
            }
            LineOperation::HardWrap { column } => wrap(
                line,
                *column,
                separator.len(),
                remaining,
                limits.max_matches.saturating_sub(output.len()),
                cancel,
            )?,
            _ => unreachable!(),
        };
        for line in values {
            if output.len() >= limits.max_matches {
                return Err(Error::Limit);
            }
            bytes = bytes
                .checked_add(line.len())
                .and_then(|n| {
                    n.checked_add(if output.is_empty() {
                        0
                    } else {
                        separator.len()
                    })
                })
                .filter(|n| *n <= limits.max_output_bytes)
                .ok_or(Error::Limit)?;
            output.push(line);
        }
    }
    Ok(output)
}
