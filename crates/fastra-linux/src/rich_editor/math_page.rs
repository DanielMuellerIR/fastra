//! Formeln als geschützte Inlineatome; Blockquellen bleiben Originalbytes.
use super::*;
use crate::markdown::syntax::{self, Generated, MappedEvent};
use std::{collections::HashSet, ops::Range};
struct Block {
    range: Range<usize>,
    events: Vec<MappedEvent>,
}
pub(super) fn page(
    source: &str,
    session: &str,
    dark: bool,
    de: bool,
    images: Option<&images::Sources>,
) -> Result<Page, &'static str> {
    let cancel = Cancellation::default();
    let parsed = syntax::Parsed::new(source, true, &cancel).map_err(|_| "size")?;
    let block_sources = parsed
        .block_math_sources()
        .map(|range| (range.start, range.end))
        .collect::<HashSet<_>>();
    let events = parsed.events(true, &cancel).map_err(|_| "size")?;
    if events.len() > 50_000 {
        return Err("size");
    }
    let formulas = events
        .iter()
        .filter(|(event, _, g)| {
            matches!(event, Event::InlineMath(_) | Event::DisplayMath(_))
                || *g == Generated::MathSource
        })
        .map(|(_, r, _)| r.clone())
        .collect::<Vec<_>>();
    let mut groups: Vec<Block> = Vec::new();
    let mut current = Vec::new();
    let mut depth = 0usize;
    let mut range = 0..0;
    for entry in events {
        if depth == 0 {
            // Einige Blank-Atome stehen nach der kompakten Displayformel im
            // Eventstrom, gehören aber zur bereits separat erhaltenen Quelllücke.
            if entry.2 == Generated::Blank
                && groups.last().is_some_and(|b| entry.1.end <= b.range.start)
            {
                continue;
            }
            if entry.2 == Generated::Blank
                && groups
                    .last()
                    .is_some_and(|b| entry.1.start < b.range.end && entry.1.end <= b.range.end)
            {
                groups.last_mut().unwrap().events.push(entry);
                continue;
            }
            range = entry.1.clone();
        }
        match &entry.0 {
            Event::Start(_) => {
                depth += 1;
                if depth > 128 {
                    return Err("size");
                }
            }
            Event::End(_) => depth = depth.checked_sub(1).ok_or("parse")?,
            _ => {}
        }
        range.end = range.end.max(entry.1.end);
        current.push(entry);
        if depth == 0 {
            groups.push(Block {
                range: range.clone(),
                events: std::mem::take(&mut current),
            });
        }
    }
    if depth != 0 {
        return Err("parse");
    }
    let mut blocks = Vec::new();
    let mut opaque = serde_json::Map::new();
    let mut body = String::new();
    let mut clipboard = String::new();
    let mut cursor = 0usize;
    for group in groups {
        if group.range.start < cursor {
            return Err("parse");
        }
        if cursor < group.range.start {
            append_blank_gap(
                &source[cursor..group.range.start],
                cursor,
                &formulas,
                &mut blocks,
                &mut body,
                &mut clipboard,
            )?;
        }
        let original = &source[group.range.clone()];
        let id = blocks.len();
        let protected = group
            .events
            .iter()
            .any(|(event, _, generated)| match event {
                Event::Html(_) | Event::InlineHtml(_)
                    if matches!(generated, Generated::Mark | Generated::Blank) =>
                {
                    false
                }
                Event::Html(_) => true,
                Event::InlineHtml(raw) => !safe_inline(raw),
                Event::Start(Tag::Link { dest_url, .. }) => !safe_link(dest_url),
                Event::Start(Tag::Image { dest_url, .. }) => {
                    images.is_none_or(|s| !s.0.contains_key(dest_url.as_ref()))
                }
                Event::Start(Tag::FootnoteDefinition(_))
                | Event::FootnoteReference(_) => true,
                _ => false,
            });
        let fragment = if protected {
            let key = format!("atom-{session}-{id}");
            opaque.insert(key.clone(), json!(original));
            format!("<div data-md-opaque=\"{key}\" contenteditable=\"false\" class=\"protected\"><pre>{}</pre></div>",escape(original))
        } else {
            fragment(
                source,
                (session, id, original),
                group.events,
                images,
                &mut opaque,
                de,
                &block_sources,
            )?
        };
        body.push_str(&format!("<div data-md-block=\"{id}\">{fragment}</div>"));
        clipboard.push_str(&fragment);
        blocks.push(json!({"id":id,"source":original,"hidden":false}));
        cursor = group.range.end;
        if blocks.len() > MAX_BLOCKS || body.len() > 8 * MAX_BYTES {
            return Err("size");
        }
    }
    if cursor < source.len() {
        append_blank_gap(
            &source[cursor..],
            cursor,
            &formulas,
            &mut blocks,
            &mut body,
            &mut clipboard,
        )?;
    }
    let configuration =
        json!({"blocks":blocks,"opaqueSources":opaque,"markdown":source,"session":session});
    Ok(Page {
        html: super::page_html(&body, dark, de),
        body,
        configuration,
        fragment: clipboard,
    })
}
fn display_source(
    event: &Event<'_>,
    range: &Range<usize>,
    generated: Generated,
    blocks: &HashSet<(usize, usize)>,
) -> bool {
    matches!(event, Event::DisplayMath(_))
        || (generated == Generated::MathSource && blocks.contains(&(range.start, range.end)))
}
fn fragment(
    source: &str,
    scope: (&str, usize, &str),
    events: Vec<MappedEvent>,
    images: Option<&images::Sources>,
    opaque: &mut serde_json::Map<String, Value>,
    de: bool,
    block_sources: &HashSet<(usize, usize)>,
) -> Result<String, &'static str> {
    let (session, id, original) = scope;
    let mut rendered = Vec::new();
    let mut events = events.into_iter().peekable();
    let mut leading_break = None;
    let mut atom = 0usize;
    while let Some((event, mut range, generated)) = events.next() {
        // Der vorhandene Blocktyp gilt auch für MathSource. Newlines in
        // eingebettetem Inlinecode allein machen noch keine Displayformel.
        let display = display_source(&event, &range, generated, block_sources);
        if matches!(event, Event::SoftBreak)
            && events
                .peek()
                .is_some_and(|(e, r, g)| display_source(e, r, *g, block_sources))
        {
            leading_break = Some(range.start);
            continue;
        }
        if display {
            if let Some(start) = leading_break.take() {
                range.start = start;
            }
            if events
                .peek()
                .is_some_and(|(e, _, _)| matches!(e, Event::SoftBreak))
            {
                range.end = events.next().unwrap().1.end;
            }
        }
        if matches!(event, Event::InlineMath(_) | Event::DisplayMath(_))
            || generated == Generated::MathSource
        {
            let key = format!("math-{session}-{id}-{atom}");
            atom += 1;
            opaque.insert(key.clone(), json!(&source[range]));
            let html=match event {
                Event::InlineMath(tex)|Event::DisplayMath(tex)=>{
                    let block=generated==Generated::MathBlock;let tag=if block{"div"}else{"span"};
                    format!("<{tag} class=\"{}\" data-tex=\"{}\" data-md-math-source=\"{key}\" contenteditable=\"false\">{}</{tag}>",if display{"math-block"}else{"math-inline"},escape(&tex),escape(&tex))
                }
                _=>format!("<span class=\"math-source\" data-md-opaque=\"{key}\" data-md-math-source=\"{key}\" contenteditable=\"false\">{}<small class=\"math-source-notice\">{}</small></span>",escape(opaque[&key].as_str().unwrap()),if de{"Formel mit eingebettetem Code bleibt als Quelltext erhalten"}else{"Formula with embedded code is preserved as source text"}),
            };
            rendered.push(Event::Html(html.into()));
            continue;
        }
        match event {
            Event::Start(Tag::Image {
                dest_url, title, ..
            }) => {
                let source = images
                    .and_then(|s| s.0.get(dest_url.as_ref()))
                    .ok_or("image")?;
                let mut alt = String::new();
                for (event, _, _) in events.by_ref() {
                    match event {
                        Event::End(TagEnd::Image) => break,
                        Event::Text(t) | Event::Code(t) => alt.push_str(&t),
                        Event::SoftBreak | Event::HardBreak => alt.push(' '),
                        _ => {}
                    }
                }
                rendered.push(Event::Html(
                    format!(
                        "<img src=\"{}{}\" data-md-src=\"{}\" alt=\"{}\" title=\"{}\">",
                        images::PREFIX,
                        source.token,
                        escape(&dest_url),
                        escape(&alt),
                        escape(&title)
                    )
                    .into(),
                ));
            }
            Event::Start(Tag::Link { dest_url, .. }) => rendered.push(Event::Html(
                format!("<a href=\"{}\">", escape(&dest_url)).into(),
            )),
            Event::End(TagEnd::Link) => rendered.push(Event::Html("</a>".into())),
            Event::Html(raw) | Event::InlineHtml(raw) => rendered.push(Event::Html(raw)),
            event => rendered.push(event),
        }
    }
    let mut html = String::new();
    html::push_html(&mut html, code_blocks::enhance(rendered.into_iter(), original, opaque, session, id));
    Ok(html.replace("<table>", "<table data-md-table=\"gfm\">"))
}
#[cfg(test)]
mod tests {
    use super::*;
    fn reconstructed(page: &Page) -> String {
        page.configuration["blocks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b["source"].as_str().unwrap())
            .collect()
    }
    #[test]
    fn math_atoms_keep_original_syntax_and_full_mixed_eol_blocks() {
        let lf="# Heading\n\nBefore ä🙂 $$x^2$$ after\n\nMixed before\n$$\na + b\n  \nc + d\n$$\nMixed after\n\n$$\nx + y\n\nz\n$$\n\n  \nTail\n";
        for eol in ["\n", "\r\n", "\r"] {
            let source = lf.replace('\n', eol);
            let page = super::page(&source, "tests", false, false, None).unwrap();
            assert_eq!(reconstructed(&page), source);
            assert_eq!(page.fragment.matches("data-tex=\"").count(), 3);
            assert_eq!(page.fragment.matches("class=\"math-block\"").count(), 2);
            assert!(page.fragment.contains("<div class=\"math-block\""));
            assert!(!page.fragment.contains("<p><div"));
            assert_eq!(
                page.fragment.matches("fastra-visible-blank-line").count(),
                1
            );
            let originals = page.configuration["opaqueSources"]
                .as_object()
                .unwrap()
                .values()
                .map(|s| s.as_str().unwrap())
                .collect::<Vec<_>>();
            assert!(originals.contains(&"$$x^2$$"));
            assert!(originals
                .contains(&format!("{eol}$${eol}a + b{eol}  {eol}c + d{eol}$${eol}").as_str()));
            assert!(originals.contains(&format!("$${eol}x + y{eol}{eol}z{eol}$$").as_str()));
        }
    }
    #[test]
    fn nested_code_keeps_visible_original_and_localized_notice_without_working_markers() {
        for de in [false, true] {
            let source = "$`x`$\r\n\r\n$$\r\n`code`\r\n$$\r\n";
            let page = super::page(source, "nested", true, de, None).unwrap();
            assert_eq!(reconstructed(&page), source);
            assert_eq!(page.fragment.matches("math-source-notice").count(), 2);
            assert!(page.fragment.contains(if de {
                "Formel mit eingebettetem Code bleibt als Quelltext erhalten"
            } else {
                "Formula with embedded code is preserved as source text"
            }));
            assert!(!page.fragment.contains("data-tex"));
            assert!(!page.fragment.contains("FASTRACODE"));
        }
    }
    #[test]
    fn currency_reference_metadata_and_code_dollars_stay_original() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("source.md");
        let literal = "FASTRAMATH00000000000000000000000000000000TOKEN.png";
        std::fs::write(
            dir.path().join(literal),
            include_bytes!("../../tests/fixtures/pixel-1.png"),
        )
        .unwrap();
        for eol in ["\n", "\r\n", "\r"] {
            let source=format!("Das kostet $5 und $10 zusammen. `echo $HOME`\n\n![alt $x$]({literal})\n\n![picture][$id$]\n\n[$id$]: {literal}\n\n~~~text\n$x$\n~~~~\n").replace('\n',eol);
            let sources = images::Sources::collect(&source, Some(&path), "sources").unwrap();
            let page = super::page(&source, "currency", false, false, Some(&sources)).unwrap();
            assert_eq!(reconstructed(&page), source);
            assert!(!page.fragment.contains("data-tex"));
            assert_eq!(page.fragment.matches("<img").count(), 2);
            assert!(page.fragment.contains("alt=\"alt $x$\""));
            assert!(page.fragment.contains("Das kostet $5 und $10 zusammen."));
            assert_eq!(page.fragment.matches("data-md-opaque=").count(), 0);
            assert!(page.fragment.contains("<code class=\"language-text\">$x$"));
        }
    }
    #[test]
    fn global_refs_mark_lists_quotes_tables_and_literal_token_names_share_original_ranges() {
        let lf="# ==Marked== $x$\n\n- Before $y$ after\n- End\n\n> Quote $z$ after\n\n| Name | Formula |\n| --- | --- |\n| keep | $a|b$ |\n\n[link $v$][r]\n\n[r]: https://example.invalid/\n\nFASTRAMATH00000000000000000000000000000000TOKEN\n";
        for eol in ["\n", "\r\n", "\r"] {
            let source = lf.replace('\n', eol);
            let page = super::page(&source, "structure", false, false, None).unwrap();
            assert_eq!(reconstructed(&page), source);
            assert_eq!(page.fragment.matches("data-tex=").count(), 5);
            assert!(page.fragment.contains("<ul>"));
            assert!(page.fragment.contains("<blockquote>"));
            assert!(page.fragment.contains("<table data-md-table=\"gfm\">"));
            assert!(page.fragment.contains("<mark>"));
            assert!(page.fragment.contains("href=\"https://example.invalid/\""));
            assert!(page
                .fragment
                .contains("FASTRAMATH00000000000000000000000000000000TOKEN"));
        }
    }
    #[test]
    fn many_formula_atoms_are_bounded_without_losing_sources() {
        let source = "before $x$ after\n\n".repeat(2000);
        let page = super::page(&source, "many", false, false, None).unwrap();
        assert_eq!(reconstructed(&page), source);
        assert_eq!(page.fragment.matches("data-tex=").count(), 2000);
        let excessive = "x $a$ ".repeat(30_000);
        assert!(super::page(&excessive, "bounded", false, false, None).is_err());
    }

    #[test]
    fn user_html_unsafe_links_and_missing_images_keep_existing_source_protection() {
        for source in [
            "$x$ <script>bad()</script>",
            "$x$ [bad](javascript:bad)",
            "$x$ ![missing](missing.png)",
            "<div>\n$x$\n</div>",
        ] {
            let page = super::page(source, "unsafe", false, false, None).unwrap();
            assert_eq!(reconstructed(&page), source);
            assert!(!page.fragment.contains("<script>"));
            assert!(!page.fragment.contains("href=\"javascript:"));
            assert!(!page.fragment.contains("<img"));
            assert!(page.configuration["opaqueSources"]
                .as_object()
                .unwrap()
                .values()
                .any(|s| s.as_str().unwrap().contains(source.trim())));
        }
    }
}

#[cfg(test)]
mod nested_source_regressions {
    use super::*;
    #[test]
    fn nested_display_owns_original_neighbor_breaks_and_table_pipe_uses_registered_source() {
        for eol in ["\n", "\r\n", "\r"] {
            let source = "Before\n$$\n`code`\n$$\nAfter\n".replace('\n', eol);
            let page = super::page(&source, "nested-display", false, false, None).unwrap();
            let expected = format!("{eol}$${eol}`code`{eol}$${eol}");
            assert!(page.configuration["opaqueSources"]
                .as_object()
                .unwrap()
                .values()
                .any(|value| value.as_str() == Some(&expected)));
            assert_eq!(page.fragment.matches(" data-md-math-source=\"").count(), 1);
            let table =
                "| Name | Value |\n| --- | --- |\n| keep | before $`a|b`$ |\n".replace('\n', eol);
            let page = super::page(&table, "nested-table", false, false, None).unwrap();
            assert_eq!(page.fragment.matches(" data-md-math-source=\"").count(), 1);
            assert!(page.configuration["opaqueSources"]
                .as_object()
                .unwrap()
                .values()
                .any(|value| value.as_str() == Some("$`a|b`$")));
        }
    }
    #[test]
    fn inline_source_with_code_newlines_does_not_gain_display_break_ownership() {
        for eol in ["\n", "\r\n", "\r"] {
            let source = "Before\n$`a\nb`$\nAfter\n".replace('\n', eol);
            let parsed = syntax::Parsed::new(&source, true, &Cancellation::default()).unwrap();
            assert_eq!(parsed.block_math_sources().count(), 0);
            let page = super::page(&source, "inline-multiline", false, false, None).unwrap();
            assert_eq!(
                page.configuration["blocks"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|block| block["source"].as_str().unwrap())
                    .collect::<String>(),
                source
            );
            assert_eq!(page.fragment.matches(" data-md-math-source=\"").count(), 0);
        }
    }
    #[test]
    fn nonmath_opaque_and_untrusted_source_attributes_gain_no_math_registration() {
        for source in [
            "$x$ <script>keep | source</script>",
            "$x$ <span data-md-math-source=\"foreign\">literal</span>",
        ] {
            let page = super::page(source, "opaque-control", false, false, None).unwrap();
            assert_eq!(page.fragment.matches(" data-md-math-source=\"").count(), 0);
            assert!(page.configuration["opaqueSources"]
                .as_object()
                .unwrap()
                .values()
                .any(|value| value.as_str() == Some(source)));
        }
    }
}
