use fastra_core::{
    example_transformation::{infer, Refusal},
    Cancellation, Error,
};
#[test]
fn actual_swift_inferences_keep_original_bytes_and_tie_breaks() {
    let vectors: Vec<serde_json::Value> =
        serde_json::from_slice(include_bytes!("fixtures/example-transformation-swift.json"))
            .unwrap();
    for value in vectors {
        let source = value["source"].as_str().unwrap();
        let destination = value["destination"].as_str().unwrap();
        let result = infer(source, destination, &Cancellation::default());
        if let Some(find) = value["find"].as_str() {
            let result = result.unwrap();
            assert_eq!(result.find_pattern, find, "{source:?} → {destination:?}");
            assert_eq!(
                result.replace_pattern,
                value["replace"].as_str().unwrap(),
                "{source:?} → {destination:?}"
            );
        } else {
            assert!(result.is_err(), "{source:?} → {destination:?}");
        }
    }
}
#[test]
fn boundaries_count_graphemes_and_cancel_without_a_partial_inference() {
    let cancel = Cancellation::default();
    assert!(infer(
        &"👩🏽‍🚀".repeat(512),
        &format!("{}x", "👩🏽‍🚀".repeat(511)),
        &cancel
    )
    .is_ok());
    assert_eq!(
        infer(&"👩🏽‍🚀".repeat(513), "👩🏽‍🚀x", &cancel),
        Err(Refusal::TooLong)
    );
    assert_eq!(infer("é", "e\u{301}", &cancel), Err(Refusal::Equal));
    assert_eq!(infer("*x", "y*x", &cancel), Err(Refusal::Wildcard));
    assert_eq!(infer("a", "b", &cancel), Err(Refusal::NoCommonPart));
    assert_eq!(infer("", "b", &cancel), Err(Refusal::Empty));
    cancel.cancel();
    assert_eq!(
        infer("abc", "cba", &cancel),
        Err(Refusal::Core(Error::Cancelled))
    );
}

#[test]
fn actual_wildcard_preview_keeps_literals_canonical_captures_and_line_boundaries() {
    let cancel = Cancellation::default();
    for (source, destination, actual) in [
        ("ring, The", "The ring", "The ring"),
        ("$1 tail", "head $1", "head $1"),
        ("a\\$b tail", "head a\\$b", "head a\\$b"),
        ("a\na\\$b tail", "head a\\$b\nz", "head a\\$b\nz"),
        ("é😀 first", "last e\u{301}😀", "last é😀"),
    ] {
        let inference = infer(source, destination, &cancel).unwrap();
        let preview = inference.preview(source, destination, &cancel).unwrap();
        assert_eq!(preview.text, actual);
        assert!(preview.reproduces_destination);
    }
    let source = "before α\nβ";
    let destination = "α\nβ after";
    let inference = infer(source, destination, &cancel).unwrap();
    assert_eq!(inference.find_pattern, "before *");
    assert_eq!(inference.replace_pattern, "* after");
    let preview = inference.preview(source, destination, &cancel).unwrap();
    assert!(!preview.reproduces_destination);
    assert_ne!(preview.text, destination);
    let dollar = infer("foo", "$1foo", &cancel).unwrap();
    assert_eq!(dollar.find_pattern, "*");
    assert_eq!(dollar.replace_pattern, "$1*");
    let actual = dollar.preview("foo", "$1foo", &cancel).unwrap();
    assert_eq!(actual.text, "foofoo");
    assert!(!actual.reproduces_destination);
    cancel.cancel();
    assert_eq!(
        inference.preview(source, destination, &cancel),
        Err(Error::Cancelled)
    );
}
