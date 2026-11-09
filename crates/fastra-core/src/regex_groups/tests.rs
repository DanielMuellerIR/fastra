use super::*;
fn syntax(p: &str) -> Syntax {
    let s = tokenize(p, &Cancellation::default()).unwrap();
    assert!(!s.has_errors, "{p}");
    s
}
fn proposal(
    p: &str,
    text: &str,
    replacement: &str,
    start: usize,
    length: usize,
) -> Option<Proposal> {
    propose(
        Utf16Range {
            location: start,
            length,
        },
        p,
        &syntax(p),
        text,
        replacement,
        true,
        &Cancellation::default(),
    )
    .unwrap()
}
fn removed(p: &str, replacement: &str, n: usize) -> Option<Removal> {
    remove(n, p, &syntax(p), replacement, &Cancellation::default()).unwrap()
}
fn replaced(p: &str, text: &str, replacement: &str) -> (Vec<Utf16Range>, String) {
    let request = crate::SearchRequest {
        pattern: p.into(),
        replacement: replacement.into(),
        mode: crate::SearchMode::Regex,
        case_sensitive: true,
        range: None,
    };
    let preview = crate::PreparedSearch::new(
        &request,
        crate::SearchFlags::default(),
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .preview(text, 1, 1)
    .unwrap();
    let selected = (0..preview.matches().len()).collect::<Vec<_>>();
    (
        preview.matches().iter().map(|m| m.range).collect(),
        preview
            .apply(text, 1, 1, &selected, &Cancellation::default())
            .unwrap(),
    )
}
#[test]
fn mac_email_tokens_units_snap_and_group_numbers() {
    let p = r"(\w+)@(\w+)\.de";
    let s = syntax(p);
    assert_eq!(
        s.groups.iter().map(|g| g.number).collect::<Vec<_>>(),
        [1, 2]
    );
    let units = units(p, &s, "anna@test.de", true, &Cancellation::default())
        .unwrap()
        .unwrap();
    assert_eq!(units.len(), 5);
    assert_eq!(
        units
            .iter()
            .map(|u| u.match_range.unwrap().length)
            .collect::<Vec<_>>(),
        [4, 1, 4, 1, 2]
    );
    for (start, len, expected, number, snapped, already) in [
        (1, 2, p, 1, (0, 4), true),
        (1, 6, r"((\w+)@(\w+))\.de", 1, (0, 9), false),
        (5, 0, p, 2, (5, 4), true),
        (4, 0, r"(\w+)(@)(\w+)\.de", 2, (4, 1), false),
        (10, 2, r"(\w+)@(\w+)\.(de)", 3, (10, 2), false),
        (12, 0, r"(\w+)@(\w+)\.(de)", 3, (10, 2), false),
    ] {
        let found = proposal(p, "anna@test.de", "$1-$2", start, len).unwrap();
        assert_eq!(found.pattern, expected);
        assert_eq!(found.group_number, number);
        assert_eq!(found.already_group, already);
        assert_eq!(
            found.snapped_match_range,
            Utf16Range {
                location: snapped.0,
                length: snapped.1
            }
        );
        assert_eq!(
            replaced(p, "anna@test.de", "$1-$2"),
            replaced(&found.pattern, "anna@test.de", &found.replacement)
        );
    }
}
#[test]
fn mac_quantifier_optional_anchor_and_alternation_units() {
    for (p, text, parts) in [
        (r"\d+abc?", "123ab", vec![r"\d+", "ab", "c?"]),
        ("^foo$", "foo", vec!["^", "foo", "$"]),
        ("a|b", "a", vec!["a|b"]),
        ("(a|b)c", "ac", vec!["(a|b)", "c"]),
        (r"(\w)+", "abc", vec![r"(\w)+"]),
        ("colou?r", "color", vec!["colo", "u?", "r"]),
    ] {
        let s = syntax(p);
        let found = units(p, &s, text, true, &Cancellation::default())
            .unwrap()
            .unwrap();
        assert_eq!(
            found
                .iter()
                .map(|u| &p[u.pattern_range.clone()])
                .collect::<Vec<_>>(),
            parts
        );
    }
    assert_eq!(
        proposal("colou?r", "color", "", 1, 4).unwrap().pattern,
        "(colou?r)"
    );
    assert_eq!(proposal("a|b", "a", "", 0, 1).unwrap().pattern, "(a|b)");
    assert_eq!(
        proposal("((a)b)c", "abc", "$1 $2", 0, 2)
            .unwrap()
            .group_number,
        1
    );
}
#[test]
fn mac_unicode_crlf_named_groups_and_empty_contributions() {
    let p = r"(\w+)-(.+)";
    let found = proposal(p, "anna-🙂e\u{301}", "$2", 6, 1).unwrap();
    assert!(found.already_group);
    assert_eq!(found.group_number, 2);
    assert_eq!(
        found.snapped_match_range,
        Utf16Range {
            location: 5,
            length: 4
        }
    );
    let s = syntax(r"(?<jahr>\d{4})-(\w+)");
    assert_eq!(s.groups[0].name.as_deref(), Some("jahr"));
    assert_eq!(
        &r"(?<jahr>\d{4})-(\w+)"[s.groups[0].inner.clone()],
        r"\d{4}"
    );
    assert_eq!(
        removed(r"(?<jahr>\d{4})", "x", 1).unwrap().pattern,
        r"\d{4}"
    );
    let u = units("a?b", &syntax("a?b"), "b", true, &Cancellation::default())
        .unwrap()
        .unwrap();
    assert!(u[0].match_range.is_none());
    let found = proposal("a.b", "a\r\nb", "", 1, 1).unwrap();
    assert_eq!(found.pattern, "a(.)b");
    assert_eq!(
        found.snapped_match_range,
        Utf16Range {
            location: 1,
            length: 2
        }
    );
    assert!(proposal("(?<=x)a", "a", "", 0, 1).is_none());
    assert!(propose(
        Utf16Range {
            location: 0,
            length: 1
        },
        "ABC",
        &syntax("ABC"),
        "abc",
        "",
        false,
        &Cancellation::default()
    )
    .unwrap()
    .is_some());
    assert!(proposal("ABC", "abc", "", 0, 1).is_none());
}
#[test]
fn mac_refusals_preserve_regex_and_template_meaning() {
    for p in [r"(a)b\1", r"(a)(b)\1", r"(?<n>a)(b)\k<n>"] {
        assert!(proposal(p, "aba", "x", 0, 2).is_none());
        assert!(removed(p, "x", 1).is_none());
    }
    for (p, replacement, n) in [
        ("(abc)+", "x", 1),
        ("(a|b)c", "x", 1),
        ("((?:a|b))", "x", 1),
        ("(a)", "$1", 1),
    ] {
        assert!(removed(p, replacement, n).is_none(), "{p}");
    }
    assert_eq!(removed("((a|b))", "x", 1).unwrap().pattern, "(a|b)");
    let p = "(a)(b)(c)(d)(e)(f)(g)(h)i";
    assert!(proposal(p, "abcdefghi", "$9", 8, 1).is_none());
    assert!(proposal(p, "abcdefghi", "$1", 8, 1).is_some());
    for template in ["$11", "$99"] {
        assert!(
            removed("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)", template, 10).is_none(),
            "{template}"
        );
    }
    let leading = removed("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)", "$01", 10).unwrap();
    assert_eq!(leading.replacement, "$1");
    let changed = proposal("(a)b(c)", "abc", "X$3Y", 1, 1).unwrap();
    assert_eq!(
        replaced("(a)b(c)", "abc", "X$3Y"),
        replaced(&changed.pattern, "abc", &changed.replacement)
    );
}
#[test]
fn reference_boundaries_and_escaped_templates_use_real_replacements() {
    let p = "(a)b(c)";
    let mut templates = vec![
        "$0".to_string(),
        "$1 $2 $3 $9 $12".into(),
        "$٠ $1\u{301}".into(),
    ];
    for n in 0..8 {
        templates.push(format!("{}$2-$1", "\\".repeat(n)));
    }
    for text in templates {
        let next = proposal(p, "abc", &text, 1, 1).unwrap();
        assert_eq!(
            replaced(p, "abc abc", &text),
            replaced(&next.pattern, "abc abc", &next.replacement),
            "{text}"
        );
    }
    let p = "(a)(b)(c)(d)(e)(f)(g)(h)(i)j";
    let next = proposal(p, "abcdefghij", "$12 $1 $9", 9, 1).unwrap();
    assert_eq!(next.replacement, "$012 $1 $9");
    assert_eq!(
        replaced(p, "abcdefghij", "$12 $1 $9"),
        replaced(&next.pattern, "abcdefghij", &next.replacement)
    );
}
#[test]
fn syntax_errors_class_parentheses_and_cancellation() {
    for p in ["(", "[a", r"\"] {
        assert!(tokenize(p, &Cancellation::default()).unwrap().has_errors);
    }
    let s = syntax(r"([()])\(\)a");
    assert_eq!(s.groups.len(), 1);
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(tokenize("a", &cancel), Err(Error::Cancelled));
    assert_eq!(
        tokenize(&"a".repeat(65537), &Cancellation::default()),
        Err(Error::Limit)
    );
}

#[test]
fn inline_flags_keep_their_original_scope_and_syntax_binds_its_source() {
    assert_ne!(
        replaced("(a(?i)b)c", "abc abC", "x"),
        replaced("a(?i)bc", "abc abC", "x")
    );
    assert!(removed("(a(?i)b)c", "x", 1).is_none());
    let safe = removed("((a(?i)b))c", "x", 1).unwrap();
    assert_eq!(
        replaced("((a(?i)b))c", "abc abC", "x"),
        replaced(&safe.pattern, "abc abC", &safe.replacement)
    );
    assert!(proposal("a(?i)b.c", "abcC", "", 0, 2).is_none());
    let safe = proposal("(?i)abc", "ABC", "", 1, 1).unwrap();
    assert_eq!(safe.pattern, "(?i)(abc)");
    assert_eq!(
        replaced("(?i)abc", "ABC abc", "x"),
        replaced(&safe.pattern, "ABC abc", "x")
    );
    assert!(propose(
        Utf16Range {
            location: 0,
            length: 1
        },
        "abc",
        &syntax("(a)"),
        "abc",
        "",
        true,
        &Cancellation::default()
    )
    .unwrap()
    .is_none());
    assert!(
        remove(1, "abc", &syntax("(a)"), "", &Cancellation::default())
            .unwrap()
            .is_none()
    );
}
