//! Sichtbare ASCII-Leerzeilen werden erst im vorhandenen Offsetbaum ergänzt.
//! Originalbytes und CommonMark-Container bleiben dabei unverändert.
#[cfg(test)]
use pulldown_cmark::Parser;
use pulldown_cmark::{Event, Options, Tag};
use std::{collections::BTreeMap, ops::Range};

pub(crate) const CLASS: &str = "fastra-visible-blank-line";
const MAX_EVENTS: usize = 500_000;
const MAX_DEPTH: usize = 128;
#[derive(Debug)]
pub(crate) struct Limit;
#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Root,
    Container,
    List,
    Item,
    Literal,
    Leaf,
}
struct Node {
    kind: Kind,
    range: Range<usize>,
    enter: usize,
    exit: usize,
    parent: usize,
    children: Vec<usize>,
}
struct Line {
    range: Range<usize>,
    content_end: usize,
}
fn lines(source: &str) -> Vec<Line> {
    let bytes = source.as_bytes();
    let mut result = Vec::new();
    let mut start = 0;
    let mut at = 0;
    while at < bytes.len() {
        if matches!(bytes[at], b'\r' | b'\n') {
            let end = at;
            at += 1;
            if bytes[end] == b'\r' && bytes.get(at) == Some(&b'\n') {
                at += 1;
            }
            result.push(Line {
                range: start..at,
                content_end: end,
            });
            start = at;
        } else {
            at += 1;
        }
    }
    if start < bytes.len() {
        result.push(Line {
            range: start..bytes.len(),
            content_end: bytes.len(),
        });
    }
    result
}
pub(crate) fn visible(line: &str) -> bool {
    let mut content = line.as_bytes();
    loop {
        let first = content.iter().position(|b| *b != b' ');
        if let Some(at) = first.filter(|at| content[*at] == b'>') {
            content = &content[at + 1..];
            if content.first() == Some(&b' ') {
                content = &content[1..];
            }
        } else {
            break;
        }
    }
    content.len() >= 2 && content.iter().all(|b| *b == b' ')
}
pub(crate) fn html(line: usize) -> String {
    format!("<div class=\"{CLASS}\" data-srcline=\"{line}\"><br></div>")
}
fn kind(tag: &Tag<'_>) -> Kind {
    match tag {
        Tag::List(_) => Kind::List,
        Tag::Item => Kind::Item,
        Tag::BlockQuote(_) | Tag::FootnoteDefinition(_) => Kind::Container,
        Tag::CodeBlock(_) | Tag::HtmlBlock => Kind::Literal,
        _ => Kind::Leaf,
    }
}
fn line_at(lines: &[Line], offset: usize) -> usize {
    lines.partition_point(|line| line.range.end <= offset)
}

/// Rich-Quellblöcke und ihre Lücken müssen dieselben Formelgrenzen verwenden.
/// Ein einzelner Lückenabschnitt enthält den öffnenden $$-Marker oft nicht mehr.
pub(crate) fn math_regions(source: &str, _options: Options) -> Result<Vec<Range<usize>>, Limit> {
    super::math::formula_ranges(
        source,
        super::math::Budget::default(),
        &fastra_core::Cancellation::default(),
    )
    .map(super::math::merged_regions)
    .map_err(|_| Limit)
}

/// Das Bool kennzeichnet ausschließlich von diesem Modul erzeugtes HTML.
/// Nutzer-HTML darf niemals über denselben Vertrauenspfad gerendert werden.
pub(crate) fn line_starts(source: &str) -> Vec<usize> {
    lines(source)
        .into_iter()
        .map(|line| line.range.start)
        .collect()
}
#[cfg(test)]
pub(crate) fn events(
    source: &str,
    options: Options,
) -> Result<Vec<(Event<'_>, Range<usize>, bool)>, Limit> {
    events_from(source, options, 1)
}
#[cfg(test)]
pub(crate) fn events_from(
    source: &str,
    options: Options,
    first_line: usize,
) -> Result<Vec<(Event<'_>, Range<usize>, bool)>, Limit> {
    insert_events(
        source,
        Parser::new_ext(source, options).into_offset_iter(),
        first_line,
    )
}
/// Übernimmt bereits global aufgelöste Referenzen; Blockausschnitte dürfen sie
/// nicht durch einen erneuten Parserlauf ohne die Dokumentdefinitionen verlieren.
#[cfg(test)]
pub(crate) fn insert_events<'a>(
    source: &str,
    input: impl IntoIterator<Item = (Event<'a>, Range<usize>)>,
    first_line: usize,
) -> Result<Vec<(Event<'a>, Range<usize>, bool)>, Limit> {
    insert_with_math(source, input, first_line, true)
}
pub(crate) fn insert_with_math<'a>(
    source: &str,
    input: impl IntoIterator<Item = (Event<'a>, Range<usize>)>,
    first_line: usize,
    infer_math: bool,
) -> Result<Vec<(Event<'a>, Range<usize>, bool)>, Limit> {
    let lines = lines(source);
    let mut events = Vec::new();
    let mut nodes = vec![Node {
        kind: Kind::Root,
        range: 0..source.len(),
        enter: 0,
        exit: 0,
        parent: 0,
        children: Vec::new(),
    }];
    let mut stack = vec![0usize];
    for (event, range) in input {
        if events.len() >= MAX_EVENTS {
            return Err(Limit);
        }
        let index = events.len();
        match &event {
            Event::Start(tag) => {
                if stack.len() > MAX_DEPTH {
                    return Err(Limit);
                }
                let parent = *stack.last().ok_or(Limit)?;
                let id = nodes.len();
                let kind = kind(tag);
                nodes.push(Node {
                    kind,
                    range: range.clone(),
                    enter: index,
                    exit: index,
                    parent,
                    children: Vec::new(),
                });
                nodes[parent].children.push(id);
                stack.push(id);
            }
            Event::End(_) => {
                let id = stack.pop().filter(|id| *id != 0).ok_or(Limit)?;
                nodes[id].exit = index;
            }
            _ => {}
        }
        events.push((event, range, false));
    }
    if stack != [0] {
        return Err(Limit);
    }
    nodes[0].exit = events.len();
    let formulas = if infer_math {
        math_regions(source, Options::empty())?
    } else {
        Vec::new()
    };
    let mut formula = 0;
    let mut inserts: BTreeMap<usize, Vec<(Event<'_>, Range<usize>, bool)>> = BTreeMap::new();
    for (number, line) in lines.iter().enumerate() {
        if !visible(&source[line.range.start..line.content_end]) {
            continue;
        }
        while formula < formulas.len() && formulas[formula].end <= line.range.start {
            formula += 1;
        }
        if formulas
            .get(formula)
            .is_some_and(|r| r.start <= line.range.start && line.range.start < r.end)
        {
            continue;
        }
        let mut parent = 0;
        let position = loop {
            let node = &nodes[parent];
            if matches!(node.kind, Kind::Literal | Kind::Leaf) {
                break None;
            }
            let children = &node.children;
            let after =
                children.partition_point(|id| line_at(&lines, nodes[*id].range.start) <= number);
            if after > 0 {
                let id = children[after - 1];
                let child = &nodes[id];
                if number <= line_at(&lines, child.range.end.saturating_sub(1)) {
                    parent = id;
                    continue;
                }
            }
            let next = children.get(after).copied();
            let previous = after.checked_sub(1).map(|i| children[i]);
            if node.kind == Kind::List {
                if next.is_none() {
                    break Some(node.exit + 1);
                }
                break previous
                    .map(|id| nodes[id].exit)
                    .or_else(|| next.map(|id| nodes[id].enter + 1));
            }
            if node.kind == Kind::Item && next.is_none() {
                let list = &nodes[node.parent];
                if list.kind == Kind::List && list.children.last() == Some(&parent) {
                    break Some(list.exit + 1);
                }
            }
            break Some(next.map_or(node.exit, |id| nodes[id].enter));
        };
        if let Some(position) = position {
            inserts.entry(position).or_default().push((
                Event::Html(html(first_line + number).into()),
                line.range.clone(),
                true,
            ));
        }
    }
    let added = inserts.values().map(Vec::len).sum::<usize>();
    if events.len() + added > MAX_EVENTS {
        return Err(Limit);
    }
    let original_len = events.len();
    let mut output = Vec::with_capacity(events.len() + added);
    for (index, event) in events.into_iter().enumerate() {
        if let Some(extra) = inserts.remove(&index) {
            output.extend(extra);
        }
        output.push(event);
    }
    if let Some(extra) = inserts.remove(&original_len) {
        output.extend(extra);
    }
    if !inserts.is_empty() {
        return Err(Limit);
    }
    Ok(output)
}

pub(crate) const CSS: &str = ".fastra-visible-blank-line{min-height:calc(var(--fastra-text-line-height)*1em);margin:0;padding:0}li .fastra-visible-blank-line{min-height:1.55em}";
/// Lücken werden zeilenweise erhalten; auch CRLF bleibt im Quellenblock stehen.
pub(crate) fn gaps(source: &str) -> impl Iterator<Item = (&str, bool)> {
    lines(source).into_iter().map(move |line| {
        (
            &source[line.range.clone()],
            visible(&source[line.range.start..line.content_end]),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn render(source: &str) -> String {
        let mut html = String::new();
        pulldown_cmark::html::push_html(
            &mut html,
            events(
                source,
                Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS | Options::ENABLE_MATH,
            )
            .unwrap()
            .into_iter()
            .map(|e| e.0),
        );
        html
    }
    fn count(source: &str) -> usize {
        render(source).matches(CLASS).count()
    }
    #[test]
    fn mac_threshold_and_character_corpus() {
        for s in [
            "Alpha\n\nOmega",
            "Alpha\n \nOmega",
            "Alpha\n\t\nOmega",
            "Alpha\n\u{a0}\nOmega",
        ] {
            assert_eq!(count(s), 0, "{s}");
        }
        for s in [
            "Alpha\n  \nOmega",
            "Alpha\n   \nOmega",
            "Alpha\n    \nOmega",
        ] {
            assert_eq!(count(s), 1, "{s}");
        }
    }
    #[test]
    fn mac_hard_breaks_and_literal_corpus() {
        let h = render("Alpha  \nBeta\nGamma\\\nDelta");
        assert_eq!(h.matches("<br />").count(), 2);
        assert!(!h.contains(CLASS));
        let s = "```text\nfenced\n  \nblock\n```\n\n    indented\n      \n    block";
        let h = render(s);
        assert_eq!(h.matches("<pre").count(), 2);
        assert!(!h.contains(CLASS));
    }
    #[test]
    fn mac_lists_quotes_and_empty_trailing_items() {
        let h = render("- Eins\n  \n- Zwei");
        assert_eq!(h.matches("<ul").count(), 1);
        assert_eq!(h.matches("<li").count(), 2);
        assert_eq!(h.matches(CLASS).count(), 1);
        let h = render("> Eins\n  \n> Zwei");
        assert_eq!(h.matches("<blockquote").count(), 2);
        assert_eq!(h.matches(CLASS).count(), 1);
        let s = format!(
            "***Getestet:***\n\n-\n-\n-\n-\n-\n-\n{}\n***Frage:***",
            ["  "; 6].join("\n")
        );
        let h = render(&s);
        assert_eq!(h.matches("<ul").count(), 1);
        assert_eq!(h.matches("<li").count(), 6);
        assert_eq!(h.matches(CLASS).count(), 6);
        for n in 9..=14 {
            assert!(h.contains(&format!("data-srcline=\"{n}\"")));
        }
        assert!(h.find("</ul>").unwrap() < h.find(CLASS).unwrap());
    }
    #[test]
    fn mac_gfm_math_blank_assertions() {
        let s="| A | B |\n| - | - |\n| 1 | 2 |\n  \n![Bild](bild.png)\n  \n$$\nx + y\n  \nz\n$$\n  \nEnde";
        let h = render(s);
        assert!(h.contains("<table"));
        assert!(h.contains("<img"));
        assert_eq!(h.matches(CLASS).count(), 3);
        assert!(h.contains("data-srcline=\"12\"")); /* Die vorbestehende Linux-Math-Darstellung wird hier nicht als Mac-Parität ausgegeben. */
    }
    #[test]
    fn mac_boundaries_and_consecutive_lines() {
        let h = render("  \n   \nText\n  ");
        assert_eq!(h.matches(CLASS).count(), 3);
        for n in [1, 2, 4] {
            assert!(h.contains(&format!("data-srcline=\"{n}\"")));
        }
    }
    #[test]
    fn nested_quotes_nonempty_trailing_lists_and_raw_html() {
        let h = render("> > Eins\n> >   \n> > Zwei");
        assert_eq!(h.matches("<blockquote").count(), 2);
        assert_eq!(h.matches(CLASS).count(), 1);
        let h = render("- Eins\n  \n  \nText");
        assert_eq!(h.matches(CLASS).count(), 2);
        assert!(h.find("</ul>").unwrap() < h.find(CLASS).unwrap());
        assert_eq!(count("<pre>\n  \n</pre>\n  \nText"), 1);
    }
    #[test]
    fn exact_crlf_unicode_and_parser_events() {
        for s in [
            "雪😀\r\n  \r\nΩ",
            "> 雪\r>   \r> Ω",
            "- 雪\n  \n- 😀",
            "\u{2028}雪\n  \nΩ",
        ] {
            let augmented = events(s, Options::all()).unwrap();
            let untouched = augmented
                .iter()
                .filter(|e| !e.2)
                .map(|e| (e.0.clone(), e.1.clone()))
                .collect::<Vec<_>>();
            let original = Parser::new_ext(s, Options::all())
                .into_offset_iter()
                .collect::<Vec<_>>();
            assert_eq!(untouched, original);
            assert_eq!(augmented.iter().filter(|e| e.2).count(), 1);
            for (_, r, synthetic) in augmented {
                assert!(s.is_char_boundary(r.start) && s.is_char_boundary(r.end));
                if synthetic {
                    assert!(visible(s[r].trim_end_matches(['\r', '\n'])));
                }
            }
            assert_eq!(gaps(s).map(|p| p.0).collect::<String>(), s);
        }
    }
    #[test]
    fn formulas_cannot_escape_code_or_raw_html() {
        assert_eq!(count("```\n$$\n  \n$$\n```\n  \nText"), 1);
        assert_eq!(count("<pre>\n$$\n  \n$$\n</pre>\n  \nText"), 1);
        assert_eq!(count("$$\nx\n  \ny\n$$\n  \nText"), 1);
    }
    #[test]
    fn bounded_deep_input() {
        let source = format!("{}text", "> ".repeat(150));
        assert!(events(&source, Options::all()).is_err());
    }
}
