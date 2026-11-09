//! Normale Codeblöcke bleiben bearbeitbar; Diagramme behalten ihre Quellidentität.
use super::*;

pub(super) fn enhance<'a>(
    events: impl Iterator<Item = Event<'a>>,
    original: &str,
    opaque: &mut serde_json::Map<String, Value>,
    session: &str,
    block: usize,
) -> std::vec::IntoIter<Event<'a>> {
    let mut result = Vec::new();
    let mut events = events.peekable();
    let mut serial = 0;
    while let Some(event) = events.next() {
        let diagram = matches!(&event, Event::Start(Tag::CodeBlock(pulldown_cmark::CodeBlockKind::Fenced(info)))
            if info.split_whitespace().next() == Some("mermaid"));
        if !diagram {
            result.push(event);
            continue;
        }
        let top_level = result.is_empty();
        let mut code = vec![event];
        let mut text = String::new();
        for event in events.by_ref() {
            if let Event::Text(value) = &event {
                text.push_str(value);
            }
            let end = matches!(event, Event::End(TagEnd::CodeBlock));
            code.push(event);
            if end {
                break;
            }
        }
        let key = format!("diagram-{session}-{block}-{serial}");
        serial += 1;
        // Wie auf dem Mac behält der ganze Block seine Originalbytes. Innerhalb
        // einer Liste schreibt der gemeinsame Serializer deren Einrückung selbst.
        let source = if top_level && events.peek().is_none() {
            original.to_owned()
        } else {
            format!("\n\n```mermaid\n{text}```\n\n")
        };
        opaque.insert(key.clone(), json!(source));
        result.push(Event::Html(
            format!("<section data-md-opaque=\"{key}\" contenteditable=\"false\">").into(),
        ));
        result.extend(code);
        result.push(Event::Html("</section>".into()));
    }
    result.into_iter()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn code_remains_editable_and_diagram_sources_survive_both_parser_paths() {
        for prefix in ["", "$x$\n\n"] {
            let original = format!("{prefix}~~~rust\r\nlet café = \"<script>\";\r\n~~~\r\n\r\n````mermaid\r\ngraph LR; 雪-->B\r\n````\r\n\r\n- item\n\n  ```mermaid\n  graph LR; C-->D\n  ```\n\n<script>bad()</script>\n");
            let rendered = page(&original, "code-test", false, false).unwrap();
            let restored = rendered.configuration["blocks"]
                .as_array()
                .unwrap()
                .iter()
                .map(|block| block["source"].as_str().unwrap())
                .collect::<String>();
            assert_eq!(restored, original);
            assert!(rendered
                .body
                .contains("<pre><code class=\"language-rust\">let café = \"&lt;script&gt;\";"));
            assert_eq!(rendered.body.matches("<section data-md-opaque=").count(), 2);
            assert!(!rendered.body.contains("<script>bad()"));
            let sources = rendered.configuration["opaqueSources"].as_object().unwrap();
            assert!(
                sources
                    .values()
                    .any(|source| source.as_str().unwrap()
                        == "````mermaid\r\ngraph LR; 雪-->B\r\n````"),
                "{sources:?}"
            );
            assert!(sources
                .values()
                .any(|source| source.as_str().unwrap().contains("graph LR; C-->D")));
            assert!(!sources
                .values()
                .any(|source| source.as_str().unwrap().contains("let café")));
        }
    }
}
