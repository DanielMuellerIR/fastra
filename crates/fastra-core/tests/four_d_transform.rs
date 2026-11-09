use fastra_core::{
    text_operations::{self, CharacterOperation as C},
    Cancellation, Error, Limits, Utf16Range,
};
#[derive(serde::Deserialize)]
struct Case {
    source: String,
    selection: [usize; 2],
    detokenized: Option<String>,
    tokenized: Option<String>,
    #[serde(rename = "detokenizeRejectedForSplitGrapheme")]
    rejected_detokenize: Option<bool>,
}
#[test]
fn all_actual_swift_transform_vectors() {
    let cases: Vec<Case> =
        serde_json::from_slice(include_bytes!("fixtures/four-d-transform-swift.json")).unwrap();
    assert_eq!(cases.len(), 7200);
    for (index, case) in cases.iter().enumerate() {
        for (op, expected) in [
            (C::FourDDetokenize, &case.detokenized),
            (C::FourDTokenizeCommands, &case.tokenized),
        ] {
            let result = text_operations::transform_characters(
                &case.source,
                Utf16Range {
                    location: case.selection[0],
                    length: case.selection[1],
                },
                op,
                Limits::default(),
                &Cancellation::default(),
            );
            if matches!(op, C::FourDDetokenize) && case.rejected_detokenize == Some(true) {
                assert!(matches!(result, Err(Error::InvalidRange)), "case{index}");
                continue;
            }
            let actual = result.unwrap_or_else(|e| panic!("case{index} {op:?} {e:?}"));
            assert_eq!(
                actual.map(|r| r.text),
                *expected,
                "case{index} {op:?}: {}",
                case.source.escape_debug()
            );
        }
    }
}
#[test]
fn transformations_are_bounded_cancelled_and_linear_for_word_chains() {
    let zero = Utf16Range {
        location: 0,
        length: 0,
    };
    let cancelled = Cancellation::default();
    cancelled.cancel();
    for op in [C::FourDDetokenize, C::FourDTokenizeCommands] {
        assert!(matches!(
            text_operations::transform_characters("ALERT", zero, op, Limits::default(), &cancelled),
            Err(Error::Cancelled)
        ));
    }
    let tiny = Limits {
        max_output_bytes: 8,
        ..Limits::default()
    };
    assert!(matches!(
        text_operations::transform_characters(
            "ALERT",
            zero,
            C::FourDTokenizeCommands,
            tiny,
            &Cancellation::default()
        ),
        Err(Error::Limit)
    ));
    let source = "x ".repeat(99999);
    assert!(text_operations::transform_characters(
        &source,
        zero,
        C::FourDTokenizeCommands,
        Limits::default(),
        &Cancellation::default()
    )
    .unwrap()
    .is_none());
    let limits = Limits {
        max_matches: 10,
        ..Limits::default()
    };
    assert!(matches!(
        text_operations::transform_characters(
            &source,
            zero,
            C::FourDDetokenize,
            limits,
            &Cancellation::default()
        ),
        Err(Error::Limit)
    ));
}

#[test]
fn long_names_and_numeric_suffixes_remain_bounded() {
    let cancel = Cancellation::default();
    let zero = Utf16Range {
        location: 0,
        length: 0,
    };
    let source = "x".repeat(4 * 1024 * 1024);
    assert!(text_operations::transform_characters(
        &source,
        zero,
        C::FourDTokenizeCommands,
        Limits::default(),
        &cancel
    )
    .unwrap()
    .is_none());
    let source = "Unknown:C".to_owned() + &"1".repeat(1024 * 1024);
    assert_eq!(
        text_operations::transform_characters(
            &source,
            zero,
            C::FourDDetokenize,
            Limits::default(),
            &cancel
        )
        .unwrap()
        .unwrap()
        .text,
        "Unknown"
    );
}

#[test]
fn split_graphemes_never_remove_bytes_outside_a_token_or_selection() {
    for source in ["ALERT:C41\u{307}", "😀\u{345}:C41"] {
        assert!(matches!(
            text_operations::transform_characters(
                source,
                Utf16Range {
                    location: 0,
                    length: 0
                },
                C::FourDDetokenize,
                Limits::default(),
                &Cancellation::default()
            ),
            Err(Error::InvalidRange)
        ));
    }
    assert!(matches!(
        text_operations::transform_characters(
            "😀\u{345}:C41",
            Utf16Range {
                location: 2,
                length: 5
            },
            C::FourDDetokenize,
            Limits::default(),
            &Cancellation::default()
        ),
        Err(Error::InvalidRange)
    ));
}
