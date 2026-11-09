use super::*;
fn body(source: &str) -> String {
    let rendered = render(source, None, false, false, &Cancellation::default()).unwrap();
    rendered
        .html
        .split_once("<body>")
        .unwrap()
        .1
        .split_once("<script nonce=")
        .unwrap()
        .0
        .to_string()
}
#[test]
fn mac_allowed_elements_and_attributes_are_canonical() {
    for tag in [
        "p",
        "div",
        "span",
        "center",
        "blockquote",
        "pre",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "b",
        "strong",
        "i",
        "em",
        "u",
        "s",
        "strike",
        "del",
        "ins",
        "mark",
        "small",
        "sub",
        "sup",
        "code",
        "kbd",
        "samp",
        "var",
        "q",
        "cite",
        "abbr",
        "dfn",
        "ul",
        "ol",
        "li",
        "dl",
        "dt",
        "dd",
        "table",
        "thead",
        "tbody",
        "tfoot",
        "tr",
        "th",
        "td",
        "caption",
        "colgroup",
        "a",
        "details",
        "summary",
    ] {
        let source = format!("<{tag} title=\"café &amp; 🙂\">Text</{tag}>");
        assert!(body(&source).contains(&source), "allowed {tag}");
    }
    for (source,expected) in [
        ("<P ALIGN='CENTER'>Text</P>","<p align=\"CENTER\">Text</p>"),
        ("<img src='https://example.invalid/x.png' alt='Safe' width='100%' height='64'/>","<img src=\"\" alt=\"Safe\" width=\"100%\" height=\"64\">"),
        ("<table width='99999%'><colgroup span='2'><col span='3' width='5'></colgroup><tr><th scope='col' colspan='2' rowspan='1' valign='middle' width='40'>X</th></tr></table>","<table width=\"99999%\">"),
        ("<ol start='0012' type='A' reversed><li>X</li></ol>","<ol start=\"0012\" type=\"A\" reversed>"),
        ("<details open><summary title='a &quot; b'>More</summary></details>","<details open><summary title=\"a &quot; b\">More</summary></details>"),
        ("<blockquote cite='https://example.invalid'>X</blockquote>","cite=\"https://example.invalid\""),
        ("<q cite='path?q=http:x'>X</q>","cite=\"path?q=http:x\""),
        ("<br/><hr>","<br><hr>"),
    ] {assert!(body(source).contains(expected),"{source}");}
}
#[test]
fn unsafe_malformed_and_duplicate_attributes_fail_closed() {
    for source in [
        "<div><p>SAFE</p><script>alert(1)</script></div>",
        "<p onclick='x'>BAD</p>",
        "<img src='a.png' ONERROR='x'>",
        "<p style='color:red'>BAD</p>",
        "<p class='fastra-visible-blank-line'>BAD</p>",
        "<p id='x'>BAD</p>",
        "<a name='x'>BAD</a>",
        "<svg><foreignObject><p>BAD</p></foreignObject></svg>",
        "<math><annotation-xml><p>BAD</p></annotation-xml></math>",
        "<iframe src='https://example.invalid'></iframe>",
        "<object>BAD</object>",
        "<style>BAD</style>",
        "<template>BAD</template>",
        "<noscript>BAD</noscript>",
        "<form>BAD</form>",
        "<input value='BAD'>",
        "<p align=center>BAD</p>",
        "<p title='one' TITLE='two'>BAD</p>",
        "<div/>BAD",
        "<p align='invalid'>BAD</p>",
        "<img src='a.png' width='999999'>",
        "<td colspan='x'>BAD</td>",
        "<details open='open'>BAD</details>",
        "<wbr>",
        "<p title='a< b'>BAD</p>",
        "<p title='unterminated>BAD</p>",
        "<div><p>BAD</div></p>",
        "<!DOCTYPE html><p>BAD</p>",
        "<?xml?><p>BAD</p>",
        "<!--bad -- inner--><p>BAD</p>",
    ] {
        let mut sanitizer = html_whitelist::Sanitizer::default();
        let output = sanitizer
            .sanitize(source, &Cancellation::default(), |_| {
                panic!("invalid fragment must not load images")
            })
            .unwrap();
        assert!(
            output.is_none(),
            "unsafe fragment accepted: {source}: {output:?}"
        );
    }
    let result = body("<div><p>SAFE</p><script>alert(1)</script></div>");
    assert!(!result.contains("SAFE") && !result.contains("alert(1)"));
    assert_eq!(
        body("Text <script>alert('x')</script> End"),
        "<p data-srcline=\"1\">Text alert('x') End</p>\n"
    );
}
#[test]
fn entities_are_decoded_once_before_url_and_control_validation() {
    for url in [
        "javascript:alert(1)",
        "jav&#x61;script:alert(1)",
        "java&Tab;script:alert(1)",
        "java&NewLine;script:alert(1)",
        "vbscript:x",
        "file:///etc/passwd",
        "data:text/plain,x",
        "//example.invalid/x",
        "&sol;&sol;example.invalid/x",
    ] {
        let source = format!("<a href=\"{url}\">BAD</a>");
        let output = body(&source);
        assert!(!output.contains("href="), "unsafe {url}: {output}");
    }
    for (url, expected) in [
        ("#heading", "#heading"),
        ("relative?a=1&amp;b=2", "relative?a=1&amp;b=2"),
        ("https&colon;//example.invalid", "https://example.invalid"),
        ("mailto:a@example.invalid", "mailto:a@example.invalid"),
        ("&amp;sol;&amp;sol;literal", "&amp;sol;&amp;sol;literal"),
    ] {
        assert!(
            body(&format!("<a href=\"{url}\">OK</a>")).contains(&format!("href=\"{expected}\"")),
            "safe URL {url}"
        );
    }
    let mut sanitizer = html_whitelist::Sanitizer::default();
    assert_eq!(
        sanitizer
            .sanitize(
                "<KBD>key</KBD>",
                &Cancellation::default(),
                |_| unreachable!()
            )
            .unwrap()
            .as_deref(),
        Some("<kbd>key</kbd>")
    );
    assert!(body(
        "<p title='&quot; &apos; &#128578; &amp;lt;'>A &amp; B &copy; &unknown; & bad</p>"
    )
    .contains("title=\"&quot; &#39; 🙂 &amp;lt;\""));
    assert!(body("<p>&lt;script&gt;not code&lt;/script&gt;</p>")
        .contains("&lt;script&gt;not code&lt;/script&gt;"));
    for control in ["&#9;", "&#10;", "&#13;", "&#127;"] {
        assert!(!body(&format!("<p title='{control}'>BAD</p>")).contains("BAD"));
    }
}
#[test]
fn stack_is_transactional_and_closes_at_document_end() {
    let mut sanitizer = html_whitelist::Sanitizer::default();
    let cancel = Cancellation::default();
    assert_eq!(
        sanitizer
            .sanitize("<div>", &cancel, |_| unreachable!())
            .unwrap()
            .as_deref(),
        Some("<div>")
    );
    assert!(sanitizer
        .sanitize("<p><script>x</script>", &cancel, |_| unreachable!())
        .unwrap()
        .is_none());
    assert_eq!(
        sanitizer
            .sanitize("</div>", &cancel, |_| unreachable!())
            .unwrap()
            .as_deref(),
        Some("</div>")
    );
    assert!(sanitizer
        .sanitize("</div>", &cancel, |_| unreachable!())
        .unwrap()
        .is_none());
    let html = body("<details>\n<summary>More</summary>\n\nNormal **Markdown**.");
    assert!(html.contains("<strong>Markdown</strong>"));
    assert!(html.ends_with("</details>"));
    assert!(
        body(&format!("{}X{}", "<div>".repeat(65), "</div>".repeat(65)))
            .trim()
            .is_empty()
    );
}
#[test]
fn local_images_reuse_raster_registry_and_forgeries_cannot_steal_annotations() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("document.md");
    std::fs::write(
        dir.path().join("a&b.png"),
        include_bytes!("../../tests/fixtures/pixel-1.png"),
    )
    .unwrap();
    let source="<p align=\"center\"><img src=\"a&amp;b.png\" width=\"64\" alt=\"local\"></p>\r\n\r\n<pre><code>raw code</code></pre>\r\n\r\nParagraph\r\n\r\n```text\r\nfenced\r\n```\r\n\r\n# Heading\r\n\r\n<p data-srcline=\"999\">BAD</p>\r\n\r\n<!--fastra-sanitized-html-0-->\r\n";
    let result = render(source, Some(&path), false, false, &Cancellation::default()).unwrap();
    assert_eq!(result.images.len(), 1);
    assert_eq!(result.html.matches("data-fastra-code=\"").count(), 1);
    assert!(result.html.contains("<pre><code>raw code</code></pre>"));
    assert!(result.html.contains("<p data-srcline=\"5\">Paragraph</p>"));
    assert!(result
        .html
        .contains("<pre data-srcline=\"8\" data-fastra-code=\"0\">"));
    assert!(!result.html.contains("BAD") && !result.html.contains("data-srcline=\"999\""));
    assert!(!result.html.contains("<!--fastra-sanitized-html-"));
    assert!(!result
        .html
        .contains(&dir.path().to_string_lossy().to_string()));
    assert!(
        result.html.contains("connect-src 'none'")
            && result.html.contains("img-src fastra-preview:")
    );
    let headings =
        super::super::markdown_navigation::headings(source, &Cancellation::default()).unwrap();
    assert_eq!(headings.len(), 1);
    assert!(result
        .html
        .contains(&format!("data-fastra-offset=\"{}\"", headings[0].offset)));
    let blocked=render("<img src=\"https://example.invalid/beacon.png\"><img src=\"fastra-preview://image/forged\">",Some(&path),false,false,&Cancellation::default()).unwrap();
    assert!(blocked.images.is_empty());
    assert!(
        !blocked.html.contains("example.invalid")
            && !blocked
                .html
                .contains("src=\"fastra-preview://image/forged\"")
    );
}
#[test]
fn attribute_limit_counts_extended_graphemes_and_cancellation_fails_closed() {
    let family = "👩‍💻e\u{301}";
    let title = family.repeat(256);
    assert!(body(&format!("<p title=\"{title}\">OK</p>")).contains("OK"));
    assert!(!body(&format!("<p title=\"{title}x\">BAD</p>")).contains("BAD"));
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(matches!(
        render("<p>OK</p>", None, false, false, &cancel),
        Err(RenderError::Cancelled)
    ));
}

#[test]
fn many_inline_fragments_expand_once_without_forging_annotation_tokens() {
    let source = format!("Start {} End", "<b>x</b>".repeat(10_000));
    let output = body(&source);
    assert_eq!(output.matches("<b>x</b>").count(), 10_000);
    assert!(!output.contains("<!--fastra-sanitized-html-"));
}

#[test]
fn forbidden_inline_foreign_tags_leave_only_normal_text() {
    let output = body("<svg><foreignObject><p>Visible</p></foreignObject></svg>");
    assert!(output.contains("Visible"));
    assert!(!output.contains("<svg") && !output.contains("<foreignObject"));
}

#[test]
fn mac_houdini_attribute_numeric_references_accept_one_to_eight_digits() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("document.md");
    std::fs::write(
        dir.path().join("pixel.png"),
        include_bytes!("../../tests/fixtures/pixel-1.png"),
    )
    .unwrap();
    for reference in [
        "&#120;",
        "&#00000120;",
        "&#x78;",
        "&#x00000078;",
        "&#X00000078;",
    ] {
        let source = format!("<img src=\"pi{reference}el.png\" alt=\"local\">");
        let rendered =
            render(&source, Some(&path), false, false, &Cancellation::default()).unwrap();
        assert_eq!(rendered.images.len(), 1, "Mac attribute entity {reference}");
    }
    for reference in ["&#00000000;", "&#x0000D800;", "&#x00110000;", "&#99999999;"] {
        assert!(body(&format!("<p title=\"{reference}\">X</p>")).contains("title=\"�\""));
    }
    assert!(body("<p title=\"&#x00000080;\">X</p>").contains("title=\"\u{80}\""));
    assert!(!body("<a href=\"jav&#x00000061;script:alert(1)\">X</a>").contains("href="));
    for reference in ["&#00000009;", "&#x0000000a;", "&#x0000007f;"] {
        assert!(!body(&format!("<p title=\"{reference}\">BAD</p>")).contains("BAD"));
    }
    // Mac escapedText ist enger als sein Attributdecoder: keine neue Textauflösung.
    assert!(body("<p>&#x00000078; &#00000120;</p>").contains("&amp;#x00000078; &amp;#00000120;"));
    assert!(body("<p title=\"&#x000000078;\">X</p>").contains("title=\"&amp;#x000000078;\""));
}
