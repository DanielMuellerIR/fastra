use super::super::{math, syntax};
use fastra_core::{Cancellation, Limits, PreparedSearch, SearchFlags, SearchMode, SearchRequest};
use gtk::glib::{Unichar, UnicodeType};
use pulldown_cmark::{Event, Tag, TagEnd};
use std::{
    collections::HashMap,
    ops::Range,
    path::{Path, PathBuf},
};

pub(super) const MAX_SOURCE: usize = 10 * 1024 * 1024;
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Error {
    Limit,
    Cancelled,
    Parse,
}
impl From<fastra_core::Error> for Error {
    fn from(e: fastra_core::Error) -> Self {
        if e == fastra_core::Error::Cancelled {
            Self::Cancelled
        } else {
            Self::Limit
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Reference {
    pub destination: String,
    pub line: usize,
    pub offset: i32,
    pub image: bool,
}
#[derive(Default, Debug)]
pub(super) struct Parsed {
    pub references: Vec<Reference>,
    pub anchors: HashMap<String, usize>,
    pub incomplete: bool,
    pub unsupported_html: bool,
    pub anchor_count: usize,
    pub anchors_complete: bool,
}
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Destination {
    Local(Option<PathBuf>, Option<String>),
    Remote,
    Invalid,
}
fn percent(raw: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(raw.len());
    let mut at = 0;
    while at < raw.len() {
        let byte = raw.as_bytes()[at];
        if byte == b'%' {
            let code = raw.get(at + 1..at + 3)?;
            bytes.push(u8::from_str_radix(code, 16).ok()?);
            at += 3;
        } else {
            bytes.push(byte);
            at += 1;
        }
    }
    let text = String::from_utf8(bytes).ok()?;
    (!text.contains('\0')).then_some(text)
}
pub(super) fn destination(raw: &str, document: Option<&Path>) -> Destination {
    if raw.starts_with("//") {
        return Destination::Remote;
    }
    let (path, fragment) = raw
        .split_once('#')
        .map_or((raw, None), |(p, f)| (p, Some(f)));
    let anchor = match fragment {
        Some(raw) => Some(match percent(raw) {
            Some(value) => value,
            None => return Destination::Invalid,
        }),
        None => None,
    };
    let Some(decoded) = percent(path) else {
        return Destination::Invalid;
    };
    if path.is_empty() {
        return Destination::Local(document.map(Path::to_path_buf), anchor);
    }
    let scheme = path.split_once(':').filter(|(s, _)| {
        !s.is_empty()
            && s.as_bytes()[0].is_ascii_alphabetic()
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.'))
    });
    if let Some((scheme, rest)) = scheme {
        if !scheme.eq_ignore_ascii_case("file") {
            return Destination::Remote;
        }
        let Ok(uri) = gtk::glib::Uri::parse(
            path,
            gtk::glib::UriFlags::PARSE_RELAXED | gtk::glib::UriFlags::ENCODED_PATH,
        ) else {
            return Destination::Remote;
        };
        if uri
            .host()
            .is_some_and(|host| !host.is_empty() && host != "localhost")
        {
            return Destination::Remote;
        }
        // Foundation bewahrt Schreibweise und Codierung von %2f im Dateinamen.
        // GLib normalisiert Escape-Hexziffern; deshalb nur seine Authority prüfen
        // und den originalen Pfad vor dem einmaligen Decodieren schützen.
        let path = rest.split('?').next().unwrap_or(rest);
        let path = if let Some(authority) = path.strip_prefix("//") {
            authority.find('/').map_or("", |at| &authority[at..])
        } else {
            path
        };
        let mut protected = String::with_capacity(path.len());
        let mut at = 0;
        while at < path.len() {
            if path.as_bytes()[at] == b'%'
                && path
                    .get(at + 1..at + 3)
                    .is_some_and(|code| code.eq_ignore_ascii_case("2f"))
            {
                protected.push_str("%25");
                protected.push_str(&path[at + 1..at + 3]);
                at += 3;
            } else {
                let c = path[at..].chars().next().unwrap();
                protected.push(c);
                at += c.len_utf8();
            }
        }
        let Some(path) = percent(&protected) else {
            return Destination::Invalid;
        };
        return Destination::Local(Some(PathBuf::from(path)), anchor);
    }
    let path = Path::new(&decoded);
    Destination::Local(
        if path.is_absolute() {
            Some(path.into())
        } else {
            document.and_then(Path::parent).map(|p| p.join(path))
        },
        anchor,
    )
}
pub(super) fn anchor(title: &str) -> String {
    let mut slug = String::new();
    for c in title.to_lowercase().chars() {
        if matches!(
            c.unicode_type(),
            UnicodeType::LowercaseLetter
                | UnicodeType::ModifierLetter
                | UnicodeType::OtherLetter
                | UnicodeType::TitlecaseLetter
                | UnicodeType::UppercaseLetter
                | UnicodeType::SpacingMark
                | UnicodeType::EnclosingMark
                | UnicodeType::NonSpacingMark
                | UnicodeType::DecimalNumber
                | UnicodeType::LetterNumber
                | UnicodeType::OtherNumber
        ) {
            slug.push(c);
        } else if !slug.is_empty() && !slug.ends_with('-') {
            slug.push('-');
        }
    }
    slug.trim_end_matches('-').to_owned()
}
struct Cursor<'a> {
    text: &'a str,
    byte: usize,
    units: usize,
}
impl<'a> Cursor<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            text,
            byte: 0,
            units: 0,
        }
    }
    fn at(&mut self, unit: usize) -> Result<usize, Error> {
        if unit < self.units {
            return Err(Error::Parse);
        }
        while self.units < unit {
            let c = self.text[self.byte..].chars().next().ok_or(Error::Parse)?;
            self.byte += c.len_utf8();
            self.units += c.len_utf16();
        }
        if self.units != unit {
            return Err(Error::Parse);
        }
        Ok(self.byte)
    }
}
struct Hit {
    range: Range<usize>,
    captures: Vec<Option<Range<usize>>>,
}
fn pattern(value: &str, cancel: &Cancellation) -> Result<PreparedSearch, Error> {
    Ok(PreparedSearch::new(
        &SearchRequest {
            pattern: value.into(),
            replacement: String::new(),
            mode: SearchMode::Regex,
            case_sensitive: true,
            range: None,
        },
        SearchFlags { whole_word: false },
        Limits {
            max_text_bytes: MAX_SOURCE,
            ..Limits::default()
        },
        cancel,
    )?)
}
fn matches(pattern: &PreparedSearch, source: &str) -> Result<Vec<Hit>, Error> {
    let preview = pattern.preview(source, 0, 0)?;
    let mut cursor = Cursor::new(source);
    let mut result = Vec::with_capacity(preview.matches().len());
    for hit in preview.matches() {
        let range = cursor.at(hit.range.location)?..cursor.at(hit.range.end()?)?;
        // Gruppen werden innerhalb des jeweiligen Treffers vorwärts abgebildet;
        // ein wiederholter Scan ab Dokumentanfang wäre bei vielen Tags quadratisch.
        let mut local = Cursor::new(&source[range.clone()]);
        let captures = hit
            .captures
            .iter()
            .skip(1)
            .map(|capture| {
                capture
                    .map(|c| {
                        let a = local.at(c.location - hit.range.location)? + range.start;
                        let b = local.at(c.end()? - hit.range.location)? + range.start;
                        Ok(a..b)
                    })
                    .transpose()
            })
            .collect::<Result<Vec<_>, Error>>()?;
        result.push(Hit { range, captures });
    }
    Ok(result)
}
struct Patterns {
    comments: PreparedSearch,
    opaque: PreparedSearch,
    tags: PreparedSearch,
    attrs: PreparedSearch,
    unsupported: PreparedSearch,
}
impl Patterns {
    fn new(cancel: &Cancellation) -> Result<Self, Error> {
        Ok(Self {
            comments: pattern(r"(?s)<!--.*?(?:-->|$)", cancel)?,
            opaque: pattern(
                r"(?is)<\s*(script|style)\b[^>]*>.*?(?:</\s*\1\s*>|$)",
                cancel,
            )?,
            tags: pattern(
                r#"(?i)<[a-z][a-z0-9:-]*\b(?:[^\"'<>]|\"[^\"]*\"|'[^']*')*>"#,
                cancel,
            )?,
            attrs: pattern(
                r#"(?i)\s+([a-z][a-z0-9-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#,
                cancel,
            )?,
            unsupported: pattern(
                r#"(?i)\b(?:srcset|style|poster|data|xlink:href)\s*=|\b(?:href|src|id|name)\s*=\s*[^\s\"']"#,
                cancel,
            )?,
        })
    }
}
struct Builder<'a> {
    source: &'a str,
    lines: Vec<(usize, i32)>,
    parsed: Parsed,
    max_refs: usize,
    max_anchors: usize,
    patterns: Patterns,
    cancel: &'a Cancellation,
}
impl Builder<'_> {
    fn reference(&mut self, destination: String, byte: usize, image: bool) {
        if self.parsed.references.len() >= self.max_refs {
            self.parsed.incomplete = true;
            return;
        }
        let line = self
            .lines
            .partition_point(|(at, _)| *at <= byte)
            .saturating_sub(1);
        self.parsed.references.push(Reference {
            destination,
            line: line + 1,
            offset: self.lines[line].1,
            image,
        });
    }
    fn anchor(&mut self, value: String) {
        if self.parsed.anchor_count < self.max_anchors {
            *self.parsed.anchors.entry(value).or_default() += 1;
            self.parsed.anchor_count += 1;
        } else {
            self.parsed.incomplete = true;
            self.parsed.anchors_complete = false;
        }
    }
    fn html(&mut self, range: Range<usize>) -> Result<(), Error> {
        let html = &self.source[range.clone()];
        let mut excluded = matches(&self.patterns.comments, html)?;
        let opaque = matches(&self.patterns.opaque, html)?;
        if !opaque.is_empty() {
            self.parsed.unsupported_html = true;
        }
        excluded.extend(opaque);
        excluded.sort_by_key(|h| h.range.start);
        let mut excluded_at = 0;
        for tag in matches(&self.patterns.tags, html)? {
            self.cancel.check()?;
            while excluded
                .get(excluded_at)
                .is_some_and(|h| h.range.end <= tag.range.start)
            {
                excluded_at += 1;
            }
            if excluded
                .get(excluded_at)
                .is_some_and(|h| h.range.start < tag.range.end)
            {
                continue;
            }
            let text = &html[tag.range.clone()];
            let name = text[1..]
                .split(|c: char| !c.is_ascii_alphanumeric() && !matches!(c, '-' | ':'))
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();
            if matches!(name.as_str(), "script" | "style") {
                self.parsed.unsupported_html = true;
                continue;
            }
            for attr in matches(&self.patterns.attrs, text)? {
                let key = text[attr.captures[0].clone().ok_or(Error::Parse)?].to_ascii_lowercase();
                let value = attr.captures[1]
                    .clone()
                    .or_else(|| attr.captures[2].clone())
                    .ok_or(Error::Parse)?;
                let value = super::super::html_whitelist::decode(&text[value], self.cancel)
                    .map_err(|e| match e {
                        super::super::RenderError::Cancelled => Error::Cancelled,
                        _ => Error::Parse,
                    })?;
                if matches!(key.as_str(), "href" | "src") {
                    self.reference(value, range.start + tag.range.start, key == "src");
                } else if key == "id" || (key == "name" && name == "a") {
                    self.anchor(value);
                }
            }
            if !matches(&self.patterns.unsupported, text)?.is_empty() {
                self.parsed.unsupported_html = true;
            }
        }
        Ok(())
    }
}
pub(super) fn parse(
    source: &str,
    max_refs: usize,
    max_anchors: usize,
    cancel: &Cancellation,
) -> Result<Parsed, Error> {
    if source.len() > MAX_SOURCE
        || source
            .bytes()
            .filter(|b| matches!(b, b'\r' | b'\n'))
            .count()
            > 200_000
    {
        return Err(Error::Limit);
    }
    cancel.check()?;
    let mut lines = vec![(0, 0)];
    let mut chars = source.char_indices().peekable();
    let mut scalar = 0;
    while let Some((byte, c)) = chars.next() {
        scalar += 1;
        if c == '\r' && chars.peek().is_some_and(|(_, c)| *c == '\n') {
            chars.next();
            scalar += 1;
            lines.push((byte + 2, scalar));
        } else if c == '\r' || c == '\n' {
            lines.push((byte + c.len_utf8(), scalar));
        }
    }
    let mut b = Builder {
        source,
        lines,
        parsed: Parsed {
            anchors_complete: true,
            ..Default::default()
        },
        max_refs,
        max_anchors,
        patterns: Patterns::new(cancel)?,
        cancel,
    };
    let events = syntax::Parsed::bounded(
        source,
        false,
        math::Budget {
            source_bytes: MAX_SOURCE,
            ..Default::default()
        },
        cancel,
    )
    .and_then(|p| p.events(false, cancel))
    .map_err(|e| match e {
        math::Error::Core(fastra_core::Error::Cancelled) => Error::Cancelled,
        _ => Error::Limit,
    })?;
    let mut html: Option<Range<usize>> = None;
    let mut headings = Vec::new();
    let mut heading_count = 0;
    for (event, range, _) in events {
        cancel.check()?;
        if matches!(event, Event::Html(_) | Event::InlineHtml(_)) {
            if let Some(previous) = html.as_mut().filter(|p| p.end == range.start) {
                previous.end = range.end;
            } else {
                if let Some(previous) = html.take() {
                    b.html(previous)?;
                }
                html = Some(range);
            }
            continue;
        }
        if let Some(previous) = html.take() {
            b.html(previous)?;
        }
        match event {
            Event::Start(Tag::Link { dest_url, .. }) => {
                b.reference(dest_url.into_string(), range.start, false)
            }
            Event::Start(Tag::Image { dest_url, .. }) => {
                b.reference(dest_url.into_string(), range.start, true)
            }
            Event::End(TagEnd::Heading(_)) => {
                heading_count += 1;
                if headings.len() < max_anchors {
                    headings.push(
                        crate::markdown_navigation::plain_title(
                            source.get(range).ok_or(Error::Parse)?,
                            cancel,
                        )
                        .map_err(|_| Error::Limit)?,
                    );
                }
            }
            _ => {}
        }
    }
    if let Some(previous) = html {
        b.html(previous)?;
    }
    if heading_count > max_anchors {
        b.parsed.incomplete = true;
        b.parsed.anchors_complete = false;
    }
    for title in headings {
        let value = anchor(&title);
        if !value.is_empty() {
            b.anchor(value);
        }
    }
    Ok(b.parsed)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn parsed(source: &str) -> Parsed {
        parse(source, 10_000, 10_000, &Cancellation::default()).unwrap()
    }
    #[test]
    fn file_url_resolution_matches_actual_foundation_provider() {
        let values: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../../tests/fixtures/swift-markdown-reference-destinations.json"
        ))
        .unwrap();
        for value in values {
            let expected = match value["kind"].as_str().unwrap() {
                "local" => Destination::Local(
                    value["path"].as_str().map(PathBuf::from),
                    value["anchor"].as_str().map(str::to_owned),
                ),
                "remote" => Destination::Remote,
                _ => Destination::Invalid,
            };
            assert_eq!(
                destination(
                    value["raw"].as_str().unwrap(),
                    Some(Path::new("/docs/a.md"))
                ),
                expected,
                "{}",
                value["raw"]
            );
        }
    }
    #[test]
    fn anchors_follow_foundation_scalar_categories() {
        for (source, expected) in [
            ("é", "é"),
            ("e\u{301}", "e\u{301}"),
            ("a_b c", "a-b-c"),
            ("雪 世界", "雪-世界"),
            ("𝟙 a", "𝟙-a"),
            ("a\u{200d}b", "a-b"),
            ("!!!", ""),
            ("İ", "i\u{307}"),
            ("Ⓐ", ""),
            ("Ⅳ", "ⅳ"),
            ("½", "½"),
            ("\u{301}", "\u{301}"),
            ("\u{20dd}", "\u{20dd}"),
            ("\u{903}", "\u{903}"),
            ("ก\u{e31}", "ก\u{e31}"),
            ("x\u{fe0f}", "x\u{fe0f}"),
        ] {
            assert_eq!(anchor(source), expected, "{source}");
        }
    }
    #[test]
    fn destinations_split_before_decoding_and_do_not_fold_symlink_parents() {
        let p = Some(Path::new("/docs/a.md"));
        assert_eq!(
            destination("b%23c.md#e%CC%81", p),
            Destination::Local(Some("/docs/b#c.md".into()), Some("e\u{301}".into()))
        );
        assert_eq!(
            destination("link/../target.md", p),
            Destination::Local(Some("/docs/link/../target.md".into()), None)
        );
        assert_eq!(
            destination("file://localhost/tmp/a%20b#x", p),
            Destination::Local(Some("/tmp/a b".into()), Some("x".into()))
        );
        assert_eq!(
            destination("#ok", None),
            Destination::Local(None, Some("ok".into()))
        );
        for raw in [
            "//server/a",
            "https://example.invalid/a",
            "file://server/tmp/a",
            "mailto:test@example.invalid",
        ] {
            assert_eq!(destination(raw, p), Destination::Remote);
        }
        for raw in ["a%00b", "a%q0", "x#%", "x#%00", "a%FF"] {
            assert_eq!(destination(raw, p), Destination::Invalid, "{raw}");
        }
    }
    #[test]
    fn real_references_use_original_line_starts_and_resolved_definitions() {
        let source="# Gleich\r\n# Gleich\r\n\r\n[def]: <ziel datei.md>\r\n😀 [Link][def]\r\n![Bild](bild%23x.png)\r\n`[Code](fake.md)`\r\n<!-- <a href=\"fake.md\"> -->\r\n\r\n<a href=\"x&amp;y.md\" id=\"ziel\">ok</a>\r\n";
        let p = parsed(source);
        assert_eq!(p.anchors["gleich"], 2);
        assert_eq!(p.anchors["ziel"], 1);
        assert_eq!(
            p.references
                .iter()
                .map(|r| (&*r.destination, r.line, r.image))
                .collect::<Vec<_>>(),
            vec![
                ("ziel datei.md", 5, false),
                ("bild%23x.png", 6, true),
                ("x&y.md", 10, false)
            ]
        );
        for reference in &p.references {
            let prefix = source
                .chars()
                .take(reference.offset as usize)
                .collect::<String>();
            assert_eq!(
                prefix.bytes().filter(|b| *b == b'\n').count() + 1,
                reference.line
            );
            assert!(prefix.is_empty() || prefix.ends_with('\n'));
        }
        assert!(!p.unsupported_html);
        assert!(!p.incomplete);
    }
    #[test]
    fn only_exact_a_name_and_quoted_attributes_have_authority() {
        let p=parsed("<article name=\"fake1\"></article><abbr name='fake2'></abbr><a-custom name='fake3'></a-custom><a:custom name='fake4'></a:custom><A name='ziel'></A>\n\n<div id='a&amp;amp;b' srcset='x 2x' href='ok.md' id=unquoted></div>");
        assert_eq!(p.anchors.len(), 2);
        assert_eq!(p.anchors["ziel"], 1);
        assert_eq!(p.anchors["a&amp;b"], 1);
        assert_eq!(p.references.len(), 1);
        assert!(p.unsupported_html);
        let p=parsed("<script><a href='phantom.md' id='fake'>x</a></script>\n\n<style><img src='phantom2.png'></style>\n\n[Real](real.md)");
        assert!(p.unsupported_html);
        assert!(p.anchors.is_empty());
        assert_eq!(
            p.references
                .iter()
                .map(|r| &*r.destination)
                .collect::<Vec<_>>(),
            vec!["real.md"]
        );
    }
    #[test]
    fn formulas_do_not_create_references_but_dollars_in_real_paths_survive() {
        let p=parsed("$[Fake](fake.md)$\n\n$$\n[Fake2](fake2.md)\n$$\n\n[real](file$name.md)\n\n[ref][x]\n\n[x]: file$ref.md\n\n<img src='file$html.png'>");
        assert_eq!(
            p.references
                .iter()
                .map(|r| &*r.destination)
                .collect::<Vec<_>>(),
            vec!["file$name.md", "file$ref.md", "file$html.png"]
        );
    }
    #[test]
    fn budgets_and_cancellation_never_produce_complete_reports() {
        let c = Cancellation::default();
        let p = parse("# !\n# !\n# Real\n\n[a](a.md) [b](b.md)", 1, 1, &c).unwrap();
        assert!(p.incomplete);
        assert!(!p.anchors_complete);
        assert_eq!(p.references.len(), 1);
        assert!(p.anchors.is_empty());
        let p = parse("<span id='html'></span>\n\n# Heading", 10, 1, &c).unwrap();
        assert!(p.incomplete);
        assert_eq!(p.anchors["html"], 1);
        assert!(!p.anchors_complete);
        assert_eq!(
            parse(&"\r\n".repeat(100_001), 10, 10, &c).unwrap_err(),
            Error::Limit
        );
        assert_eq!(
            parse(&"x".repeat(MAX_SOURCE + 1), 10, 10, &c).unwrap_err(),
            Error::Limit
        );
        c.cancel();
        assert_eq!(
            parse("[a](a.md)", 10, 10, &c).unwrap_err(),
            Error::Cancelled
        );
    }
}
