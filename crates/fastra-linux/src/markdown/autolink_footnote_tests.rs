use super::{autolink_tests::links, syntax::Parsed};
use fastra_core::Cancellation;
use pulldown_cmark::{Event, Tag};
#[test]
fn referenced_footnote_links_keep_original_ranges_and_reference_labels() {
    for eol in ["\n", "\r\n", "\r"] {
        let source=format!("雪🙂 [^note] and [^note]{eol}{eol}[^note]: https://example.invalid/a a&#64;example.com{eol}    second www.b.com{eol}");
        let actual = links(&source, true);
        assert_eq!(actual.len(), 3, "{source}");
        assert_eq!(
            actual
                .iter()
                .map(|link| &source[link.2.clone()])
                .collect::<Vec<_>>(),
            vec![
                "https://example.invalid/a",
                "a&#64;example.com",
                "www.b.com"
            ]
        );
        let events = Parsed::new(&source, true, &Cancellation::default())
            .unwrap()
            .events(false, &Cancellation::default())
            .unwrap();
        let refs = events
            .iter()
            .filter_map(|(event, range, _)| {
                if let Event::FootnoteReference(label) = event {
                    Some((label.as_ref(), &source[range.clone()]))
                } else {
                    None
                }
            })
            .collect::<Vec<_>>();
        assert_eq!(refs, vec![("note", "[^note]"), ("note", "[^note]")]);
        assert!(events.iter().any(|(event,_,_)|matches!(event,Event::Start(Tag::FootnoteDefinition(label)) if label.as_ref()=="note")));
    }
}
#[test]
fn footnote_reference_identifiers_are_not_auto_linked_or_renamed() {
    for source in [
        "ref[^a@example.com]\n\n[^a@example.com]: note https://example.invalid/\n",
        "ref[^http://a/]\n\n[^http://a/]: note a@example.com\n",
        "ref[^a&#64;example.com]\n\n[^a&#64;example.com]: note www.b.com\n",
    ] {
        let actual = links(source, true);
        assert_eq!(actual.len(), 1, "{source}");
        let events = Parsed::new(source, true, &Cancellation::default())
            .unwrap()
            .events(false, &Cancellation::default())
            .unwrap();
        assert_eq!(
            events
                .iter()
                .filter(|(event, _, _)| matches!(event, Event::FootnoteReference(_)))
                .count(),
            1
        );
        for (event, _, _) in events {
            if let Event::FootnoteReference(label) = event {
                assert!(!label.contains("FASTRA"));
            }
        }
    }
}
#[test]
fn nested_list_footnotes_keep_links_out_of_code_and_existing_links() {
    for eol in ["\n", "\r\n", "\r"] {
        let source=format!("- outer [^n]{eol}  - inner [^n]{eol}{eol}[^n]: - first http://a/{eol}      - second a\\@example.com{eol}{eol}    `www.code.com` [label](https://explicit.invalid/){eol}");
        let actual = links(&source, true);
        assert_eq!(
            actual
                .iter()
                .map(|link| link.0.as_str())
                .collect::<Vec<_>>(),
            vec![
                "http://a/",
                "mailto:a@example.com",
                "https://explicit.invalid/"
            ],
            "{source}"
        );
        assert_eq!(&source[actual[1].2.clone()], "a\\@example.com");
    }
}
#[test]
fn unreferenced_definitions_remain_available_to_existing_pulldown_pipeline() {
    let source = "[^unused]: a@example.com http://a/\n";
    let actual = links(source, true);
    assert_eq!(actual.len(), 2);
}
#[test]
fn unresolved_reference_labels_keep_regular_decoded_text_autolinks() {
    for (source, expected) in [
        ("[^missing@example.com]", "mailto:missing@example.com"),
        ("[^a&#64;example.com]", "mailto:a@example.com"),
        ("[^a\\@example.com]", "mailto:a@example.com"),
        (
            "[^unknown@example.com]\n\n[^other]: http://a/\n",
            "mailto:unknown@example.com",
        ),
    ] {
        let actual = links(source, true);
        assert!(
            actual.iter().any(|link| link.0 == expected),
            "{source}: {actual:?}"
        );
        let events = Parsed::new(source, true, &Cancellation::default())
            .unwrap()
            .events(false, &Cancellation::default())
            .unwrap();
        assert!(!events
            .iter()
            .any(|(event, _, _)| matches!(event, Event::FootnoteReference(_))));
    }
}
#[test]
fn rendered_footnote_html_retains_ids_and_separate_auto_anchor_targets() {
    for eol in ["\n", "\r\n", "\r"] {
        let source=format!("雪🙂 ref[^n] again[^n]{eol}{eol}[^n]: a&#64;example.com http://a/$x${eol}{eol}[^unused]: www.unused.com{eol}");
        let events = Parsed::new(&source, true, &Cancellation::default())
            .unwrap()
            .events(false, &Cancellation::default())
            .unwrap();
        let mut html = String::new();
        pulldown_cmark::html::push_html(&mut html, events.into_iter().map(|item| item.0));
        assert_eq!(html.matches("href=\"#n\"").count(), 2);
        assert!(html.contains("id=\"n\""));
        assert!(html.contains("href=\"mailto:a@example.com\""));
        assert!(html.contains("href=\"http://a/$x$\""));
        assert!(html.contains("href=\"http://www.unused.com\""));
        assert!(!html.contains("FASTRA"));
        assert!(!html.contains("href=\"http://a/<"));
    }
}
