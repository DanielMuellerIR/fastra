use fastra_core::{
    text_operations::{titlecase_with_locale, TitlecaseLocale},
    Cancellation, Error, Limits, Utf16Range,
};
#[derive(serde::Deserialize)]
struct Reference {
    cases: Vec<Case>,
}
#[derive(serde::Deserialize)]
struct Case {
    input: String,
    explicit: std::collections::BTreeMap<String, String>,
}
#[test]
fn explicit_swift_locale_unicode_and_punctuation_matrix() {
    let data: Reference =
        serde_json::from_slice(include_bytes!("fixtures/titlecase-swift.json")).unwrap();
    assert_eq!(data.cases.len(), 217);
    let zero = Utf16Range {
        location: 0,
        length: 0,
    };
    for (index, case) in data.cases.iter().enumerate() {
        for (locale, expected) in &case.explicit {
            let locale = TitlecaseLocale::from_ctype(locale).unwrap();
            let actual = titlecase_with_locale(
                &case.input,
                zero,
                &locale,
                Limits::default(),
                &Cancellation::default(),
            )
            .unwrap()
            .map_or_else(|| case.input.clone(), |r| r.text);
            assert_eq!(
                &actual,
                expected,
                "case {index}, locale {} input {:?}",
                locale.as_str(),
                case.input
            );
        }
    }
}
#[test]
fn locale_selection_limits_and_cancellation() {
    let locale = TitlecaseLocale::from_ctype("tr_TR.UTF-8").unwrap();
    assert_eq!(locale.as_str(), "tr_TR");
    for c in ["C", "C.UTF-8", "POSIX"] {
        assert_eq!(
            TitlecaseLocale::from_ctype(c).unwrap().as_str(),
            "en_US_POSIX"
        );
    }
    for bad in [
        "",
        "x\0y",
        "foo/bar",
        "日本語",
        "nonsense_XX",
        "x",
        "en_US.UTF-8\0hidden",
    ] {
        assert!(TitlecaseLocale::from_ctype(bad).is_err());
    }
    let selection = Utf16Range {
        location: 3,
        length: 8,
    };
    let actual = titlecase_with_locale(
        "😀 istanbul tail",
        selection,
        &locale,
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(actual.text, "😀 İstanbul tail");
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(
        titlecase_with_locale("abc", selection, &locale, Limits::default(), &cancel).unwrap_err(),
        Error::Cancelled
    );
    let limits = Limits {
        max_output_bytes: 1,
        ..Limits::default()
    };
    assert_eq!(
        titlecase_with_locale(
            "ß",
            Utf16Range {
                location: 0,
                length: 0
            },
            &locale,
            limits,
            &Cancellation::default()
        )
        .unwrap_err(),
        Error::Limit
    );
}
