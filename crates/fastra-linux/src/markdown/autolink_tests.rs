use super::syntax::{self, Parsed};
use fastra_core::Cancellation;
use pulldown_cmark::{Event, Tag, TagEnd};
pub(super) fn links(source: &str, mark: bool) -> Vec<(String, String, std::ops::Range<usize>)> {
    let parsed = Parsed::new(source, mark, &Cancellation::default()).unwrap();
    let events = parsed.events(false, &Cancellation::default()).unwrap();
    let mut active = None;
    let mut result = Vec::new();
    for (event, range, _) in events {
        assert!(source.is_char_boundary(range.start) && source.is_char_boundary(range.end));
        match event {
            Event::Start(Tag::Link { dest_url, .. }) => {
                assert!(active.is_none(), "nested link in {source:?}");
                active = Some((dest_url.to_string(), String::new(), range));
            }
            Event::Text(text) => {
                if let Some((_, value, _)) = &mut active {
                    value.push_str(&text);
                }
            }
            Event::End(TagEnd::Link) => result.push(active.take().expect("balanced link")),
            _ => {}
        }
    }
    assert!(active.is_none());
    result
}
#[test]
fn genuine_math_and_literal_uri_atoms_keep_safe_precedence() {
    let cancel = Cancellation::default();
    let source = "$http://a/$";
    let events = syntax::events(source, &cancel).unwrap();
    assert!(events.iter().any(
        |(event, range, _)| matches!(event,Event::InlineMath(text) if text.as_ref()=="http://a/")
            && range == &(0..source.len())
    ));
    assert!(links(source, true).is_empty());
    for (source, url, text, original) in [
        (
            "http://a/$x$",
            "http://a/$x$",
            "http://a/$x$",
            "http://a/$x$",
        ),
        (
            "<http://a/$x$>",
            "http://a/$x$",
            "http://a/$x$",
            "<http://a/$x$>",
        ),
        (
            "[label](http://a/$x$)",
            "http://a/$x$",
            "label",
            "[label](http://a/$x$)",
        ),
        (
            "http://a/==x==",
            "http://a/==x==",
            "http://a/==x==",
            "http://a/==x==",
        ),
    ] {
        for mark in [false, true] {
            let actual = links(source, mark);
            assert_eq!(actual.len(), 1);
            assert_eq!(actual[0].0, url);
            assert_eq!(actual[0].1, text);
            assert_eq!(&source[actual[0].2.clone()], original);
            assert!(!actual[0].0.contains("<span"));
            assert!(!actual[0].0.contains("FASTRA"));
        }
    }
    let source = "$x$ http://a/";
    let events = Parsed::new(source, true, &cancel)
        .unwrap()
        .events(false, &cancel)
        .unwrap();
    assert_eq!(
        events
            .iter()
            .filter(|(event, _, _)| matches!(event, Event::InlineMath(_)))
            .count(),
        1
    );
    assert_eq!(links(source, true).len(), 1);
}
#[test]
fn delimiters_consumed_by_earlier_urls_change_later_literal_contexts() {
    for (source, expected) in [
        (
            "http://a/`foo www.b.com`",
            vec!["http://a/`foo", "www.b.com`"],
        ),
        (
            "http://a/`foo bar` www.c.com ` www.d.com",
            vec!["http://a/`foo", "www.d.com"],
        ),
        (
            "http://a/[foo www.b.com](x)",
            vec!["http://a/[foo", "www.b.com](x)"],
        ),
        ("[http://a/]", vec![]),
        ("[x http://a/", vec![]),
    ] {
        let actual = links(source, true);
        assert_eq!(
            actual.iter().map(|x| x.1.as_str()).collect::<Vec<_>>(),
            expected,
            "{source}"
        );
        for item in actual {
            assert_eq!(&source[item.2], item.1);
        }
    }
}
#[test]
fn decoded_mail_and_repeated_identity_survive_unicode_and_all_eols() {
    for eol in ["\n", "\r\n", "\r"] {
        let source = format!("雪🙂{eol}{eol}> a@example.com a&#64;example.com a\\@example.com");
        let actual = links(&source, true);
        assert_eq!(actual.len(), 3);
        assert_eq!(
            actual
                .iter()
                .map(|x| &source[x.2.clone()])
                .collect::<Vec<_>>(),
            vec!["a@example.com", "a&#64;example.com", "a\\@example.com"]
        );
        for item in actual {
            assert_eq!(item.0, "mailto:a@example.com");
            assert_eq!(item.1, "a@example.com");
        }
    }
}
#[test]
fn restored_references_images_code_html_and_user_token_names_stay_protected() {
    let name = "FASTRAAUTOLINK00000000000000000000000000000000TOKEN";
    let source=format!("{name} http://a/\n\n`http://code/`\n\n![a@example.com](img.png)\n\n[a@example.com $x$]\n\n[a@example.com $x$]: https://existing.invalid/\n\n<span title=\"http://attribute/\">text</span>");
    let actual = links(&source, true);
    assert_eq!(actual.len(), 2);
    assert_eq!(actual[0].0, "http://a/");
    assert_eq!(actual[1].0, "https://existing.invalid/");
    let events = Parsed::new(&source, true, &Cancellation::default())
        .unwrap()
        .events(false, &Cancellation::default())
        .unwrap();
    assert!(events
        .iter()
        .any(|(event, _, _)| matches!(event,Event::Text(text) if text.contains(name))));
}
#[test]
fn registered_math_in_email_is_restored_as_uri_text_without_html() {
    let source = "$a$@example.com";
    let actual = links(source, true);
    assert_eq!(actual.len(), 1);
    assert_eq!(actual[0].0, "mailto:$a$@example.com");
    assert_eq!(actual[0].1, source);
    assert_eq!(actual[0].2, 0..source.len());
}
#[test]
fn table_pipe_mapping_and_mark_protection_share_original_bytes() {
    for eol in ["\n", "\r\n", "\r"] {
        let source = format!("| http://a/$x$\\|tail |{eol}| --- |{eol}| www.b.com/==x== |{eol}");
        let actual = links(&source, true);
        assert_eq!(actual.len(), 2);
        assert_eq!(&source[actual[0].2.clone()], "http://a/$x$\\|tail");
        assert_eq!(actual[0].1, "http://a/$x$|tail");
        assert_eq!(actual[0].0, "http://a/$x$|tail");
        assert_eq!(actual[1].1, "www.b.com/==x==");
    }
}
#[test]
fn source_limit_and_cancellation_propagate_without_partial_events() {
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(matches!(
        syntax::events("http://a/", &cancel),
        Err(super::math::Error::Core(
            fastra_core::Error::Cancelled
        ))
    ));
    assert!(matches!(
        syntax::events(&"x".repeat(4 * 1024 * 1024 + 1), &Cancellation::default()),
        Err(super::math::Error::Limit)
    ));
}
