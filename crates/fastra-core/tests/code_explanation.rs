use fastra_core::{
    code_explanation::{self as model, Id},
    Cancellation,
};
#[test]
fn native_foundation_dates_ids_and_exhaustive_utf16_grapheme_ranges() {
    let value: serde_json::Value = serde_json::from_slice(include_bytes!(
        "fixtures/code-explanation-foundation-macos.json"
    ))
    .unwrap();
    for row in value["dates"].as_array().unwrap() {
        let input = row["input"].as_str().unwrap();
        assert_eq!(
            model::valid_created_at(input),
            row["accepted"].as_bool().unwrap(),
            "{input:?}"
        );
    }
    for row in value["ids"].as_array().unwrap() {
        let input = row["input"].as_str().unwrap();
        let id = Id::parse(input);
        assert_eq!(
            id.is_some(),
            row["accepted"].as_bool().unwrap(),
            "{input:?}"
        );
        if let Some(id) = id {
            assert_eq!(id.as_str(), row["canonical"].as_str().unwrap());
        }
    }
    for row in value["ranges"].as_array().unwrap() {
        let text = row["text"].as_str().unwrap();
        let count = text.encode_utf16().count();
        let expected: Vec<(usize, usize)> = row["ranges"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| {
                (
                    a[0].as_u64().unwrap() as usize,
                    a[1].as_u64().unwrap() as usize,
                )
            })
            .collect();
        for start in 0..=count + 1 {
            for length in 0..=count + 1 {
                assert_eq!(
                    model::validate_range(text, start, length, &Cancellation::default()).is_ok(),
                    expected.contains(&(start, length)),
                    "{text:?} {start}/{length}"
                );
            }
        }
        assert!(
            model::validate_range(text, usize::MAX, usize::MAX, &Cancellation::default()).is_err()
        );
    }
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(model::validate_range("", 0, 0, &cancel).is_err());
}
