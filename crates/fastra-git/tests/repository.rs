use fastra_git::*;
use std::{
    ffi::{OsStr, OsString},
    fs,
    os::unix::ffi::{OsStrExt, OsStringExt},
    path::{Path, PathBuf},
    process::Command,
};
use tempfile::TempDir;

fn git(directory: &Path, args: &[&OsStr]) -> Vec<u8> {
    let output = Command::new("/usr/bin/git")
        .current_dir(directory)
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgSign=false",
            "-c",
            "core.fsmonitor=false",
        ])
        .args(args)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "Fixture")
        .env("GIT_AUTHOR_EMAIL", "fixture@example.invalid")
        .env("GIT_COMMITTER_NAME", "Fixture")
        .env("GIT_COMMITTER_EMAIL", "fixture@example.invalid")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{:?}: {:?}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
    output.stdout
}
fn cli(directory: &Path, args: &[&str]) -> Vec<u8> {
    git(directory, &args.iter().map(OsStr::new).collect::<Vec<_>>())
}
fn fixture() -> TempDir {
    let directory = tempfile::tempdir().unwrap();
    cli(directory.path(), &["init", "-q", "-b", "main"]);
    fs::write(directory.path().join("tracked"), "original\n").unwrap();
    cli(directory.path(), &["add", "--", "tracked"]);
    cli(directory.path(), &["commit", "-q", "-m", "initial"]);
    directory
}
fn adapter() -> Git {
    Git::new(PathBuf::from("/usr/bin/git")).unwrap()
}
fn discover(path: &Path) -> Repository {
    adapter()
        .discover(path, Policy::default(), &Cancellation::default())
        .unwrap()
}
#[test]
fn discovery_preserves_newline_and_non_utf8_roots() {
    let parent = tempfile::tempdir().unwrap();
    let root = parent
        .path()
        .join(OsString::from_vec(b"repo\n\xff".to_vec()));
    fs::create_dir(&root).unwrap();
    cli(&root, &["init", "-q", "-b", "main"]);
    fs::create_dir(root.join("nested")).unwrap();
    let repository = discover(&root.join("nested"));
    assert_eq!(repository.root(), root);
    let status = repository
        .status(Policy::default(), &Cancellation::default())
        .unwrap()
        .value;
    assert_eq!(status.branch.as_deref(), Some(&b"main"[..]));
    assert_eq!(status.head_oid, None);
}
#[test]
fn porcelain_preserves_staged_unstaged_rename_and_raw_names() {
    let directory = fixture();
    cli(directory.path(), &["mv", "tracked", "renamed\nwith\ttab"]);
    fs::write(
        directory.path().join("renamed\nwith\ttab"),
        "original\nmodified\n",
    )
    .unwrap();
    let raw = OsString::from_vec(b"raw\xff\nfile".to_vec());
    fs::write(directory.path().join(&raw), "untracked").unwrap();
    fs::write(directory.path().join(":(glob)*"), "literal").unwrap();
    let repository = discover(directory.path());
    let status = repository
        .status(Policy::default(), &Cancellation::default())
        .unwrap()
        .value;
    let rename = status
        .changes
        .iter()
        .find(|change| change.path.bytes() == b"renamed\nwith\ttab")
        .unwrap();
    assert_eq!(rename.xy, *b"RM");
    assert!(
        matches!(&rename.kind, ChangeKind::RenameOrCopy { original, .. } if original.bytes() == b"tracked")
    );
    assert!(status.changes.iter().any(
        |change| change.path.bytes() == raw.as_bytes() && change.kind == ChangeKind::Untracked
    ));
    let staged = repository
        .diff(
            DiffTarget::Index,
            None,
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    assert!(String::from_utf8_lossy(&staged.stdout).contains("rename to"));
    let path = RepoPath::new(b"renamed\nwith\ttab".to_vec()).unwrap();
    let unstaged = repository
        .diff(
            DiffTarget::WorkingTree,
            Some(&path),
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    assert!(String::from_utf8_lossy(&unstaged.stdout).contains("+modified"));
}
#[test]
fn raw_non_utf8_paths_are_actionable_as_exact_cli_arguments() {
    let directory = fixture();
    let raw = OsString::from_vec(b"bad\xfe.txt".to_vec());
    fs::write(directory.path().join(&raw), "first\n").unwrap();
    git(
        directory.path(),
        &[OsStr::new("add"), OsStr::new("--"), &raw],
    );
    cli(directory.path(), &["commit", "-q", "-m", "raw"]);
    fs::write(directory.path().join(&raw), "second\n").unwrap();
    let output = discover(directory.path())
        .diff(
            DiffTarget::WorkingTree,
            Some(&RepoPath::new(raw.as_bytes().to_vec()).unwrap()),
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    assert!(String::from_utf8_lossy(&output.stdout).contains("+second"));
}
#[test]
fn branch_worktree_paths_and_log_are_not_split_at_newlines() {
    let directory = fixture();
    cli(directory.path(), &["branch", "topic"]);
    let parent = tempfile::tempdir().unwrap();
    let worktree = parent.path().join("work\ntree\tpath");
    git(
        directory.path(),
        &[
            OsStr::new("worktree"),
            OsStr::new("add"),
            OsStr::new("-q"),
            worktree.as_os_str(),
            OsStr::new("topic"),
        ],
    );
    let repository = discover(directory.path());
    let branches = repository
        .branches(Policy::default(), &Cancellation::default())
        .unwrap()
        .value;
    assert_eq!(branches.len(), 2);
    assert!(branches
        .iter()
        .any(|branch| branch.full_name == b"refs/heads/main" && branch.current));
    assert!(branches
        .iter()
        .any(|branch| branch.full_name == b"refs/heads/topic"
            && branch.worktree_path == worktree.as_os_str().as_bytes()));
    let log = repository
        .log(10, Policy::default(), &Cancellation::default())
        .unwrap();
    assert!(String::from_utf8_lossy(&log.stdout).contains("initial"));
    // Auch der verknüpfte Worktree muss sein eigenes Git-Verzeichnis entdecken.
    let linked = discover(&worktree);
    assert_ne!(linked.git_directory(), repository.git_directory());
}
#[test]
fn local_remote_ahead_behind_is_read_only() {
    let directory = fixture();
    let remote = tempfile::tempdir().unwrap();
    cli(remote.path(), &["init", "--bare", "-q"]);
    git(
        directory.path(),
        &[
            OsStr::new("remote"),
            OsStr::new("add"),
            OsStr::new("fixture"),
            remote.path().as_os_str(),
        ],
    );
    cli(directory.path(), &["push", "-q", "-u", "fixture", "main"]);
    fs::write(directory.path().join("tracked"), "new\n").unwrap();
    cli(directory.path(), &["commit", "-q", "-am", "second"]);
    let status = discover(directory.path())
        .status(Policy::default(), &Cancellation::default())
        .unwrap()
        .value;
    assert_eq!(status.upstream.as_deref(), Some(&b"fixture/main"[..]));
    assert_eq!((status.ahead, status.behind), (1, 0));
    let remote_head = cli(remote.path(), &["rev-parse", "refs/heads/main"]);
    assert_ne!(remote_head, cli(directory.path(), &["rev-parse", "HEAD"]));
}
#[test]
fn malformed_and_truncated_status_is_rejected() {
    for invalid in [
        b"? path".as_slice(),
        b"2 R. N... 100644 100644 100644 abc def R100 target\0",
        b"? ../outside\0",
        b"1 XX N... 0 0 0 a b path\0",
    ] {
        assert!(parse_status(invalid).is_err());
    }
    let conflict =
        parse_status(b"u UU N... 100644 100644 100644 100644 a b c conflicted\0").unwrap();
    assert_eq!(conflict.changes[0].kind, ChangeKind::Unmerged);
}
#[test]
fn missing_git_and_real_git_errors_remain_distinct() {
    let directory = tempfile::tempdir().unwrap();
    assert_eq!(
        Git::new(PathBuf::from("/not-a-real-git"))
            .unwrap()
            .discover(
                directory.path(),
                Policy::default(),
                &Cancellation::default()
            )
            .unwrap_err(),
        Error::Unavailable
    );
    match adapter().discover(
        directory.path(),
        Policy::default(),
        &Cancellation::default(),
    ) {
        Err(Error::GitFailed(output)) => {
            assert_ne!(output.exit_code, Some(0));
            assert!(!output.stderr.is_empty());
            assert!(!output.stderr_truncated);
        }
        other => panic!("{other:?}"),
    }
}
#[test]
fn moved_or_replaced_repository_handles_are_stale() {
    let directory = fixture();
    let repository = discover(directory.path());
    fs::rename(
        directory.path().join(".git"),
        directory.path().join("previous-git"),
    )
    .unwrap();
    cli(directory.path(), &["init", "-q"]);
    assert_eq!(
        repository.status(Policy::default(), &Cancellation::default()),
        Err(Error::StaleRepository)
    );
}
#[test]
fn external_diff_is_never_launched() {
    let directory = fixture();
    cli(
        directory.path(),
        &["config", "diff.external", "/not-a-real-external-program"],
    );
    fs::write(directory.path().join("tracked"), "changed\n").unwrap();
    assert!(discover(directory.path())
        .diff(
            DiffTarget::WorkingTree,
            None,
            Policy::default(),
            &Cancellation::default()
        )
        .unwrap()
        .success());
}
