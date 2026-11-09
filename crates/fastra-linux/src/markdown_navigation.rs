//! Markdown-/4D-Gliederung und gemeinsamer Verlauf bleiben an Dokument und Ansichtsrevision gebunden.
use super::*;
use pulldown_cmark::{Event, Tag, TagEnd};
use std::rc::Weak;
mod history;
mod view;
pub(super) use history::History;
pub(crate) use history::{begin_request, prepare_point, PreparedPoint};
pub(super) use view::View;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Heading {
    pub level: u8,
    pub title: String,
    pub line: usize,
    pub offset: i32,
    pub byte: usize,
    pub anchor: String,
    pub end: i32,
    pub kind: Kind,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    Markdown,
    Method,
    Function(fastra_core::four_d::Kind),
}
fn title(doc: &Document) -> String {
    doc.snapshot
        .borrow()
        .as_ref()
        .and_then(|snapshot| {
            snapshot
                .path()
                .file_name()
                .map(|name| project_view::display(std::path::Path::new(name)))
        })
        .unwrap_or_else(|| doc.name.clone())
}
fn language(doc: &Document) -> String {
    doc.buffer
        .language()
        .map(|l| l.id().to_string())
        .unwrap_or_default()
}
fn supported(doc: &Document) -> bool {
    doc.has_source_text() && matches!(language(doc).as_str(), "markdown" | "fastra-4d")
}
fn entries(
    source: &str,
    language: &str,
    title: &str,
    cancel: &Cancellation,
) -> Result<Vec<Heading>, ()> {
    if source.len() > 10 * 1024 * 1024 {
        return Err(());
    }
    let mut lines = 0;
    let mut chars = source.chars().peekable();
    let mut n = 0;
    while let Some(c) = chars.next() {
        n += 1;
        if n & 1023 == 0 {
            cancel.check().map_err(|_| ())?;
        }
        if matches!(c, '\r' | '\n' | '\u{85}' | '\u{2028}' | '\u{2029}') {
            lines += 1;
            if c == '\r' && chars.peek() == Some(&'\n') {
                chars.next();
            }
            if lines >= 200_000 && chars.peek().is_some() {
                return Err(());
            }
        }
    }
    if language == "fastra-4d" {
        let values = fastra_core::four_d::Analysis::outline(source, cancel).map_err(|_| ())?;
        if values.is_empty() {
            return Ok(vec![Heading {
                level: 1,
                title: title.into(),
                line: 1,
                offset: 0,
                end: 0,
                byte: 0,
                anchor: String::new(),
                kind: Kind::Method,
            }]);
        }
        return Ok(values
            .into_iter()
            .map(|value| Heading {
                level: 1,
                title: value.name,
                line: value.span.line,
                offset: value.span.characters.start as i32,
                end: value.span.characters.end as i32,
                byte: value.span.bytes.start,
                anchor: String::new(),
                kind: Kind::Function(value.kind),
            })
            .collect());
    }
    if language == "markdown" {
        headings(source, cancel)
    } else {
        Ok(vec![])
    }
}
pub(crate) fn plain_title(source: &str, cancel: &Cancellation) -> Result<String, ()> {
    let options = markdown::parser_options() - pulldown_cmark::Options::ENABLE_MATH;
    let marked = crate::rich_editor::mark::rewrite_tagged(source, options).map_err(|_| ())?;
    let input = marked
        .as_ref()
        .map_or(source, |marked| marked.source.as_str());
    let mut title = String::new();
    for event in pulldown_cmark::Parser::new_ext(input, options) {
        cancel.check().map_err(|_| ())?;
        match event {
            Event::Text(text) | Event::Code(text) => title.push_str(&text),
            Event::SoftBreak | Event::HardBreak => title.push(' '),
            Event::InlineHtml(html) if html.to_lowercase().starts_with("<br") => title.push(' '),
            _ => {}
        }
        if title.len() > 16 * 1024 {
            return Err(());
        }
    }
    Ok(title.replace('\n', " ").trim().to_owned())
}
pub(super) fn headings(source: &str, cancel: &Cancellation) -> Result<Vec<Heading>, ()> {
    cancel.check().map_err(|_| ())?;
    if source.len() > 10 * 1024 * 1024 {
        return Err(());
    }
    let mut lines = vec![(0, 0)];
    let mut chars = source.char_indices().peekable();
    let mut offset = 0;
    while let Some((byte, c)) = chars.next() {
        offset += 1;
        if c == '\r' && chars.peek().is_some_and(|(_, c)| *c == '\n') {
            chars.next();
            offset += 1;
            lines.push((byte + 2, offset));
        } else if c == '\r' || c == '\n' {
            lines.push((byte + 1, offset));
        }
    }
    let mut result = Vec::new();
    let mut current: Option<Heading> = None;
    let mut used = std::collections::HashSet::<String>::new();
    let mut next = std::collections::HashMap::<String, usize>::new();
    for (count, (event, range, _)) in markdown::syntax::Parsed::bounded(
        source,
        false,
        markdown::math::Budget {
            source_bytes: 10 * 1024 * 1024,
            ..Default::default()
        },
        cancel,
    )
    .and_then(|p| p.events(false, cancel))
    .map_err(|_| ())?
    .into_iter()
    .enumerate()
    {
        if count >= 500_000 || cancel.check().is_err() {
            return Err(());
        }
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                if result.len() >= 10_000 {
                    return Err(());
                }
                let line = lines.partition_point(|(byte, _)| *byte <= range.start) - 1;
                current = Some(Heading {
                    level: level as u8,
                    title: String::new(),
                    line: line + 1,
                    offset: lines[line].1,
                    byte: range.start,
                    anchor: String::new(),
                    end: lines[line].1,
                    kind: Kind::Markdown,
                });
            }
            Event::End(TagEnd::Heading(_)) => {
                if let Some(mut heading) = current.take() {
                    heading.title = plain_title(source.get(range.clone()).ok_or(())?, cancel)?;
                    let mut slug = String::new();
                    for c in heading.title.to_lowercase().chars() {
                        if c.is_alphanumeric() {
                            slug.push(c);
                        } else if !slug.is_empty() && !slug.ends_with('-') {
                            slug.push('-');
                        }
                    }
                    let slug = slug.trim_end_matches('-');
                    let slug = if slug.is_empty() { "heading" } else { slug };
                    let number = next.entry(slug.to_owned()).or_default();
                    loop {
                        let candidate = if *number == 0 {
                            slug.to_owned()
                        } else {
                            format!("{slug}-{number}")
                        };
                        if used.insert(candidate.clone()) {
                            heading.anchor = candidate;
                            *number += 1;
                            break;
                        }
                        *number += 1;
                    }
                    result.push(heading);
                }
            }
            Event::Text(text) | Event::Code(text) | Event::InlineMath(text) => {
                if let Some(heading) = current.as_mut() {
                    heading.title.push_str(&text);
                    if heading.title.len() > 16 * 1024 {
                        return Err(());
                    }
                }
            }
            Event::SoftBreak | Event::HardBreak => {
                if let Some(heading) = current.as_mut() {
                    heading.title.push(' ');
                }
            }
            _ => {}
        }
    }
    cancel.check().map_err(|_| ())?;
    Ok(result)
}
pub(super) fn install(
    ui: &Rc<Ui>,
    doc: &Rc<Document>,
    _view: &sourceview5::View,
    unfold: &gtk::Button,
    options: &gtk::FlowBox,
) {
    let history = history::get(ui);
    let view = View::new(ui, doc, unfold, history);
    options.insert(&view.root, -1);
    *doc.outline.borrow_mut() = Some(view);
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) use gui_test::start as selftest;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parsed_headings_preserve_original_unicode_positions_and_ignore_code() {
        let source = "🙂\r\n# A &amp; **B**\r\n\r\n```md\r\n# hidden\r\n```\r\n\r\nTitle `code`\r\n---\r\n\r\n# A &amp; **B**\r\n";
        let h = headings(source, &Cancellation::default()).unwrap();
        assert_eq!(h.len(), 3);
        assert_eq!(
            (h[0].line, h[0].offset, h[0].title.as_str()),
            (2, 3, "A & B")
        );
        assert_eq!(h[1].title, "Title code");
        assert_eq!(h[0].anchor, "a-b");
        assert_eq!(h[2].anchor, "a-b-1");
        for heading in h {
            assert_eq!(
                source[..heading.byte].chars().count() as i32,
                heading.offset
            );
        }
    }
    #[test]
    fn cancelled_or_excessive_outline_has_no_partial_result() {
        let cancel = Cancellation::default();
        cancel.cancel();
        assert!(headings("# heading", &cancel).is_err());
        assert!(headings(&"# heading\n".repeat(10_001), &Cancellation::default()).is_err());
    }
}

#[cfg(test)]
mod outline_tests {
    use super::*;
    #[test]
    fn original_heading_titles_keep_formula_delimiters_and_mac_inline_marks() {
        let values = headings(
            "# **Bold** and ==marked== $a_b$ <br> &amp;\r\n",
            &Cancellation::default(),
        )
        .unwrap();
        assert_eq!(values[0].title, "Bold and marked $a_b$   &");
        assert_eq!(values[0].kind, Kind::Markdown);
        assert_eq!(values[0].offset, values[0].end);
    }
    #[test]
    fn four_d_outline_has_method_fallback_and_declared_accessors_without_running_an_engine() {
        let cancel = Cancellation::default();
        let value = entries("// no definitions\r\n", "fastra-4d", "Method.4dm", &cancel).unwrap();
        assert_eq!(
            (
                value[0].kind.clone(),
                value[0].title.as_str(),
                value[0].line
            ),
            (Kind::Method, "Method.4dm", 1)
        );
        let values = entries(
            "// Function fake()\nFunction get real()\n",
            "fastra-4d",
            "Method.4dm",
            &cancel,
        )
        .unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(
            values[0].kind,
            Kind::Function(fastra_core::four_d::Kind::Getter)
        );
        assert!(values[0].end > values[0].offset);
    }
}
