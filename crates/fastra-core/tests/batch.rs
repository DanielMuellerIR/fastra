use fastra_core::{batch::*, Cancellation, Error, SearchFlags, SearchMode, SearchRequest};
fn documents() -> Vec<DocumentSnapshot> {
    vec![
        DocumentSnapshot {
            id: "a".into(),
            revision: 10,
            text: "cat cat🙂".into(),
        },
        DocumentSnapshot {
            id: "b".into(),
            revision: 20,
            text: "nothing".into(),
        },
    ]
}
fn request() -> SearchRequest {
    SearchRequest {
        pattern: "cat".into(),
        replacement: "dog".into(),
        mode: SearchMode::Literal,
        case_sensitive: true,
        range: None,
    }
}
fn prepare(d: Vec<DocumentSnapshot>) -> std::sync::Arc<BatchPreview> {
    BatchPreview::create(
        d,
        3,
        &request(),
        SearchFlags::default(),
        BatchLimits::default(),
        &Cancellation::default(),
    )
    .unwrap()
}
#[test]
fn complete_plan_is_pure_and_keeps_unmatched_documents_bound() {
    let docs = documents();
    let p = prepare(docs.clone());
    assert_eq!(p.documents().len(), 2);
    let plan = p
        .plan(&docs, 3, &[vec![1], vec![]], &Cancellation::default())
        .unwrap();
    assert_eq!(plan.outputs(), ["cat dog🙂", "nothing"]);
    assert_eq!(docs, documents());
    let mut changed = docs.clone();
    changed[1].text = "cat".into();
    assert!(matches!(
        plan.validate(&changed, 3, &Cancellation::default()),
        Err(Error::Stale)
    ));
}
#[test]
fn membership_order_generation_and_duplicate_identity_are_rejected() {
    let docs = documents();
    let p = prepare(docs.clone());
    let c = Cancellation::default();
    let mut swapped = docs.clone();
    swapped.swap(0, 1);
    assert!(p.validate(&swapped, 3, &c).is_err());
    assert!(p.validate(&docs[..1], 3, &c).is_err());
    assert!(p.validate(&docs, 4, &c).is_err());
    let mut duplicate = docs;
    duplicate[1].id = duplicate[0].id.clone();
    assert!(matches!(
        BatchPreview::create(
            duplicate,
            3,
            &request(),
            SearchFlags::default(),
            BatchLimits::default(),
            &c
        ),
        Err(Error::Stale)
    ));
}
#[test]
fn final_document_failure_never_publishes_a_partial_plan() {
    let docs = documents();
    let p = prepare(docs.clone());
    let c = Cancellation::default();
    assert!(matches!(
        p.plan(&docs, 3, &[vec![0], vec![0]], &c),
        Err(Error::InvalidApproval)
    ));
    assert!(matches!(
        p.plan(&docs, 3, &[vec![1, 0], vec![]], &c),
        Err(Error::InvalidApproval)
    ));
    assert_eq!(p.documents()[0].preview().source(), docs[0].text);
}
#[test]
fn joint_restoration_binds_real_post_apply_revisions_and_every_text() {
    let docs = documents();
    let p = prepare(docs.clone());
    let c = Cancellation::default();
    let plan = p.plan(&docs, 3, &[vec![0, 1], vec![]], &c).unwrap();
    let mut after = docs.clone();
    after[0].text = plan.outputs()[0].clone();
    after[0].revision = 13;
    let restore = plan.bind_restoration(after.clone(), &c).unwrap();
    assert_eq!(
        restore.restore(&after, &c).unwrap(),
        ["cat cat🙂", "nothing"]
    );
    after[1].revision += 1;
    assert!(matches!(restore.restore(&after, &c), Err(Error::Stale)));
}
#[test]
fn unseen_post_apply_data_cannot_become_an_undo_receipt() {
    let docs = documents();
    let p = prepare(docs.clone());
    let c = Cancellation::default();
    let plan = p.plan(&docs, 3, &[vec![0], vec![]], &c).unwrap();
    assert!(matches!(plan.bind_restoration(docs, &c), Err(Error::Stale)));
}
#[test]
fn aggregate_limits_apply_before_a_plan_can_escape() {
    let c = Cancellation::default();
    let limits = BatchLimits {
        max_source_bytes: 1,
        ..Default::default()
    };
    assert!(matches!(
        BatchPreview::create(
            documents(),
            3,
            &request(),
            SearchFlags::default(),
            limits,
            &c
        ),
        Err(Error::Limit)
    ));
    let limits = BatchLimits {
        max_matches: 1,
        ..Default::default()
    };
    assert!(matches!(
        BatchPreview::create(
            documents(),
            3,
            &request(),
            SearchFlags::default(),
            limits,
            &c
        ),
        Err(Error::Limit)
    ));
    let limits = BatchLimits {
        max_preview_bytes: 4,
        ..Default::default()
    };
    assert!(matches!(
        BatchPreview::create(
            documents(),
            3,
            &request(),
            SearchFlags::default(),
            limits,
            &c
        ),
        Err(Error::Limit)
    ));
    let limits = BatchLimits {
        max_plan_bytes: 4,
        ..Default::default()
    };
    let docs = documents();
    let p = BatchPreview::create(
        docs.clone(),
        3,
        &request(),
        SearchFlags::default(),
        limits,
        &c,
    )
    .unwrap();
    assert!(matches!(
        p.plan(&docs, 3, &[vec![0], vec![]], &c),
        Err(Error::Limit)
    ));
}
#[test]
fn selection_ranges_are_not_silently_reinterpreted_across_documents() {
    let mut r = request();
    r.range = Some(fastra_core::Utf16Range {
        location: 0,
        length: 1,
    });
    assert!(matches!(
        BatchPreview::create(
            documents(),
            3,
            &r,
            SearchFlags::default(),
            BatchLimits::default(),
            &Cancellation::default()
        ),
        Err(Error::InvalidRange)
    ));
}
#[test]
fn cancellation_is_checked_for_preview_plan_and_restoration() {
    let c = Cancellation::default();
    let docs = documents();
    let p = prepare(docs.clone());
    let plan = p.plan(&docs, 3, &[vec![], vec![]], &c).unwrap();
    let restore = plan.bind_restoration(docs.clone(), &c).unwrap();
    c.cancel();
    assert!(matches!(
        p.plan(&docs, 3, &[vec![], vec![]], &c),
        Err(Error::Cancelled)
    ));
    assert!(matches!(restore.restore(&docs, &c), Err(Error::Cancelled)));
    assert!(matches!(
        BatchPreview::create(
            docs,
            3,
            &request(),
            SearchFlags::default(),
            BatchLimits::default(),
            &c
        ),
        Err(Error::Cancelled)
    ));
}
