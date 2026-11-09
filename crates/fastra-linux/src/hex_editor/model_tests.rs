use super::*;

struct ParseCase {
    text: &'static str,
    expected: usize,
    values: Option<&'static [u8]>,
}
enum ReferenceAction {
    Edit { offset: usize, text: &'static str },
    Undo,
    Redo,
}
struct ReferenceState {
    revision: u64,
    dirty: bool,
    can_undo: bool,
    can_redo: bool,
    changes: &'static [Change],
    output: &'static [u8],
    rows: &'static [&'static str],
    page_offset: usize,
    page: &'static [u8],
}
struct ReferenceStep {
    action: ReferenceAction,
    changed: bool,
    invalid: bool,
    state: ReferenceState,
}
struct ReferenceScenario {
    name: &'static str,
    source: &'static [u8],
    initial: ReferenceState,
    steps: &'static [ReferenceStep],
}
include!("../../tests/hex-reference/reference.rs");

fn assert_state(session: &Session, expected: &ReferenceState, name: &str) {
    assert_eq!(session.revision(), expected.revision, "{name}");
    assert_eq!(session.dirty(), expected.dirty, "{name}");
    assert_eq!(session.can_undo(), expected.can_undo, "{name}");
    assert_eq!(session.can_redo(), expected.can_redo, "{name}");
    assert_eq!(session.changes().as_slice(), expected.changes, "{name}");
    for (row, text) in expected.rows.iter().enumerate() {
        assert_eq!(session.row(row * 16).unwrap(), *text, "{name}");
    }
    assert_eq!(
        session.page(expected.page_offset, 24).unwrap(),
        expected.page,
        "{name}"
    );
    let frozen = session.frozen(session.revision()).unwrap();
    assert_eq!(frozen.revision(), session.revision());
    assert_eq!(frozen.changes(), expected.changes);
    assert_eq!(frozen.output().unwrap(), expected.output, "{name}");
    assert_eq!(
        session.output(session.revision()).unwrap(),
        expected.output,
        "{name}"
    );
}
fn line(value: u8) -> String {
    [value; 16]
        .iter()
        .map(|v| format!("{v:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

#[test]
fn actual_swift_parser_cases_include_signs_and_whitespace_clusters() {
    for case in PARSE_CASES {
        let actual = parse_row(case.text, case.expected);
        match case.values {
            Some(bytes) => assert_eq!(actual.unwrap().as_slice(), bytes, "{:?}", case.text),
            None => assert!(actual.is_err(), "{:?}: {actual:?}", case.text),
        }
    }
    assert_eq!(WHITESPACE_SUFFIX_RANGES, EXPECTED_WHITESPACE_SUFFIX);
}
#[test]
fn actual_swift_sessions_match_rows_pages_deltas_and_history() {
    for case in SESSION_CASES {
        let mut session = Session::new(Arc::from(case.source)).unwrap();
        assert_state(&session, &case.initial, case.name);
        for (step_number, step) in case.steps.iter().enumerate() {
            let name = format!("{} step {step_number}", case.name);
            match step.action {
                ReferenceAction::Edit { offset, text } => {
                    let result = session.edit_row(offset, text);
                    if step.invalid {
                        assert!(result.is_err(), "{name}");
                    } else {
                        assert_eq!(result.unwrap(), step.changed, "{name}");
                    }
                }
                ReferenceAction::Undo => assert_eq!(session.undo(), step.changed, "{name}"),
                ReferenceAction::Redo => assert_eq!(session.redo(), step.changed, "{name}"),
            }
            assert_state(&session, &step.state, &name);
            assert_eq!(session.source(), case.source, "{name}");
        }
    }
}
#[test]
fn frozen_plan_shares_source_but_retains_its_own_immutable_delta() {
    let source: Arc<[u8]> = vec![0; 16].into();
    let mut session = Session::new(source.clone()).unwrap();
    let initial = session.frozen(0).unwrap();
    assert!(Arc::ptr_eq(&initial.source, &source));
    session.edit_row(0, &line(1)).unwrap();
    let edited = session.frozen(1).unwrap();
    session.edit_row(0, &line(2)).unwrap();
    assert_eq!(initial.output().unwrap(), vec![0; 16]);
    assert_eq!(edited.output().unwrap(), vec![1; 16]);
    assert_eq!(session.output(2).unwrap(), vec![2; 16]);
    assert_eq!(edited.revision(), 1);
    assert!(matches!(session.frozen(1), Err(Error::Stale)));
    assert!(matches!(session.output(1), Err(Error::Stale)));
    assert!(Arc::ptr_eq(&edited.source, &source));
}
#[test]
fn rebase_requires_a_new_host_epoch_even_when_revision_numbers_repeat() {
    let mut old = Session::new(Arc::from([0; 16])).unwrap();
    old.edit_row(0, &line(1)).unwrap();
    let plan = old.frozen(1).unwrap();
    let mut rebased = Session::new(plan.output().unwrap().into()).unwrap();
    rebased.edit_row(0, &line(2)).unwrap();
    assert_eq!(plan.revision(), rebased.revision());
    assert_ne!(plan.output().unwrap(), rebased.output(1).unwrap());
    // Genau deshalb bindet der Host zusätzlich Snapshot und eine erneuerte State-Epoch.
}
#[test]
fn offsets_partial_rows_and_page_lengths_are_bounded() {
    let mut session = Session::new(Arc::from((0u8..17).collect::<Vec<_>>())).unwrap();
    assert_eq!(session.row(16).unwrap(), "10");
    assert!(session.edit_row(16, "+F").unwrap());
    assert_eq!(session.page(15, 4096).unwrap(), [15, 15]);
    assert!(session.page(17, 4096).unwrap().is_empty());
    let revision = session.revision();
    let bytes = session.output(revision).unwrap();
    for offset in [1, 17, 32, usize::MAX] {
        assert_eq!(session.row(offset), Err(Error::InvalidOffset));
        assert_eq!(session.edit_row(offset, "00"), Err(Error::InvalidOffset));
    }
    assert_eq!(session.page(18, 0), Err(Error::InvalidOffset));
    assert_eq!(session.page(0, 4097), Err(Error::InvalidOffset));
    assert_eq!(session.revision(), revision);
    assert_eq!(session.output(revision).unwrap(), bytes);
    let empty = Session::new(Arc::from([])).unwrap();
    assert!(empty.page(0, 4096).unwrap().is_empty());
    assert_eq!(empty.row(0), Err(Error::InvalidOffset));
}
#[test]
fn changed_byte_limit_is_atomic_and_allows_updates_within_existing_changes() {
    let mut session = Session::new(vec![0; MAX_CHANGES + 16].into()).unwrap();
    for offset in (0..MAX_CHANGES).step_by(16) {
        assert!(session.edit_row(offset, &line(255)).unwrap());
    }
    let revision = session.revision();
    let original = session.output(revision).unwrap();
    assert_eq!(session.edit_row(MAX_CHANGES, &line(1)), Err(Error::Limit));
    assert_eq!(session.revision(), revision);
    assert_eq!(session.output(revision).unwrap(), original);
    assert!(session.edit_row(0, &line(254)).unwrap());
    assert_eq!(session.changes().len(), MAX_CHANGES);
    assert!(session.changes().iter().all(|c| c.old == 0));
    assert!(session.undo());
    assert_eq!(session.output(session.revision()).unwrap(), original);
}
#[test]
fn history_limit_noops_errors_and_redo_forks_do_not_drop_actions() {
    let mut session = Session::new(Arc::from([0; 16])).unwrap();
    for index in 0..MAX_HISTORY {
        assert!(session
            .edit_row(0, &line(if index % 2 == 0 { 1 } else { 2 }))
            .unwrap());
    }
    let revision = session.revision();
    assert_eq!(session.edit_row(0, &line(2)), Ok(false));
    assert_eq!(session.edit_row(0, "bad"), Err(Error::InvalidRow));
    assert_eq!(session.edit_row(0, &line(3)), Err(Error::Limit));
    assert_eq!(session.revision(), revision);
    assert!(session.undo());
    let undone = session.revision();
    assert!(session.can_redo());
    assert_eq!(session.edit_row(0, &line(1)), Ok(false));
    assert_eq!(session.edit_row(0, "GG"), Err(Error::InvalidRow));
    assert_eq!(session.revision(), undone);
    assert!(session.can_redo());
    assert!(session.edit_row(0, &line(3)).unwrap());
    assert!(!session.can_redo());
    assert!(!session.redo());
    for _ in 0..MAX_HISTORY {
        assert!(session.undo());
    }
    assert!(!session.undo());
    assert!(!session.dirty());
    assert!(session.can_redo());
    for _ in 0..MAX_HISTORY {
        assert!(session.redo());
    }
    assert!(!session.redo());
    assert_eq!(session.page(0, 16).unwrap(), [3; 16]);
}
#[test]
fn source_and_input_limits_are_explicit_without_modifying_a_session() {
    let maximum: Arc<[u8]> = vec![0; MAX_SOURCE].into();
    assert!(Session::new(maximum).is_ok());
    assert!(matches!(
        Session::new(vec![0; MAX_SOURCE + 1].into()),
        Err(Error::Limit)
    ));
    let mut session = Session::new(Arc::from([0; 16])).unwrap();
    session.edit_row(0, &line(1)).unwrap();
    session.undo();
    let revision = session.revision();
    assert!(session.can_redo());
    assert_eq!(
        session.edit_row(0, &" ".repeat(MAX_ROW_TEXT + 1)),
        Err(Error::Limit)
    );
    assert_eq!(session.revision(), revision);
    assert!(session.can_redo());
    assert_eq!(session.page(0, 16).unwrap(), [0; 16]);
}
