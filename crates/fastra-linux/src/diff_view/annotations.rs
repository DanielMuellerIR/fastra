use std::ops::Range;

pub(super) struct Annotations {
    pub rows: Vec<[Option<String>; 2]>,
    pub changed: Vec<bool>,
    pub blocks: Vec<Range<usize>>,
    pub marked: bool,
}

fn endings<'a>(text: &'a str, cancel: &fastra_diff::Cancellation) -> Result<Vec<&'a str>, String> {
    let mut result = Vec::new();
    let mut chars = text.char_indices().peekable();
    while let Some((start, ch)) = chars.next() {
        if matches!(ch, '\r' | '\n' | '\u{85}' | '\u{2028}' | '\u{2029}') {
            cancel.check().map_err(|e| e.to_string())?;
            let mut end = start + ch.len_utf8();
            if ch == '\r' && chars.peek().is_some_and(|(_, ch)| *ch == '\n') {
                end = chars.next().unwrap().0 + 1;
            }
            result.push(&text[start..end]);
        }
    }
    result.push("");
    Ok(result)
}
fn display(
    text: &str,
    ending: Option<&str>,
    unicode: bool,
    room: usize,
    cancel: &fastra_diff::Cancellation,
) -> Result<String, String> {
    let ending_label = ending.map(|ending| match ending {
        "\r\n" => "CRLF".into(),
        "\r" => "CR".into(),
        "\n" => "LF".into(),
        "" => "EOF".into(),
        other => other
            .chars()
            .map(|ch| format!("U+{:X}", ch as u32))
            .collect::<Vec<_>>()
            .join(" "),
    });
    let mut required = text
        .len()
        .saturating_add(
            ending_label
                .as_ref()
                .map_or(0, |label: &String| label.len() + 7),
        )
        .saturating_add(if unicode { 7 } else { 0 });
    if unicode {
        for (index, ch) in text.chars().enumerate() {
            if index % 2048 == 0 {
                cancel.check().map_err(|e| e.to_string())?;
            }
            required = required.saturating_add(match ch {
                '\\' => 2,
                ' '..='~' => 1,
                other => format!("\\u{{{:X}}}", other as u32).len(),
            });
            if required > room {
                return Err("annotation limit".into());
            }
        }
    }
    if required > room {
        return Err("annotation limit".into());
    }
    let mut value = text.to_owned();
    if unicode {
        value.push_str(" ⟦");
        for ch in text.chars() {
            match ch {
                '\\' => value.push_str("\\\\"),
                ' '..='~' => value.push(ch),
                other => value.push_str(&format!("\\u{{{:X}}}", other as u32)),
            }
        }
        value.push('⟧');
    }
    if let Some(label) = ending_label {
        value.push_str(" ⟦");
        value.push_str(&label);
        value.push('⟧');
    }
    Ok(value)
}
impl Annotations {
    pub fn build(
        comparison: &fastra_diff::Comparison,
        inputs: [&str; 2],
        cancel: &fastra_diff::Cancellation,
    ) -> Result<Self, String> {
        let ends = [endings(inputs[0], cancel)?, endings(inputs[1], cancel)?];
        let mut result = Self {
            rows: Vec::new(),
            changed: Vec::new(),
            blocks: Vec::new(),
            marked: false,
        };
        let mut bytes = [0usize; 2];
        for (index, row) in comparison.rows().iter().enumerate() {
            cancel.check().map_err(|e| e.to_string())?;
            let numbers = [row.left_line, row.right_line];
            let values = [
                row.left_line.and_then(|n| comparison.content(true, n)),
                row.right_line.and_then(|n| comparison.content(false, n)),
            ];
            let different = values[0] != values[1] || row.terminators_differ;
            let unicode = different
                && values
                    .iter()
                    .flatten()
                    .any(|value| value.chars().any(|ch| !(' '..='~').contains(&ch)));
            let single = numbers.iter().any(Option::is_none);
            let mut rendered: [Option<String>; 2] = [None, None];
            for side in 0..2 {
                if let (Some(value), Some(number)) = (values[side], numbers[side]) {
                    let ending =
                        (single || row.terminators_differ).then_some(ends[side][number - 1]);
                    let text = display(
                        value,
                        ending,
                        unicode,
                        (32 * 1024 * 1024usize).saturating_sub(bytes[side]),
                        cancel,
                    )?;
                    bytes[side] = bytes[side].saturating_add(text.len());
                    if bytes[side] > 32 * 1024 * 1024 {
                        return Err(
                            "Complete annotated comparison exceeds 32 MiB per column".into()
                        );
                    }
                    result.marked |= unicode || ending.is_some();
                    rendered[side] = Some(text);
                }
            }
            result.rows.push(rendered);
            result.changed.push(different);
            if different {
                if let Some(previous) = result
                    .blocks
                    .last_mut()
                    .filter(|previous| previous.end == index)
                {
                    previous.end += 1;
                } else {
                    result.blocks.push(index..index + 1);
                }
            }
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_preview_exposes_canonical_unicode_and_ending_changes() {
        let left = "é\r\nsame\r\n";
        let right = "e\u{301}\nsame\r\n";
        let snapshot = |id: &str, text: &str| fastra_diff::TextSnapshot {
            document_id: id.into(),
            revision: 0,
            text: text.into(),
        };
        let cancel = fastra_diff::Cancellation::default();
        let comparison = fastra_diff::Comparison::compare(
            snapshot("left", left),
            snapshot("right", right),
            0,
            Default::default(),
            Default::default(),
            &cancel,
        )
        .unwrap();
        let annotations = Annotations::build(&comparison, [left, right], &cancel).unwrap();
        assert!(annotations.marked);
        assert_eq!(
            annotations.rows[0][0].as_deref(),
            Some("é ⟦\\u{E9}⟧ ⟦CRLF⟧")
        );
        assert_eq!(
            annotations.rows[0][1].as_deref(),
            Some("e\u{301} ⟦e\\u{301}⟧ ⟦LF⟧")
        );
        assert_eq!(annotations.rows[1][0].as_deref(), Some("same"));
        assert_eq!(annotations.blocks, vec![0..1]);
    }
    #[test]
    fn complete_annotation_fits_exactly_or_returns_no_text() {
        let cancel = fastra_diff::Cancellation::default();
        let expected = "é ⟦\\u{E9}⟧ ⟦EOF⟧";
        assert_eq!(
            display("é", Some(""), true, expected.len(), &cancel).unwrap(),
            expected
        );
        assert!(display("é", Some(""), true, expected.len() - 1, &cancel).is_err());
        cancel.cancel();
        assert!(display("é", Some(""), true, 1024, &cancel).is_err());
    }
}
