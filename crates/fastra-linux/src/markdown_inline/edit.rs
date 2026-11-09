use std::ops::Range;
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Edit {
    pub range: (i32, i32),
    pub remove_markers: bool,
    pub bytes: Range<usize>,
    pub replacement: String,
    pub selection: (i32, i32),
}
fn byte_at(source: &str, offset: i32) -> Option<usize> {
    let offset = usize::try_from(offset).ok()?;
    source
        .char_indices()
        .map(|(byte, _)| byte)
        .chain(std::iter::once(source.len()))
        .nth(offset)
}
pub(super) fn toggle(source: &str, (start, end): (i32, i32), marker: &str) -> Option<Edit> {
    if start > end || !matches!(marker, "**" | "*" | "==" | "`") {
        return None;
    }
    let a = byte_at(source, start)?;
    let b = byte_at(source, end)?;
    let selected = &source[a..b];
    let m = i32::try_from(marker.len()).ok()?;
    if selected.len() >= 2 * marker.len()
        && selected.starts_with(marker)
        && selected.ends_with(marker)
    {
        let inner = selected[marker.len()..selected.len() - marker.len()].to_owned();
        return Some(Edit {
            range: (start, end),
            remove_markers: true,
            bytes: a..b,
            replacement: inner,
            selection: (start, end - 2 * m),
        });
    }
    if source[..a].ends_with(marker) && source[b..].starts_with(marker) {
        return Some(Edit {
            range: (start - m, end + m),
            remove_markers: true,
            bytes: a - marker.len()..b + marker.len(),
            replacement: selected.to_owned(),
            selection: (start - m, end - m),
        });
    }
    Some(Edit {
        range: (start, end),
        remove_markers: false,
        bytes: a..b,
        replacement: format!("{marker}{selected}{marker}"),
        selection: (start + m, end + m),
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    fn check(source: &str, range: (i32, i32), marker: &str, expected: &str, selection: (i32, i32)) {
        let edit = toggle(source, range, marker).unwrap();
        let prefix = &source[..edit.bytes.start];
        let suffix = &source[edit.bytes.end..];
        let mut result = source.to_owned();
        result.replace_range(edit.bytes.clone(), &edit.replacement);
        assert_eq!(result, expected);
        assert_eq!(edit.selection, selection);
        assert!(result.starts_with(prefix) && result.ends_with(suffix));
    }
    #[test]
    fn mac_reference_cases() {
        check("ein wort hier", (4, 8), "**", "ein **wort** hier", (6, 10));
        check("ein **wort** hier", (6, 10), "**", "ein wort hier", (4, 8));
        check("ein **wort** hier", (4, 12), "**", "ein wort hier", (4, 8));
        check("abc", (3, 3), "*", "abc**", (4, 4));
        check(
            "Das ist wichtig.",
            (8, 15),
            "==",
            "Das ist ==wichtig==.",
            (10, 17),
        );
    }
    #[test]
    fn every_marker_unicode_empty_pairs_and_exact_outside_bytes() {
        for marker in ["**", "*", "==", "`"] {
            let source = "前\r\n雪🙂e\u{301}\r\n後";
            let wrapped = format!("前\r\n{marker}雪🙂e\u{301}{marker}\r\n後");
            let m = marker.len() as i32;
            check(source, (3, 7), marker, &wrapped, (3 + m, 7 + m));
            check(&wrapped, (3 + m, 7 + m), marker, source, (3, 7));
            check(&wrapped, (3, 7 + 2 * m), marker, source, (3, 7));
            let pair = format!("x{marker}{marker}y");
            check("xy", (1, 1), marker, &pair, (1 + m, 1 + m));
            check(&pair, (1 + m, 1 + m), marker, "xy", (1, 1));
            check(&pair, (1, 1 + 2 * m), marker, "xy", (1, 1));
        }
    }
    #[test]
    fn boundaries_and_unmatched_markers() {
        assert!(toggle("雪🙂", (-1, 1), "**").is_none());
        assert!(toggle("雪🙂", (0, 3), "**").is_none());
        assert!(toggle("abc", (2, 1), "**").is_none());
        assert!(toggle("abc", (0, 1), "~").is_none());
        check("*雪", (1, 2), "*", "**雪*", (2, 3));
        check("", (0, 0), "`", "``", (1, 1));
    }
}
