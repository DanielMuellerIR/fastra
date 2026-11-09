use fastra_diff_helper::*;
use std::{os::unix::fs::symlink, path::Path};
fn parse(values: &[&str]) -> Result<Option<Request>, i32> {
    Request::parse(
        &values.iter().map(|v| v.to_string()).collect::<Vec<_>>(),
        Path::new("/tmp/caller"),
    )
}
#[test]
fn literal_arguments_labels_and_relative_paths() {
    let r = parse(&[
        "--left-label",
        "--literal",
        "--read-only",
        "--focus-diff",
        "--",
        "left Ä.txt",
        "-right.txt",
    ])
    .unwrap()
    .unwrap();
    assert_eq!(r.left_label, "--literal");
    assert_eq!(r.right_label, "-right.txt");
    assert_eq!(r.left_path, "/tmp/caller/left Ä.txt");
    assert_eq!(r.right_path, "/tmp/caller/-right.txt");
    assert!(r.read_only && r.focus_diff);
    r.validate(now()).unwrap();
}
#[test]
fn only_exact_capabilities_query_has_no_request() {
    assert!(parse(&["--capabilities", "--json"]).unwrap().is_none());
    for args in [
        &["--capabilities"][..],
        &["--json", "--capabilities"][..],
        &["--merge", "--", "a", "b"][..],
    ] {
        assert_eq!(parse(args).unwrap_err(), 4);
    }
}
#[test]
fn malformed_and_duplicate_arguments_are_rejected() {
    for args in [
        &["a", "b"][..],
        &["--", "a"][..],
        &["--", "a", "b", "c"][..],
        &["--read-only", "--read-only", "--", "a", "b"][..],
        &["--left-label", "a", "--left-label", "b", "--", "a", "b"][..],
        &["--", "", "b"][..],
        &["--left-label", "bad\0label", "--", "a", "b"][..],
    ] {
        assert_eq!(parse(args).unwrap_err(), 2);
    }
}
#[test]
fn wire_requires_exact_typed_fields_and_matching_uuid() {
    let mut r = parse(&["--", "a", "b"]).unwrap().unwrap();
    r.deadline = r.deadline.floor();
    let wire = r.encode().unwrap();
    assert_eq!(Request::decode(&wire).unwrap(), r);
    let mut value = serde_json::to_value(&r).unwrap();
    value["extra"] = true.into();
    assert_eq!(Request::decode(&value.to_string()).unwrap_err(), 4);
    value.as_object_mut().unwrap().remove("extra");
    value.as_object_mut().unwrap().remove("readOnly");
    assert_eq!(Request::decode(&value.to_string()).unwrap_err(), 4);
    let mut invalid = r.clone();
    invalid.id = "not-a-uuid".into();
    assert_eq!(invalid.validate(now()), Err(2));
}
#[test]
fn deadlines_versions_nul_and_json_overhead_are_bound() {
    let r = parse(&["--", "a", "b"]).unwrap().unwrap();
    let mut x = r.clone();
    x.version = 2;
    assert_eq!(x.validate(now()), Err(4));
    for deadline in [now() - 1., now() + 12., f64::INFINITY, f64::NAN] {
        x = r.clone();
        x.deadline = deadline;
        assert_eq!(x.validate(now()), Err(6));
    }
    x = r.clone();
    x.left_path = "relative".into();
    assert_eq!(x.validate(now()), Err(2));
    x = r.clone();
    x.left_label = "\u{1}".repeat(MAX_MESSAGE / 6);
    assert_eq!(x.encode(), Err(2));
    assert_eq!(
        Request::decode(&" ".repeat(MAX_MESSAGE + 1)).unwrap_err(),
        2
    );
}
#[test]
fn open_follows_regular_symlinks_but_never_blocks_on_fifo() {
    let temp = tempfile::tempdir().unwrap();
    let left = temp.path().join("a");
    let right = temp.path().join("link");
    std::fs::write(&left, "text").unwrap();
    symlink(&left, &right).unwrap();
    let mut r = parse(&["--", "a", "b"]).unwrap().unwrap();
    r.left_path = left.to_str().unwrap().into();
    r.right_path = right.to_str().unwrap().into();
    r.validate_files().unwrap();
    r.right_path = temp.path().to_str().unwrap().into();
    assert_eq!(r.validate_files(), Err(3));
    let fifo = temp.path().join("pipe");
    let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    r.right_path = fifo.to_str().unwrap().into();
    assert_eq!(r.validate_files(), Err(3));
    std::fs::remove_file(&left).unwrap();
    assert_eq!(r.validate_files(), Err(3));
}

#[test]
fn only_local_unix_session_bus_transports_are_accepted() {
    assert!(local_bus_address("unix:path=/run/user/1000/bus"));
    assert!(local_bus_address(
        "unix:abstract=session,guid=123;unix:path=/tmp/session"
    ));
    for value in [
        "",
        "tcp:host=127.0.0.1,port=42",
        "unix:path=/tmp/a;tcp:host=example.test,port=42",
        "autolaunch:",
    ] {
        assert!(!local_bus_address(value));
    }
}

#[test]
fn uuid_spelling_does_not_create_a_second_request_identity() {
    let mut request = parse(&["--", "a", "b"]).unwrap().unwrap();
    // Diese Identitätsprobe braucht keine fehleranfällige Fließkomma-Rundreise.
    request.deadline = request.deadline.floor();
    request.id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee".into();
    let mut upper = request.clone();
    upper.id.make_ascii_uppercase();
    assert_eq!(Request::decode(&upper.encode().unwrap()).unwrap(), request);
}
