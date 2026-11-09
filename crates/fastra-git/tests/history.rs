use fastra_git::*;
use std::{fs, os::unix::ffi::OsStringExt, path::Path, process::Command};
fn git(root: &Path, args: &[&str]) -> String {
    let out = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(out.status.success(), "{args:?}: {:?}", out);
    String::from_utf8(out.stdout).unwrap().trim().into()
}
fn setup() -> tempfile::TempDir {
    let t = tempfile::tempdir().unwrap();
    git(t.path(), &["init", "-q", "-b", "main"]);
    git(t.path(), &["config", "user.name", "Synthetic"]);
    git(
        t.path(),
        &["config", "user.email", "synthetic@example.invalid"],
    );
    git(t.path(), &["config", "commit.gpgsign", "false"]);
    t
}
fn commit(root: &Path, msg: &str) -> String {
    git(root, &["add", "-A"]);
    git(root, &["commit", "-qm", msg]);
    git(root, &["rev-parse", "HEAD"])
}
fn repo(root: &Path) -> Repository {
    Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(root, Policy::default(), &Cancellation::default())
        .unwrap()
}
#[test]
fn roots_renames_raw_paths_and_immutable_unicode_crlf_pairs() {
    let t = setup();
    let r = t.path();
    let raw = std::ffi::OsString::from_vec(b"raw-\xff\n.txt".to_vec());
    fs::write(r.join(&raw), "Grüße 🚀\r\nlast\r\n").unwrap();
    let first = commit(r, "initial");
    let repository = repo(r);
    let changes = repository
        .commit_changes(&first, 0, Policy::default(), &Cancellation::default())
        .unwrap();
    assert!(changes.parent.is_none());
    assert_eq!(
        changes.changes()[0].new_path.bytes(),
        raw.as_encoded_bytes()
    );
    let pair = changes
        .pair(0, Policy::default(), &Cancellation::default())
        .unwrap();
    assert_eq!(pair.before.text(), Some(""));
    assert_eq!(pair.after.text(), Some("Grüße 🚀\r\nlast\r\n"));
    fs::rename(r.join(&raw), r.join("renamed.txt")).unwrap();
    let next = commit(r, "rename");
    let renamed = repository
        .commit_changes(&next, 0, Policy::default(), &Cancellation::default())
        .unwrap();
    assert!(renamed.changes()[0].status.starts_with('R'));
    assert_eq!(
        renamed.changes()[0].old_path.bytes(),
        raw.as_encoded_bytes()
    );
    assert_eq!(renamed.changes()[0].new_path.bytes(), b"renamed.txt");
    fs::write(r.join("renamed.txt"), "working change").unwrap();
    assert_eq!(
        changes
            .pair(0, Policy::default(), &Cancellation::default())
            .unwrap()
            .after
            .bytes,
        pair.after.bytes
    );
    let history = repository
        .history(200, Policy::default(), &Cancellation::default())
        .unwrap();
    assert_eq!(history.commits.len(), 2);
    assert!(String::from_utf8_lossy(&history.graph.stdout).contains("rename"));
}
#[test]
fn merge_parent_choice_is_explicit() {
    let t = setup();
    let r = t.path();
    fs::write(r.join("base"), "base").unwrap();
    commit(r, "base");
    git(r, &["checkout", "-qb", "side"]);
    fs::write(r.join("side"), "side").unwrap();
    let side = commit(r, "side");
    git(r, &["checkout", "-q", "main"]);
    fs::write(r.join("main"), "main").unwrap();
    let main = commit(r, "main");
    git(r, &["merge", "--no-ff", "-qm", "merge", "side"]);
    let merge = git(r, &["rev-parse", "HEAD"]);
    let repository = repo(r);
    let a = repository
        .commit_changes(&merge, 0, Policy::default(), &Cancellation::default())
        .unwrap();
    let b = repository
        .commit_changes(&merge, 1, Policy::default(), &Cancellation::default())
        .unwrap();
    assert_eq!(a.parent, Some(main));
    assert_eq!(b.parent, Some(side));
    assert_eq!(a.changes()[0].new_path.bytes(), b"side");
    assert_eq!(b.changes()[0].new_path.bytes(), b"main");
    assert!(repository
        .commit_changes(&merge, 2, Policy::default(), &Cancellation::default())
        .is_err());
}
#[test]
fn binary_deletion_cancel_and_size_limits_are_honest() {
    let t = setup();
    let r = t.path();
    fs::write(r.join("binary"), [0, 255, 1]).unwrap();
    let initial = commit(r, "binary");
    let repository = repo(r);
    let changed = repository
        .commit_changes(&initial, 0, Policy::default(), &Cancellation::default())
        .unwrap();
    assert!(changed
        .pair(0, Policy::default(), &Cancellation::default())
        .unwrap()
        .after
        .text()
        .is_none());
    fs::remove_file(r.join("binary")).unwrap();
    let deleted = commit(r, "delete");
    let deletion = repository
        .commit_changes(&deleted, 0, Policy::default(), &Cancellation::default())
        .unwrap();
    assert!(deletion
        .pair(0, Policy::default(), &Cancellation::default())
        .unwrap()
        .after
        .oid
        .is_none());
    fs::write(r.join("huge"), vec![b'x'; 1024 * 1024 + 1]).unwrap();
    let huge = commit(r, "huge");
    assert!(repository
        .commit_changes(&huge, 0, Policy::default(), &Cancellation::default())
        .unwrap()
        .pair(0, Policy::default(), &Cancellation::default())
        .is_err());
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(matches!(
        repository.history(10, Policy::default(), &cancel),
        Err(Error::Cancelled(_))
    ));
    assert!(repository
        .history(201, Policy::default(), &Cancellation::default())
        .is_err());
}

#[test]
fn history_never_rebinds_a_replaced_repository_or_git_replace_blob() {
    let t = setup();
    let r = t.path();
    fs::write(r.join("file"), "original").unwrap();
    let initial = commit(r, "initial");
    let repository = repo(r);
    let history = repository
        .history(20, Policy::default(), &Cancellation::default())
        .unwrap();
    let changes = history
        .commit_changes(0, 0, Policy::default(), &Cancellation::default())
        .unwrap();
    let original_oid = changes
        .pair(0, Policy::default(), &Cancellation::default())
        .unwrap()
        .after
        .oid
        .unwrap();
    fs::write(r.join("file"), "replacement").unwrap();
    git(r, &["add", "-A"]);
    let replacement_oid = git(r, &["rev-parse", ":file"]);
    git(r, &["replace", &original_oid, &replacement_oid]);
    assert_eq!(
        repository
            .commit_changes(&initial, 0, Policy::default(), &Cancellation::default())
            .unwrap()
            .pair(0, Policy::default(), &Cancellation::default())
            .unwrap()
            .after
            .text(),
        Some("original")
    );
    fs::rename(r.join(".git"), r.join("old-git")).unwrap();
    git(r, &["init", "-q"]);
    assert!(history
        .commit_changes(0, 0, Policy::default(), &Cancellation::default())
        .is_err());
}

#[test]
fn symlink_gitlink_and_promisor_objects_never_open_foreign_files_or_transport() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let t = setup();
    let r = t.path();
    let foreign = tempfile::tempdir().unwrap();
    fs::write(foreign.path().join("private"), "foreign contents").unwrap();
    fs::write(r.join("file"), "base").unwrap();
    let initial = commit(r, "base");
    symlink(foreign.path().join("private"), r.join("link")).unwrap();
    git(r, &["add", "-A"]);
    git(
        r,
        &[
            "update-index",
            "--add",
            "--cacheinfo",
            &format!("160000,{initial},module"),
        ],
    );
    git(r, &["commit", "-qm", "links"]);
    let linked = git(r, &["rev-parse", "HEAD"]);
    let repository = repo(r);
    let changes = repository
        .commit_changes(&linked, 0, Policy::default(), &Cancellation::default())
        .unwrap();
    for (i, c) in changes.changes().iter().enumerate() {
        let pair = changes
            .pair(i, Policy::default(), &Cancellation::default())
            .unwrap();
        assert!(pair.after.text().is_none());
        if c.new_path.bytes() == b"link" {
            assert_eq!(pair.after.mode, "120000");
            assert_eq!(
                pair.after.bytes,
                foreign
                    .path()
                    .join("private")
                    .as_os_str()
                    .as_encoded_bytes()
            );
        } else {
            assert_eq!(pair.after.mode, "160000");
            assert_eq!(pair.after.oid, Some(initial.clone()));
        }
    }
    let original = repository
        .commit_changes(&initial, 0, Policy::default(), &Cancellation::default())
        .unwrap();
    let oid = original
        .pair(0, Policy::default(), &Cancellation::default())
        .unwrap()
        .after
        .oid
        .unwrap();
    let helper = r.join("transport");
    let flag = r.join("transport-ran");
    fs::write(
        &helper,
        format!("#!/bin/sh\nprintf unsafe > '{}'\nexit 1\n", flag.display()),
    )
    .unwrap();
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
    git(r, &["config", "core.repositoryformatversion", "1"]);
    git(r, &["config", "extensions.partialclone", "origin"]);
    git(r, &["config", "remote.origin.promisor", "true"]);
    git(
        r,
        &[
            "config",
            "remote.origin.url",
            &format!("ext::{}", helper.display()),
        ],
    );
    git(r, &["config", "protocol.ext.allow", "always"]);
    fs::remove_file(r.join(".git/objects").join(&oid[..2]).join(&oid[2..])).unwrap();
    assert!(original
        .pair(0, Policy::default(), &Cancellation::default())
        .is_err());
    assert!(!flag.exists());
    fs::write(r.join("file"), "dirty source").unwrap();
    assert!(repository
        .diff(
            DiffTarget::WorkingTree,
            Some(&RepoPath::new(b"file".to_vec()).unwrap()),
            Policy::default(),
            &Cancellation::default()
        )
        .is_err());
    assert!(!flag.exists());
    fs::remove_file(
        r.join(".git/objects")
            .join(&initial[..2])
            .join(&initial[2..]),
    )
    .unwrap();
    assert!(repository
        .log(20, Policy::default(), &Cancellation::default())
        .is_err());
    assert!(!flag.exists());
    // Positivkontrolle: derselbe ungeschützte CLI-Aufruf würde den lokalen Sentinel starten.
    let uncontrolled = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(r)
        .args(["cat-file", "-s", &oid])
        .env("GIT_ALLOW_PROTOCOL", "ext")
        .env_remove("GIT_NO_LAZY_FETCH")
        .output()
        .unwrap();
    assert!(!uncontrolled.status.success());
    assert!(
        flag.exists(),
        "promisor fixture must actually attempt transport without the guard"
    );
    assert_eq!(
        fs::read_to_string(foreign.path().join("private")).unwrap(),
        "foreign contents"
    );
}
