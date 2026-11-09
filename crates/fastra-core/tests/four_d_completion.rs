use fastra_core::{four_d_completion::*, Cancellation, Utf16Range};
#[test]
fn original_swift_unicode_prefixes_and_contexts() {
    let vectors: Vec<serde_json::Value> = serde_json::from_slice(include_bytes!(
        "fixtures/four-d-completion-prefix-swift.json"
    ))
    .unwrap();
    for vector in vectors {
        let source = vector["text"].as_str().unwrap();
        let cursor = vector["cursor"].as_u64().unwrap() as usize;
        let range = prefix_range(source, cursor).map(|range| vec![range.location, range.length]);
        let expected = vector["range"].as_array().map(|a| {
            a.iter()
                .map(|v| v.as_u64().unwrap() as usize)
                .collect::<Vec<_>>()
        });
        assert_eq!(range, expected, "{source:?}@{cursor}");
        if vector["inside"].as_bool().unwrap() {
            assert!(
                suggest(
                    source,
                    Utf16Range {
                        location: cursor,
                        length: 0
                    },
                    true,
                    false,
                    &[],
                    &[],
                    &Cancellation::default()
                )
                .unwrap()
                .is_none(),
                "{source:?}@{cursor}"
            );
        }
    }
}
#[test]
fn canonical_symbols_order_shadowing_thresholds_and_cancel() {
    let cancel = Cancellation::default();
    let project = [Method {
        name: "ALproject".into(),
        signature: None,
    }];
    let components = [
        Component {
            name: "ALproject".into(),
            component: "A".into(),
            signature: None,
        },
        Component {
            name: "ALshared".into(),
            component: "B".into(),
            signature: None,
        },
    ];
    let items = matches("AL", &project, &components, 200, &cancel).unwrap();
    assert_eq!(items[0].name, "ALERT");
    assert!(items[0].signature.as_ref().unwrap().starts_with("ALERT"));
    let p = items.iter().position(|m| m.name == "ALproject").unwrap();
    let c = items.iter().position(|m| m.name == "ALshared").unwrap();
    assert!(p < c);
    assert_eq!(items.iter().filter(|m| m.name == "ALproject").count(), 1);
    assert_eq!(matches("a", &[], &[], 1, &cancel).unwrap().len(), 1);
    assert!(suggest(
        "A",
        Utf16Range {
            location: 1,
            length: 0
        },
        false,
        false,
        &[],
        &[],
        &cancel
    )
    .unwrap()
    .is_none());
    assert!(suggest(
        "A",
        Utf16Range {
            location: 1,
            length: 0
        },
        true,
        false,
        &[],
        &[],
        &cancel
    )
    .unwrap()
    .is_some());
    assert!(suggest(
        "AL",
        Utf16Range {
            location: 1,
            length: 1
        },
        true,
        false,
        &[],
        &[],
        &cancel
    )
    .unwrap()
    .is_none());
    cancel.cancel();
    assert_eq!(
        matches("AL", &project, &components, 200, &cancel),
        Err(fastra_core::Error::Cancelled)
    );
}

#[test]
fn original_swift_matching_unicode_order_signatures_and_cap() {
    let project = [
        "ALProject",
        "SAME",
        "ZZProject",
        "éMethod",
        "İProject",
        "ΣProject",
    ]
    .map(|name| Method {
        name: name.into(),
        signature: None,
    });
    let components = [
        ("ALProject", "Shadowed"),
        ("ComponentOnly", "C"),
        ("e\u{301}Method", "D"),
        ("İComponent", "I"),
    ]
    .map(|(name, component)| Component {
        name: name.into(),
        component: component.into(),
        signature: None,
    });
    let vectors: Vec<serde_json::Value> = serde_json::from_slice(include_bytes!(
        "fixtures/four-d-completion-matches-swift.json"
    ))
    .unwrap();
    for vector in vectors {
        let prefix = vector["prefix"].as_str().unwrap();
        let result = matches(prefix, &project, &components, 200, &Cancellation::default()).unwrap();
        let actual=result.into_iter().map(|item|serde_json::json!({"name":item.name,"signature":item.signature,"project":matches!(item.kind,Kind::Project),"constant":matches!(item.kind,Kind::Constant),"component":if let Kind::Component(name)=item.kind{Some(name)}else{None}})).collect::<Vec<_>>();
        assert_eq!(
            serde_json::Value::Array(actual),
            vector["items"],
            "prefix {prefix:?}"
        );
    }
}
