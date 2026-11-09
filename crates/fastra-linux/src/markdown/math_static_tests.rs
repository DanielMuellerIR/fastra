use super::*;
#[test]
fn static_math_blank_code_mark_headings_and_original_rewrites() {
    let lf="雪🙂\n\n==Before== $x^2$\n\n$$\na + b\n  \n# fake heading\n![fake](missing.png)\n$$\n\n  \n# After ==Mark==\n\n```md\n$x$\n![code](missing.png)\n```\n\n~~~text\nsecond\n~~~\n\n```\nthird\n```\n\n![picture][p]\n\n[p]: pixel.png\n";
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join("pixel.png"),
        include_bytes!("../../tests/fixtures/pixel-1.png"),
    )
    .unwrap();
    let path = dir.path().join("fixture.md");
    for eol in ["\n", "\r\n", "\r"] {
        let source = lf.replace('\n', eol);
        let rendered =
            render(&source, Some(&path), false, false, &Cancellation::default()).unwrap();
        assert_eq!(rendered.warnings, 0);
        assert_eq!(rendered.images.len(), 1);
        assert_eq!(rendered.html.matches("data-fastra-code=\"").count(), 3);
        assert_eq!(rendered.html.matches("data-tex=\"").count(), 2);
        assert_eq!(
            rendered
                .html
                .matches("class=\"fastra-visible-blank-line\"")
                .count(),
            1
        );
        assert!(rendered
            .html
            .contains("<div class=\"math-block\" data-srcline=\"5\""));
        assert!(rendered.html.contains("data-srcline=\"12\"><br>"));
        let marked = rendered
            .html
            .split("<mark>")
            .skip(1)
            .map(|rest| rest.split("</mark>").next().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(marked.len(), 2);
        assert!(marked[0].contains("Before"));
        assert!(marked[1].contains("Mark"));
        let heading =
            crate::markdown_navigation::headings(&source, &Cancellation::default()).unwrap();
        assert_eq!(heading.len(), 1);
        assert_eq!(heading[0].line, 13);
        assert_eq!(heading[0].byte, source.find("# After").unwrap());
        assert_eq!(
            heading[0].offset as usize,
            source[..heading[0].byte].chars().count()
        );
        assert!(rendered
            .html
            .contains(&format!("data-fastra-offset=\"{}\"", heading[0].offset)));
        let refs = crate::rich_editor::asset_flow::references(&source).unwrap();
        assert_eq!(refs.len(), 1);
        assert_eq!(&source[refs[0].range.clone()], "![picture][p]");
        let mut edited = source.clone();
        edited.replace_range(refs[0].range.clone(), "![new](next.png)");
        assert_eq!(edited, source.replace("![picture][p]", "![new](next.png)"));
    }
}
#[test]
fn nested_code_stays_source_with_concrete_localized_notice() {
    for (de, notice) in [
        (
            true,
            "Formel mit eingebettetem Code bleibt als Quelltext erhalten",
        ),
        (
            false,
            "Formula with embedded code is preserved as source text",
        ),
    ] {
        let source = "$`x`$\r\n\r\n$$\r\n`code`\r\n$$\r\n";
        let rendered = render(source, None, false, de, &Cancellation::default()).unwrap();
        assert_eq!(rendered.html.matches("class=\"math-source\"").count(), 2);
        assert_eq!(rendered.html.matches(notice).count(), 2);
        assert!(rendered.html.contains("$`x`$"));
        assert!(rendered.html.contains("$$\r\n`code`\r\n$$"));
        assert!(!rendered.html.contains("FASTRACODE"));
        assert!(!rendered.html.contains("data-tex=\""));
    }
}
#[test]
fn mixed_eols_and_math_click_positions_keep_original_utf16_columns() {
    let source = "雪🙂\r\n雪🙂Before $x$\r\n\r\n$$\ra\r  \rb\r$$\r\n\r\n# Last\r";
    let rendered = render(source, None, false, false, &Cancellation::default()).unwrap();
    assert!(rendered
        .html
        .contains("class=\"math-inline\" data-srcline=\"2\" data-srccol=\"11\""));
    assert!(rendered
        .html
        .contains("class=\"math-block\" data-srcline=\"4\" data-srccol=\"1\""));
    let headings = crate::markdown_navigation::headings(source, &Cancellation::default()).unwrap();
    assert_eq!(headings.len(), 1);
    assert_eq!(headings[0].line, 10);
    assert_eq!(
        headings[0].offset as usize,
        source[..source.find("# Last").unwrap()].chars().count()
    );
}

#[test]
fn commonmark_code_literals_remain_source_when_mac_code_regex_is_narrower() {
    for source in [
        "```text\n$x$\n````\n",
        "~~~text\n$x$\n~~~~\n",
        "`a $x$\nb`\n",
        "    $x$\n",
    ] {
        let rendered = render(source, None, false, false, &Cancellation::default()).unwrap();
        assert!(!rendered.html.contains("data-tex=\""), "{source:?}");
        assert!(!rendered.html.contains("FASTRAMATH"), "{source:?}");
        assert!(rendered.html.contains("$x$"), "{source:?}");
    }
}

#[test]
fn text_after_math_keeps_its_own_original_line_and_utf16_column() {
    let source = "ä🙂 $x$ tail\r\n\r\nMixed before\r\n$$\r\nx\r\n\r\ny\r\n$$\r\nAfter";
    let rendered = render(source, None, false, false, &Cancellation::default()).unwrap();
    assert!(rendered
        .html
        .contains("data-srcline=\"1\" data-srccol=\"8\"> tail</span>"));
    assert!(rendered
        .html
        .contains("data-srcline=\"9\" data-srccol=\"1\">After</span>"));
}

#[test]
fn literal_image_destinations_and_math_reference_ids_use_real_images_and_original_rewrites() {
    let literal = "FASTRAMATH00000000000000000000000000000000TOKEN.png";
    for eol in ["\n", "\r\n", "\r"] {
        for occurrence in [
            format!("![alt $x$]({literal})"),
            "![picture][$x$]".into(),
            "![alt $x$][]".into(),
            "![alt $x$]".into(),
        ] {
            let source =
                format!("雪🙂\n\n{occurrence}\n\n[$x$]: {literal}\n[alt $x$]: {literal}\n")
                    .replace('\n', eol);
            let dir = tempfile::tempdir().unwrap();
            std::fs::write(
                dir.path().join(literal),
                include_bytes!("../../tests/fixtures/pixel-1.png"),
            )
            .unwrap();
            let path = dir.path().join("source.md");
            let rendered =
                render(&source, Some(&path), false, false, &Cancellation::default()).unwrap();
            assert_eq!(rendered.images.len(), 1, "{source:?}");
            assert_eq!(rendered.warnings, 0);
            if occurrence.contains("alt") {
                assert!(rendered.html.contains("alt=\"alt $x$\""));
            }
            let refs = crate::rich_editor::asset_flow::references(&source).unwrap();
            assert_eq!(refs.len(), 1);
            assert_eq!(
                refs[0].alt,
                if occurrence.contains("alt") {
                    "alt $x$"
                } else {
                    "picture"
                }
            );
            assert_eq!(&source[refs[0].range.clone()], occurrence);
            let mut rewritten = source.clone();
            rewritten.replace_range(refs[0].range.clone(), "![moved](next.png)");
            assert_eq!(
                rewritten,
                source.replacen(&occurrence, "![moved](next.png)", 1)
            );
        }
    }
}
#[test]
fn partial_commonmark_literals_keep_render_and_codecopy_payloads_separate() {
    for fence in ["`", "~"] {
        for eol in ["\n", "\r\n", "\r"] {
            let source = format!("{fence}{fence}{fence}text\n$$\ninside\n{fence}{fence}{fence}{fence}\noutside\n$$\n").replace('\n',eol);
            let rendered = render(&source, None, false, false, &Cancellation::default()).unwrap();
            assert_eq!(rendered.html.matches("data-fastra-code=\"").count(), 1);
            assert!(rendered.html.contains("$$\ninside\n</code>"));
            assert!(rendered.html.contains("outside"));
            assert!(!rendered.html.contains("data-tex=\""));
        }
    }
}
