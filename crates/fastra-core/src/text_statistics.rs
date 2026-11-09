//! Footerzahlen wie im Mac-Editor: Grapheme statt Codepoints, CRLF als ein Zeichen.
use crate::{Cancellation, Error, icu};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Counts {
    pub characters: usize,
    pub words: usize,
    pub lines: usize,
}

pub fn count(text: &str, cancel: &Cancellation) -> Result<Counts, Error> {
    cancel.check()?;
    let mut counts = Counts {
        characters: 0,
        words: 0,
        lines: 1,
    };
    let mut inside_word = false;
    icu::walk_graphemes(text, |grapheme| {
        if counts.characters % 256 == 0 {
            cancel.check()?;
        }
        let first = grapheme.chars().next().ok_or(Error::InvalidRange)?;
        counts.characters += 1;
        if matches!(
            first,
            '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
        ) {
            counts.lines += 1;
        }
        if first.is_whitespace() {
            inside_word = false;
        } else if !inside_word {
            counts.words += 1;
            inside_word = true;
        }
        Ok(())
    })?;
    cancel.check()?;
    Ok(counts)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mac_character_word_and_line_examples() {
        for (text, characters, words, lines) in [
            ("", 0, 0, 1),
            ("e\u{301} 👩\u{200d}💻\r\nx\u{85}z", 7, 4, 3),
            (" \u{301}", 1, 0, 1),
            ("🇩🇪 👩\u{200d}💻", 3, 2, 1),
            ("a\r\nb\rc\n", 6, 3, 4),
        ] {
            assert_eq!(
                count(text, &Cancellation::default()).unwrap(),
                Counts {
                    characters,
                    words,
                    lines
                }
            );
        }
    }
    #[test]
    fn cancelled_count_has_no_partial_result() {
        let cancel = Cancellation::default();
        cancel.cancel();
        assert_eq!(count("text", &cancel), Err(Error::Cancelled));
    }
}
