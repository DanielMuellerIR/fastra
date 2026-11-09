use fastra_core::{Cancellation, Limits, PreparedSearch, SearchFlags, SearchMode, SearchRequest};
use fastra_workflow::{patterns::*, Error};
fn fixture() -> Collection {
    Collection::decode(
        include_bytes!("fixtures/swift-patterns.json"),
        &Cancellation::default(),
    )
    .unwrap()
}
#[test]
fn swift_array_roundtrip_and_all_38_original_examples() {
    let cancel = Cancellation::default();
    let value = fixture();
    assert_eq!(value.0[0].group_labels, ["Tier", "Emoji"]);
    let original: serde_json::Value =
        serde_json::from_slice(include_bytes!("fixtures/swift-patterns.json")).unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&value.encode(&cancel).unwrap()).unwrap(),
        original
    );
    let vectors: serde_json::Value =
        serde_json::from_slice(include_bytes!("fixtures/swift-pattern-vectors.json")).unwrap();
    let values = builtins().unwrap();
    assert_eq!(values.len(), 38);
    for value in values {
        value.usable(&cancel).unwrap();
        let p = PreparedSearch::new(
            &SearchRequest {
                pattern: value.regex.clone(),
                replacement: value
                    .default_replacement
                    .clone()
                    .unwrap_or_else(|| "$0".into()),
                mode: SearchMode::Regex,
                case_sensitive: true,
                range: None,
            },
            SearchFlags::default(),
            Limits::default(),
            &cancel,
        )
        .unwrap()
        .preview(&value.example_match, 1, 1)
        .unwrap();
        assert!(!p.matches().is_empty(), "{}", value.id);
        let vector = vectors
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == value.id)
            .unwrap();
        let ranges: Vec<_> = p
            .matches()
            .iter()
            .map(|hit| vec![hit.range.location, hit.range.length])
            .collect();
        assert_eq!(
            serde_json::to_value(ranges).unwrap(),
            vector["ranges"],
            "{}",
            value.id
        );
        assert_eq!(
            p.apply(
                p.source(),
                1,
                1,
                &(0..p.matches().len()).collect::<Vec<_>>(),
                &cancel
            )
            .unwrap(),
            vector["output"].as_str().unwrap(),
            "{}",
            value.id
        );
        assert_eq!(
            p.matches()[0].captures.len() - 1,
            value.group_labels.len(),
            "{}",
            value.id
        );
    }
}
#[test]
fn unknown_fields_preserved_but_cannot_fill_a_form() {
    let cancel = Cancellation::default();
    let mut value = fixture();
    value.0[0].extra.insert(
        "futureFlags".into(),
        serde_json::from_str("{\"big\":123456789012345678901234567890,\"enabled\":true}").unwrap(),
    );
    value.0[1].category = "Future category".into();
    let decoded = Collection::decode(&value.encode(&cancel).unwrap(), &cancel).unwrap();
    assert_eq!(decoded, value);
    assert!(matches!(
        decoded.0[0].usable(&cancel),
        Err(Error::Unsupported(_))
    ));
    assert!(matches!(
        decoded.0[1].usable(&cancel),
        Err(Error::Unsupported(_))
    ));
}
#[test]
fn import_validates_whole_array_and_replaces_explicit_ids() {
    let cancel = Cancellation::default();
    let old = fixture();
    let mut incoming = Collection(vec![old.0[0].clone()]);
    incoming.0[0].name = "Updated".into();
    let merged = old.merged(&incoming, &cancel).unwrap();
    assert_eq!(merged.0.len(), 2);
    assert_eq!(merged.0[1].name, "Updated");
    incoming.0.push(incoming.0[0].clone());
    assert!(old.merged(&incoming, &cancel).is_err());
    assert_eq!(old, fixture());
    for invalid in ["email", "", "  "] {
        let mut value = fixture();
        value.0[0].id = invalid.into();
        assert!(value.encode(&cancel).is_err());
    }
    let mut value = fixture();
    value.0[1].regex = "(".into();
    assert!(value.encode(&cancel).is_err());
    let mut value = fixture();
    value.0[1].default_replacement = Some("a\0b".into());
    assert!(value.encode(&cancel).is_err());
    assert!(Collection::decode(&vec![b' '; MAX_BYTES + 1], &cancel).is_err());
    cancel.cancel();
    assert!(Collection::default().encode(&cancel).is_err());
    assert!(matches!(
        old.encode(&cancel),
        Err(Error::Core(fastra_core::Error::Cancelled))
    ));
}
#[test]
fn private_pattern_store_cas_and_workflow_store_are_separate() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let cancel = Cancellation::default();
    let store = Store::open(root.path()).unwrap();
    let first = store.load(&cancel).unwrap();
    let second = Store::open(root.path()).unwrap();
    let stale = second.load(&cancel).unwrap();
    let next = store.save(&first, &fixture(), &cancel).unwrap();
    assert!(matches!(
        second.save(&stale, &Collection::default(), &cancel),
        Err(Error::Stale)
    ));
    assert_eq!(store.load(&cancel).unwrap().collection, next.collection);
    assert_eq!(
        std::fs::metadata(root.path().join("fastra-patterns/library.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    let workflows = fastra_workflow::store::Store::open(root.path()).unwrap();
    assert!(workflows
        .load()
        .unwrap()
        .library
        .workflows
        .workflows
        .is_empty());
    assert_eq!(store.load(&cancel).unwrap().collection, fixture());
}
#[test]
fn corrupt_or_untrusted_private_collection_is_not_reset() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let root = tempfile::tempdir().unwrap();
    let store = Store::open(root.path()).unwrap();
    let file = root.path().join("fastra-patterns/library.json");
    std::fs::write(&file, b"broken").unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert!(store.load(&Cancellation::default()).is_err());
    assert_eq!(std::fs::read(&file).unwrap(), b"broken");
    std::fs::remove_file(&file).unwrap();
    let other = root.path().join("other");
    std::fs::write(&other, b"[]").unwrap();
    symlink(&other, &file).unwrap();
    assert!(store.load(&Cancellation::default()).is_err());
    assert_eq!(std::fs::read(&other).unwrap(), b"[]");
}
