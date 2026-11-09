//! Markdown-Quellbefehle nach dem Mac-Vertrag; Bereiche bleiben in UTF-16.
use crate::{icu, Cancellation, Error, Limits, Utf16Range};
use std::ops::Range;
const MAX_BYTES: usize = 32 * 1024 * 1024;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    Heading(u8),
    BulletList,
    OrderedList,
    TaskList,
    Quote,
    HardBreak,
    Link,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Edit {
    pub range: Utf16Range,
    pub replacement: String,
    pub selection: Utf16Range,
}
fn whitespace(ch: char) -> bool {
    // Foundation führt U+200B in CharacterSet.whitespaces weiter mit.
    matches!(
        ch,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}
fn checked_range(
    source: &str,
    range: Utf16Range,
    cancel: &Cancellation,
) -> Result<Range<usize>, Error> {
    cancel.check()?;
    if source.len() > MAX_BYTES {
        return Err(Error::Limit);
    }
    range.byte_range(source)
}
fn make(
    source: &str,
    range: Range<usize>,
    replacement: String,
    relative: Utf16Range,
) -> Result<Edit, Error> {
    if source.len() - range.len() + replacement.len() > MAX_BYTES {
        return Err(Error::Limit);
    }
    let start = source[..range.start].encode_utf16().count();
    Ok(Edit {
        range: Utf16Range {
            location: start,
            length: source[range].encode_utf16().count(),
        },
        replacement,
        selection: Utf16Range {
            location: start + relative.location,
            length: relative.length,
        },
    })
}
struct Lines<'a> {
    text: &'a str,
    cursor: usize,
    finished: bool,
    foundation: bool,
    cancel: &'a Cancellation,
}
impl<'a> Lines<'a> {
    fn new(text: &'a str, foundation: bool, cancel: &'a Cancellation) -> Self {
        Self {
            text,
            cursor: 0,
            finished: false,
            foundation,
            cancel,
        }
    }
}
impl Iterator for Lines<'_> {
    type Item = Result<Range<usize>, Error>;
    fn next(&mut self) -> Option<Self::Item> {
        if self.finished {
            return None;
        }
        let start = self.cursor;
        let mut count = 0;
        while self.cursor < self.text.len() {
            if count % 4096 == 0 {
                if let Err(error) = self.cancel.check() {
                    self.finished = true;
                    return Some(Err(error));
                }
            }
            let ch = self.text[self.cursor..].chars().next().unwrap();
            self.cursor += ch.len_utf8();
            count += 1;
            if ch == '\r' && self.text[self.cursor..].starts_with('\n') {
                self.cursor += 1;
                return Some(Ok(start..self.cursor));
            }
            if matches!(ch, '\r' | '\n')
                || (self.foundation && matches!(ch, '\u{85}' | '\u{2028}' | '\u{2029}'))
            {
                return Some(Ok(start..self.cursor));
            }
        }
        self.finished = true;
        Some(Ok(start..self.cursor))
    }
}
fn line_range(
    source: &str,
    selection: Range<usize>,
    cancel: &Cancellation,
) -> Result<Range<usize>, Error> {
    let target = if selection.is_empty() {
        selection.end
    } else {
        selection.end - 1
    };
    let mut start = None;
    let mut end = source.len();
    for line in Lines::new(source, true, cancel) {
        let line = line?;
        if start.is_none() && (selection.start < line.end || line.end == line.start) {
            start = Some(line.start);
        }
        if target < line.end || line.end == line.start {
            end = line.end;
            break;
        }
    }
    while end > start.unwrap_or(source.len()) && matches!(source.as_bytes()[end - 1], b'\r' | b'\n')
    {
        end -= 1;
    }
    Ok(start.unwrap_or(source.len())..end)
}
struct Prefixes {
    heading: icu::Regex,
    bullet: icu::Regex,
    ordered: icu::Regex,
    quote: icu::Regex,
    task: icu::Regex,
}
impl Prefixes {
    fn new(cancel: &Cancellation) -> Result<Self, Error> {
        let regex = |pattern| icu::Regex::new(pattern, "", true, Limits::default(), cancel);
        Ok(Self {
            heading: regex(r"^#{1,6}\s+")?,
            bullet: regex(r"^[-*+]\s+")?,
            ordered: regex(r"^\d+[.)]\s+")?,
            quote: regex(r"^>\s?")?,
            task: regex(r"^(?:[-*+]|\d+[.)])\s+\[[ xX]\]\s*")?,
        })
    }
    fn end(regex: &icu::Regex, text: &str) -> Result<usize, Error> {
        let mut matcher = regex.with_text(text)?;
        let hit = matcher.next()?.and_then(|captures| captures[0]);
        hit.map_or(Ok(0), |range| Ok(range.byte_range(text)?.end))
    }
    fn plain<'a>(&self, text: &'a str) -> Result<&'a str, Error> {
        let mut text = text;
        for regex in [&self.task, &self.bullet, &self.ordered, &self.quote] {
            text = &text[Self::end(regex, text)?..];
        }
        Ok(text)
    }
}
fn parts(text: &str) -> (&str, &str) {
    let n = text.len() - text.trim_start_matches([' ', '\t']).len();
    text.split_at(n)
}
pub fn edit(
    source: &str,
    selection: Utf16Range,
    command: Command,
    cancel: &Cancellation,
) -> Result<Option<Edit>, Error> {
    let bytes = checked_range(source, selection, cancel)?;
    if command == Command::Link {
        let selected = &source[bytes.clone()];
        let replacement = format!("[{selected}]()");
        let cursor = if selected.is_empty() {
            1
        } else {
            selected.encode_utf16().count() + 3
        };
        return make(
            source,
            bytes,
            replacement,
            Utf16Range {
                location: cursor,
                length: 0,
            },
        )
        .map(Some);
    }
    if command == Command::HardBreak {
        let at = bytes.end;
        let start = source[..at].rfind(['\r', '\n']).map_or(0, |n| n + 1);
        if source[start..at].trim_matches(whitespace).is_empty() {
            return Ok(None);
        }
        let spaces = source[start..at]
            .bytes()
            .rev()
            .take_while(|b| *b == b' ')
            .count();
        let before_newline = source[at..].starts_with(['\r', '\n']);
        if spaces == 2 && before_newline {
            return Ok(None);
        }
        let ending = match crate::encoding::LineEnding::detect(source) {
            crate::encoding::LineEnding::Lf => "\n",
            crate::encoding::LineEnding::CrLf => "\r\n",
            crate::encoding::LineEnding::Cr => "\r",
        };
        let replacement = format!("  {}", if before_newline { "" } else { ending });
        let cursor = replacement.len();
        return make(
            source,
            at - spaces..at,
            replacement,
            Utf16Range {
                location: cursor,
                length: 0,
            },
        )
        .map(Some);
    }
    if matches!(command,Command::Heading(level) if level>6) {
        return Err(Error::InvalidRange);
    }
    let range = line_range(source, bytes, cancel)?;
    let block = &source[range.clone()];
    let rules = Prefixes::new(cancel)?;
    let mut remove = true;
    let mut visible = false;
    for line in Lines::new(block, false, cancel) {
        let line = &block[line?];
        let content = line.trim_end_matches(['\r', '\n']);
        if content.trim_matches(whitespace).is_empty() {
            continue;
        }
        visible = true;
        let (_, content) = parts(content);
        let yes = match command {
            Command::TaskList => Prefixes::end(&rules.task, content)? > 0,
            Command::BulletList => {
                Prefixes::end(&rules.bullet, content)? > 0
                    && Prefixes::end(&rules.task, content)? == 0
            }
            Command::OrderedList => {
                Prefixes::end(&rules.ordered, content)? > 0
                    && Prefixes::end(&rules.task, content)? == 0
            }
            Command::Quote => {
                Prefixes::end(&rules.quote, content)? > 0
                    && Prefixes::end(&rules.task, content)? == 0
            }
            _ => false,
        };
        remove &= yes;
    }
    remove &= visible;
    let mut result = String::new();
    let mut index = 0;
    for line in Lines::new(block, false, cancel) {
        cancel.check()?;
        let line = &block[line?];
        let content = line.trim_end_matches(['\r', '\n']);
        let ending = &line[content.len()..];
        if content.trim_matches(whitespace).is_empty() {
            result.push_str(line);
            continue;
        }
        index += 1;
        if let Command::Heading(level) = command {
            let plain = &content[Prefixes::end(&rules.heading, content)?..];
            if level > 0 {
                result.push_str(&"#".repeat(level as usize));
                result.push(' ');
            }
            result.push_str(plain);
        } else {
            let (indentation, content) = parts(content);
            result.push_str(indentation);
            let task = Prefixes::end(&rules.task, content)?;
            if command == Command::TaskList {
                if task > 0 {
                    result.push_str(if remove { &content[task..] } else { content });
                } else {
                    let plain = &content[Prefixes::end(&rules.bullet, content)?..];
                    let plain = &plain[Prefixes::end(&rules.ordered, plain)?..];
                    result.push_str("- [ ] ");
                    result.push_str(plain);
                }
            } else {
                if !remove {
                    match command {
                        Command::BulletList => result.push_str("- "),
                        Command::OrderedList => result.push_str(&format!("{index}. ")),
                        Command::Quote => result.push_str("> "),
                        _ => return Err(Error::InvalidRange),
                    }
                }
                result.push_str(rules.plain(content)?);
            }
        }
        result.push_str(ending);
        if result.len() > MAX_BYTES {
            return Err(Error::Limit);
        }
    }
    let length = result.encode_utf16().count();
    cancel.check()?;
    make(
        source,
        range,
        result,
        Utf16Range {
            location: 0,
            length,
        },
    )
    .map(Some)
}
pub fn table(
    source: &str,
    selection: Utf16Range,
    columns: usize,
    header: bool,
    title: &str,
    cancel: &Cancellation,
) -> Result<Edit, Error> {
    let range = checked_range(source, selection, cancel)?;
    if !(1..=50).contains(&columns) || title.len() > 128 || title.contains(['\r', '\n', '|', '\0'])
    {
        return Err(Error::InvalidRange);
    }
    let cells = (1..=columns)
        .map(|n| {
            if header {
                format!("{title} {n}")
            } else {
                "   ".into()
            }
        })
        .collect::<Vec<_>>();
    let heading = format!("| {} |", cells.join(" | "));
    let template = format!(
        "{heading}\n|{}\n|{}",
        " --- |".repeat(columns),
        "   |".repeat(columns)
    );
    let before = &source[..range.start];
    let after = &source[range.end..];
    let prefix = if before.is_empty() || before.ends_with("\n\n") {
        ""
    } else if before.ends_with('\n') {
        "\n"
    } else {
        "\n\n"
    };
    let suffix = if after.is_empty() || after.starts_with('\n') {
        ""
    } else {
        "\n"
    };
    let cursor = prefix.encode_utf16().count()
        + template[..=template.rfind('\n').unwrap()]
            .encode_utf16()
            .count()
        + 2;
    make(
        source,
        range,
        format!("{prefix}{template}{suffix}"),
        Utf16Range {
            location: cursor,
            length: 0,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn range(location: usize, length: usize) -> Utf16Range {
        Utf16Range { location, length }
    }
    fn check(source: &str, selection: Utf16Range, command: Command, expected: &str) -> Edit {
        let edit = edit(source, selection, command, &Cancellation::default())
            .unwrap()
            .unwrap();
        let mut actual = source.to_owned();
        actual.replace_range(edit.range.byte_range(source).unwrap(), &edit.replacement);
        assert_eq!(actual, expected);
        edit.selection.byte_range(&actual).unwrap();
        edit
    }
    #[test]
    fn native_mac_line_endings_and_nested_list_contracts() {
        for ending in ["\r", "\r\n", "\n", "\r\n\r\n"] {
            let source = format!("eins{ending}zwei");
            let selection = range(0, source.encode_utf16().count());
            check(
                &source,
                selection,
                Command::BulletList,
                &format!("- eins{ending}- zwei"),
            );
            check(
                &source,
                selection,
                Command::Quote,
                &format!("> eins{ending}> zwei"),
            );
        }
        let source = "- Eltern\n    - [x] Kind\n\t- [ ] Weiter";
        let selection = range(0, source.encode_utf16().count());
        check(
            source,
            selection,
            Command::BulletList,
            "- Eltern\n    - Kind\n\t- Weiter",
        );
        check(
            source,
            selection,
            Command::OrderedList,
            "1. Eltern\n    2. Kind\n\t3. Weiter",
        );
        check(
            "- Eltern\n    - [x] Kind\n    1. Weiter\n",
            range(0, "- Eltern\n    - [x] Kind\n    1. Weiter\n".encode_utf16().count()),
            Command::TaskList,
            "- [ ] Eltern\n    - [x] Kind\n    - [ ] Weiter\n",
        );
        check(
            "- [ ] Eltern\n    - [x] Kind\n",
            range(0, "- [ ] Eltern\n    - [x] Kind\n".encode_utf16().count()),
            Command::TaskList,
            "Eltern\n    Kind\n",
        );
        check(
            "vorher\nmittig markiert\nnachher",
            range(9, 3),
            Command::Quote,
            "vorher\n> mittig markiert\nnachher",
        );
        check("### Alt", range(0, 7), Command::Heading(1), "# Alt");
        check(
            "## Titelzeile",
            range(0, 13),
            Command::Heading(0),
            "Titelzeile",
        );
    }
    #[test]
    fn hard_break_preserves_selection_and_document_endings() {
        for ending in ["\r", "\r\n", "\n"] {
            let source = format!("Zeile{ending}Weiter");
            check(
                &source,
                range(5, 0),
                Command::HardBreak,
                &format!("Zeile  {ending}Weiter"),
            );
            check(
                &source,
                range(2, 0),
                Command::HardBreak,
                &format!("Ze  {ending}ile{ending}Weiter"),
            );
        }
        for spaces in ["", " ", "  ", "   "] {
            let source = format!("Zeile{spaces}\nDanach");
            let result = edit(
                &source,
                range(5 + spaces.len(), 0),
                Command::HardBreak,
                &Cancellation::default(),
            )
            .unwrap();
            if let Some(edit) = result {
                let mut actual = source.clone();
                actual.replace_range(edit.range.byte_range(&source).unwrap(), &edit.replacement);
                assert_eq!(actual, "Zeile  \nDanach");
            } else {
                assert_eq!(spaces, "  ");
            }
        }
        assert!(edit(
            "Davor\n\nDanach",
            range(6, 0),
            Command::HardBreak,
            &Cancellation::default()
        )
        .unwrap()
        .is_none());
        let e = check(
            "Erste ZeileZweite Zeile",
            range(0, 11),
            Command::HardBreak,
            "Erste Zeile  \nZweite Zeile",
        );
        assert_eq!(e.range, range(11, 0));
        assert_eq!(e.selection, range(14, 0));
    }
    #[test]
    fn unicode_ranges_line_boundaries_links_and_table_cursor() {
        let e = check(
            "前🙂\n雪e\u{301}\n後",
            range(5, 1),
            Command::Heading(2),
            "前🙂\n## 雪e\u{301}\n後",
        );
        assert_eq!(e.range, range(4, 3));
        assert_eq!(e.selection, range(4, 6));
        check("a\nb", range(0, 2), Command::Quote, "> a\nb");
        check("a\n", range(2, 0), Command::Heading(1), "a\n");
        check(
            "١. 雪\n٢. 月",
            range(0, 9),
            Command::BulletList,
            "- 雪\n- 月",
        );
        let e = check(
            "siehe Doku dazu",
            range(6, 4),
            Command::Link,
            "siehe [Doku]() dazu",
        );
        assert_eq!(e.selection, range(13, 0));
        let e = check("🙂", range(0, 2), Command::Link, "[🙂]()");
        assert_eq!(e.selection, range(5, 0));
        let e = table(
            "前🙂後",
            range(3, 0),
            2,
            true,
            "列",
            &Cancellation::default(),
        )
        .unwrap();
        let mut source = "前🙂後".to_owned();
        source.replace_range(e.range.byte_range(&source).unwrap(), &e.replacement);
        assert_eq!(
            source,
            "前🙂\n\n| 列 1 | 列 2 |\n| --- | --- |\n|   |   |\n後"
        );
        let caret = e.selection.byte_range(&source).unwrap().start;
        assert!(source[..caret].ends_with("\n| "));
    }
    #[test]
    fn invalid_ranges_limits_and_cancellation_do_not_produce_edits() {
        let cancel = Cancellation::default();
        assert_eq!(
            edit("🙂", range(1, 0), Command::Quote, &cancel).unwrap_err(),
            Error::InvalidRange
        );
        assert_eq!(
            table("", range(0, 0), 51, true, "Column", &cancel).unwrap_err(),
            Error::InvalidRange
        );
        cancel.cancel();
        assert_eq!(
            edit("a", range(0, 1), Command::TaskList, &cancel).unwrap_err(),
            Error::Cancelled
        );
    }
}
