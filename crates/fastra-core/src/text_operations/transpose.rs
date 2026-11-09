use super::*;
#[derive(Clone, Copy, PartialEq, Eq)]
struct Span {
    start: usize,
    end: usize,
    byte_start: usize,
    byte_end: usize,
}
fn roll(pair: &mut [Option<Span>; 2], span: Span) {
    pair[0] = pair[1];
    pair[1] = Some(span);
}
fn swap(
    text: &str,
    a: Span,
    b: Span,
    block_lf: bool,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    let left = &text[a.byte_start..a.byte_end];
    let right = &text[b.byte_start..b.byte_end];
    if block_lf && (left == "\n" || right == "\n")
        || canonical_eq(left, right, limits.max_output_bytes, cancel)?
    {
        return Ok(None);
    }
    let mut replacement = String::new();
    push_bounded(&mut replacement, right, limits.max_output_bytes)?;
    push_bounded(
        &mut replacement,
        &text[a.byte_end..b.byte_start],
        limits.max_output_bytes,
    )?;
    push_bounded(&mut replacement, left, limits.max_output_bytes)?;
    finish(
        text,
        Utf16Range {
            location: a.start,
            length: b.end - a.start,
        },
        replacement,
        0,
        limits,
        cancel,
    )
}
fn characters(
    text: &str,
    selection: Utf16Range,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    let end = selection.end()?;
    let mut unit = 0;
    let mut byte = 0;
    let mut first = None;
    let mut last = None;
    let mut before = [None; 2];
    let mut after = [None; 2];
    let mut caret_byte = None;
    icu::walk_graphemes(text, |ch| {
        cancel.check()?;
        let span = Span {
            start: unit,
            end: unit + ch.encode_utf16().count(),
            byte_start: byte,
            byte_end: byte + ch.len(),
        };
        if span.start == selection.location {
            first = Some(span);
            caret_byte = Some(byte);
        }
        if span.end == end {
            last = Some(span);
        }
        if span.end <= selection.location {
            roll(&mut before, span);
        }
        if span.start == selection.location {
            after[0] = Some(span);
        } else if after[0].is_some() && after[1].is_none() {
            after[1] = Some(span);
        }
        unit = span.end;
        byte = span.byte_end;
        Ok(())
    })?;
    if selection.length > 0 {
        return match (first, last) {
            (Some(a), Some(b)) if a != b => swap(text, a, b, false, limits, cancel),
            _ => Ok(None),
        };
    }
    if selection.location == unit {
        caret_byte = Some(text.len());
    }
    let Some(caret) = caret_byte else {
        return Ok(None);
    };
    let at_start = caret == 0 || text[..caret].ends_with('\n');
    let at_end = caret == text.len() || text[caret..].starts_with('\n');
    let pair = if at_start && at_end {
        return Ok(None);
    } else if at_start {
        after
    } else if at_end {
        before
    } else {
        [before[1], after[0]]
    };
    match pair {
        [Some(a), Some(b)] => swap(text, a, b, true, limits, cancel),
        _ => Ok(None),
    }
}
#[derive(Default)]
struct Candidates {
    first: Option<Span>,
    last: Option<Span>,
    following: [Option<Span>; 2],
    before: [Option<Span>; 2],
    left: [Option<Span>; 2],
    right: Option<Span>,
}
impl Candidates {
    fn add(&mut self, span: Span, selection: Utf16Range, end: usize) {
        if span.start >= selection.location && span.end <= end {
            if self.first.is_none() {
                self.first = Some(span);
            }
            self.last = Some(span);
        }
        if span.start >= selection.location {
            if self.following[0].is_none() {
                self.following[0] = Some(span);
            } else if self.following[1].is_none() {
                self.following[1] = Some(span);
            }
            if self.right.is_none() {
                self.right = Some(span);
            }
        }
        if span.end <= selection.location {
            roll(&mut self.before, span);
        }
        if span.start < selection.location {
            roll(&mut self.left, span);
        }
    }
}
fn words(
    text: &str,
    selection: Utf16Range,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    let end = selection.end()?;
    let mut candidates = Candidates::default();
    let mut start = None;
    let mut unit = 0;
    let mut at_start = selection.location == 0;
    let mut at_end = false;
    for (byte, c) in text.char_indices() {
        cancel.check()?;
        let next = unit + c.len_utf16();
        if c == '\n' {
            at_start |= next == selection.location;
            at_end |= unit == selection.location;
        }
        // Das Original prüft einzelne NSString-UTF16-Zellen; Supplementärzeichen sind keine Wörter.
        if c.len_utf16() == 1 && scalar_flags(c) & 1 != 0 {
            if start.is_none() {
                start = Some((unit, byte));
            }
        } else if let Some((word, byte_start)) = start.take() {
            candidates.add(
                Span {
                    start: word,
                    end: unit,
                    byte_start,
                    byte_end: byte,
                },
                selection,
                end,
            );
        }
        unit = next;
    }
    if let Some((start, byte_start)) = start {
        candidates.add(
            Span {
                start,
                end: unit,
                byte_start,
                byte_end: text.len(),
            },
            selection,
            end,
        );
    }
    if selection.length == 0 && selection.location > unit {
        return Ok(None);
    }
    at_end |= selection.location == unit;
    let pair = if selection.length > 0 {
        [candidates.first, candidates.last]
    } else if at_start && at_end {
        return Ok(None);
    } else if at_start {
        candidates.following
    } else if at_end {
        candidates.before
    } else if let (Some(left), Some(right)) = (candidates.left[1], candidates.right) {
        if left != right {
            [Some(left), Some(right)]
        } else {
            candidates.left
        }
    } else {
        candidates.left
    };
    match pair {
        [Some(a), Some(b)] if a != b => swap(text, a, b, false, limits, cancel),
        _ => Ok(None),
    }
}
pub(super) fn transform(
    text: &str,
    selection: Utf16Range,
    operation: CharacterOperation,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Option<TextResult>, Error> {
    match operation {
        CharacterOperation::ExchangeCharacters => characters(text, selection, limits, cancel),
        CharacterOperation::ExchangeWords => words(text, selection, limits, cancel),
        _ => unreachable!(),
    }
}
