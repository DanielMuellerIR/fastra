//! Ein Parserlauf über die gemeinsame Ansicht; alle ausgegebenen Bereiche sind Originalbytes.
use super::{autolinks, math, visible_blank_lines};
use fastra_core::Cancellation;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use std::{collections::HashMap, ops::Range};

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum Generated {
    None,
    Mark,
    Blank,
    MathSource,
    MathBlock,
}
pub(crate) type MappedEvent = (Event<'static>, Range<usize>, Generated);
pub(crate) struct Parsed {
    pub(super) extraction: math::Extraction,
    references: HashMap<(usize, usize), (String, String)>,
    collapsed: HashMap<(usize, usize), usize>,
    autolinks: Vec<autolinks::Link>,
}
impl Parsed {
    pub(crate) fn new(
        source: &str,
        mark: bool,
        cancel: &Cancellation,
    ) -> Result<Self, math::Error> {
        Self::bounded(source, mark, math::Budget::default(), cancel)
    }
    pub(crate) fn bounded(source: &str, mark: bool, budget: math::Budget, cancel: &Cancellation) -> Result<Self, math::Error> {
        let normalized = math::normalized(source, budget, cancel)?;
        let mut literals = Vec::new();
        let mut references = HashMap::new();
        let mut collapsed = HashMap::new();
        let mut reference_bytes = 0usize;
        let mut links: Vec<(Range<usize>, Option<Range<usize>>)> = Vec::new();
        let mut parser = Parser::new_ext(
            normalized.prepared(),
            super::parser_options() - Options::ENABLE_MATH,
        )
        .into_offset_iter();
        let mut count = 0usize;
        for (event, range) in parser.by_ref() {
            cancel.check()?;
            count += 1;
            if count > 500_000 {
                return Err(math::Error::Limit);
            }
            match &event {
                Event::Start(
                    Tag::Image {
                        dest_url,
                        title,
                        link_type,
                        id,
                        ..
                    }
                    | Tag::Link {
                        dest_url,
                        title,
                        link_type,
                        id,
                        ..
                    },
                ) => {
                    let original = normalized.original_range(range.clone())?.bytes;
                    if matches!(
                        link_type,
                        pulldown_cmark::LinkType::Autolink | pulldown_cmark::LinkType::Email
                    ) {
                        // Bei Autolinks ist der sichtbare Text zugleich das Ziel.
                        literals.push(original.clone());
                    }
                    if *link_type == pulldown_cmark::LinkType::Collapsed {
                        // Pulldown 0.13 meldet nur den ersten Klammerblock. Nur der
                        // belegte Collapsed-Typ besitzt die konsumierten Abschluss-[] .
                        if !source[original.end..].starts_with("[]") {
                            return Err(math::Error::Boundary);
                        }
                        collapsed.insert((original.start, original.end), original.end + 2);
                    }
                    reference_bytes = reference_bytes
                        .checked_add(dest_url.len())
                        .and_then(|n| n.checked_add(title.len()))
                        .and_then(|n| n.checked_add(id.len()))
                        .ok_or(math::Error::Limit)?;
                    if reference_bytes > budget.view_bytes {
                        return Err(math::Error::Limit);
                    }
                    references.insert(
                        (original.start, original.end),
                        (dest_url.to_string(), title.to_string(), id.to_string()),
                    );
                    if links.len() >= 128 {
                        return Err(math::Error::Limit);
                    }
                    links.push((range.clone(), None));
                }
                Event::End(TagEnd::Image | TagEnd::Link) => {
                    let (whole, content) = links.pop().ok_or(math::Error::Invariant)?;
                    // Nur sichtbare Kinder dürfen Formeln enthalten. Ziel, Titel und
                    // Referenz-ID bleiben anhand ihrer Quellpositionen unverändert.
                    if let Some(content) = content {
                        literals.push(normalized.original_range(whole.start..content.start)?.bytes);
                        literals.push(normalized.original_range(content.end..whole.end)?.bytes);
                    } else {
                        literals.push(normalized.original_range(whole)?.bytes);
                    }
                }
                Event::Text(_)
                | Event::Code(_)
                | Event::Html(_)
                | Event::InlineHtml(_)
                | Event::SoftBreak
                | Event::HardBreak => {
                    for (_, content) in &mut links {
                        if let Some(content) = content {
                            content.end = content.end.max(range.end);
                        } else {
                            *content = Some(range.clone());
                        }
                    }
                }
                _ => {}
            }
            if matches!(
                event,
                Event::Start(Tag::CodeBlock(_) | Tag::HtmlBlock)
                    | Event::Code(_)
                    | Event::Html(_)
                    | Event::InlineHtml(_)
            ) {
                literals.push(normalized.original_range(range)?.bytes);
            }
        }
        for (_, definition) in parser.reference_definitions().iter() {
            cancel.check()?;
            if literals.len() >= 500_000 {
                return Err(math::Error::Limit);
            }
            literals.push(normalized.original_range(definition.span.clone())?.bytes);
        }
        let mut dependencies = HashMap::new();
        for (key, (_, _, id)) in &references {
            cancel.check()?;
            if let Some(definition) = parser.reference_definitions().get(id) {
                dependencies.insert(
                    *key,
                    normalized.original_range(definition.span.clone())?.bytes,
                );
            }
        }
        literals.sort_by_key(|r| r.start);
        let mut extraction = math::extract_mapped(normalized, &literals, budget, cancel)?;
        let regions = math::merged_regions(
            extraction
                .formulas()
                .iter()
                .map(|f| f.source.clone())
                .collect(),
        );
        let mut surviving = HashMap::new();
        for (key, (url, title, _)) in references {
            cancel.check()?;
            if let Some(definition) = dependencies.get(&key) {
                let first = regions.partition_point(|r| r.end <= definition.start);
                // Eine durch Formelextraktion entfernte Definition begründet keine
                // spätere Dateiautorität für ein außerhalb stehendes Label.
                if regions.get(first).is_none_or(|r| r.start >= definition.end) {
                    surviving.insert(key, (url, title));
                }
            }
        }
        let references = surviving;
        let autolinks = autolinks::scan(&extraction, cancel)?;
        extraction.apply_links(
            &autolinks
                .iter()
                .map(|link| link.range.clone())
                .collect::<Vec<_>>(),
            budget,
            cancel,
        )?;
        if mark {
            if let Ok(Some(marked)) = crate::rich_editor::mark::rewrite_tagged(
                extraction.prepared(),
                super::parser_options() - Options::ENABLE_MATH,
            ) {
                extraction.apply_marks(marked.changes(), budget, cancel)?;
            }
        }
        Ok(Self {
            extraction,
            references,
            collapsed,
            autolinks,
        })
    }
    pub(crate) fn block_math_sources(&self) -> impl Iterator<Item = Range<usize>> + '_ {
        self.extraction
            .formulas()
            .iter()
            .filter(|formula| formula.block)
            .map(|formula| formula.source.bytes.clone())
    }
    fn prepared_events(
        &self,
        cancel: &Cancellation,
    ) -> Result<Vec<(Event<'static>, Range<usize>)>, math::Error> {
        let view = self.extraction.prepared();
        enum Atom {
            Math(usize),
            Link(usize),
        }
        let mut tokens = self
            .extraction
            .tokens()
            .iter()
            .map(|token| (token.prepared.clone(), Atom::Math(token.formula)))
            .collect::<Vec<_>>();
        tokens.extend(
            self.extraction
                .link_tokens()
                .map(|(range, id)| (range, Atom::Link(id))),
        );
        tokens.sort_by_key(|token| token.0.start);
        let mut output = Vec::new();
        let mut image_depth = 0usize;
        let mut link_depth = 0usize;
        let invalid_reference = std::cell::Cell::new(false);
        let mut resolve = |link: pulldown_cmark::BrokenLink<'_>| {
            let original = match self.extraction.original_range(link.span) {
                Ok(original) => original.bytes,
                Err(_) => {
                    invalid_reference.set(true);
                    return None;
                }
            };
            // Eine sichtbare Formel kann die Kurzreferenz-ID im Arbeitsview ändern.
            // Auflösen darf nur genau der zuvor belegte Original-Quellverweis.
            self.references
                .get(&(original.start, original.end))
                .map(|(url, title)| (url.clone().into(), title.clone().into()))
        };
        let parser = Parser::new_with_broken_link_callback(
            view,
            super::parser_options() - Options::ENABLE_MATH,
            Some(&mut resolve),
        )
        .into_offset_iter();
        let mut examined = 0usize;
        for (event, range) in parser {
            examined += 1;
            cancel.check()?;
            if examined > 500_000 || output.len() >= 500_000 {
                return Err(math::Error::Limit);
            }
            match &event {
                Event::Start(Tag::Link { .. }) => link_depth += 1,
                Event::End(TagEnd::Link) => {
                    link_depth = link_depth.checked_sub(1).ok_or(math::Error::Invariant)?
                }
                Event::Start(Tag::Image { .. }) => image_depth += 1,
                Event::End(TagEnd::Image) => {
                    image_depth = image_depth.checked_sub(1).ok_or(math::Error::Invariant)?
                }
                _ => {}
            }
            let first = tokens.partition_point(|t| t.0.end <= range.start);
            let relevant = tokens[first..].iter().take_while(|t| t.0.start < range.end);
            if let Event::Text(text) = &event {
                let relevant = relevant.collect::<Vec<_>>();
                if !relevant.is_empty() {
                    // Pulldown trennt Entity-/Escapeereignisse ab. Nur ein exakt
                    // belegter Textbereich darf positionsregistrierte Atome enthalten.
                    if text.as_ref() != &view[range.clone()] {
                        return Err(math::Error::Boundary);
                    }
                    let mut cursor = range.start;
                    for (prepared, atom) in relevant {
                        if prepared.start < cursor || prepared.end > range.end {
                            return Err(math::Error::Boundary);
                        }
                        if cursor < prepared.start {
                            output.push((
                                Event::Text(view[cursor..prepared.start].to_owned().into()),
                                cursor..prepared.start,
                            ));
                        }
                        match atom {
                            Atom::Math(id) => {
                                let formula = &self.extraction.formulas()[*id];
                                let event = if formula.nested_tokens || image_depth > 0 {
                                    Event::Text(
                                        self.extraction.source()[formula.source.bytes.clone()]
                                            .to_owned()
                                            .into(),
                                    )
                                } else if formula.block {
                                    Event::DisplayMath(formula.captured_tex.clone().into())
                                } else {
                                    Event::InlineMath(formula.captured_tex.clone().into())
                                };
                                output.push((event, prepared.clone()));
                            }
                            Atom::Link(id) => {
                                let link = &self.autolinks[*id];
                                // Wiederhergestellte Referenzen und Bildlabels dürfen
                                // aus einem Textatom keinen verschachtelten Link machen.
                                if image_depth == 0 && link_depth == 0 {
                                    output.push((
                                        Event::Start(Tag::Link {
                                            link_type: pulldown_cmark::LinkType::Autolink,
                                            dest_url: link.url.clone().into(),
                                            title: "".into(),
                                            id: "".into(),
                                        }),
                                        prepared.clone(),
                                    ));
                                    output.push((
                                        Event::Text(link.text.clone().into()),
                                        prepared.clone(),
                                    ));
                                    output.push((Event::End(TagEnd::Link), prepared.clone()));
                                } else {
                                    output.push((
                                        Event::Text(link.text.clone().into()),
                                        prepared.clone(),
                                    ));
                                }
                            }
                        }
                        cursor = prepared.end;
                    }
                    if cursor < range.end {
                        output.push((
                            Event::Text(view[cursor..range.end].to_owned().into()),
                            cursor..range.end,
                        ));
                    }
                    continue;
                }
            }
            let event = match event {
                Event::Html(_) | Event::InlineHtml(_)
                    if !self.extraction.generated_mark(&range) =>
                {
                    let original = self.extraction.original_range(range.clone())?.bytes;
                    // Rohes Nutzer-HTML geht unverändert an die Positivliste; Arbeitsmarker
                    // innerhalb eines HTML-Blocks werden niemals als Atome aktiviert.
                    let raw = self.extraction.source()[original].to_owned();
                    if matches!(event, Event::Html(_)) {
                        Event::Html(raw.into())
                    } else {
                        Event::InlineHtml(raw.into())
                    }
                }
                event => event.into_static(),
            };
            output.push((event, range));
        }
        if invalid_reference.get() {
            return Err(math::Error::Boundary);
        }
        Ok(output)
    }
    pub(crate) fn events(
        &self,
        blanks: bool,
        cancel: &Cancellation,
    ) -> Result<Vec<MappedEvent>, math::Error> {
        let input = self.prepared_events(cancel)?;
        let mut standalone = std::collections::HashSet::new();
        let mut compact = Vec::with_capacity(input.len());
        let mut input = input.into_iter().peekable();
        while let Some((event, range)) = input.next() {
            if matches!(event, Event::Start(Tag::Paragraph))
                && input
                    .peek()
                    .is_some_and(|(e, _)| matches!(e, Event::DisplayMath(_)))
            {
                let math = input.next().unwrap();
                if input
                    .peek()
                    .is_some_and(|(e, _)| matches!(e, Event::End(TagEnd::Paragraph)))
                {
                    input.next();
                    standalone.insert(math.1.start);
                    compact.push(math);
                    continue;
                }
                compact.push((event, range));
                compact.push(math);
                continue;
            }
            compact.push((event, range));
        }
        let input = if blanks {
            visible_blank_lines::insert_with_math(self.extraction.prepared(), compact, 1, false)
                .map_err(|_| math::Error::Limit)?
        } else {
            compact.into_iter().map(|(e, r)| (e, r, false)).collect()
        };
        let mut output = Vec::with_capacity(input.len());
        for (event, range, blank) in input {
            cancel.check()?;
            let mut original = self.extraction.original_range(range.clone())?.bytes;
            if matches!(
                &event,
                Event::Start(Tag::Image { .. } | Tag::Link { .. })
                    | Event::End(TagEnd::Image | TagEnd::Link)
            ) {
                if let Some(end) = self.collapsed.get(&(original.start, original.end)) {
                    original.end = *end;
                }
            }
            let generated = if blank {
                Generated::Blank
            } else if self.extraction.generated_mark(&range) {
                Generated::Mark
            } else if self
                .extraction
                .token_at(&range)
                .is_some_and(|t| self.extraction.formulas()[t.formula].nested_tokens)
            {
                Generated::MathSource
            } else if standalone.contains(&range.start) && matches!(event, Event::DisplayMath(_)) {
                Generated::MathBlock
            } else {
                Generated::None
            };
            let event = if blank {
                Event::Html(
                    visible_blank_lines::html(self.extraction.original_line_at(range.start)?)
                        .into(),
                )
            } else {
                event
            };
            output.push((event, original, generated));
        }
        Ok(output)
    }
}
pub(crate) fn events(source: &str, cancel: &Cancellation) -> Result<Vec<MappedEvent>, math::Error> {
    Parsed::new(source, false, cancel)?.events(false, cancel)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lf_crlf_cr_fences_and_reference_ranges_share_original_source() {
        let lf = "雪🙂\n\n```md\n# hidden\n![fake](inside.png)\n$x$\n```\n\n~~~text\n==code==\n~~~\n\n```\nlast\n```\n\n$$\nx + y\n  \n# not a heading\n![fake](formula.png)\n$$\n\n  \n# Real ==Marked== $z$\n\n![picture][p]\n\n[p]: actual.png\n";
        for eol in ["\n", "\r\n", "\r"] {
            let source = lf.replace('\n', eol);
            let events = events(&source, &Cancellation::default()).unwrap();
            assert_eq!(
                events
                    .iter()
                    .filter(|(e, _, _)| matches!(e, Event::Start(Tag::CodeBlock(_))))
                    .count(),
                3
            );
            assert_eq!(
                events
                    .iter()
                    .filter(|(e, _, _)| matches!(e, Event::Start(Tag::Heading { .. })))
                    .count(),
                1
            );
            let images = events
                .iter()
                .filter_map(|(e, r, _)| {
                    if let Event::Start(Tag::Image { dest_url, .. }) = e {
                        Some((dest_url.as_ref(), r))
                    } else {
                        None
                    }
                })
                .collect::<Vec<_>>();
            assert_eq!(images.len(), 1);
            assert_eq!(images[0].0, "actual.png");
            assert_eq!(&source[images[0].1.clone()], "![picture][p]");
            let codes = events
                .iter()
                .filter_map(|(e, _, _)| {
                    if let Event::Text(t) = e {
                        Some(t.as_ref())
                    } else {
                        None
                    }
                })
                .collect::<String>();
            assert!(codes.contains("# hidden\n![fake](inside.png)\n$x$\n"));
            let p = Parsed::new(&source, true, &Cancellation::default()).unwrap();
            let rendered = p.events(true, &Cancellation::default()).unwrap();
            assert_eq!(
                rendered
                    .iter()
                    .filter(|(_, _, g)| *g == Generated::Blank)
                    .count(),
                1
            );
            assert_eq!(
                rendered
                    .iter()
                    .filter(|(_, _, g)| *g == Generated::Mark)
                    .count(),
                2
            );
            let (_, r, _) = rendered
                .iter()
                .find(|(e, _, _)| matches!(e, Event::Start(Tag::Heading { .. })))
                .unwrap();
            assert_eq!(r.start, source.find("# Real").unwrap());
            for (_, range, _) in rendered {
                assert!(source.is_char_boundary(range.start) && source.is_char_boundary(range.end));
            }
        }
    }
    #[test]
    fn token_provenance_survives_mark_entities_escapes_and_literal_names() {
        let literal = "FASTRAMATH00000000000000000000000000000000TOKEN";
        let source = format!("==before== &amp; \\*{literal} $x$==after==");
        let p = Parsed::new(&source, true, &Cancellation::default()).unwrap();
        let events = p.events(false, &Cancellation::default()).unwrap();
        let formulas = events
            .iter()
            .filter(|(e, _, _)| matches!(e, Event::InlineMath(_)))
            .count();
        assert_eq!(formulas, 1);
        let plain = events
            .iter()
            .filter_map(|(e, _, _)| {
                if let Event::Text(t) = e {
                    Some(t.as_ref())
                } else {
                    None
                }
            })
            .collect::<String>();
        assert!(plain.contains(literal));
        assert!(plain.contains('&'));
        assert!(plain.contains('*'));
        assert_eq!(
            events
                .iter()
                .filter(|(_, _, g)| *g == Generated::Mark)
                .count(),
            4
        );
        for token in p.extraction.tokens() {
            assert!(p
                .extraction
                .original_range(token.prepared.start + 1..token.prepared.end)
                .is_err());
        }
    }
    #[test]
    fn literal_destination_and_title_dollars_remain_original_metadata() {
        let cancel = Cancellation::default();
        for source in [
            "![picture]($x$)",
            "[label]($x$)",
            "![picture][r]\n\n[r]: $x$ \"$title$\"\n",
        ] {
            let result = events(source, &cancel).unwrap();
            assert!(result.iter().any(|(e,_,_)| matches!(e, Event::Start(Tag::Image { dest_url, .. } | Tag::Link { dest_url, .. }) if dest_url.as_ref()=="$x$")));
            assert!(!result
                .iter()
                .any(|(e, _, _)| matches!(e, Event::InlineMath(_) | Event::DisplayMath(_))));
        }
        for source in ["<https://example.invalid/$x$>", "<a$x$@example.invalid>"] {
            let result = events(source, &cancel).unwrap();
            let expected = Parser::new_ext(
                source,
                super::super::parser_options() - Options::ENABLE_MATH,
            )
            .find_map(|e| {
                if let Event::Start(Tag::Link { dest_url, .. }) = e {
                    Some(dest_url.to_string())
                } else {
                    None
                }
            })
            .unwrap();
            assert!(result.iter().any(|(e,_,_)|matches!(e,Event::Start(Tag::Link{dest_url,..})if dest_url.as_ref()==expected)));
            assert!(!result
                .iter()
                .any(|(e, _, _)| matches!(e, Event::InlineMath(_) | Event::DisplayMath(_))));
        }
        let source = "<div>$$x$$</div>";
        let result = events(source, &cancel).unwrap();
        assert!(!result
            .iter()
            .any(|(e, _, _)| matches!(e, Event::InlineMath(_) | Event::DisplayMath(_))));
        assert_eq!(
            result
                .iter()
                .filter_map(|(e, _, _)| match e {
                    Event::Text(t) | Event::Html(t) | Event::InlineHtml(t) => Some(t.as_ref()),
                    _ => None,
                })
                .collect::<String>(),
            source
        );
    }
}

#[cfg(test)]
mod review {
    use crate::markdown::syntax;
    use fastra_core::Cancellation;
    use pulldown_cmark::{Event, Tag};
    #[test]
    fn image_label_token_collision() {
        let literal = "FASTRAMATH00000000000000000000000000000000TOKEN";
        for source in [
            format!("![alt $x$]({literal}.png)"),
            format!("[label $x$]({literal})"),
            format!("![alt $x$](pic.png \"{literal}\")"),
        ] {
            let events = syntax::events(&source, &Cancellation::default()).unwrap();
            println!("SOURCE {source:?}\nEVENTS {events:?}");
            assert!(
                events.iter().any(|(e, _, _)| matches!(
                    e,
                    Event::Start(Tag::Image { .. } | Tag::Link { .. })
                )),
                "literal dependency must stay active"
            );
        }
    }

    #[test]
    fn global_math_reference_labels_must_resolve() {
        use pulldown_cmark::{Event, Parser, Tag};
        for source in [
            "![picture][$x$]\n\n[$x$]: pic.png\n",
            "[label][$x$]\n\n[$x$]: https://example.invalid/\n",
            "![picture][r]\n\n[r]: pic.png \"$x$\"\n",
        ] {
            let expected = Parser::new_ext(source, super::super::parser_options())
                .any(|e| matches!(e, Event::Start(Tag::Image { .. } | Tag::Link { .. })));
            let result = syntax::events(source, &fastra_core::Cancellation::default()).unwrap();
            println!("SOURCE {source:?} directactive={expected} result={result:?}");
            assert_eq!(
                result.iter().any(|(e, _, _)| matches!(
                    e,
                    Event::Start(Tag::Image { .. } | Tag::Link { .. })
                )),
                expected,
                "global reference must survive"
            );
        }
    }
    #[test]
    fn formula_must_not_escape_partial_commonmark_literal() {
        use pulldown_cmark::{Event, Parser};
        for source in [
            "```text\n$$\ninside\n````\noutside\n$$\n",
            "~~~text\n$$\ninside\n~~~~\noutside\n$$\n",
            "<div>\n$$\ninside\n</div>\n\noutside\n$$\n",
            "`start\n$$\ninside`\noutside\n$$\n",
        ] {
            let expected = Parser::new_ext(
                source,
                super::super::parser_options() - pulldown_cmark::Options::ENABLE_MATH,
            )
            .into_offset_iter()
            .collect::<Vec<_>>();
            let result = syntax::events(source, &fastra_core::Cancellation::default());
            println!("SOURCE {source:?}\nBEFORE {expected:?}\nRESULT {result:?}");
            assert!(
                !result
                    .unwrap()
                    .iter()
                    .any(|(e, _, _)| matches!(e, Event::DisplayMath(_) | Event::InlineMath(_))),
                "formula delimiter inside literal must not escape it"
            );
        }
    }
    #[test]
    fn longer_backtick_fence_preserves_codecopy_text() {
        use pulldown_cmark::{Event, Tag};
        let source = "```text\n$$\ninside\n````\noutside\n$$\n";
        let events = syntax::events(source, &fastra_core::Cancellation::default()).unwrap();
        let start = events
            .iter()
            .find(|(e, _, _)| matches!(e, Event::Start(Tag::CodeBlock(_))))
            .unwrap();
        assert_eq!(
            start.1,
            0..22,
            "original code block must end at closing fence"
        );
        let actual = events
            .iter()
            .skip(1)
            .take_while(|(e, _, _)| !matches!(e, Event::End(pulldown_cmark::TagEnd::CodeBlock)))
            .filter_map(|(e, _, _)| {
                if let Event::Text(t) = e {
                    Some(t.as_ref())
                } else {
                    None
                }
            })
            .collect::<String>();
        assert_eq!(actual, "$$\ninside\n");
    }
}

#[cfg(test)]
mod reference_identity_tests {
    use super::*;
    #[test]
    fn collapsed_shortcut_and_full_reference_labels_keep_original_resolution() {
        for eol in ["\n", "\r\n", "\r"] {
            for occurrence in ["![alt $x$]", "![alt $x$][]", "![alt $x$][$id$]"] {
                let source = format!("{occurrence}\n\n[alt $x$]: literal.png \"$title$\"\n[$id$]: literal.png \"$title$\"\n").replace('\n',eol);
                for mark in [false, true] {
                    let parsed = Parsed::new(&source, mark, &Cancellation::default()).unwrap();
                    let events = parsed.events(false, &Cancellation::default()).unwrap();
                    assert!(events.iter().any(|(e,_,_)| matches!(e,Event::Start(Tag::Image{dest_url,title,..}) if dest_url.as_ref()=="literal.png" && title.as_ref()=="$title$")),"{source:?}");
                    assert!(events
                        .iter()
                        .any(|(e, _, _)| matches!(e,Event::Text(t) if t.as_ref()=="$x$")));
                }
            }
        }
    }
}

#[cfg(test)]
mod collapsed_range_tests {
    use super::*;
    #[test]
    fn only_original_collapsed_occurrences_include_the_consumed_brackets() {
        for (source, expected) in [
            ("![a][]\n\n[a]: pixel.png\n", "![a][]"),
            ("![a](pixel.png)[]", "![a](pixel.png)"),
            ("![a][r][]\n\n[r]: pixel.png\n", "![a][r]"),
            ("![a]\\[\\]\n\n[a]: pixel.png\n", "![a]"),
        ] {
            let result = events(source, &Cancellation::default()).unwrap();
            let (_, range, _) = result
                .iter()
                .find(|(e, _, _)| matches!(e, Event::Start(Tag::Image { .. })))
                .unwrap();
            assert_eq!(&source[range.clone()], expected);
        }
    }
}

#[cfg(test)]
mod opaque_definition_tests {
    use super::*;
    #[test]
    fn definitions_removed_inside_formulas_cannot_restore_external_image_authority() {
        for occurrence in ["![alt $x$]", "![alt $x$][]", "![picture][$id$]"] {
            for eol in ["\n", "\r\n", "\r"] {
                let source =
                    format!("{occurrence}\n\n$$\n[alt $x$]: hidden.png\n[$id$]: hidden.png\n$$\n")
                        .replace('\n', eol);
                let result = events(&source, &Cancellation::default()).unwrap();
                assert!(
                    !result
                        .iter()
                        .any(|(e, _, _)| matches!(e, Event::Start(Tag::Image { .. }))),
                    "{source:?}"
                );
            }
        }
    }
}
