use fastra_core::{text_operations::*, Cancellation, Error, Limits, Utf16Range};
use serde::Deserialize;

const WHOLE: Utf16Range = Utf16Range {
    location: 0,
    length: 0,
};
fn run(text: &str, operation: LineOperation) -> Option<TextResult> {
    transform_lines(
        text,
        WHOLE,
        &operation,
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Vector {
    operation: String,
    text: String,
    location: usize,
    length: usize,
    argument: String,
    output: Option<String>,
    affected_location: Option<usize>,
    affected_length: Option<usize>,
    line_count: Option<usize>,
}
#[test]
fn original_swift_reference_vectors() {
    let cases: Vec<Vector> =
        serde_json::from_str(include_str!("fixtures/swift-text-reference.json")).unwrap();
    assert!(cases.len() >= 35);
    for case in cases {
        let selection = Utf16Range {
            location: case.location,
            length: case.length,
        };
        let character = match case.operation.as_str() {
            "nfc" => Some(CharacterOperation::Nfc),
            "nfd" => Some(CharacterOperation::Nfd),
            "spaces" => Some(CharacterOperation::NormalizeSpaces),
            "zap" => Some(CharacterOperation::ZapGremlins),
            _ => None,
        };
        let result = if let Some(operation) = character {
            transform_characters(
                &case.text,
                selection,
                operation,
                Limits::default(),
                &Cancellation::default(),
            )
        } else {
            let operation = match case.operation.as_str() {
                "sort" => LineOperation::SortRoot(RootSortOptions::default()),
                "descending" => LineOperation::SortRoot(RootSortOptions {
                    descending: true,
                    ..RootSortOptions::default()
                }),
                "dedup" => LineOperation::Duplicates(DuplicateMode::KeepFirst),
                "duplicates" => LineOperation::Duplicates(DuplicateMode::KeepDuplicates),
                "unique" => LineOperation::Duplicates(DuplicateMode::RemoveAllDuplicates),
                "reverse" => LineOperation::Reverse,
                "blank" => LineOperation::RemoveBlank,
                "trim" => LineOperation::TrimTrailingWhitespace,
                "prefix" => LineOperation::Prefix(case.argument),
                "suffix" => LineOperation::Suffix(case.argument),
                "join" => LineOperation::Join(case.argument),
                "number" => LineOperation::AddNumbers,
                "unnumber" => LineOperation::RemoveNumbers,
                "keep" | "delete" => LineOperation::Filter {
                    pattern: case.argument,
                    keep_matching: case.operation == "keep",
                    case_sensitive: false,
                },
                _ => panic!("Unknown reference operation"),
            };
            transform_lines(
                &case.text,
                selection,
                &operation,
                Limits::default(),
                &Cancellation::default(),
            )
        }
        .unwrap_or_else(|error| panic!("{} {:?}: {error:?}", case.operation, case.text));
        assert_eq!(
            result.as_ref().map(|r| &r.text),
            case.output.as_ref(),
            "{} {:?}",
            case.operation,
            case.text
        );
        assert_eq!(
            result.as_ref().map(|r| r.affected_range.location),
            case.affected_location,
            "{} range",
            case.operation
        );
        assert_eq!(
            result.as_ref().map(|r| r.affected_range.length),
            case.affected_length,
            "{} range",
            case.operation
        );
        assert_eq!(
            result.as_ref().map(|r| r.line_count),
            case.line_count,
            "{} count",
            case.operation
        );
    }
}
#[test]
fn sort_options_are_stable_and_explicit() {
    let text = "a10\na2\na1";
    assert_eq!(
        run(text, LineOperation::SortRoot(RootSortOptions::default()))
            .unwrap()
            .text,
        "a1\na2\na10"
    );
    assert_eq!(
        run(
            text,
            LineOperation::SortRoot(RootSortOptions {
                numeric: false,
                ..RootSortOptions::default()
            })
        )
        .unwrap()
        .text,
        "a1\na10\na2"
    );
    let text = "b\nA\na\nB";
    assert_eq!(
        run(text, LineOperation::SortRoot(RootSortOptions::default()))
            .unwrap()
            .text,
        "A\na\nb\nB"
    );
    assert_eq!(
        run(
            text,
            LineOperation::SortRoot(RootSortOptions {
                descending: true,
                ..RootSortOptions::default()
            })
        )
        .unwrap()
        .text,
        "b\nB\nA\na"
    );
    assert_eq!(
        run(
            "a\nA",
            LineOperation::SortRoot(RootSortOptions {
                case_sensitive: true,
                ..RootSortOptions::default()
            })
        ),
        None
    );
}
#[test]
fn canonical_duplicates_preserve_first_bytes() {
    let result = run(
        "e\u{301}\né\nx",
        LineOperation::Duplicates(DuplicateMode::KeepFirst),
    )
    .unwrap();
    assert_eq!(result.text.as_bytes(), "e\u{301}\nx".as_bytes());
}
#[test]
fn selection_at_final_empty_line_is_not_previous_line() {
    assert_eq!(
        full_line_range(
            "a\n",
            Utf16Range {
                location: 2,
                length: 1
            }
        )
        .unwrap(),
        Utf16Range {
            location: 2,
            length: 0
        }
    );
}
#[test]
fn malformed_utf16_selection_is_rejected() {
    let selection = Utf16Range {
        location: 1,
        length: 1,
    };
    assert_eq!(
        transform_characters(
            "😀a",
            selection,
            CharacterOperation::NormalizeSpaces,
            Limits::default(),
            &Cancellation::default()
        ),
        Err(Error::InvalidRange)
    );
    assert_eq!(
        transform_lines(
            "😀a",
            selection,
            &LineOperation::Reverse,
            Limits::default(),
            &Cancellation::default()
        ),
        Err(Error::InvalidRange)
    );
    assert!(matches!(
        full_line_range(
            "x",
            Utf16Range {
                location: usize::MAX,
                length: 2
            }
        ),
        Err(Error::InvalidRange)
    ));
}
#[test]
fn normalization_expands_split_surrogate_and_grapheme() {
    let range = Utf16Range {
        location: 1,
        length: 1,
    };
    assert_eq!(
        transform_characters(
            "😀é",
            range,
            CharacterOperation::Nfd,
            Limits::default(),
            &Cancellation::default()
        )
        .unwrap(),
        None
    );
    let result = transform_characters(
        "e\u{301}",
        Utf16Range {
            location: 0,
            length: 1,
        },
        CharacterOperation::Nfc,
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(result.text.as_bytes(), "é".as_bytes());
    assert_eq!(result.affected_range.length, 2);
}
#[test]
fn root_casing_expands_unicode_without_touching_outside_selection() {
    let result = transform_characters(
        "x straße y",
        Utf16Range {
            location: 2,
            length: 6,
        },
        CharacterOperation::UppercaseRoot,
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(result.text, "x STRASSE y");
    let result = transform_characters(
        "İΣ",
        WHOLE,
        CharacterOperation::LowercaseRoot,
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(result.text, "i\u{307}ς");
}
#[test]
fn filters_cannot_wipe_the_selected_block_and_report_regex_errors() {
    assert_eq!(
        run(
            "a\nb",
            LineOperation::Filter {
                pattern: ".".into(),
                keep_matching: false,
                case_sensitive: true
            }
        ),
        None
    );
    assert!(matches!(
        transform_lines(
            "a\nb",
            WHOLE,
            &LineOperation::Filter {
                pattern: "(".into(),
                keep_matching: true,
                case_sensitive: true
            },
            Limits::default(),
            &Cancellation::default()
        ),
        Err(Error::Regex { .. })
    ));
}
#[test]
fn cancellation_and_size_limits_never_return_partial_results() {
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(
        transform_lines(
            "a\nb",
            WHOLE,
            &LineOperation::Reverse,
            Limits::default(),
            &cancel
        ),
        Err(Error::Cancelled)
    );
    assert_eq!(
        transform_characters(
            "x",
            WHOLE,
            CharacterOperation::UppercaseRoot,
            Limits::default(),
            &cancel
        ),
        Err(Error::Cancelled)
    );
    let limits = Limits {
        max_output_bytes: 3,
        ..Limits::default()
    };
    assert_eq!(
        transform_lines(
            "a\nb",
            WHOLE,
            &LineOperation::Prefix("x".into()),
            limits,
            &Cancellation::default()
        ),
        Err(Error::Limit)
    );
    assert_eq!(
        transform_lines(
            "a\nb",
            WHOLE,
            &LineOperation::AddNumbers,
            limits,
            &Cancellation::default()
        ),
        Err(Error::Limit)
    );
    let limits = Limits {
        max_matches: 1,
        ..Limits::default()
    };
    assert_eq!(
        transform_lines(
            "a\nb",
            WHOLE,
            &LineOperation::Reverse,
            limits,
            &Cancellation::default()
        ),
        Err(Error::Limit)
    );
}

#[test]
fn filters_evaluate_real_empty_lines() {
    let result = run(
        "a\n\nb",
        LineOperation::Filter {
            pattern: "^$".into(),
            keep_matching: true,
            case_sensitive: true,
        },
    )
    .unwrap();
    assert_eq!(result.text, "");
    assert_eq!(result.line_count, 1);
    let result = run(
        "a\n\nb",
        LineOperation::Filter {
            pattern: ".".into(),
            keep_matching: true,
            case_sensitive: true,
        },
    )
    .unwrap();
    assert_eq!(result.text, "a\nb");
}
#[test]
fn many_short_lines_stop_at_the_budget() {
    let limits = Limits {
        max_matches: 10,
        ..Limits::default()
    };
    assert_eq!(
        transform_lines(
            &"\n".repeat(100_000),
            WHOLE,
            &LineOperation::Reverse,
            limits,
            &Cancellation::default()
        ),
        Err(Error::Limit)
    );
    assert_eq!(
        full_line_range(
            "abc",
            Utf16Range {
                location: 3,
                length: 1
            }
        )
        .unwrap(),
        Utf16Range {
            location: 0,
            length: 3
        }
    );
}

#[test]
fn filters_keep_unicode_captures_and_anchors_local_to_each_line() {
    let text = "😀Ä😀\r\nno\r\n😀ä😀\r\n😀Äx\r\n";
    for (case_sensitive, keep_matching, expected) in [
        (true, true, "😀Ä😀\r\n"),
        (false, true, "😀Ä😀\r\n😀ä😀\r\n"),
        (false, false, "no\r\n😀Äx\r\n"),
    ] {
        let result = run(
            text,
            LineOperation::Filter {
                pattern: r"^(😀)Ä\1$".into(),
                keep_matching,
                case_sensitive,
            },
        )
        .unwrap();
        assert_eq!(result.text, expected);
    }
}

#[test]
fn filters_keep_limits_and_cancellation_when_reusing_patterns() {
    let operation = LineOperation::Filter {
        pattern: "a".into(),
        keep_matching: true,
        case_sensitive: true,
    };
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(
        transform_lines("a\nb", WHOLE, &operation, Limits::default(), &cancel),
        Err(Error::Cancelled),
    );
    for limits in [
        Limits {
            max_text_bytes: 2,
            ..Limits::default()
        },
        Limits {
            max_output_bytes: 0,
            ..Limits::default()
        },
        Limits {
            max_matches: 1,
            ..Limits::default()
        },
        Limits {
            regex_time_ms: 0,
            ..Limits::default()
        },
        Limits {
            regex_stack_bytes: 0,
            ..Limits::default()
        },
    ] {
        assert_eq!(
            transform_lines("a\nb", WHOLE, &operation, limits, &Cancellation::default()),
            Err(Error::Limit),
        );
    }
    let explosive = LineOperation::Filter {
        pattern: "(a+)+$".into(),
        keep_matching: true,
        case_sensitive: true,
    };
    let text = format!("a\n{}!", "a".repeat(100_000));
    assert!(matches!(
        transform_lines(
            &text,
            WHOLE,
            &explosive,
            Limits {
                regex_time_ms: 1,
                ..Limits::default()
            },
            &Cancellation::default()
        ),
        Err(Error::Engine(66322 | 66321)),
    ));
}

#[test]
fn interactive_text_operation_limits_preserve_the_four_mib_boundary() {
    let limits = Limits::interactive_text_operations();
    let mut text = "x".repeat(4 * 1024 * 1024);
    assert_eq!(
        transform_lines(
            &text,
            WHOLE,
            &LineOperation::Prefix("".into()),
            limits,
            &Cancellation::default()
        ),
        Ok(None),
    );
    assert_eq!(
        transform_lines(
            &text,
            WHOLE,
            &LineOperation::Prefix("x".into()),
            limits,
            &Cancellation::default()
        ),
        Err(Error::Limit),
    );
    text.push('x');
    assert_eq!(
        transform_lines(
            &text,
            WHOLE,
            &LineOperation::Prefix("".into()),
            limits,
            &Cancellation::default()
        ),
        Err(Error::Limit),
    );
}

#[test]
fn an_active_filter_can_be_cancelled_without_returning_kept_lines() {
    let cancel = Cancellation::default();
    let worker_cancel = cancel.clone();
    let (started, receiver) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        started.send(()).unwrap();
        transform_lines(
            &format!("a\n{}!", "a".repeat(40)),
            WHOLE,
            &LineOperation::Filter {
                pattern: "(a|aa)+$".into(),
                keep_matching: true,
                case_sensitive: true,
            },
            Limits {
                regex_time_ms: 10_000,
                ..Limits::default()
            },
            &worker_cancel,
        )
    });
    receiver
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap();
    std::thread::sleep(std::time::Duration::from_millis(30));
    assert!(
        !worker.is_finished(),
        "filter must still be running before cancellation"
    );
    cancel.cancel();
    assert_eq!(worker.join().unwrap(), Err(Error::Cancelled));
}
