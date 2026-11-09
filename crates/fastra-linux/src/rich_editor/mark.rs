//! Exakt-zwei-Delimiter aus Fastras cmark-Mark-Erweiterung, auf bereits geparsten Textbereichen.
use fastra_core::{Cancellation, Limits, PreparedSearch, SearchFlags, SearchMode, SearchRequest};
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use std::collections::{BTreeMap, HashMap};

#[derive(Debug)]
pub(crate) struct Unsupported;
struct Classes {
    prepared: Option<PreparedSearch>,
    cached: HashMap<char, bool>,
}
impl Classes {
    fn punctuation(&mut self, c: Option<char>) -> Result<bool, Unsupported> {
        let Some(c) = c else { return Ok(false) };
        if c.is_ascii() {
            return Ok(c.is_ascii_punctuation());
        }
        if let Some(value) = self.cached.get(&c) {
            return Ok(*value);
        }
        if self.prepared.is_none() {
            self.prepared = Some(
                PreparedSearch::new(
                    &SearchRequest {
                        pattern: r"[\p{P}\p{S}]".into(),
                        replacement: String::new(),
                        mode: SearchMode::Regex,
                        case_sensitive: true,
                        range: None,
                    },
                    SearchFlags::default(),
                    Limits {
                        max_text_bytes: 128,
                        max_output_bytes: 128,
                        max_matches: 2,
                        ..Default::default()
                    },
                    &Cancellation::default(),
                )
                .map_err(|_| Unsupported)?,
            );
        }
        let result = !self
            .prepared
            .as_ref()
            .unwrap()
            .preview(&c.to_string(), 0, 0)
            .map_err(|_| Unsupported)?
            .matches()
            .is_empty();
        self.cached.insert(c, result);
        Ok(result)
    }
}
struct Opener {
    position: usize,
    path: Vec<(String, usize)>,
}
fn escaped(source: &str, position: usize) -> bool {
    source.as_bytes()[..position]
        .iter()
        .rev()
        .take_while(|b| **b == b'\\')
        .count()
        % 2
        == 1
}
fn inline_start(tag: &Tag<'_>) -> Option<&'static str> {
    match tag {
        Tag::Emphasis => Some("em"),
        Tag::Strong => Some("strong"),
        Tag::Strikethrough => Some("del"),
        Tag::Link { .. } => Some("a"),
        _ => None,
    }
}
fn inline_end(tag: TagEnd) -> Option<&'static str> {
    match tag {
        TagEnd::Emphasis => Some("em"),
        TagEnd::Strong => Some("strong"),
        TagEnd::Strikethrough => Some("del"),
        TagEnd::Link => Some("a"),
        _ => None,
    }
}
/// Kreuzende Delimiter werden als geschützter Originalblock behandelt statt falsch verschachtelt.
pub(super) fn rewrite(source: &str, options: Options) -> Result<Option<String>, Unsupported> {
    Ok(rewrite_tagged(source, options)?.map(|marked| marked.source))
}
pub(crate) struct Marked {
    pub source: String,
    tags: Vec<(std::ops::Range<usize>, usize)>,
}
impl Marked {
    pub(crate) fn changes(&self) -> Vec<(std::ops::Range<usize>, String)> {
        self.tags.iter().map(|(tag, original)| ((*original..original+2), self.source[tag.clone()].to_owned())).collect()
    }

}
pub(crate) fn rewrite_tagged(
    source: &str,
    options: Options,
) -> Result<Option<Marked>, Unsupported> {
    if !source.contains("==") {
        return Ok(None);
    }
    let mut classes = Classes {
        prepared: None,
        cached: HashMap::new(),
    };
    let (mut path, mut openers, mut replacements) = (
        Vec::<(String, usize)>::new(),
        Vec::<Opener>::new(),
        BTreeMap::new(),
    );
    let mut examined = 0usize;
    let mut literal = false;
    for (index, (event, range)) in Parser::new_ext(source, options)
        .into_offset_iter()
        .enumerate()
    {
        if index >= 500_000 {
            return Err(Unsupported);
        }
        match &event {
            Event::Start(Tag::CodeBlock(_) | Tag::HtmlBlock) => { literal = true; continue; }
            Event::End(TagEnd::CodeBlock | TagEnd::HtmlBlock) => { literal = false; continue; }
            _ if literal => continue,
            _ => {},
        }
        match &event {
            Event::Start(Tag::Paragraph | Tag::Heading { .. } | Tag::TableCell) => {
                openers.clear();
                path.clear();
            }
            Event::End(TagEnd::Paragraph | TagEnd::Heading(_) | TagEnd::TableCell) => {
                openers.clear();
                path.clear();
            }
            Event::Start(tag) => {
                if let Some(tag) = inline_start(tag) {
                    path.push((tag.into(), index));
                }
            }
            Event::End(tag) => {
                if let Some(tag) = inline_end(*tag) {
                    if path.last().is_none_or(|(name, _)| name != tag) {
                        return Err(Unsupported);
                    }
                    path.pop();
                }
            }
            Event::InlineHtml(raw) => {
                let raw = raw.trim().to_ascii_lowercase();
                let name = raw.trim_start_matches('<').trim_end_matches('>').trim();
                if let Some(name) = name.strip_prefix('/') {
                    if path.last().is_some_and(|(tag, _)| tag == name) {
                        path.pop();
                    }
                } else if matches!(
                    name,
                    "strong"
                        | "b"
                        | "em"
                        | "i"
                        | "mark"
                        | "del"
                        | "s"
                        | "u"
                        | "ins"
                        | "small"
                        | "sub"
                        | "sup"
                        | "kbd"
                        | "samp"
                        | "var"
                        | "q"
                        | "cite"
                ) {
                    path.push((name.into(), index));
                }
            }
            Event::Text(_) => {
                let bytes = source.as_bytes();
                let mut at = range.start;
                while at < range.end {
                    if bytes[at] != b'=' || (at > 0 && bytes[at - 1] == b'=') {
                        at += 1;
                        continue;
                    }
                    let mut end = at + 1;
                    while end < bytes.len() && bytes[end] == b'=' {
                        end += 1;
                    }
                    if end - at != 2 || escaped(source, at) {
                        at = end;
                        continue;
                    }
                    examined += 1;
                    if examined > 16384 {
                        return Err(Unsupported);
                    }
                    let before = source[..at].chars().next_back();
                    let after = source[end..].chars().next();
                    let before_space = before.is_none_or(char::is_whitespace);
                    let after_space = after.is_none_or(char::is_whitespace);
                    let before_punctuation = classes.punctuation(before)?;
                    let after_punctuation = classes.punctuation(after)?;
                    let can_open =
                        !after_space && (!after_punctuation || before_space || before_punctuation);
                    let can_close =
                        !before_space && (!before_punctuation || after_space || after_punctuation);
                    let mut closed = false;
                    if can_close && !openers.is_empty() {
                        let Some(last) = openers.iter().rposition(|opener| opener.path == path)
                        else {
                            return Err(Unsupported);
                        };
                        if last + 1 != openers.len() {
                            return Err(Unsupported);
                        }
                        let opener = openers.pop().unwrap();
                        replacements.insert(opener.position, "<mark>");
                        replacements.insert(at, "</mark>");
                        closed = true;
                    }
                    if can_open && !closed {
                        openers.push(Opener {
                            position: at,
                            path: path.clone(),
                        });
                    }
                    at = end;
                }
            }
            _ => {}
        }
        if path.len() > 128 {
            return Err(Unsupported);
        }
    }
    if replacements.is_empty() {
        return Ok(None);
    }
    let mut output = String::with_capacity(source.len() + replacements.len() * 5);
    let mut cursor = 0;
    let mut tags = Vec::with_capacity(replacements.len());
    for (position, tag) in replacements {
        output.push_str(&source[cursor..position]);
        let start = output.len();
        output.push_str(tag);
        tags.push((start..output.len(), position));
        cursor = position + 2;
    }
    output.push_str(&source[cursor..]);
    Ok(Some(Marked {
        source: output,
        tags,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cmark_delimiter_contract_and_nested_styles() {
        for (source, expected) in [
            ("==Marked==", "<mark>Marked</mark>"),
            ("a==Marked==b", "a<mark>Marked</mark>b"),
            ("==**Bold**==", "<mark>**Bold**</mark>"),
            ("**==Marked==**", "**<mark>Marked</mark>**"),
            ("==A&nbsp;==", "<mark>A&nbsp;</mark>"),
            ("==A &amp; B==", "<mark>A &amp; B</mark>"),
            ("==a====b==", "<mark>a====b</mark>"),
            ("==a\\==b==", "<mark>a\\==b</mark>"),
            ("==Ä😀==", "<mark>Ä😀</mark>"),
            ("==one==\n\n==two==", "<mark>one</mark>\n\n<mark>two</mark>"),
            (
                "| ==Marked== |\n| --- |\n| ==Cell== |",
                "| <mark>Marked</mark> |\n| --- |\n| <mark>Cell</mark> |",
            ),
        ] {
            assert_eq!(
                rewrite(source, Options::ENABLE_TABLES).unwrap().as_deref(),
                Some(expected),
                "{source}"
            );
        }
        for source in [
            "====Marked====",
            "== spaced ==",
            r"\==Marked==",
            "`==code==`",
            "```text\n==code==\n```",
            "~~~\n==code==\n~~~",
            "==one\n\ntwo==",
            "[label](https://example.test/==path==)",
            "&#61;=literal==",
        ] {
            assert!(
                rewrite(source, Options::ENABLE_TABLES).unwrap().is_none(),
                "{source}"
            );
        }
        assert!(rewrite("==a *b== c*", Options::empty()).is_err());
    }
}
