use super::*;
use std::{os::unix::fs::PermissionsExt, process::Command, time::Duration};
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    a: PathBuf,
    b: PathBuf,
    repo: Repository,
}
fn git(path: &Path, args: &[&str]) -> Vec<u8> {
    let out = Command::new("/usr/bin/git")
        .current_dir(path)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{:?}: {}",
        args,
        String::from_utf8_lossy(&out.stderr)
    );
    out.stdout
}
fn fixture() -> Fixture {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("work");
    let a = temp.path().join("a.git");
    let b = temp.path().join("b.git");
    fs::create_dir(&root).unwrap();
    git(&root, &["init", "-b", "main"]);
    git(&root, &["config", "user.email", "test@example.invalid"]);
    git(&root, &["config", "user.name", "Test"]);
    fs::write(root.join("file"), "one\n").unwrap();
    git(&root, &["add", "file"]);
    git(&root, &["commit", "-m", "initial"]);
    for p in [&a, &b] {
        git(
            temp.path(),
            &[
                "clone",
                "--bare",
                root.to_str().unwrap(),
                p.to_str().unwrap(),
            ],
        );
    }
    git(&root, &["remote", "add", "origin", a.to_str().unwrap()]);
    git(&root, &["remote", "add", "second", b.to_str().unwrap()]);
    let repo = Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(&root, Policy::default(), &Cancellation::default())
        .unwrap();
    Fixture {
        _temp: temp,
        root,
        a,
        b,
        repo,
    }
}
fn run(f: &Fixture, selection: FetchSelection, prune: bool) -> FetchReport {
    f.repo
        .prepare_fetch(
            selection,
            prune,
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap()
        .execute(Policy::default(), &Cancellation::default(), &mut |_, _| {})
        .unwrap()
}
#[test]
fn one_all_and_prune_preserve_worktree_head_and_index() {
    let f = fixture();
    let head = git(&f.root, &["rev-parse", "HEAD"]);
    let index = fs::read(f.root.join(".git/index")).unwrap();
    let out = run(&f, FetchSelection::Remote(b"origin".to_vec()), false);
    assert!(out.success());
    assert_eq!(out.attempts.len(), 1);
    assert!(!git(&f.root, &["for-each-ref", "refs/remotes/origin/main"]).is_empty());
    assert!(git(&f.root, &["for-each-ref", "refs/remotes/second"]).is_empty());
    git(&f.root, &["config", "remote.second.skipFetchAll", "true"]);
    git(&f.root, &["config", "remotes.origin", "missing"]);
    assert!(run(&f, FetchSelection::All, false).success());
    assert!(!git(&f.root, &["for-each-ref", "refs/remotes/second/main"]).is_empty());
    git(&f.a, &["branch", "obsolete", "main"]);
    assert!(run(&f, FetchSelection::All, false).success());
    git(&f.a, &["branch", "-D", "obsolete"]);
    git(&f.root, &["config", "remote.origin.prune", "true"]);
    assert!(run(&f, FetchSelection::All, false).success());
    assert!(!git(&f.root, &["for-each-ref", "refs/remotes/origin/obsolete"]).is_empty());
    assert!(run(&f, FetchSelection::All, true).success());
    assert!(git(&f.root, &["for-each-ref", "refs/remotes/origin/obsolete"]).is_empty());
    assert_eq!(head, git(&f.root, &["rev-parse", "HEAD"]));
    assert_eq!(index, fs::read(f.root.join(".git/index")).unwrap());
    assert_eq!(fs::read(f.root.join("file")).unwrap(), b"one\n");
}
#[test]
fn missing_removed_and_option_like_remote_names_are_bound() {
    let f = fixture();
    assert!(f
        .repo
        .prepare_fetch(
            FetchSelection::Remote(b"missing".to_vec()),
            false,
            Policy::default(),
            &Cancellation::default()
        )
        .is_err());
    let plan = f
        .repo
        .prepare_fetch(
            FetchSelection::All,
            false,
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    git(&f.root, &["remote", "remove", "second"]);
    assert!(plan
        .execute(Policy::default(), &Cancellation::default(), &mut |_, _| {})
        .is_err());
    git(
        &f.root,
        &["config", "remote.-dash.url", f.a.to_str().unwrap()],
    );
    git(
        &f.root,
        &[
            "config",
            "remote.-dash.fetch",
            "+refs/heads/*:refs/remotes/-dash/*",
        ],
    );
    assert!(run(&f, FetchSelection::Remote(b"-dash".to_vec()), false).success());
    assert!(!git(&f.root, &["for-each-ref", "refs/remotes/-dash/main"]).is_empty());
}
#[test]
fn all_keeps_partial_failure_and_continues_other_remotes() {
    let f = fixture();
    git(
        &f.root,
        &[
            "remote",
            "set-url",
            "origin",
            f.root.join("missing.git").to_str().unwrap(),
        ],
    );
    let out = run(&f, FetchSelection::All, false);
    assert!(!out.success());
    assert_eq!(out.attempts.len(), 2);
    assert!(matches!(&out.attempts[0].result,Err(Error::GitFailed(out)) if !out.stderr.is_empty()));
    assert!(out.attempts[1].result.is_ok());
    assert!(out.remaining.is_empty());
}
#[test]
fn replaced_repository_and_concurrent_operation_never_start() {
    let f = fixture();
    let plan = f
        .repo
        .prepare_fetch(
            FetchSelection::All,
            false,
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    let lease = f.repo.try_operation().unwrap();
    assert!(plan
        .execute(Policy::default(), &Cancellation::default(), &mut |_, _| {})
        .is_err());
    drop(lease);
    fs::rename(f.root.join(".git"), f.root.join(".git-old")).unwrap();
    git(&f.root, &["init", "-b", "main"]);
    assert!(matches!(
        plan.execute(Policy::default(), &Cancellation::default(), &mut |_, _| {}),
        Err(Error::StaleRepository)
    ));
}
fn slow(f: &Fixture) {
    let script = f.root.join("slow-upload-pack");
    fs::write(
        &script,
        "#!/bin/sh\nprintf 'fetch ready\\n' >&2\nsleep 30\n",
    )
    .unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
    git(
        &f.root,
        &[
            "config",
            "remote.origin.uploadpack",
            script.to_str().unwrap(),
        ],
    );
}
#[test]
fn cancellation_is_live_and_stops_later_remotes() {
    let f = fixture();
    slow(&f);
    let cancel = Cancellation::default();
    let mut seen = Vec::new();
    let report = f
        .repo
        .prepare_fetch(FetchSelection::All, false, Policy::default(), &cancel)
        .unwrap()
        .execute(Policy::default(), &cancel, &mut |remote, b| {
            assert_eq!(remote, b"origin");
            seen.extend_from_slice(b);
            cancel.cancel();
        })
        .unwrap();
    assert_eq!(report.attempts.len(), 1);
    assert_eq!(report.remaining, vec![b"second".to_vec()]);
    assert!(matches!(&report.attempts[0].result,Err(Error::Cancelled(out)) if out.stderr==seen));
    assert!(seen.starts_with(b"fetch ready"));
    assert!(!report.success());
}
#[test]
fn timeout_and_output_limit_preserve_real_diagnostics() {
    let f = fixture();
    slow(&f);
    let cancel = Cancellation::default();
    let plan = f
        .repo
        .prepare_fetch(FetchSelection::All, false, Policy::default(), &cancel)
        .unwrap();
    let report = plan
        .execute(
            Policy {
                timeout: Duration::from_millis(180),
                ..Policy::default()
            },
            &cancel,
            &mut |_, _| {},
        )
        .unwrap();
    assert!(
        matches!(&report.attempts[0].result,Err(Error::TimedOut(out)) if !out.stderr.is_empty())
    );
    let report = plan
        .execute(
            Policy {
                stderr_bytes: 5,
                ..Policy::default()
            },
            &cancel,
            &mut |_, _| {},
        )
        .unwrap();
    assert!(
        matches!(&report.attempts[0].result,Err(Error::OutputLimit(out)) if out.stderr.len()==5&&out.stderr_truncated)
    );
    assert_eq!(report.remaining.len(), 1);
}
#[test]
fn read_api_keeps_network_disabled_and_names_are_configuration_only() {
    let f = fixture();
    assert!(f.b.is_dir());
    let names = f
        .repo
        .remotes(Policy::default(), &Cancellation::default())
        .unwrap();
    assert_eq!(names.value, vec![b"origin".to_vec(), b"second".to_vec()]);
    git(&f.root, &["remote", "remove", "origin"]);
    git(&f.root, &["remote", "remove", "second"]);
    assert!(f
        .repo
        .remotes(Policy::default(), &Cancellation::default())
        .unwrap()
        .value
        .is_empty());
    assert!(f
        .repo
        .prepare_fetch(
            FetchSelection::All,
            false,
            Policy::default(),
            &Cancellation::default()
        )
        .is_err());
}

#[test]
fn linked_worktrees_share_the_same_operation_lease() {
    let f = fixture();
    let linked = f._temp.path().join("linked");
    git(
        &f.root,
        &["worktree", "add", "-b", "linked", linked.to_str().unwrap()],
    );
    let other = Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(&linked, Policy::default(), &Cancellation::default())
        .unwrap();
    let lease = f.repo.try_operation().unwrap();
    assert!(other.try_operation().is_err());
    drop(lease);
    assert!(other.try_operation().is_ok());
}

#[test]
fn changed_common_directory_cannot_redirect_a_prepared_fetch() {
    let f = fixture();
    let linked = f._temp.path().join("linked");
    git(
        &f.root,
        &["worktree", "add", "-b", "linked", linked.to_str().unwrap()],
    );
    let repository = Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(&linked, Policy::default(), &Cancellation::default())
        .unwrap();
    let plan = repository
        .prepare_fetch(
            FetchSelection::Remote(b"origin".to_vec()),
            false,
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    let before = git(&f.b, &["for-each-ref"]);
    fs::write(
        repository.git_directory().join("commondir"),
        format!("{}\n", f.b.display()),
    )
    .unwrap();
    assert!(matches!(
        plan.execute(Policy::default(), &Cancellation::default(), &mut |_, _| {}),
        Err(Error::StaleRepository)
    ));
    assert_eq!(before, git(&f.b, &["for-each-ref"]));
}

fn quick_identity(repository: &Repository) -> Result<(u64, u64), Error> {
    let repository = repository.clone();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(repository.operation_identity());
    });
    rx.recv_timeout(Duration::from_secs(1))
        .expect("commondir inspection must not block")
}

#[test]
fn commondir_fifo_and_symlinks_fail_without_waiting() {
    use std::{
        ffi::CString,
        os::unix::{ffi::OsStrExt, fs::symlink},
    };
    let f = fixture();
    let expected = f.repo.operation_identity().unwrap();
    let common = f.repo.git_directory().join("commondir");
    assert_eq!(quick_identity(&f.repo).unwrap(), expected);
    let name = CString::new(common.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    assert!(matches!(
        quick_identity(&f.repo),
        Err(Error::StaleRepository)
    ));
    fs::remove_file(&common).unwrap();
    let target = f._temp.path().join("common-target");
    fs::write(&target, format!("{}\n", f.repo.git_directory().display())).unwrap();
    for target in [target, f._temp.path().join("missing-target")] {
        symlink(target, &common).unwrap();
        assert!(matches!(
            quick_identity(&f.repo),
            Err(Error::StaleRepository)
        ));
        fs::remove_file(&common).unwrap();
    }
    assert_eq!(quick_identity(&f.repo).unwrap(), expected);
}

#[test]
fn commondir_requires_a_regular_bounded_nonempty_file() {
    let f = fixture();
    let common = f.repo.git_directory().join("commondir");
    fs::create_dir(&common).unwrap();
    assert!(matches!(
        quick_identity(&f.repo),
        Err(Error::StaleRepository)
    ));
    fs::remove_dir(&common).unwrap();
    fs::write(&common, vec![b'x'; 4097]).unwrap();
    assert!(matches!(
        quick_identity(&f.repo),
        Err(Error::InvalidInput("Git common-directory path limit"))
    ));
    for bytes in [b"".as_slice(), b"\n".as_slice(), b"bad\0path".as_slice()] {
        fs::write(&common, bytes).unwrap();
        assert!(matches!(
            quick_identity(&f.repo),
            Err(Error::StaleRepository)
        ));
    }
}

#[test]
fn common_directory_swap_after_first_fetch_blocks_the_second_start() {
    let f = fixture();
    let linked = f._temp.path().join("linked");
    git(
        &f.root,
        &["worktree", "add", "-b", "linked", linked.to_str().unwrap()],
    );
    let repository = Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(&linked, Policy::default(), &Cancellation::default())
        .unwrap();
    let plan = repository
        .prepare_fetch(
            FetchSelection::All,
            false,
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    git(
        &f.b,
        &["config", "remote.second.url", f.a.to_str().unwrap()],
    );
    git(
        &f.b,
        &[
            "config",
            "remote.second.fetch",
            "+refs/heads/*:refs/remotes/second/*",
        ],
    );
    let before = git(&f.b, &["for-each-ref"]);
    let mut swapped = false;
    let mut second_observed = false;
    let report = plan
        .execute(
            Policy::default(),
            &Cancellation::default(),
            &mut |remote, _bytes| {
                if remote == b"second" {
                    second_observed = true;
                }
                if remote == b"origin" && !swapped {
                    fs::write(
                        repository.git_directory().join("commondir"),
                        format!("{}\n", f.b.display()),
                    )
                    .unwrap();
                    swapped = true;
                }
            },
        )
        .unwrap();
    assert!(swapped, "first fetch must produce real progress");
    assert!(!second_observed, "second fetch must never start");
    assert_eq!(report.attempts.len(), 2);
    assert!(
        report.attempts[0].result.is_ok(),
        "{:?}",
        report.attempts[0]
    );
    assert!(matches!(
        report.attempts[1].result,
        Err(Error::StaleRepository)
    ));
    assert!(!report.success());
    assert_eq!(before, git(&f.b, &["for-each-ref"]));
}
