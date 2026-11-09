//! Exakte reine Textdarstellung für Freigaben; keine Suche und keine Kürzung.
use crate::{Cancellation, Error};
use std::fmt::Write;
use std::ops::Range;
use unicode_normalization::UnicodeNormalization;

/// Gemeinsamer Präfix/Suffix wie im Mac-Diff. Bereiche zählen Unicode-Skalare
/// für native Textpuffer; Grapheme bleiben einschließlich ZWJ und Akzenten ganz.
/// `None` bezeichnet die bewusst begrenzte Detailmarkierung langer Zeilen.
pub fn intraline_ranges(
    before: &str,
    after: &str,
) -> Result<Option<[Option<Range<usize>>; 2]>, Error> {
    let mut parts = [Vec::new(), Vec::new()];
    for (text, output) in [before, after].into_iter().zip(parts.iter_mut()) {
        let result = crate::icu::walk_graphemes(text, |part| {
            if output.len() == 4096 {
                return Err(Error::Limit);
            }
            output.push(part);
            Ok(())
        });
        match result {
            Err(Error::Limit) => return Ok(None),
            other => other?,
        }
    }
    let same = |a: &str, b: &str| a == b || a.nfc().eq(b.nfc());
    let [a, b] = &parts;
    let mut prefix = 0;
    while prefix < a.len().min(b.len()) && same(a[prefix], b[prefix]) {
        prefix += 1;
    }
    let mut suffix = 0;
    while suffix < a.len().min(b.len()) - prefix
        && same(a[a.len() - 1 - suffix], b[b.len() - 1 - suffix])
    {
        suffix += 1;
    }
    Ok(Some(parts.each_ref().map(|parts| {
        let start = parts[..prefix].iter().map(|p| p.chars().count()).sum();
        let length: usize = parts[prefix..parts.len() - suffix]
            .iter()
            .map(|p| p.chars().count())
            .sum();
        (length > 0).then_some(start..start + length)
    })))
}
const MAX_INPUT: usize = 8 * 1024 * 1024;
const MAX_OUTPUT: usize = 64 * 1024 * 1024;
fn width(character: char) -> usize {
    match character {
        '\\' | '\r' | '\t' => 2,
        '\n' => 3,
        ' '..='~' => 1,
        c => 4 + ((32 - (c as u32).leading_zeros()).div_ceil(4) as usize).max(1),
    }
}
/// Backslash wird verdoppelt, CR/Tab werden `\r`/`\t`, LF wird `\n` plus
/// sichtbarer Zeilenumbruch. Andere Steuerzeichen und Nicht-ASCII werden
/// als `\u{HEX}` gezeigt. Die Grenzen gelten einschließlich dieser Marker.
pub fn escaped_text(
    input: &str,
    cancel: &Cancellation,
    max_output_bytes: usize,
) -> Result<String, Error> {
    cancel.check()?;
    if input.len() > MAX_INPUT || max_output_bytes > MAX_OUTPUT {
        return Err(Error::Limit);
    }
    let mut required = 0usize;
    for (index, character) in input.chars().enumerate() {
        if index % 1024 == 0 {
            cancel.check()?;
        }
        required = required.checked_add(width(character)).ok_or(Error::Limit)?;
        if required > max_output_bytes {
            return Err(Error::Limit);
        }
    }
    // Erst die vollständige Größe prüfen; so gibt es weder übergroße
    // Zwischenallokationen noch einen abgeschnittenen Freigabetext.
    let mut result = String::with_capacity(required);
    for (index, character) in input.chars().enumerate() {
        if index % 1024 == 0 {
            cancel.check()?;
        }
        match character {
            '\\' => result.push_str("\\\\"),
            '\r' => result.push_str("\\r"),
            '\n' => result.push_str("\\n\n"),
            '\t' => result.push_str("\\t"),
            ' '..='~' => result.push(character),
            c => write!(&mut result, "\\u{{{:X}}}", c as u32).map_err(|_| Error::Limit)?,
        }
    }
    cancel.check()?;
    Ok(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn intraline_preserves_graphemes_canonical_prefixes_and_the_detail_limit() {
        assert_eq!(
            intraline_ranges("é 👩‍💻 old!", "e\u{301} 👨‍💻 new!").unwrap(),
            Some([Some(2..9), Some(3..10)])
        );
        assert_eq!(
            intraline_ranges("same", "same!").unwrap(),
            Some([None, Some(4..5)])
        );
        assert_eq!(intraline_ranges(&"x".repeat(4097), "y").unwrap(), None);
        assert_eq!(
            intraline_ranges(&"x".repeat(4096), &"x".repeat(4096)).unwrap(),
            Some([None, None])
        );
    }
    #[test]
    fn exact_unicode_endings_and_limits() {
        let cancel = Cancellation::default();
        assert_eq!(
            escaped_text("é e\u{301}\t\r\n\0\\\u{7f}😀", &cancel, 1024).unwrap(),
            "\\u{E9} e\\u{301}\\t\\r\\n\n\\u{0}\\\\\\u{7F}\\u{1F600}"
        );
        assert_ne!(
            escaped_text("é", &cancel, 64).unwrap(),
            escaped_text("e\u{301}", &cancel, 64).unwrap()
        );
        assert_eq!(escaped_text("é", &cancel, 6).unwrap(), "\\u{E9}");
        assert_eq!(escaped_text("", &cancel, 0).unwrap(), "");
        assert_eq!(escaped_text("é", &cancel, 5), Err(Error::Limit));
        assert_eq!(
            escaped_text("x", &cancel, MAX_OUTPUT + 1),
            Err(Error::Limit)
        );
        assert_eq!(
            escaped_text(&"x".repeat(MAX_INPUT + 1), &cancel, MAX_OUTPUT),
            Err(Error::Limit)
        );
        cancel.cancel();
        assert_eq!(escaped_text("x", &cancel, 1), Err(Error::Cancelled));
    }
    #[test]
    fn cancellation_during_a_large_display() {
        let input = "\u{7f}".repeat(MAX_INPUT);
        let cancel = Cancellation::default();
        let worker = cancel.clone();
        let task = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(5));
            worker.cancel();
        });
        let result = escaped_text(&input, &cancel, MAX_OUTPUT);
        task.join().unwrap();
        assert_eq!(result, Err(Error::Cancelled));
    }
}
