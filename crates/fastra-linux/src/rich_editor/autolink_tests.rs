use super::*;
fn original(page: &Page) -> String {
    page.configuration["blocks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|block| block["source"].as_str().unwrap())
        .collect()
}
#[test]
fn auto_urls_mail_and_math_preserve_rich_source_blocks_clipboard_and_safe_attributes() {
    for eol in ["\n", "\r\n", "\r"] {
        let source=format!("雪🙂{eol}{eol}$http://a/${eol}{eol}http://a/$x${eol}{eol}<http://a/$x$>{eol}{eol}[label](http://a/$x$){eol}{eol}$x$ http://a/{eol}{eol}==text== http://a/==x=={eol}{eol}a&#64;example.com a\\@example.com{eol}");
        let page = math_page::page(&source, "autolinks", false, false, None).unwrap();
        assert_eq!(original(&page), source);
        assert_eq!(page.configuration["markdown"], source);
        assert_eq!(page.fragment.matches("data-tex=").count(), 2);
        assert_eq!(page.fragment.matches("<a href=").count(), 7);
        assert!(page.fragment.contains("href=\"http://a/$x$\""));
        assert!(page.fragment.contains("href=\"mailto:a@example.com\""));
        assert!(page.fragment.contains("<mark>text</mark>"));
        assert!(!page.fragment.contains("FASTRAAUTOLINK"));
        assert!(!page.fragment.contains("FASTRAMATH"));
        assert!(!page.fragment.contains("href=\"http://a/<"));
        for value in page
            .fragment
            .split("href=\"")
            .skip(1)
            .map(|value| value.split('"').next().unwrap())
        {
            assert!(!value.contains('<') && !value.contains('>'));
        }
    }
}
#[test]
fn image_labels_restored_references_and_unsafe_schemes_keep_rich_protection() {
    for source in [
        "a@example.com [bad](javascript:bad)",
        "a@example.com <script>bad()</script>",
        "a@example.com ![missing](missing.png)",
    ] {
        let page = math_page::page(source, "protected", false, false, None).unwrap();
        assert_eq!(original(&page), source);
        assert!(page.fragment.contains("data-md-opaque="));
        assert!(!page.fragment.contains("<script>"));
        assert!(!page.fragment.contains("href=\"javascript:"));
    }
    let source = "[a@example.com $x$]\n\n[a@example.com $x$]: https://existing.invalid/\n";
    let page = math_page::page(source, "reference", false, false, None).unwrap();
    assert_eq!(original(&page), source);
    assert_eq!(page.fragment.matches("<a href=").count(), 1);
    assert!(page.fragment.contains("href=\"https://existing.invalid/\""));
}
#[test]
fn original_visible_url_bytes_survive_consumed_code_context_and_table_pipes() {
    let source="http://a/`foo bar` www.c.com ` www.d.com\n\n| http://a/$x$\\|tail |\n| --- |\n| www.b.com/==x== |\n";
    let page = math_page::page(source, "contexts", false, false, None).unwrap();
    assert_eq!(original(&page), source);
    assert_eq!(page.fragment.matches("<a href=").count(), 4);
    assert!(page.fragment.contains("<code>www.c.com</code>"));
    assert!(page.fragment.contains("href=\"http://a/$x$|tail\""));
    assert!(!page.fragment.contains("data-tex="));
}
#[test]
fn footnote_definitions_and_references_keep_exact_rich_sources_and_protection() {
    for eol in ["\n", "\r\n", "\r"] {
        for lf in ["雪🙂 ref[^n] again[^n]\n\n[^n]: a&#64;example.com http://a/$x$\n    - child www.b.com\n\n[^unused]: a\\@example.com\n","- outer[^n]\n  - inner[^n]\n\n[^n]: - child http://a/\n      - second a&#64;example.com\n","[^a&#64;example.com]\n\n[^other]: www.b.com\n"]{let source=lf.replace('\n',eol);let page=math_page::page(&source,"footnotes",false,false,None).unwrap();assert_eq!(original(&page),source);assert_eq!(page.configuration["markdown"],source);assert!(!page.fragment.contains("FASTRAMATH"));assert!(!page.fragment.contains("FASTRAAUTOLINK"));assert!(!page.fragment.contains("href=\"http://a/<"));assert!(page.configuration["opaqueSources"].as_object().unwrap().values().any(|value|value.as_str().unwrap().contains("[^")));}
    }
}

#[test]
fn rich_mailto_is_explicit_and_control_bytes_are_rejected() {
    assert!(safe_link("mailto:a@example.com"));
    for value in ["mailto:a@example.com\r\nBcc:b@example.com", "https://example.com/\t", "#fragment\u{7f}", "javascript:bad"] {
        assert!(!safe_link(value));
    }
}
