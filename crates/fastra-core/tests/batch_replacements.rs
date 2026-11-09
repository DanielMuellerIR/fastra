use fastra_core::{batch::*, Cancellation, Error};
fn source() -> Vec<DocumentSnapshot> {
    vec![
        DocumentSnapshot {
            id: "a".into(),
            revision: 1,
            text: "🙂a\r\n".into(),
        },
        DocumentSnapshot {
            id: "b".into(),
            revision: 2,
            text: "unchanged".into(),
        },
        DocumentSnapshot {
            id: "c".into(),
            revision: 3,
            text: String::new(),
        },
    ]
}
fn prepare() -> std::sync::Arc<BatchPreview> {
    BatchPreview::from_replacements(
        source(),
        vec!["🙂B\r\n".into(), "unchanged".into(), "inserted".into()],
        9,
        BatchLimits::default(),
        &Cancellation::default(),
    )
    .unwrap()
}
#[test]
fn whole_document_approvals_include_empty_unicode_noop_and_unapproved_inputs() {
    let c = Cancellation::default();
    let preview = prepare();
    assert_eq!(
        preview.documents()[0].preview().matches()[0].range.length,
        5
    );
    let plan = preview
        .plan(&source(), 9, &[vec![0], vec![0], vec![]], &c)
        .unwrap();
    assert_eq!(plan.outputs(), ["🙂B\r\n", "unchanged", ""]);
    let mut changed = source();
    changed[2].revision += 1;
    assert!(matches!(plan.validate(&changed, 9, &c), Err(Error::Stale)));
    changed = source();
    changed[1].text.push('!');
    assert!(plan.validate(&changed, 9, &c).is_err());
    assert!(preview
        .plan(&source(), 9, &[vec![1], vec![], vec![]], &c)
        .is_err());
}
#[test]
fn restoration_checks_every_post_apply_input_before_returning_any_original() {
    let c = Cancellation::default();
    let plan = prepare()
        .plan(&source(), 9, &[vec![0], vec![], vec![0]], &c)
        .unwrap();
    let mut after = source();
    for (doc, text) in after.iter_mut().zip(plan.outputs()) {
        if doc.text != *text {
            doc.text = text.clone();
            doc.revision += 2;
        }
    }
    let restore = plan.bind_restoration(after.clone(), &c).unwrap();
    assert_eq!(
        restore.restore(&after, &c).unwrap(),
        ["🙂a\r\n", "unchanged", ""]
    );
    after[1].revision += 1;
    assert!(restore.restore(&after, &c).is_err());
    after.pop();
    assert!(restore.restore(&after, &c).is_err());
}
#[test]
fn invalid_membership_limits_outputs_and_cancellation_publish_no_plan() {
    let c = Cancellation::default();
    let mut docs = source();
    docs[1].id = docs[0].id.clone();
    assert!(BatchPreview::from_replacements(
        docs,
        vec![String::new(); 3],
        9,
        BatchLimits::default(),
        &c
    )
    .is_err());
    assert!(
        BatchPreview::from_replacements(source(), vec![], 9, BatchLimits::default(), &c).is_err()
    );
    let limits = BatchLimits {
        max_plan_bytes: 2,
        ..BatchLimits::default()
    };
    assert!(matches!(
        BatchPreview::from_replacements(
            source(),
            vec!["123".into(), String::new(), String::new()],
            9,
            limits,
            &c
        ),
        Err(Error::Limit)
    ));
    let limits = BatchLimits {
        max_preview_bytes: 2,
        ..BatchLimits::default()
    };
    assert!(
        BatchPreview::from_replacements(source(), vec![String::new(); 3], 9, limits, &c).is_err()
    );
    c.cancel();
    assert!(matches!(
        BatchPreview::from_replacements(
            source(),
            vec![String::new(); 3],
            9,
            BatchLimits::default(),
            &c
        ),
        Err(Error::Cancelled)
    ));
}
