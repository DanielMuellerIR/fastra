use fastra_core::{
    text_operations::{case_with_locale, TitlecaseLocale},
    Cancellation, Error, Limits, Utf16Range,
};
#[derive(serde::Deserialize)]
struct Case {
    locale: String,
    input: String,
    uppercase: bool,
    output: String,
}
#[test]
fn explicit_foundation_locale_case_matrix() {
    let vectors: Vec<Case> =
        serde_json::from_slice(include_bytes!("fixtures/case-locale-swift.json")).unwrap();
    assert_eq!(vectors.len(), 120);
    for case in vectors {
        let locale = TitlecaseLocale::from_ctype(&case.locale).unwrap();
        let result = case_with_locale(
            &case.input,
            Utf16Range {
                location: 0,
                length: 0,
            },
            case.uppercase,
            &locale,
            Limits::default(),
            &Cancellation::default(),
        )
        .unwrap()
        .map_or_else(|| case.input.clone(), |r| r.text);
        assert_eq!(
            result, case.output,
            "{} / uppercase={} / {:?}",
            case.locale, case.uppercase, case.input
        );
    }
}
#[test]
fn exact_utf16_selection_context_and_limits() {
    let locale = TitlecaseLocale::from_ctype("tr_TR.UTF-8").unwrap();
    let text = "😀 iI tail";
    let range = Utf16Range {
        location: 3,
        length: 2,
    };
    for (upper, expected) in [(true, "😀 İI tail"), (false, "😀 iı tail")] {
        let result = case_with_locale(
            text,
            range,
            upper,
            &locale,
            Limits::default(),
            &Cancellation::default(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(result.text, expected);
        assert_eq!(result.affected_range, range);
    }
    assert!(case_with_locale(
        text,
        Utf16Range {
            location: 1,
            length: 1
        },
        true,
        &locale,
        Limits::default(),
        &Cancellation::default()
    )
    .is_err());
    let limits = Limits {
        max_output_bytes: 1,
        ..Limits::default()
    };
    assert!(matches!(
        case_with_locale(
            "ß",
            Utf16Range {
                location: 0,
                length: 0
            },
            true,
            &locale,
            limits,
            &Cancellation::default()
        ),
        Err(Error::Limit)
    ));
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(matches!(
        case_with_locale(text, range, true, &locale, Limits::default(), &cancel),
        Err(Error::Cancelled)
    ));
}

#[test]
fn selected_substring_has_no_external_sigma_context() {
    let locale = TitlecaseLocale::from_ctype("el_GR").unwrap();
    let selected = case_with_locale(
        "AΣ",
        Utf16Range {
            location: 1,
            length: 1,
        },
        false,
        &locale,
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(selected.text, "Aσ");
    let whole = case_with_locale(
        "AΣ",
        Utf16Range {
            location: 0,
            length: 0,
        },
        false,
        &locale,
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(whole.text, "aς");
}
