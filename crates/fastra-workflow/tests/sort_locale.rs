use fastra_core::{text_operations::TitlecaseLocale, Cancellation};
use fastra_workflow::{preview, preview_with_locale, Error, Workflow, WorkflowArchive};
fn flow(kind: &str) -> Workflow {
    let archive =
        WorkflowArchive::decode(include_bytes!("fixtures/titlecase-workflow-swift.json")).unwrap();
    let mut flow = archive.workflows[0].clone();
    flow.steps.truncate(1);
    flow.steps[0].kind = kind.into();
    flow
}
#[test]
fn locale_sort_preserves_legacy_root_and_binds_apply_without_schema_changes() {
    let sv = TitlecaseLocale::from_ctype("sv_SE").unwrap();
    let en = TitlecaseLocale::from_ctype("en_US").unwrap();
    let cancel = Cancellation::default();
    let source = "ä\nz\na\r\n";
    for (kind, expected, root) in [
        ("sortAscending", "a\nz\nä\r\n", "a\nä\nz\r\n"),
        ("sortDescending", "ä\nz\na\r\n", "z\nä\na\r\n"),
    ] {
        let flow = flow(kind);
        assert!(flow.steps[0].uses_text_locale());
        assert!(serde_json::to_value(&flow).unwrap().get("locale").is_none());
        let legacy = preview(&flow, source, None, 4, 5, &cancel).unwrap();
        assert_eq!(legacy.output(), root);
        assert!(legacy.locale().is_none());
        let bound = preview_with_locale(&flow, source, None, 4, 5, Some(&sv), &cancel).unwrap();
        assert_eq!(bound.output(), expected);
        assert_eq!(bound.locale(), Some(&sv));
        assert_eq!(bound.steps[0].after.as_ref(), expected);
        assert!(matches!(
            bound.apply(source, 4, 5, &flow, None, &cancel),
            Err(Error::Stale)
        ));
        assert!(matches!(
            bound.apply_with_locale(source, 4, 5, &flow, None, Some(&en), &cancel),
            Err(Error::Stale)
        ));
        assert_eq!(
            bound
                .apply_with_locale(source, 4, 5, &flow, None, Some(&sv), &cancel)
                .unwrap(),
            expected
        );
    }
}
#[test]
fn unchanged_sort_is_still_locale_bound_and_disabled_sort_needs_no_context() {
    let locale = TitlecaseLocale::from_ctype("en_US").unwrap();
    let other = TitlecaseLocale::from_ctype("de_DE").unwrap();
    let cancel = Cancellation::default();
    let mut flow = flow("sortAscending");
    let bound = preview_with_locale(&flow, "a\nb", None, 1, 1, Some(&locale), &cancel).unwrap();
    assert_eq!(bound.output(), "a\nb");
    assert!(matches!(
        bound.apply_with_locale("a\nb", 1, 1, &flow, None, Some(&other), &cancel),
        Err(Error::Stale)
    ));
    flow.steps[0].enabled = false;
    assert!(!flow
        .steps
        .iter()
        .any(|step| step.enabled && step.uses_text_locale()));
    let reverse = fastra_workflow::Step::new("reverseLines").unwrap();
    flow.steps.push(reverse);
    assert_eq!(
        preview(&flow, "b\na", None, 1, 1, &cancel)
            .unwrap()
            .output(),
        "a\nb"
    );
}

#[test]
fn exact_utf16_workflow_selection_preserves_surroundings_and_mixed_endings() {
    let locale = TitlecaseLocale::from_ctype("sv_SE").unwrap();
    let cancel = Cancellation::default();
    let flow = flow("sortAscending");
    let selection = Some(fastra_core::Utf16Range {
        location: 9,
        length: 6,
    });
    let source = "😀 head\r\nz\r\nä\na\r\ntail";
    let bound =
        preview_with_locale(&flow, source, selection, 1, 2, Some(&locale), &cancel).unwrap();
    assert_eq!(bound.output(), "😀 head\r\na\r\nz\nä\r\ntail");
    assert_eq!(
        bound
            .apply_with_locale(source, 1, 2, &flow, selection, Some(&locale), &cancel)
            .unwrap(),
        bound.output()
    );
    assert!(matches!(
        bound.apply_with_locale(source, 1, 2, &flow, None, Some(&locale), &cancel),
        Err(Error::Stale)
    ));
}
