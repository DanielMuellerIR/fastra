//! Kompakte Zeilenpaare aus bereits freigegebenen Treffern, wie in der Mac-Suchmaske.
use crate::{Cancellation, Error, Preview, Utf16Range};

#[derive(Debug, PartialEq, Eq)]
pub struct Row {
    pub line: usize,
    pub before: String,
    pub after: String,
}
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Summary {
    pub rows: Vec<Row>,
    pub total_changed_lines: usize,
}
pub fn build(
    preview: &Preview,
    approved: &[usize],
    cancel: &Cancellation,
) -> Result<Summary, Error> {
    cancel.check()?;
    let source = preview.source();
    let mut lines = Vec::new();
    let mut start = 0;
    let mut chars = source.char_indices().peekable();
    while let Some((byte, ch)) = chars.next() {
        if byte % 512 == 0 {
            cancel.check()?;
        }
        if matches!(ch, '\r' | '\n' | '\u{85}' | '\u{2028}' | '\u{2029}') {
            if lines.len() >= 200_000 {
                return Err(Error::Limit);
            }
            lines.push((start, byte));
            start = byte + ch.len_utf8();
            if ch == '\r' && chars.peek().is_some_and(|(_, ch)| *ch == '\n') {
                start = chars.next().unwrap().0 + 1;
            }
        }
    }
    lines.push((start, source.len()));
    let mut groups =
        std::collections::BTreeMap::<usize, Vec<(std::ops::Range<usize>, &str)>>::new();
    let mut byte = 0;
    let mut units = 0;
    let mut last = None;
    for &index in approved {
        cancel.check()?;
        if last.is_some_and(|last| index <= last) {
            return Err(Error::InvalidRange);
        }
        last = Some(index);
        let hit = preview.matches().get(index).ok_or(Error::InvalidRange)?;
        let relative = Utf16Range {
            location: hit
                .range
                .location
                .checked_sub(units)
                .ok_or(Error::InvalidRange)?,
            length: hit.range.length,
        }
        .byte_range(&source[byte..])?;
        let range = (byte + relative.start)..(byte + relative.end);
        byte = range.end;
        units = hit
            .range
            .location
            .checked_add(hit.range.length)
            .ok_or(Error::InvalidRange)?;
        let line = lines
            .partition_point(|(start, _)| *start <= range.start)
            .saturating_sub(1);
        groups
            .entry(line)
            .or_default()
            .push((range, &hit.replacement));
    }
    let mut result = Summary::default();
    let mut output_bytes = 0usize;
    for (line, hits) in groups {
        cancel.check()?;
        let (start, end) = lines[line];
        let before = &source[start..end];
        let mut after = String::new();
        let mut cursor = start;
        for (range, replacement) in hits {
            let at = range.start.max(cursor);
            if at > end {
                continue;
            }
            if output_bytes
                .checked_add(after.len())
                .and_then(|n| n.checked_add(at - cursor))
                .and_then(|n| n.checked_add(replacement.len()))
                .is_none_or(|n| n > 64 * 1024 * 1024)
            {
                return Err(Error::Limit);
            }
            after.push_str(&source[cursor..at]);
            after.push_str(replacement);
            cursor = cursor.max(range.end.min(end));
        }
        if output_bytes
            .checked_add(after.len())
            .and_then(|n| n.checked_add(end - cursor))
            .is_none_or(|n| n > 64 * 1024 * 1024)
        {
            return Err(Error::Limit);
        }
        after.push_str(&source[cursor..end]);
        output_bytes = output_bytes.checked_add(after.len()).ok_or(Error::Limit)?;
        if output_bytes > 64 * 1024 * 1024 {
            return Err(Error::Limit);
        }
        if after != before {
            result.total_changed_lines += 1;
            if result.rows.len() < 3 {
                result.rows.push(Row {
                    line: line + 1,
                    before: before.into(),
                    after,
                });
            }
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Limits, SearchMode, SearchRequest};
    fn preview(text: &str, pattern: &str, replacement: &str) -> Preview {
        crate::preview(
            text,
            7,
            11,
            &SearchRequest {
                pattern: pattern.into(),
                replacement: replacement.into(),
                mode: SearchMode::Regex,
                case_sensitive: true,
                range: None,
            },
            Limits::default(),
            &Cancellation::default(),
        )
        .unwrap()
    }
    #[test]
    fn approved_lines_group_unicode_crlf_and_report_remaining_rows() {
        let p = preview("🙂cat cat\r\ncat\r\ncat\ncat\u{2028}cat", "cat", "犬");
        let s = build(&p, &[1, 2, 3, 4, 5], &Cancellation::default()).unwrap();
        assert_eq!(s.total_changed_lines, 5);
        assert_eq!(s.rows.len(), 3);
        assert_eq!(
            s.rows[0],
            Row {
                line: 1,
                before: "🙂cat cat".into(),
                after: "🙂cat 犬".into()
            }
        );
        assert_eq!(s.rows[2].line, 3);
        assert!(build(&p, &[], &Cancellation::default())
            .unwrap()
            .rows
            .is_empty());
        assert!(build(&p, &[1, 1], &Cancellation::default()).is_err());
        assert!(build(&p, &[99], &Cancellation::default()).is_err());
    }
    #[test]
    fn no_op_multiline_and_zero_width_use_mac_line_contract() {
        let p = preview("cat cat", "cat", "cat");
        assert_eq!(
            build(&p, &[0, 1], &Cancellation::default()).unwrap(),
            Summary::default()
        );
        let p = preview("a\r\nb\nc", "a\\r\\nb", "x\ny");
        assert_eq!(
            build(&p, &[0], &Cancellation::default()).unwrap().rows[0],
            Row {
                line: 1,
                before: "a".into(),
                after: "x\ny".into()
            }
        );
        let p = preview("🙂\n", "\\z", "end");
        assert_eq!(
            build(&p, &[0], &Cancellation::default()).unwrap().rows[0],
            Row {
                line: 2,
                before: "".into(),
                after: "end".into()
            }
        );
        let huge = preview(&"\n".repeat(200_001), "\\z", "end");
        assert!(matches!(
            build(&huge, &[0], &Cancellation::default()),
            Err(Error::Limit)
        ));
        let c = Cancellation::default();
        c.cancel();
        assert!(build(&p, &[0], &c).is_err());
    }
}
