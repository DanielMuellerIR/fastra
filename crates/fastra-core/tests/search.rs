use fastra_core::{
    preview, wildcard, Cancellation, Error, Limits, SearchMode, SearchRequest, Utf16Range,
};

fn request(pattern: &str, replacement: &str, mode: SearchMode) -> SearchRequest {
    SearchRequest {
        pattern: pattern.into(),
        replacement: replacement.into(),
        mode,
        case_sensitive: true,
        range: None,
    }
}
fn replace(text: &str, request: SearchRequest) -> String {
    let cancel = Cancellation::default();
    let result = preview(text, 7, 9, &request, Limits::default(), &cancel).unwrap();
    result
        .apply(
            text,
            7,
            9,
            &(0..result.matches().len()).collect::<Vec<_>>(),
            &cancel,
        )
        .unwrap()
}

#[test]
fn greedy_stars_and_line_boundaries() {
    let mut input = request("*, the", "*", SearchMode::Wildcard);
    input.case_sensitive = false;
    assert_eq!(replace("Hello, There, The", input), "Hello, There");
    assert_eq!(
        replace("aZ\nb", request("a*b", "[*]", SearchMode::Wildcard)),
        "aZ\nb"
    );
    for stars in ["**", "***", "****"] {
        assert_eq!(
            replace(
                "aZ\nb",
                request(
                    &format!("a{stars}b"),
                    &format!("[{stars}]"),
                    SearchMode::Wildcard
                )
            ),
            "[Z\n]"
        );
    }
}

#[test]
fn grapheme_star_offsets_use_utf16() {
    let compiled = wildcard::compile_find("😀e\u{301}*x**").unwrap();
    assert_eq!(compiled.star_offsets, [4, 6]);
    assert_eq!(compiled.regex_pattern, "😀e\u{301}(.+)x([\\s\\S]+)");
    assert!(wildcard::compile_find("*\u{301}")
        .unwrap()
        .star_offsets
        .is_empty());
}

#[test]
fn literal_and_wildcard_templates_preserve_user_text() {
    assert_eq!(
        replace("a.*$\\", request("a.*$\\", "$1\\U*", SearchMode::Literal)),
        "$1\\U*"
    );
    assert_eq!(
        replace("ab-cd", request("*-*", "$2/*/$5.00", SearchMode::Wildcard)),
        "cd/ab/$5.00"
    );
    assert_eq!(
        wildcard::compile_replace("*2\u{301}", Some(10)).unwrap(),
        "$012\u{301}"
    );
}

#[test]
fn captures_are_exact_utf16_ranges() {
    let cancel = Cancellation::default();
    let p = preview(
        "b 😀a",
        0,
        0,
        &request("(😀)?(.)", "$2$1", SearchMode::Regex),
        Limits::default(),
        &cancel,
    )
    .unwrap();
    assert_eq!(p.matches()[0].captures[1], None);
    assert_eq!(
        p.matches()[2].range,
        Utf16Range {
            location: 2,
            length: 3
        }
    );
    assert_eq!(
        p.matches()[2].captures[1],
        Some(Utf16Range {
            location: 2,
            length: 2
        })
    );
    assert_eq!(p.matches()[2].replacement, "a😀");
}

#[test]
fn foundation_numeric_reference_budget_and_escapes() {
    assert_eq!(
        replace("ab", request("(a)(b)", "$12", SearchMode::Regex)),
        "a2"
    );
    assert_eq!(
        replace("x", request("(x)", r"\$1-$1-\\", SearchMode::Regex)),
        "$1-x-\\"
    );
    assert_eq!(
        replace("x", request("(x)", "$٠-$9", SearchMode::Regex)),
        "$٠-"
    );
}

#[test]
fn case_operators_act_after_expansion() {
    for (text, pattern, template, expected) in [
        ("straße", "(straße)", r"\U$1\E", "STRASSE"),
        ("ÄBC", "(ÄBC)", r"\L$1\E", "äbc"),
        ("ßa", "(ßa)", r"\u$1", "SSa"),
        ("e\u{301}ß", "(e\u{301}ß)", r"\u$1", "E\u{301}ß"),
        ("b", "(a)?(b)", r"\u$1$2", "B"),
        ("AbC", "(AbC)", r"\L\u$1\E", "Abc"),
        ("x", "(x)", r"\\U$1", r"\Ux"),
    ] {
        assert_eq!(
            replace(text, request(pattern, template, SearchMode::Regex)),
            expected
        );
    }
}

#[test]
fn zero_length_matches_and_unmatched_text_are_preserved() {
    assert_eq!(
        replace("aa", request("(?=a)", "X", SearchMode::Regex)),
        "XaXa"
    );
    assert_eq!(
        replace("😀a😀", request("(?=😀)|$", "X", SearchMode::Regex)),
        "X😀aX😀X"
    );
}

#[test]
fn selection_has_opaque_anchoring_boundaries() {
    let mut r = request("(?<=a)b", "X", SearchMode::Regex);
    r.range = Some(Utf16Range {
        location: 1,
        length: 1,
    });
    assert_eq!(replace("ab", r.clone()), "ab");
    r.pattern = "^b$".into();
    assert_eq!(replace("abc", r.clone()), "aXc");
    r.pattern = "(?:)".into();
    r.range = Some(Utf16Range {
        location: 1,
        length: 0,
    });
    assert_eq!(replace("abc", r), "aXbc");
}

#[test]
fn invalid_utf16_boundaries_never_reach_the_engine() {
    for range in [
        Utf16Range {
            location: 1,
            length: 1,
        },
        Utf16Range {
            location: usize::MAX,
            length: 2,
        },
    ] {
        let mut r = request(".", "X", SearchMode::Regex);
        r.range = Some(range);
        assert_eq!(
            preview("😀", 0, 0, &r, Limits::default(), &Cancellation::default()).unwrap_err(),
            Error::InvalidRange
        );
    }
}

#[test]
fn apply_is_bound_to_content_revision_and_generation() {
    let cancel = Cancellation::default();
    let p = preview(
        "aba",
        3,
        4,
        &request("a", "X", SearchMode::Literal),
        Limits::default(),
        &cancel,
    )
    .unwrap();
    for (text, revision, generation) in [("aba!", 3, 4), ("aba", 4, 4), ("aba", 3, 5)] {
        assert_eq!(
            p.apply(text, revision, generation, &[0, 1], &cancel),
            Err(Error::Stale)
        );
    }
    assert_eq!(p.apply("aba", 3, 4, &[1], &cancel).unwrap(), "abX");
    assert_eq!(p.apply("aba", 3, 4, &[], &cancel).unwrap(), "aba");
}

#[test]
fn duplicate_reordered_or_foreign_approvals_are_rejected() {
    let cancel = Cancellation::default();
    let p = preview(
        "aa",
        0,
        0,
        &request("a", "X", SearchMode::Literal),
        Limits::default(),
        &cancel,
    )
    .unwrap();
    for indices in [vec![0, 0], vec![1, 0], vec![2]] {
        assert_eq!(
            p.apply("aa", 0, 0, &indices, &cancel),
            Err(Error::InvalidApproval)
        );
    }
}

#[test]
fn noop_preview_still_rejects_stale_source() {
    let cancel = Cancellation::default();
    let p = preview(
        "a",
        0,
        0,
        &request("a", "a", SearchMode::Literal),
        Limits::default(),
        &cancel,
    )
    .unwrap();
    assert_eq!(p.apply("b", 0, 0, &[0], &cancel), Err(Error::Stale));
}

#[test]
fn pre_cancelled_search_and_apply_fail_explicitly() {
    let cancel = Cancellation::default();
    let r = request("a", "X", SearchMode::Literal);
    let p = preview("a", 0, 0, &r, Limits::default(), &cancel).unwrap();
    cancel.cancel();
    assert_eq!(
        preview("a", 0, 0, &r, Limits::default(), &cancel).unwrap_err(),
        Error::Cancelled
    );
    assert_eq!(p.apply("a", 0, 0, &[0], &cancel), Err(Error::Cancelled));
}

#[test]
fn match_limit_never_yields_a_partial_applyable_plan() {
    let limits = Limits {
        max_matches: 1,
        ..Limits::default()
    };
    assert_eq!(
        preview(
            "aa",
            0,
            0,
            &request("a", "X", SearchMode::Literal),
            limits,
            &Cancellation::default()
        )
        .unwrap_err(),
        Error::Limit
    );
}

#[test]
fn output_growth_is_bounded() {
    let cancel = Cancellation::default();
    let limits = Limits {
        max_output_bytes: 5,
        ..Limits::default()
    };
    let p = preview(
        "abcd",
        0,
        0,
        &request("a", "XYZ", SearchMode::Literal),
        limits,
        &cancel,
    )
    .unwrap();
    assert_eq!(p.apply("abcd", 0, 0, &[0], &cancel), Err(Error::Limit));
}

#[test]
fn unicode_and_all_supported_line_endings_survive_assembly() {
    let text = "😀a\r\néa\rxa\nya\u{85}za\u{2028}aa\u{2029}ba";
    assert_eq!(
        replace(text, request("a", "Q", SearchMode::Literal)),
        text.replace('a', "Q")
    );
}

#[test]
fn regex_syntax_error_is_structured() {
    assert!(matches!(
        preview(
            "x",
            0,
            0,
            &request("(", "", SearchMode::Regex),
            Limits::default(),
            &Cancellation::default()
        ),
        Err(Error::Regex { .. })
    ));
}

#[test]
fn pathological_regex_has_a_real_engine_limit() {
    let limits = Limits {
        regex_time_ms: 1,
        ..Limits::default()
    };
    let result = preview(
        &format!("{}!", "a".repeat(10_000)),
        0,
        0,
        &request("(a+)+$", "", SearchMode::Regex),
        limits,
        &Cancellation::default(),
    );
    assert!(matches!(result, Err(Error::Engine(66322 | 66321))));
}

#[test]
fn active_search_can_be_cancelled_from_another_thread() {
    let cancellation = Cancellation::default();
    let worker_token = cancellation.clone();
    let limits = Limits {
        regex_time_ms: 10_000,
        ..Limits::default()
    };
    let (started, receiver) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        started.send(()).unwrap();
        preview(
            &format!("{}!", "a".repeat(40)),
            0,
            0,
            &request("(a|aa)+$", "", SearchMode::Regex),
            limits,
            &worker_token,
        )
    });
    receiver
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap();
    std::thread::sleep(std::time::Duration::from_millis(30));
    assert!(
        !worker.is_finished(),
        "the pathological search must still be running before cancellation"
    );
    cancellation.cancel();
    assert_eq!(worker.join().unwrap().unwrap_err(), Error::Cancelled);
}

#[test]
fn empty_input_is_not_a_zero_length_search() {
    let cancel = Cancellation::default();
    for mode in [SearchMode::Literal, SearchMode::Wildcard, SearchMode::Regex] {
        let p = preview(
            "abc",
            0,
            0,
            &request("", "X", mode),
            Limits::default(),
            &cancel,
        )
        .unwrap();
        assert!(p.matches().is_empty());
    }
}

#[test]
fn shared_swift_reference_corpus() {
    use serde_json::{json, Value};
    let cases: Vec<Value> =
        serde_json::from_str(include_str!("../../../tools/linux-probes/regex/cases.json")).unwrap();
    let expected: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/swift-search-reference.json")).unwrap();
    assert_eq!(cases.len(), expected.len());
    for (case, expected) in cases.iter().zip(expected) {
        let mut request = request(
            case["pattern"].as_str().unwrap(),
            case["template"].as_str().unwrap(),
            if case["wildcard"].as_bool() == Some(true) {
                SearchMode::Wildcard
            } else {
                SearchMode::Regex
            },
        );
        request.case_sensitive = case["flags"].as_u64().unwrap_or(0) != 2;
        request.range = case["range"].as_array().map(|r| Utf16Range {
            location: r[0].as_u64().unwrap() as usize,
            length: r[1].as_u64().unwrap() as usize,
        });
        let text = case["text"].as_str().unwrap();
        let cancel = Cancellation::default();
        let actual = match preview(text, 0, 0, &request, Limits::default(), &cancel) {
            Ok(p) => {
                let ranges: Vec<_> = p
                    .matches()
                    .iter()
                    .map(|m| {
                        m.captures
                            .iter()
                            .map(|r| {
                                r.map(|r| json!([r.location, r.length]))
                                    .unwrap_or(json!([-1, 0]))
                            })
                            .collect::<Vec<_>>()
                    })
                    .collect();
                json!({"id":case["id"], "ranges":ranges, "output":p.apply(text, 0, 0, &(0..p.matches().len()).collect::<Vec<_>>(), &cancel).unwrap()})
            }
            Err(Error::Regex { .. }) => json!({"id":case["id"], "error":"compile"}),
            Err(error) => panic!("{}: {error}", case["id"]),
        };
        assert_eq!(actual, expected, "case {}", case["id"]);
    }
}

#[test]
fn capture_storage_is_bounded_independently_of_replacement_bytes() {
    let cancel = Cancellation::default();
    let result = preview(
        &"a".repeat(2_000),
        0,
        0,
        &request(&"()".repeat(1_000), "", SearchMode::Regex),
        Limits::default(),
        &cancel,
    );
    assert_eq!(result.unwrap_err(), Error::Limit);
}

#[test]
fn wildcard_mode_without_a_star_keeps_replacement_stars_and_dollars_literal() {
    assert_eq!(
        replace("cat", request("cat", "** $1", SearchMode::Wildcard)),
        "** $1"
    );
    assert_eq!(
        replace("*\u{301}", request("*\u{301}", "*", SearchMode::Wildcard)),
        "*"
    );
}

#[test]
fn prepared_search_reuses_pattern_without_leaking_previous_text_or_captures() {
    let cancel = Cancellation::default();
    let prepared = fastra_core::PreparedSearch::new(
        &request("(a)?b", "$1!", SearchMode::Regex),
        fastra_core::SearchFlags::default(),
        Limits::default(),
        &cancel,
    )
    .unwrap();
    for (text, output) in [("ab", "a!"), ("b", "!"), ("no", "no"), ("ab", "a!")] {
        let p = prepared.preview(text, 7, 9).unwrap();
        assert_eq!(
            p.apply(
                text,
                7,
                9,
                &(0..p.matches().len()).collect::<Vec<_>>(),
                &cancel
            )
            .unwrap(),
            output
        );
    }
    cancel.cancel();
    assert_eq!(prepared.preview("ab", 7, 9).unwrap_err(), Error::Cancelled);
}

#[test]
fn whole_word_flag_matches_existing_foundation_boundary_wrapper() {
    let cancel = Cancellation::default();
    let prepared = fastra_core::PreparedSearch::new(
        &request("cat", "dog", SearchMode::Literal),
        fastra_core::SearchFlags { whole_word: true },
        Limits::default(),
        &cancel,
    )
    .unwrap();
    let p = prepared.preview("cat cats cat", 0, 0).unwrap();
    assert_eq!(p.matches().len(), 2);
    assert_eq!(
        p.apply("cat cats cat", 0, 0, &[0, 1], &cancel).unwrap(),
        "dog cats dog"
    );
}

#[test]
fn foundation_trailing_backslash_is_consumed_after_case_tokenization() {
    for (template, expected) in [
        ("\\", ""),
        ("abc\\", "abc"),
        ("$1\\", "é😀"),
        ("\\U$1\\", "É😀"),
        ("\\U$1\\E\\", "É😀"),
        ("\\\\", "\\"),
    ] {
        assert_eq!(
            replace("é😀", request("(é😀)", template, SearchMode::Regex)),
            expected,
            "{template:?}",
        );
    }
    for mode in [SearchMode::Literal, SearchMode::Wildcard] {
        assert_eq!(replace("x", request("x", "é😀\\", mode)), "é😀\\");
    }
}
