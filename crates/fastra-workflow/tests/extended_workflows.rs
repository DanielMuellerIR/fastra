use fastra_core::{Cancellation, Utf16Range};
use fastra_workflow::{preview, Error, Workflow, WorkflowArchive};
use serde::Deserialize;
#[derive(Deserialize)]
struct Case {
    workflow: Workflow,
    source: String,
    selection: Option<[usize; 2]>,
    stages: Vec<String>,
    expected: String,
}
#[test]
fn exact_swift_extended_workflow_stages_and_archive() {
    let cases: Vec<Case> = serde_json::from_slice(include_bytes!(
        "fixtures/swift-extended-workflow-results.json"
    ))
    .unwrap();
    let archive =
        WorkflowArchive::decode(include_bytes!("fixtures/swift-extended-workflows.json")).unwrap();
    assert_eq!(cases.len(), 5);
    assert_eq!(
        WorkflowArchive::decode(&archive.encode().unwrap()).unwrap(),
        archive
    );
    for (case, archived) in cases.iter().zip(&archive.workflows) {
        assert_eq!(&case.workflow, archived);
        assert!(archived.steps.iter().all(|s| s.supported()));
        let selection = case.selection.map(|r| Utf16Range {
            location: r[0],
            length: r[1],
        });
        let cancel = Cancellation::default();
        let calculated = preview(archived, &case.source, selection, 9, 11, &cancel).unwrap();
        assert_eq!(calculated.output(), case.expected, "{}", archived.name);
        assert_eq!(calculated.steps.len(), case.stages.len());
        for (stage, expected) in calculated.steps.iter().zip(&case.stages) {
            assert_eq!(
                &*stage.after, expected,
                "{} stage{}",
                archived.name, stage.index
            );
        }
        assert!(matches!(
            calculated.apply(&case.source, 10, 11, archived, selection, &cancel),
            Err(Error::Stale)
        ));
        let mut changed = archived.clone();
        changed.steps[0].tab_width += 1;
        assert!(matches!(
            calculated.apply(&case.source, 9, 11, &changed, selection, &cancel),
            Err(Error::Stale)
        ));
    }
}
