use fastra_core::{text_operations::TitlecaseLocale, Cancellation};
use fastra_search::{preview_workflow, WorkflowRequest};
use fastra_workflow::{Step, Workflow};
fn fixture() -> tempfile::TempDir {
    let root = std::env::var_os("FASTRA_IO_TEST_ROOT").unwrap_or_else(|| "/var/tmp".into());
    tempfile::tempdir_in(root).unwrap()
}

fn request(path: &std::path::Path) -> WorkflowRequest {
    let mut a = Step::new("replace").unwrap();
    a.find = "cat".into();
    a.replacement = "dog".into();
    WorkflowRequest {
        roots: vec![path.into()],
        files: vec![],
        exclusions: vec![],
        known_text_only: true,
        definition: Workflow {
            id: fastra_workflow::new_id().unwrap(),
            revision: fastra_workflow::new_id().unwrap(),
            name: "Disk".into(),
            steps: vec![a, Step::new("uppercase").unwrap()],
            extra: Default::default(),
        },
        locale: None,
    }
}
fn approvals(p: &fastra_search::FolderPreview) -> Vec<Vec<usize>> {
    p.files()
        .iter()
        .map(|f| (0..f.preview().matches().len()).collect())
        .collect()
}
#[test]
fn complete_stages_encoding_atomic_apply_and_undo() {
    let dir = fixture();
    let a = dir.path().join("a.txt");
    let b = dir.path().join("b.txt");
    let c = dir.path().join("c.txt");
    std::fs::write(&a, b"\xef\xbb\xbfcat\r\n").unwrap();
    let mut utf16 = vec![0xff, 0xfe];
    for u in "cat café\r\n".encode_utf16() {
        utf16.extend(u.to_le_bytes());
    }
    std::fs::write(&b, &utf16).unwrap();
    std::fs::write(&c, "NONE\n").unwrap();
    let cancel = Cancellation::default();
    let p = preview_workflow(&request(dir.path()), 7, &cancel).unwrap();
    assert_eq!(p.files().len(), 3);
    assert_eq!(p.files()[0].workflow_preview().unwrap().steps.len(), 2);
    let mut tx = p.apply(7, &approvals(&p), &cancel).unwrap().unwrap();
    assert_eq!(std::fs::read(&a).unwrap(), b"\xef\xbb\xbfDOG\r\n");
    let encoded = std::fs::read(&b).unwrap();
    assert!(encoded.starts_with(&[0xff, 0xfe]));
    assert_eq!(
        fastra_core::encoding::decode(&encoded, None)
            .unwrap()
            .text(),
        "DOG CAFÉ\r\n"
    );
    assert_eq!(tx.applied_snapshots(&cancel).unwrap().len(), 3);
    tx.undo(&cancel).unwrap();
    assert_eq!(std::fs::read(&a).unwrap(), b"\xef\xbb\xbfcat\r\n");
    assert_eq!(std::fs::read(&b).unwrap(), utf16);
    tx.discard(&cancel).unwrap();
}
#[test]
fn no_op_and_unapproved_inputs_still_block_stale_apply() {
    for name in ["b.txt", "c.txt"] {
        let dir = fixture();
        for (n, t) in [("a.txt", "cat"), ("b.txt", "cat"), ("c.txt", "NONE")] {
            std::fs::write(dir.path().join(n), t).unwrap();
        }
        let cancel = Cancellation::default();
        let p = preview_workflow(&request(dir.path()), 4, &cancel).unwrap();
        let mut approved = approvals(&p);
        approved[1].clear();
        std::fs::write(dir.path().join(name), "changed").unwrap();
        assert!(p.apply(4, &approved, &cancel).is_err());
        assert_eq!(std::fs::read(dir.path().join("a.txt")).unwrap(), b"cat");
    }
}
#[test]
fn one_file_and_whole_plan_encoding_binary_and_cancel_refusals() {
    let dir = fixture();
    let a = dir.path().join("a.txt");
    std::fs::write(&a, b"istanbul\x80").unwrap();
    let mut req = request(dir.path());
    req.roots.clear();
    req.files = vec![a.clone()];
    req.definition.steps = vec![Step::new("titlecase").unwrap()];
    req.locale = Some(TitlecaseLocale::from_ctype("tr_TR").unwrap());
    assert!(preview_workflow(&req, 0, &Cancellation::default()).is_err());
    assert_eq!(std::fs::read(&a).unwrap(), b"istanbul\x80");
    std::fs::write(&a, "cat").unwrap();
    std::fs::write(dir.path().join("bad.txt"), [0, 1, 2]).unwrap();
    assert!(preview_workflow(&request(dir.path()), 0, &Cancellation::default()).is_err());
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(preview_workflow(&req, 0, &cancel).is_err());
}

#[test]
fn changed_readonly_file_and_duplicate_explicit_inputs_refuse_the_plan() {
    use std::os::unix::fs::PermissionsExt;
    let dir = fixture();
    let a = dir.path().join("a.txt");
    std::fs::write(&a, "cat").unwrap();
    let mut req = request(dir.path());
    req.roots.clear();
    req.files = vec![a.clone(), a.clone()];
    assert!(preview_workflow(&req, 0, &Cancellation::default()).is_err());
    req.files.pop();
    std::fs::set_permissions(&a, std::fs::Permissions::from_mode(0o400)).unwrap();
    assert!(preview_workflow(&req, 0, &Cancellation::default()).is_err());
    assert_eq!(std::fs::read(&a).unwrap(), b"cat");
    std::fs::set_permissions(&a, std::fs::Permissions::from_mode(0o600)).unwrap();
}
