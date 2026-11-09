#![cfg(test)]
use super::*;
#[test]
fn nested_and_crossing_normalization() {
    let source = "x\n😀ab\r\ncd\nlast";
    let budget = Budget {
        cancel: &Cancellation::default(),
        started: Instant::now(),
    };
    let result = normalize(
        source,
        vec![0..15, 2..12, 2..10, 8..16, 2..12, 13..14],
        &budget,
    )
    .unwrap();
    assert_eq!(
        result
            .iter()
            .map(|r| (r.bytes.clone(), r.depth))
            .collect::<Vec<_>>(),
        vec![(0..15, 1), (2..12, 2)]
    );
    assert_eq!(result[1].characters, 2..9);
    assert_eq!(result[1].utf16, 2..10);
}
#[test]
fn no_partial_results_after_cancel_or_limits() {
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(
        regions("If x\nEnd if", "fourD", &cancel),
        Err(Failure::Cancelled)
    );
    assert_eq!(
        regions(
            &" ".repeat(MAX_BYTES + 1),
            "fourD",
            &Cancellation::default()
        ),
        Err(Failure::Limit)
    );
}
#[test]
fn four_d_nested_branch_and_sql() {
    let source="Function f\r\nIf ($x)\r\nBegin SQL\r\nIf broken\r\nEnd SQL\r\nElse\r\nALERT(\"😀\")\r\nEnd if\r\n";
    let result = regions(source, "fourD", &Cancellation::default()).unwrap();
    assert_eq!(result.len(), 4);
    assert_eq!(
        result.iter().map(|r| r.depth).collect::<Vec<_>>(),
        vec![1, 2, 3, 3]
    );
}
#[cfg(feature = "syntax-folding")]
#[test]
fn exact_pinned_grammars_and_existing_mac_feasibility() {
    assert_eq!(syntax::abis().len(), 32);
    assert!(syntax::abis()
        .iter()
        .all(|(_, abi)| (13..=15).contains(abi)));
    let rust="fn run(x: bool) {\r\nif x {\r\nprintln!(\"😀 }\");\r\n} else {\r\nprintln!(\"no\");\r\n}\r\n}\r\n";
    let result = regions(rust, "rust", &Cancellation::default()).unwrap();
    assert_eq!(
        result
            .iter()
            .map(|r| (r.bytes.start, r.bytes.end, r.depth))
            .collect::<Vec<_>>(),
        vec![(17, 78, 1), (25, 48, 2), (56, 75, 2)]
    );
    assert!(regions(
        "fn f() {\n if true {\n println!(\"}\");\n",
        "rust",
        &Cancellation::default()
    )
    .unwrap()
    .is_empty());
    assert!(regions(
        "# Header\n\n```rust\nfn f() {}\n```\n",
        "markdown",
        &Cancellation::default()
    )
    .unwrap()
    .is_empty());
}

#[cfg(all(test, feature = "syntax-folding"))]
#[test]
fn actual_mac_provider_vectors() {
    let fixtures: serde_json::Value = serde_json::from_str(include_str!(
        "../../tests/fixtures/mac-folding-regions.json"
    ))
    .unwrap();
    for fixture in fixtures.as_array().unwrap() {
        let regions = super::regions(
            fixture["text"].as_str().unwrap(),
            fixture["language"].as_str().unwrap(),
            &crate::Cancellation::default(),
        )
        .unwrap();
        let value=serde_json::Value::Array(regions.into_iter().map(|r|serde_json::json!({"bytes":[r.bytes.start,r.bytes.end],"characters":[r.characters.start,r.characters.end],"utf16":[r.utf16.start,r.utf16.end],"depth":r.depth})).collect());
        assert_eq!(
            value, fixture["regions"],
            "Mac provider fixture {}",
            fixture["name"]
        );
    }
}

#[test]
fn validate_rejects_corrupt_worker_positions() {
    let text = "If (True)\nALERT(\"😀\")\nEnd if\n";
    let mut folds = regions(text, "fourD", &Cancellation::default()).unwrap();
    assert!(validate(text, &folds, &Cancellation::default()).unwrap());
    folds[0].characters.end += 1;
    assert!(!validate(text, &folds, &Cancellation::default()).unwrap());
}
