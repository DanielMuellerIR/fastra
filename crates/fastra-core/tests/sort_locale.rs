use fastra_core::{text_operations::*, Cancellation, Error, Limits, Utf16Range};
const WHOLE: Utf16Range = Utf16Range {
    location: 0,
    length: 0,
};
fn sort(text: &str, locale: &str, descending: bool) -> String {
    sort_lines_with_locale(
        text,
        WHOLE,
        descending,
        &TitlecaseLocale::from_ctype(locale).unwrap(),
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .map_or_else(|| text.into(), |r| r.text)
}
#[test]
fn explicit_icu_locale_contract_six_languages() {
    for (locale, input, output) in [
        ("en_US", "z\nö\nä\nå\na", "a\nå\nä\nö\nz"),
        ("de_DE", "z\nö\nä\nå\na", "a\nå\nä\nö\nz"),
        ("sv_SE", "ö\nä\nå\nz\na", "a\nz\nå\nä\nö"),
        ("tr_TR", "İ\ni\nI\nı", "ı\nI\ni\nİ"),
        ("lt_LT", "z\nj\ny\nį\ni", "i\nį\ny\nj\nz"),
        ("el_GR", "a\nσ\nι", "ι\nσ\na"),
    ] {
        assert_eq!(sort(input, locale, false), output, "{locale}");
        assert_eq!(
            sort(input, locale, true),
            output.split('\n').rev().collect::<Vec<_>>().join("\n"),
            "{locale}"
        );
    }
}
#[test]
fn numeric_canonical_and_case_ties_are_stable_in_both_directions() {
    assert_eq!(
        sort("a02\na2\na002\na10\na1\na001", "en_US", false),
        "a1\na001\na02\na2\na002\na10"
    );
    assert_eq!(
        sort("a02\na2\na002\na10\na1\na001", "en_US", true),
        "a10\na02\na2\na002\na1\na001"
    );
    assert_eq!(
        sort("z\né\ne\u{301}\né\na\nA", "en_US", false),
        "a\nA\né\ne\u{301}\né\nz"
    );
    assert_eq!(
        sort("z\né\ne\u{301}\né\na\nA", "en_US", true),
        "z\né\ne\u{301}\né\nA\na"
    );
    assert_eq!(
        sort("ab\na-b\na b\na_b", "en_US", false),
        "a b\na_b\na-b\nab"
    );
}
#[test]
fn utf16_selection_crlf_and_phantom_newline() {
    let input = "😀 outside\r\na10\r\na2\r\ntail\r\n";
    let locale = TitlecaseLocale::from_ctype("en_US").unwrap();
    let result = sort_lines_with_locale(
        input,
        Utf16Range {
            location: 13,
            length: 6,
        },
        false,
        &locale,
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(result.text, "😀 outside\r\na2\r\na10\r\ntail\r\n");
    assert_eq!(
        result.affected_range,
        Utf16Range {
            location: 12,
            length: 7
        }
    );
    assert_eq!(result.line_count, 2);
    assert_eq!(sort("a10\r\na2\r\n", "en_US", false), "a2\r\na10\r\n");
}
#[test]
fn limits_cancellation_and_noop() {
    let locale = TitlecaseLocale::from_ctype("en_US").unwrap();
    let cancel = Cancellation::default();
    assert!(
        sort_lines_with_locale("a\nb", WHOLE, false, &locale, Limits::default(), &cancel)
            .unwrap()
            .is_none()
    );
    for limits in [
        Limits {
            max_text_bytes: 2,
            ..Limits::default()
        },
        Limits {
            max_output_bytes: 2,
            ..Limits::default()
        },
        Limits {
            max_matches: 1,
            ..Limits::default()
        },
    ] {
        assert!(matches!(
            sort_lines_with_locale("b\na", WHOLE, false, &locale, limits, &cancel),
            Err(Error::Limit)
        ));
    }
    cancel.cancel();
    assert!(matches!(
        sort_lines_with_locale("a", WHOLE, false, &locale, Limits::default(), &cancel),
        Err(Error::Cancelled)
    ));
}
#[test]
fn root_entry_retains_its_independent_options() {
    let input = "A\na\nz\nä";
    let original = transform_lines(
        input,
        WHOLE,
        &LineOperation::SortRoot(RootSortOptions::default()),
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(original.text, "A\na\nä\nz");
    assert_eq!(sort(input, "sv_SE", false), "a\nA\nz\nä");
    let lexical = transform_lines(
        "a10\na2",
        WHOLE,
        &LineOperation::SortRoot(RootSortOptions {
            numeric: false,
            ..RootSortOptions::default()
        }),
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap();
    assert!(lexical.is_none());
}
