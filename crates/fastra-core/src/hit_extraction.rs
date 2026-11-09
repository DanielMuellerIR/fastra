//! Extraktion folgt dem Mac-Vertrag: Reihenfolge, kanonische Duplikate und CSV-Quoting.
use crate::{Cancellation, Error};
use std::collections::HashSet;
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Copy)]
pub enum Quoting {
    None,
    WhenNeeded,
    Always,
}
pub struct Options {
    pub separator: String,
    pub append_newline: bool,
    pub quoting: Quoting,
    pub deduplicate: bool,
}

pub fn content(
    values: &[String],
    options: &Options,
    max_bytes: usize,
    cancel: &Cancellation,
) -> Result<String, Error> {
    if values.len() > 100_000 {
        return Err(Error::Limit);
    }
    let mut output = String::new();
    let mut seen = HashSet::new();
    let mut count = 0;
    for value in values {
        cancel.check()?;
        if value.len() > max_bytes {
            return Err(Error::Limit);
        }
        if options.deduplicate && !seen.insert(value.nfc().collect::<String>()) {
            continue;
        }
        let quote = match options.quoting {
            Quoting::None => false,
            Quoting::Always => true,
            Quoting::WhenNeeded => {
                value.contains(&options.separator) || value.contains(['"', '\r', '\n'])
            }
        };
        let bytes = value
            .len()
            .checked_add(if quote {
                value.bytes().filter(|b| *b == b'"').count() + 2
            } else {
                0
            })
            .and_then(|size| {
                size.checked_add(if count > 0 {
                    options.separator.len()
                } else {
                    0
                })
            })
            .ok_or(Error::Limit)?;
        if output.len().saturating_add(bytes) > max_bytes {
            return Err(Error::Limit);
        }
        if count > 0 {
            output.push_str(&options.separator);
        }
        if quote {
            output.push('"');
            for ch in value.chars() {
                output.push(ch);
                if ch == '"' {
                    output.push('"');
                }
            }
            output.push('"');
        } else {
            output.push_str(value);
        }
        count += 1;
    }
    if count > 0 && options.append_newline {
        if output.len() == max_bytes {
            return Err(Error::Limit);
        }
        output.push('\n');
    }
    cancel.check()?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mac_examples_order_quotes_canonical_dedup_and_final_newline() {
        for (values, separator, append_newline, quoting, deduplicate, expected) in [
            (
                vec!["foo", "foo"],
                "\n",
                true,
                Quoting::None,
                false,
                "foo\nfoo\n",
            ),
            (
                vec!["a;b", "a;b", "plain"],
                ";",
                false,
                Quoting::WhenNeeded,
                true,
                "\"a;b\";plain",
            ),
            (
                vec!["red", "blue"],
                " | ",
                false,
                Quoting::Always,
                false,
                "\"red\" | \"blue\"",
            ),
            (
                vec!["e\u{301}", "é", "猫"],
                ",",
                false,
                Quoting::None,
                true,
                "e\u{301},猫",
            ),
            (
                vec!["a\"b", "a\nb", ""],
                ",",
                false,
                Quoting::WhenNeeded,
                false,
                "\"a\"\"b\",\"a\nb\",",
            ),
            (vec![""], "\n", true, Quoting::None, false, "\n"),
            (vec![], "\n", true, Quoting::None, false, ""),
        ] {
            assert_eq!(
                content(
                    &values.into_iter().map(str::to_owned).collect::<Vec<_>>(),
                    &Options {
                        separator: separator.into(),
                        append_newline,
                        quoting,
                        deduplicate
                    },
                    1024,
                    &Cancellation::default()
                )
                .unwrap(),
                expected
            );
        }
    }
    #[test]
    fn output_expansion_and_trailing_newline_are_bounded_without_partial_result() {
        let options = Options {
            separator: ",".into(),
            append_newline: true,
            quoting: Quoting::Always,
            deduplicate: false,
        };
        assert_eq!(
            content(&["\"".into()], &options, 4, &Cancellation::default()),
            Err(Error::Limit)
        );
        assert_eq!(
            content(&["\"".into()], &options, 5, &Cancellation::default()).unwrap(),
            "\"\"\"\"\n"
        );
        let cancel = Cancellation::default();
        cancel.cancel();
        assert_eq!(
            content(&["x".into()], &options, 1024, &cancel),
            Err(Error::Cancelled)
        );
    }
}
