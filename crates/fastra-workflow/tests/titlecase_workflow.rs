use fastra_core::{text_operations::TitlecaseLocale, Cancellation, Utf16Range};
use fastra_workflow::{preview, preview_with_locale, Error, Workflow};
fn flow() -> Workflow {
    let archive = fastra_workflow::WorkflowArchive::decode(include_bytes!(
        "fixtures/titlecase-workflow-swift.json"
    ))
    .unwrap();
    assert_eq!(
        fastra_workflow::WorkflowArchive::decode(&archive.encode().unwrap()).unwrap(),
        archive
    );
    archive.workflows[0].clone()
}
#[test]
fn explicit_locale_stages_selection_and_apply_binding_without_json_migration() {
    let mut flow = flow();
    flow.steps[1].argument = "!".into();
    let encoded = serde_json::to_vec(&flow).unwrap();
    let json: serde_json::Value = serde_json::from_slice(&encoded).unwrap();
    assert!(json.get("locale").is_none());
    assert!(json["steps"]
        .as_array()
        .unwrap()
        .iter()
        .all(|step| step.get("locale").is_none()));
    let source = "😀 istanbul izmir untouched";
    let selection = Some(Utf16Range {
        location: 3,
        length: 14,
    });
    let tr = TitlecaseLocale::from_ctype("tr_TR.UTF-8").unwrap();
    let en = TitlecaseLocale::from_ctype("en_US.UTF-8").unwrap();
    let c = Cancellation::default();
    assert!(matches!(
        preview(&flow, source, selection, 4, 5, &c),
        Err(Error::Invalid(_))
    ));
    let p = preview_with_locale(&flow, source, selection, 4, 5, Some(&tr), &c).unwrap();
    assert_eq!(&*p.steps[0].after, "İstanbul İzmir");
    assert_eq!(p.output(), "😀 İstanbul İzmir! untouched");
    assert_eq!(p.locale(), Some(&tr));
    assert_eq!(
        p.apply_with_locale(source, 4, 5, &flow, selection, Some(&tr), &c)
            .unwrap(),
        p.output()
    );
    assert!(matches!(
        p.apply_with_locale(source, 4, 5, &flow, selection, Some(&en), &c),
        Err(Error::Stale)
    ));
    assert!(matches!(
        p.apply(source, 4, 5, &flow, selection, &c),
        Err(Error::Stale)
    ));
    assert!(matches!(
        p.apply_with_locale(source, 5, 5, &flow, selection, Some(&tr), &c),
        Err(Error::Stale)
    ));
    assert_eq!(serde_json::to_vec(&flow).unwrap(), encoded);
    flow.steps.remove(0);
    let p = preview(&flow, source, None, 0, 0, &c).unwrap();
    assert!(p.apply(source, 0, 0, &flow, None, &c).is_ok());
}
