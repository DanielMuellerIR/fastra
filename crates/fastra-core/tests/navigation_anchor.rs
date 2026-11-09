use fastra_core::{navigation_anchor::Anchor, Cancellation, Error};
use serde::Deserialize;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    source: String,
    current: String,
    revision: u64,
    current_revision: u64,
    location: usize,
    length: usize,
    expected: Option<[usize; 2]>,
    original_expected: Option<[usize; 2]>,
}
#[test]
fn swift_anchors_preserve_unicode_context_and_correct_only_duplicate_final_line() {
    let cases: Vec<Case> =
        serde_json::from_str(include_str!("fixtures/swift-outline-anchor.json")).unwrap();
    assert!(cases.len() > 800);
    let mut corrected = 0;
    for case in cases {
        if case.expected != case.original_expected {
            assert!(case.original_expected.is_none() && case.expected.is_some());
            corrected += 1;
        }
        let cancel = Cancellation::default();
        let anchor = Anchor::capture(
            &case.source,
            case.revision,
            case.location..case.location + case.length,
            &cancel,
        )
        .unwrap();
        assert_eq!(
            anchor
                .resolve(&case.current, case.current_revision, &cancel)
                .unwrap()
                .map(|r| [r.start, r.len()]),
            case.expected,
            "{:?} at {}+{} in {:?}",
            case.source,
            case.location,
            case.length,
            case.current
        );
    }
    assert!(corrected > 0);
}
#[test]
fn gtk_scalar_bridge_preserves_astral_selection_and_stale_context() {
    let cancel = Cancellation::default();
    let anchor = Anchor::from_characters("top\r\n🙂 é\r\nend", 3, 5..6, &cancel).unwrap();
    assert_eq!(anchor.range, 5..7);
    assert_eq!(
        anchor
            .resolve_characters("new\r\ntop\r\n🙂 é\r\nend", 4, &cancel)
            .unwrap(),
        Some(10..11)
    );
    assert_eq!(
        anchor
            .resolve_characters("top\r\nchanged\r\nend", 4, &cancel)
            .unwrap(),
        None
    );
}
#[test]
fn cancelled_or_excessive_anchor_search_never_returns_a_partial_destination() {
    let cancel = Cancellation::default();
    let anchor = Anchor::capture("before\nline\nafter", 1, 7..7, &cancel).unwrap();
    cancel.cancel();
    assert!(matches!(
        anchor.resolve("before\nline\nafter", 2, &cancel),
        Err(Error::Cancelled)
    ));
    let cancel = Cancellation::default();
    assert_eq!(
        anchor
            .resolve(
                &format!("{}before\nline\nafter", "x\n".repeat(200_000)),
                2,
                &cancel
            )
            .unwrap(),
        None
    );
    assert_eq!(
        anchor
            .resolve(
                &format!("{}before\nline\nafter", "line\n".repeat(1001)),
                2,
                &cancel
            )
            .unwrap(),
        None
    );
}
