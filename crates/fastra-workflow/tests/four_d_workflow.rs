use fastra_core::{Cancellation, Utf16Range};
use fastra_workflow::{preview, Error, WorkflowArchive};
#[derive(serde::Deserialize)]
struct Expected {
    source: String,
    selection: [usize; 2],
    stages: Vec<String>,
    expected: String,
}
#[test]
fn actual_swift_4d_workflow_archive_stages_selection_and_binding() {
    let archive =
        WorkflowArchive::decode(include_bytes!("fixtures/four-d-workflow-swift.json")).unwrap();
    assert_eq!(
        WorkflowArchive::decode(&archive.encode().unwrap()).unwrap(),
        archive
    );
    let expected: Expected =
        serde_json::from_slice(include_bytes!("fixtures/four-d-workflow-results.json")).unwrap();
    let flow = &archive.workflows[0];
    assert!(flow.steps.iter().all(|s| s.supported()));
    let selection = Some(Utf16Range {
        location: expected.selection[0],
        length: expected.selection[1],
    });
    let cancel = Cancellation::default();
    let p = preview(flow, &expected.source, selection, 2, 3, &cancel).unwrap();
    assert_eq!(p.output(), expected.expected);
    for (step, text) in p.steps.iter().zip(&expected.stages) {
        assert_eq!(&*step.after, text);
    }
    assert!(matches!(
        p.apply(&expected.source, 3, 3, flow, selection, &cancel),
        Err(Error::Stale)
    ));
    assert!(matches!(
        p.apply(&expected.source, 2, 3, flow, None, &cancel),
        Err(Error::Stale)
    ));
    let mut titlecase = flow.clone();
    titlecase.steps[0].kind = "titlecase".into();
    assert!(matches!(
        preview(&titlecase, &expected.source, selection, 2, 3, &cancel),
        Err(Error::Invalid(_))
    ));
    assert!(
        matches!(preview(flow,"😀\u{345}:C41",None,0,0,&cancel),Err(Error::Invalid(ref key)) if key == "4D grapheme token")
    );
}
