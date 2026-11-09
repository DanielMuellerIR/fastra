use fastra_core::{text_operations::TitlecaseLocale, Cancellation, Utf16Range};
use fastra_workflow::{preview, preview_with_locale, Error, WorkflowArchive};
#[test]
fn explicit_and_legacy_case_contexts_bind_apply_without_schema_changes() {
    let archive =
        WorkflowArchive::decode(include_bytes!("fixtures/titlecase-workflow-swift.json")).unwrap();
    let tr = TitlecaseLocale::from_ctype("tr_TR.UTF-8").unwrap();
    let en = TitlecaseLocale::from_ctype("en_US.UTF-8").unwrap();
    let cancel = Cancellation::default();
    let range = Some(Utf16Range {
        location: 3,
        length: 2,
    });
    for (kind, source, localized, root) in [
        ("uppercase", "😀 ii tail", "😀 İİ! tail", "😀 II! tail"),
        ("lowercase", "😀 II tail", "😀 ıı! tail", "😀 ii! tail"),
    ] {
        let mut flow = archive.workflows[0].clone();
        flow.steps[0].kind = kind.into();
        assert!(flow.steps[0].uses_text_locale());
        let encoded = serde_json::to_value(&flow).unwrap();
        assert!(encoded.get("locale").is_none());
        let legacy = preview(&flow, source, range, 4, 5, &cancel).unwrap();
        assert_eq!(legacy.output(), root);
        assert!(legacy.locale().is_none());
        assert_eq!(
            legacy.apply(source, 4, 5, &flow, range, &cancel).unwrap(),
            root
        );
        let bound = preview_with_locale(&flow, source, range, 4, 5, Some(&tr), &cancel).unwrap();
        assert_eq!(bound.output(), localized);
        assert_eq!(bound.locale(), Some(&tr));
        assert!(matches!(
            bound.apply(source, 4, 5, &flow, range, &cancel),
            Err(Error::Stale)
        ));
        assert!(matches!(
            bound.apply_with_locale(source, 4, 5, &flow, range, Some(&en), &cancel),
            Err(Error::Stale)
        ));
        assert_eq!(
            bound
                .apply_with_locale(source, 4, 5, &flow, range, Some(&tr), &cancel)
                .unwrap(),
            localized
        );
        flow.steps[0].enabled = false;
        assert!(!flow
            .steps
            .iter()
            .any(|step| step.enabled && step.uses_text_locale()));
    }
}
