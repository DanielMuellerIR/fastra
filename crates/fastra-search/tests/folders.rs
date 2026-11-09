use fastra_core::{Cancellation, SearchFlags, SearchMode, SearchRequest};
use fastra_search::{preview, Error, Request, SkipReason};
use std::path::PathBuf;
fn dir() -> tempfile::TempDir {
    tempfile::tempdir_in(std::env::var_os("FASTRA_IO_TEST_ROOT").unwrap_or_else(|| "/tmp".into()))
        .unwrap()
}
fn request(root: PathBuf) -> Request {
    Request {
        roots: vec![root],
        search: SearchRequest {
            pattern: "cat".into(),
            replacement: "dog".into(),
            mode: SearchMode::Literal,
            case_sensitive: true,
            range: None,
        },
        flags: SearchFlags::default(),
        exclusions: vec![],
        include_hidden: false,
        known_text_only: false,
    }
}
#[test]
fn planned_write_paths_exclude_unapproved_and_ineffective_inputs() {
    let d = dir();
    for (name, text) in [("a.txt", "cat"), ("b.txt", "cat"), ("c.txt", "none")] {
        std::fs::write(d.path().join(name), text).unwrap();
    }
    let c = Cancellation::default();
    let mut r = request(d.path().into());
    let p = preview(&r, 1, &c).unwrap();
    assert_eq!(p.files().len(), 3);
    assert_eq!(
        p.changed_paths(1, &[vec![0], vec![], vec![]], &c).unwrap(),
        vec![d.path().join("a.txt")]
    );
    assert!(p.changed_paths(2, &[vec![0], vec![], vec![]], &c).is_err());
    r.search.replacement = "cat".into();
    let p = preview(&r, 2, &c).unwrap();
    assert!(p
        .changed_paths(2, &[vec![0], vec![0], vec![]], &c)
        .unwrap()
        .is_empty());
}
#[test]
fn raw_filenames_work_without_unicode_exclusions_and_are_explicit_with_them() {
    use std::{ffi::OsString, os::unix::ffi::OsStringExt};
    let d = dir();
    let path = d.path().join(OsString::from_vec(b"raw-\xff.txt".to_vec()));
    std::fs::write(&path, "cat").unwrap();
    let c = Cancellation::default();
    let mut r = request(d.path().into());
    r.known_text_only = true;
    let p = preview(&r, 1, &c).unwrap();
    assert_eq!(p.files().len(), 1);
    assert_eq!(p.files()[0].path(), path);
    let mut tx = p.apply(1, &[vec![0]], &c).unwrap().unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), b"dog");
    tx.undo(&c).unwrap();
    tx.discard(&c).unwrap();
    r.exclusions = vec!["*.log".into()];
    let p = preview(&r, 2, &c).unwrap();
    assert!(p.files().is_empty());
    assert_eq!(p.skipped()[0].path, path);
    assert_eq!(p.skipped()[0].reason, SkipReason::NonUnicodePath);
    assert_eq!(std::fs::read(&path).unwrap(), b"cat");
}
#[test]
fn nested_codec_preservation_selective_apply_and_verified_undo() {
    let dir = dir();
    let sub = dir.path().join("sub");
    std::fs::create_dir(&sub).unwrap();
    let a = dir.path().join("a");
    let b = sub.join("b");
    std::fs::write(&a, b"\xef\xbb\xbfcat cat\r\n").unwrap();
    std::fs::write(&b, [0xff, 0xfe, b'c', 0, b'a', 0, b't', 0]).unwrap();
    let c = Cancellation::default();
    let p = preview(&request(dir.path().into()), 7, &c).unwrap();
    assert_eq!(p.matches(), 3);
    assert_eq!(p.files().len(), 2);
    assert_eq!(p.files()[0].after(&[1], &c).unwrap(), "cat dog\r\n");
    let mut tx = p.apply(7, &[vec![1], vec![0]], &c).unwrap().unwrap();
    assert_eq!(std::fs::read(&a).unwrap(), b"\xef\xbb\xbfcat dog\r\n");
    assert_eq!(
        std::fs::read(&b).unwrap(),
        [0xff, 0xfe, b'd', 0, b'o', 0, b'g', 0]
    );
    tx.undo(&c).unwrap();
    tx.discard(&c).unwrap();
    assert_eq!(std::fs::read(&a).unwrap(), b"\xef\xbb\xbfcat cat\r\n");
}
#[test]
fn external_change_in_unchecked_input_blocks_all_writes() {
    let d = dir();
    let a = d.path().join("a");
    let b = d.path().join("b");
    std::fs::write(&a, "cat").unwrap();
    std::fs::write(&b, "cat").unwrap();
    let c = Cancellation::default();
    let p = preview(&request(d.path().into()), 1, &c).unwrap();
    std::fs::write(&b, "other").unwrap();
    assert!(p.apply(1, &[vec![0], vec![]], &c).is_err());
    assert_eq!(std::fs::read_to_string(a).unwrap(), "cat");
}
#[test]
fn directory_changes_generation_and_invalid_approval_are_rejected() {
    let d = dir();
    std::fs::write(d.path().join("a"), "cat cat").unwrap();
    let c = Cancellation::default();
    let p = preview(&request(d.path().into()), 1, &c).unwrap();
    assert!(matches!(p.apply(2, &[vec![0]], &c), Err(Error::Stale)));
    assert!(p.apply(1, &[vec![1, 0]], &c).is_err());
    std::fs::write(d.path().join("new"), "cat").unwrap();
    assert!(matches!(p.apply(1, &[vec![0]], &c), Err(Error::Stale)));
}
#[test]
fn overlapping_roots_hidden_globs_and_nfc() {
    let d = dir();
    let sub = d.path().join("src");
    std::fs::create_dir(&sub).unwrap();
    for name in ["a.txt", "b.json", ".hidden", "cafe\u{301}.txt"] {
        std::fs::write(sub.join(name), "cat").unwrap();
    }
    let mut r = request(d.path().into());
    r.roots.push(sub);
    r.exclusions = vec![".json".into(), "café.txt".into()];
    let p = preview(&r, 1, &Cancellation::default()).unwrap();
    assert_eq!(p.files().len(), 1);
    assert!(p.files()[0].path().ends_with("a.txt"));
    r.exclusions = vec![
        "src/**".into(),
        "a.txt".into(),
        ".json".into(),
        "café.txt".into(),
    ];
    assert_eq!(
        preview(&r, 1, &Cancellation::default()).unwrap().matches(),
        0
    );
}
#[test]
fn symlink_fifo_binary_and_long_line_are_visible_skips() {
    use std::os::unix::{ffi::OsStrExt, fs::symlink};
    let d = dir();
    std::fs::write(d.path().join("text"), "cat").unwrap();
    symlink("text", d.path().join("link")).unwrap();
    symlink(d.path(), d.path().join("loop")).unwrap();
    std::fs::write(d.path().join("binary"), b"cat\0").unwrap();
    std::fs::write(d.path().join("long"), "cat".repeat(30_000)).unwrap();
    let fifo = std::ffi::CString::new(d.path().join("pipe").as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    let p = preview(&request(d.path().into()), 1, &Cancellation::default()).unwrap();
    assert_eq!(p.matches(), 1);
    assert_eq!(p.skipped().len(), 5);
    assert!(p.skipped().iter().any(|s| s.reason == SkipReason::LongLine));
}
#[test]
fn cancellation_and_match_limit_never_yield_partial_preview() {
    let d = dir();
    std::fs::write(d.path().join("text"), "cat ".repeat(10_001)).unwrap();
    let c = Cancellation::default();
    assert!(preview(&request(d.path().into()), 1, &c).is_err());
    c.cancel();
    assert!(matches!(
        preview(&request(d.path().into()), 1, &c),
        Err(Error::Core(fastra_core::Error::Cancelled))
    ));
}
#[test]
fn folder_query_range_is_forbidden() {
    let d = dir();
    let mut r = request(d.path().into());
    r.search.range = Some(fastra_core::Utf16Range {
        location: 0,
        length: 0,
    });
    assert!(matches!(
        preview(&r, 0, &Cancellation::default()),
        Err(Error::InvalidRoots)
    ));
}

#[test]
fn nonmatching_input_is_retained_until_apply() {
    let d = dir();
    let a = d.path().join("a");
    let b = d.path().join("b");
    std::fs::write(&a, "cat").unwrap();
    std::fs::write(&b, "none").unwrap();
    let c = Cancellation::default();
    let p = preview(&request(d.path().into()), 1, &c).unwrap();
    assert_eq!(p.files().len(), 2);
    std::fs::write(&b, "cat").unwrap();
    assert!(p.apply(1, &[vec![0], vec![]], &c).is_err());
    assert_eq!(std::fs::read_to_string(a).unwrap(), "cat");
}
#[test]
fn replacement_storage_has_an_aggregate_budget() {
    let d = dir();
    for i in 0..17 {
        std::fs::write(d.path().join(format!("{i}")), "cat").unwrap();
    }
    let mut r = request(d.path().into());
    r.search.replacement = "x".repeat(8 * 1024 * 1024);
    assert!(matches!(
        preview(&r, 1, &Cancellation::default()),
        Err(Error::Limit)
    ));
}

#[test]
fn project_file_sets_filter_before_read_and_keep_verified_apply_undo() {
    let d = dir();
    std::fs::create_dir(d.path().join("src")).unwrap();
    std::fs::create_dir(d.path().join("other")).unwrap();
    for name in ["src/a.txt", "src/b.log", "one.txt", "other/b.txt"] {
        std::fs::write(d.path().join(name), "cat\r\n").unwrap();
    }
    std::os::unix::fs::symlink(d.path().join("other"), d.path().join("linked")).unwrap();
    use std::os::unix::ffi::OsStringExt;
    std::fs::write(
        d.path()
            .join(std::ffi::OsString::from_vec(b"outside-\xff.txt".to_vec())),
        "cat",
    )
    .unwrap();
    let mut r = request(d.path().into());
    r.exclusions = vec!["*.log".into()];
    let c = Cancellation::default();
    let p = fastra_search::preview_selected(&r, Some(&["src".into(), "one.txt".into()]), 9, &c)
        .unwrap();
    assert_eq!(
        p.files()
            .iter()
            .map(|f| f.path().strip_prefix(d.path()).unwrap().to_owned())
            .collect::<Vec<_>>(),
        vec![PathBuf::from("one.txt"), PathBuf::from("src/a.txt")]
    );
    assert!(
        p.skipped().is_empty(),
        "unselected raw paths do not become skipped search inputs"
    );
    let mut tx = p.apply(9, &[vec![0], vec![0]], &c).unwrap().unwrap();
    for name in ["one.txt", "src/a.txt"] {
        assert_eq!(std::fs::read(d.path().join(name)).unwrap(), b"dog\r\n");
    }
    for name in ["src/b.log", "other/b.txt"] {
        assert_eq!(std::fs::read(d.path().join(name)).unwrap(), b"cat\r\n");
    }
    tx.undo(&c).unwrap();
    tx.discard(&c).unwrap();
    assert!(fastra_search::preview_selected(&r, Some(&[]), 9, &c).is_err());
    assert!(fastra_search::preview_selected(&r, Some(&["../other".into()]), 9, &c).is_err());
    let p = fastra_search::preview_selected(&r, Some(&["linked".into()]), 9, &c).unwrap();
    assert!(p.files().is_empty());
    assert_eq!(p.skipped()[0].reason, SkipReason::LinkOrSpecial);
}
