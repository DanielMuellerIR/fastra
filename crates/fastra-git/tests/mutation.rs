use fastra_git::*;
use std::{
    ffi::{OsStr, OsString},
    fs,
    os::unix::{
        ffi::OsStringExt,
        fs::{symlink, PermissionsExt},
    },
    path::{Path, PathBuf},
    process::Command,
};
use tempfile::TempDir;
fn cli(path: &Path, args: &[&OsStr]) -> Vec<u8> {
    let out = Command::new("/usr/bin/git")
        .current_dir(path)
        .args(args)
        .env_remove("GIT_DIR")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_WORK_TREE")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "Fixture")
        .env("GIT_AUTHOR_EMAIL", "fixture@example.invalid")
        .env("GIT_COMMITTER_NAME", "Fixture")
        .env("GIT_COMMITTER_EMAIL", "fixture@example.invalid")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out.stdout
}
fn git(path: &Path, args: &[&str]) -> Vec<u8> {
    cli(path, &args.iter().map(OsStr::new).collect::<Vec<_>>())
}
fn fixture(initial: bool) -> TempDir {
    let dir = tempfile::tempdir().unwrap();
    git(dir.path(), &["init", "-q", "-b", "main"]);
    git(dir.path(), &["config", "commit.gpgSign", "false"]);
    if initial {
        fs::write(dir.path().join("tracked"), "first\n").unwrap();
        git(dir.path(), &["add", "--", "tracked"]);
        git(dir.path(), &["commit", "-q", "-m", "initial"]);
    }
    dir
}
fn repo(path: &Path) -> Repository {
    Git::new(PathBuf::from("/usr/bin/git"))
        .unwrap()
        .discover(path, Policy::default(), &Cancellation::default())
        .unwrap()
}
fn raw(bytes: &[u8]) -> RepoPath {
    RepoPath::new(bytes.to_vec()).unwrap()
}
fn prepare(r: &Repository, action: IndexAction, paths: &[RepoPath]) -> IndexPreview {
    r.prepare_index(action, paths, Policy::default(), &Cancellation::default())
        .unwrap()
}
fn apply(r: &Repository, p: IndexPreview) {
    r.apply_index(p, Policy::default(), &Cancellation::default())
        .unwrap()
}
fn index(path: &Path) -> Option<Vec<u8>> {
    fs::read(path.join(".git/index")).ok()
}
fn no_lock(path: &Path) {
    assert!(!path.join(".git/index.lock").exists());
    assert!(!fs::read_dir(path.join(".git")).unwrap().any(|p| p
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with("fastra-index-")));
}
#[test]
fn exact_preview_stages_raw_names_binary_symlink_and_deletion_without_touching_worktree() {
    let d = fixture(true);
    let root = d.path();
    let r = repo(root);
    fs::remove_file(root.join("tracked")).unwrap();
    let paths = [
        raw(b"tracked"),
        raw(b":(glob)*"),
        raw(b"raw\xff\nname"),
        raw(b"binary"),
        raw(b"link"),
    ];
    fs::write(root.join(":(glob)*"), "literal\n").unwrap();
    fs::write(
        root.join(OsString::from_vec(b"raw\xff\nname".to_vec())),
        "raw\n",
    )
    .unwrap();
    fs::write(root.join("binary"), [0, 255, 0, 1, 2]).unwrap();
    symlink("missing-target", root.join("link")).unwrap();
    let original = index(root);
    let preview = prepare(&r, IndexAction::Stage, &paths);
    assert_eq!(index(root), original);
    assert!(preview
        .diff()
        .stdout
        .windows(16)
        .any(|b| b == b"GIT binary patch"));
    assert_eq!(preview.paths(), paths);
    apply(&r, preview);
    assert!(!root.join("tracked").exists());
    assert_eq!(fs::read(root.join("binary")).unwrap(), [0, 255, 0, 1, 2]);
    assert_eq!(
        fs::read_link(root.join("link")).unwrap(),
        PathBuf::from("missing-target")
    );
    assert_eq!(git(root, &["show", ":binary"]), [0, 255, 0, 1, 2]);
    assert_eq!(git(root, &["show", ":link"]), b"missing-target");
    let status = r
        .status(Policy::default(), &Cancellation::default())
        .unwrap()
        .value;
    assert_eq!(status.changes.len(), 5);
    assert!(status.changes.iter().all(|c| c.xy[1] == b'.'));
    no_lock(root);
}
#[test]
fn selected_unstage_preserves_other_staged_changes_and_working_bytes() {
    let d = fixture(true);
    let root = d.path();
    let r = repo(root);
    fs::write(root.join("tracked"), "edited\n").unwrap();
    fs::write(root.join("other"), "keep\n").unwrap();
    apply(
        &r,
        prepare(&r, IndexAction::Stage, &[raw(b"tracked"), raw(b"other")]),
    );
    let before = index(root);
    let p = prepare(&r, IndexAction::Unstage, &[raw(b"tracked")]);
    assert_eq!(index(root), before);
    apply(&r, p);
    assert_eq!(git(root, &["show", ":tracked"]), b"first\n");
    assert_eq!(git(root, &["show", ":other"]), b"keep\n");
    assert_eq!(fs::read(root.join("tracked")).unwrap(), b"edited\n");
    no_lock(root);
}
#[test]
fn initial_branch_stage_and_unstage_keep_file_without_creating_a_commit() {
    let d = fixture(false);
    let root = d.path();
    fs::write(root.join("new"), "initial\n").unwrap();
    let r = repo(root);
    let p = prepare(&r, IndexAction::Stage, &[raw(b"new")]);
    assert!(p.head_oid().is_none());
    assert_eq!(p.branch(), Some(&b"main"[..]));
    assert!(index(root).is_none());
    apply(&r, p);
    apply(&r, prepare(&r, IndexAction::Unstage, &[raw(b"new")]));
    assert_eq!(fs::read(root.join("new")).unwrap(), b"initial\n");
    assert!(r
        .status(Policy::default(), &Cancellation::default())
        .unwrap()
        .value
        .head_oid
        .is_none());
    no_lock(root);
}
#[test]
fn rename_unstage_explicitly_expands_original_and_destination() {
    let d = fixture(true);
    let root = d.path();
    fs::rename(root.join("tracked"), root.join("renamed")).unwrap();
    let r = repo(root);
    apply(
        &r,
        prepare(&r, IndexAction::Stage, &[raw(b"tracked"), raw(b"renamed")]),
    );
    let p = prepare(&r, IndexAction::Unstage, &[raw(b"renamed")]);
    assert!(p.paths().contains(&raw(b"tracked")));
    assert!(p.paths().contains(&raw(b"renamed")));
    apply(&r, p);
    assert!(git(root, &["diff", "--cached"]).is_empty());
    assert_eq!(fs::read(root.join("renamed")).unwrap(), b"first\n");
    assert!(!root.join("tracked").exists());
    no_lock(root);
}
#[test]
fn changed_and_same_bytes_replaced_working_file_invalidate_approval() {
    for same in [false, true] {
        let d = fixture(true);
        let root = d.path();
        fs::write(root.join("tracked"), "approved\n").unwrap();
        let r = repo(root);
        let p = prepare(&r, IndexAction::Stage, &[raw(b"tracked")]);
        let before = index(root);
        fs::write(
            root.join("replacement"),
            if same { "approved\n" } else { "later\n" },
        )
        .unwrap();
        fs::rename(root.join("replacement"), root.join("tracked")).unwrap();
        assert!(matches!(
            r.apply_index(p, Policy::default(), &Cancellation::default()),
            Err(Error::StalePreview)
        ));
        assert_eq!(index(root), before);
        no_lock(root);
    }
}
#[test]
fn external_index_and_same_oid_branch_change_are_not_overwritten() {
    for branch in [false, true] {
        let d = fixture(true);
        let root = d.path();
        fs::write(root.join("tracked"), "approved\n").unwrap();
        let r = repo(root);
        let p = prepare(&r, IndexAction::Stage, &[raw(b"tracked")]);
        if branch {
            git(root, &["branch", "other"]);
            git(root, &["symbolic-ref", "HEAD", "refs/heads/other"]);
        } else {
            fs::write(root.join("other"), "external\n").unwrap();
            git(root, &["add", "--", "other"]);
        }
        let before = index(root);
        assert!(matches!(
            r.apply_index(p, Policy::default(), &Cancellation::default()),
            Err(Error::StalePreview)
        ));
        assert_eq!(index(root), before);
        no_lock(root);
    }
}
#[test]
fn cancellation_and_foreign_lock_leave_index_and_foreign_lock_intact() {
    let d = fixture(true);
    let root = d.path();
    fs::write(root.join("tracked"), "approved\n").unwrap();
    let r = repo(root);
    let p = prepare(&r, IndexAction::Stage, &[raw(b"tracked")]);
    let before = index(root);
    let c = Cancellation::default();
    c.cancel();
    assert!(matches!(
        r.apply_index(p, Policy::default(), &c),
        Err(Error::Cancelled(_))
    ));
    assert_eq!(index(root), before);
    no_lock(root);
    let p = prepare(&r, IndexAction::Stage, &[raw(b"tracked")]);
    fs::write(root.join(".git/index.lock"), "foreign lock").unwrap();
    assert!(r
        .apply_index(p, Policy::default(), &Cancellation::default())
        .is_err());
    assert_eq!(
        fs::read(root.join(".git/index.lock")).unwrap(),
        b"foreign lock"
    );
    assert_eq!(index(root), before);
}
#[test]
fn configured_filter_and_index_hook_are_rejected_before_execution() {
    for filter in [false, true] {
        let d = fixture(true);
        let root = d.path();
        fs::write(root.join("tracked"), "approved\n").unwrap();
        let marker = root.join("executed");
        if filter {
            git(
                root,
                &[
                    "config",
                    "filter.fixture.clean",
                    &format!("touch {}", marker.display()),
                ],
            );
            fs::write(root.join(".gitattributes"), "tracked filter=fixture\n").unwrap();
        } else {
            let hook = root.join(".git/hooks/post-index-change");
            fs::write(&hook, format!("#!/bin/sh\ntouch '{}'\n", marker.display())).unwrap();
            fs::set_permissions(hook, fs::Permissions::from_mode(0o700)).unwrap();
        }
        let before = index(root);
        assert!(matches!(
            repo(root).prepare_index(
                IndexAction::Stage,
                &[raw(b"tracked")],
                Policy::default(),
                &Cancellation::default()
            ),
            Err(Error::InvalidInput(_))
        ));
        assert!(!marker.exists());
        assert_eq!(index(root), before);
        no_lock(root);
    }
}
#[test]
fn directories_and_fifos_never_become_recursive_or_blocking_stage_targets() {
    let d = fixture(true);
    let root = d.path();
    fs::create_dir(root.join("folder")).unwrap();
    fs::write(root.join("folder/child"), "child").unwrap();
    let r = repo(root);
    let before = index(root);
    assert!(r
        .prepare_index(
            IndexAction::Stage,
            &[raw(b"folder")],
            Policy::default(),
            &Cancellation::default()
        )
        .is_err());
    fs::remove_file(root.join("tracked")).unwrap();
    let full = std::ffi::CString::new(root.join("tracked").as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(full.as_ptr(), 0o600) }, 0);
    assert!(r
        .prepare_index(
            IndexAction::Stage,
            &[raw(b"tracked")],
            Policy::default(),
            &Cancellation::default()
        )
        .is_err());
    assert_eq!(index(root), before);
    no_lock(root);
}
#[test]
fn git_output_limits_and_split_index_are_honest() {
    let d = fixture(true);
    let root = d.path();
    fs::write(root.join("tracked"), "approved\n").unwrap();
    let r = repo(root);
    let before = index(root);
    let tiny = Policy {
        stdout_bytes: 8,
        ..Policy::default()
    };
    assert!(matches!(
        r.prepare_index(
            IndexAction::Stage,
            &[raw(b"tracked")],
            tiny,
            &Cancellation::default()
        ),
        Err(Error::OutputLimit(_))
    ));
    assert_eq!(index(root), before);
    no_lock(root);
    git(root, &["update-index", "--split-index"]);
    apply(&r, prepare(&r, IndexAction::Stage, &[raw(b"tracked")]));
    assert_eq!(git(root, &["show", ":tracked"]), b"approved\n");
    no_lock(root);
}

#[test]
fn linked_worktree_uses_its_own_index_and_retains_main_index() {
    let d = fixture(true);
    let parent = tempfile::tempdir().unwrap();
    let work = parent.path().join("linked");
    cli(
        d.path(),
        &[
            OsStr::new("worktree"),
            OsStr::new("add"),
            OsStr::new("-b"),
            OsStr::new("linked"),
            work.as_os_str(),
        ],
    );
    let main_before = index(d.path());
    fs::write(work.join("tracked"), "linked approved\n").unwrap();
    let r = repo(&work);
    apply(&r, prepare(&r, IndexAction::Stage, &[raw(b"tracked")]));
    assert_eq!(git(&work, &["show", ":tracked"]), b"linked approved\n");
    assert_eq!(index(d.path()), main_before);
    assert_eq!(fs::read(d.path().join("tracked")).unwrap(), b"first\n");
}
#[test]
fn replaced_repository_does_not_receive_an_old_approval() {
    let parent = tempfile::tempdir().unwrap();
    let original = fixture(true);
    let path = parent.path().join("repo");
    fs::rename(original.path(), &path).unwrap();
    fs::write(path.join("tracked"), "approved\n").unwrap();
    let r = repo(&path);
    let p = prepare(&r, IndexAction::Stage, &[raw(b"tracked")]);
    fs::rename(&path, parent.path().join("old-repo")).unwrap();
    fs::create_dir(&path).unwrap();
    git(&path, &["init", "-q", "-b", "main"]);
    let before = index(&path);
    assert!(matches!(
        r.apply_index(p, Policy::default(), &Cancellation::default()),
        Err(Error::StaleRepository)
    ));
    assert_eq!(index(&path), before);
    no_lock(&path);
}

#[test]
fn externally_pruned_preview_objects_fail_before_index_publication() {
    let d = fixture(true);
    let root = d.path();
    fs::write(root.join("tracked"), "new preview-only blob\n").unwrap();
    let r = repo(root);
    let preview = prepare(&r, IndexAction::Stage, &[raw(b"tracked")]);
    let before = index(root);
    git(root, &["prune", "--expire=now"]);
    assert!(matches!(
        r.apply_index(preview, Policy::default(), &Cancellation::default()),
        Err(Error::GitFailed(_))
    ));
    assert_eq!(index(root), before);
    assert_eq!(
        fs::read(root.join("tracked")).unwrap(),
        b"new preview-only blob\n"
    );
    no_lock(root);
}

#[test]
fn fifo_index_is_rejected_before_git_status_can_wait_on_it() {
    let d = fixture(true);
    let root = d.path();
    let r = repo(root);
    fs::rename(root.join(".git/index"), root.join(".git/index.original")).unwrap();
    let name =
        std::ffi::CString::new(root.join(".git/index").as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    assert!(matches!(
        r.index_status(Policy::default(), &Cancellation::default()),
        Err(Error::InvalidInput(_))
    ));
    assert!(matches!(
        r.prepare_index(
            IndexAction::Stage,
            &[raw(b"tracked")],
            Policy::default(),
            &Cancellation::default()
        ),
        Err(Error::InvalidInput(_))
    ));
    no_lock(root);
}

fn ancestry_fixture(command: &str) -> (TempDir, Repository) {
    let directory = fixture(true);
    let root = directory.path();
    fs::create_dir_all(root.join("nested/watched")).unwrap();
    fs::create_dir_all(root.join("nested/alternate")).unwrap();
    fs::create_dir(root.join(".test-evidence")).unwrap();
    fs::write(root.join("nested/watched/tracked"), "initial nested\n").unwrap();
    git(root, &["add", "--", "nested/watched/tracked"]);
    git(root, &["commit", "-q", "-m", "nested initial"]);
    fs::write(root.join("nested/watched/tracked"), "approved nested\n").unwrap();
    fs::write(
        root.join("nested/alternate/tracked"),
        "FOREIGN DIRECTORY BYTES\n",
    )
    .unwrap();
    let wrapper = root.join(".test-evidence/git");
    fs::write(&wrapper,r##"#!/bin/sh
set -u
command=$(cat .test-evidence/command)
for arg in "$@"; do
  if [ "$arg" = "$command" ] && [ -e .test-evidence/armed ]; then
    rm .test-evidence/armed
    mv nested/watched nested/original-parent
    mv nested/alternate nested/watched
    /usr/bin/git "$@"
    result=$?
    if [ "$command" = add ]; then /usr/bin/git show :nested/watched/tracked > .test-evidence/captured; fi
    mv nested/watched nested/alternate
    mv nested/original-parent nested/watched
    printf executed > .test-evidence/ran
    exit "$result"
  fi
done
exec /usr/bin/git "$@"
"##).unwrap();
    fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(root.join(".test-evidence/command"), command).unwrap();
    // Ein alter Verzeichnis-mtime macht den Austausch unabhängig von Uhrgranularität/Last beobachtbar.
    let name = std::ffi::CString::new(root.join("nested").as_os_str().as_encoded_bytes()).unwrap();
    let times = [libc::timespec {
        tv_sec: 946684800,
        tv_nsec: 0,
    }; 2];
    assert_eq!(
        unsafe { libc::utimensat(libc::AT_FDCWD, name.as_ptr(), times.as_ptr(), 0) },
        0
    );
    let repository = Git::new(wrapper)
        .unwrap()
        .discover(root, Policy::default(), &Cancellation::default())
        .unwrap();
    (directory, repository)
}
#[test]
fn parent_exchange_and_restoration_during_native_add_cannot_publish_foreign_bytes() {
    use std::os::unix::fs::MetadataExt;
    let (directory, repository) = ancestry_fixture("add");
    let root = directory.path();
    fs::write(root.join(".test-evidence/armed"), "").unwrap();
    let before = index(root);
    let file = root.join("nested/watched/tracked");
    let metadata = fs::metadata(&file).unwrap();
    let result = repository.prepare_index(
        IndexAction::Stage,
        &[raw(b"nested/watched/tracked")],
        Policy::default(),
        &Cancellation::default(),
    );
    assert!(matches!(result, Err(Error::StalePreview)), "{result:?}");
    assert_eq!(
        fs::read(root.join(".test-evidence/captured")).unwrap(),
        b"FOREIGN DIRECTORY BYTES\n"
    );
    let after = fs::metadata(&file).unwrap();
    assert_eq!(
        (
            metadata.ino(),
            metadata.ctime(),
            metadata.ctime_nsec(),
            metadata.mtime(),
            metadata.mtime_nsec()
        ),
        (
            after.ino(),
            after.ctime(),
            after.ctime_nsec(),
            after.mtime(),
            after.mtime_nsec()
        )
    );
    assert_eq!(fs::read(file).unwrap(), b"approved nested\n");
    assert_eq!(index(root), before);
    no_lock(root);
}
#[test]
fn parent_exchange_and_restoration_after_initial_preflight_is_caught_before_publish() {
    use std::os::unix::fs::MetadataExt;
    let (directory, repository) = ancestry_fixture("diff");
    let root = directory.path();
    let preview = prepare(
        &repository,
        IndexAction::Stage,
        &[raw(b"nested/watched/tracked")],
    );
    let before = index(root);
    let file = root.join("nested/watched/tracked");
    let metadata = fs::metadata(&file).unwrap();
    fs::write(root.join(".test-evidence/armed"), "").unwrap();
    assert!(matches!(
        repository.apply_index(preview, Policy::default(), &Cancellation::default()),
        Err(Error::StalePreview)
    ));
    assert!(root.join(".test-evidence/ran").exists());
    let after = fs::metadata(&file).unwrap();
    assert_eq!(
        (
            metadata.ino(),
            metadata.ctime(),
            metadata.ctime_nsec(),
            metadata.mtime(),
            metadata.mtime_nsec()
        ),
        (
            after.ino(),
            after.ctime(),
            after.ctime_nsec(),
            after.mtime(),
            after.mtime_nsec()
        )
    );
    assert_eq!(fs::read(file).unwrap(), b"approved nested\n");
    assert_eq!(index(root), before);
    no_lock(root);
}

#[test]
fn deep_and_wide_ancestry_exceeds_budget_without_publishing_an_index() {
    let directory = fixture(true);
    let root = directory.path();
    let repository = repo(root);
    let before = index(root);
    let deep = (0..65).map(|_| "nested").collect::<Vec<_>>().join("/");
    fs::create_dir_all(root.join(&deep)).unwrap();
    fs::write(root.join(&deep).join("file"), "x").unwrap();
    assert!(matches!(
        repository.prepare_index(
            IndexAction::Stage,
            &[raw(format!("{deep}/file").as_bytes())],
            Policy::default(),
            &Cancellation::default()
        ),
        Err(Error::InvalidInput(_))
    ));
    let mut paths = Vec::new();
    for n in 0..128 {
        let relative = format!("branch-{n}/nested/file");
        fs::create_dir_all(root.join(format!("branch-{n}/nested"))).unwrap();
        fs::write(root.join(&relative), "x").unwrap();
        paths.push(raw(relative.as_bytes()));
    }
    assert!(matches!(
        repository.prepare_index(
            IndexAction::Stage,
            &paths,
            Policy::default(),
            &Cancellation::default()
        ),
        Err(Error::InvalidInput(_))
    ));
    assert_eq!(index(root), before);
    no_lock(root);
}
