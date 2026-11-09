use super::*;
use std::{os::unix::fs::PermissionsExt, process::Command, time::Duration};
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    bare: PathBuf,
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
        "{args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out.stdout
}
fn fixture() -> Fixture {
    fixture_format(false)
}
fn fixture_format(sha256: bool) -> Fixture {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("work");
    fs::create_dir(&root).unwrap();
    git(
        &root,
        &[
            "init",
            "-b",
            "main",
            if sha256 {
                "--object-format=sha256"
            } else {
                "--object-format=sha1"
            },
        ],
    );
    for args in [
        &["config", "user.name", "Test"],
        &["config", "user.email", "test@example.invalid"],
        &["config", "commit.gpgsign", "false"],
    ] {
        git(&root, args);
    }
    fs::write(root.join("file"), "one\n").unwrap();
    git(&root, &["add", "file"]);
    git(&root, &["commit", "-qm", "initial"]);
    let bare = temp.path().join("remote.git");
    git(
        temp.path(),
        &[
            "clone",
            "--bare",
            root.to_str().unwrap(),
            bare.to_str().unwrap(),
        ],
    );
    git(&root, &["remote", "add", "origin", bare.to_str().unwrap()]);
    commit(&root, "two");
    let repo = Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(&root, Policy::default(), &Cancellation::default())
        .unwrap();
    Fixture {
        _temp: temp,
        root,
        bare,
        repo,
    }
}
fn commit(root: &Path, text: &str) {
    fs::write(root.join("file"), text).unwrap();
    git(root, &["add", "file"]);
    git(root, &["commit", "-qm", text]);
}
fn plan(f: &Fixture) -> PushPreview {
    let cancel = Cancellation::default();
    let target = f
        .repo
        .push_targets(Policy::default(), &cancel)
        .unwrap()
        .remove(0);
    f.repo
        .prepare_push(&target, Policy::default(), &cancel, &mut |_| {})
        .unwrap()
}
fn execute(p: &PushPreview) -> Result<GitOutput, Error> {
    p.execute(Policy::default(), &Cancellation::default(), &mut |_| {})
}
fn hook(path: &Path, text: &str) {
    fs::write(path, format!("#!/bin/sh\n{text}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}
#[test]
fn normal_push_uses_frozen_oid_and_preserves_local_files_index_head() {
    let f = fixture();
    let p = plan(&f);
    assert_eq!((p.ahead(), p.behind()), (1, 0));
    assert!(p.can_push());
    assert!(String::from_utf8_lossy(&p.commits.stdout).contains("two"));
    let index = fs::read(f.root.join(".git/index")).unwrap();
    let head = git(&f.root, &["rev-parse", "HEAD"]);
    let file = fs::read(f.root.join("file")).unwrap();
    assert!(execute(&p).unwrap().success());
    assert_eq!(git(&f.bare, &["rev-parse", "main"]), head);
    assert_eq!(fs::read(f.root.join(".git/index")).unwrap(), index);
    assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), head);
    assert_eq!(fs::read(f.root.join("file")).unwrap(), file);
    assert!(!f.root.join(".git/FETCH_HEAD").exists());
}
#[test]
fn new_branch_is_bound_to_exact_absence() {
    let f = fixture();
    git(&f.bare, &["update-ref", "-d", "refs/heads/main"]);
    let p = plan(&f);
    assert!(p.remote_oid().is_none());
    assert!(execute(&p).is_ok());
}
#[test]
fn new_branch_created_after_preview_rejects() {
    let f = fixture();
    let old = git(&f.bare, &["rev-parse", "main"]);
    git(&f.bare, &["update-ref", "-d", "refs/heads/main"]);
    let p = plan(&f);
    git(
        &f.bare,
        &[
            "update-ref",
            "refs/heads/main",
            std::str::from_utf8(&old).unwrap().trim(),
        ],
    );
    assert!(matches!(execute(&p), Err(Error::GitFailed(_))));
    assert_eq!(git(&f.bare, &["rev-parse", "main"]), old);
}
#[test]
fn head_and_target_changes_require_new_preview() {
    let f = fixture();
    let p = plan(&f);
    commit(&f.root, "three");
    assert_eq!(execute(&p), Err(Error::StalePreview));
    let p = plan(&f);
    git(
        &f.root,
        &["remote", "set-url", "--push", "origin", "/missing.git"],
    );
    assert_eq!(execute(&p), Err(Error::StalePreview));
}
#[test]
fn remote_race_is_rejected_by_exact_server_cas() {
    let f = fixture();
    let p = plan(&f);
    let old = git(&f.bare, &["rev-parse", "main"]);
    git(&f.bare, &["update-ref", "-d", "refs/heads/main"]);
    assert!(matches!(execute(&p), Err(Error::GitFailed(_))));
    assert!(git(&f.bare, &["for-each-ref", "refs/heads/main"]).is_empty());
    git(
        &f.bare,
        &[
            "update-ref",
            "refs/heads/main",
            std::str::from_utf8(&old).unwrap().trim(),
        ],
    );
}
#[test]
fn divergent_history_cannot_be_forced_by_normal_cas() {
    let f = fixture();
    let old = git(&f.root, &["rev-parse", "HEAD~1"]);
    git(
        &f.root,
        &[
            "checkout",
            "--detach",
            std::str::from_utf8(&old).unwrap().trim(),
        ],
    );
    commit(&f.root, "other");
    git(&f.root, &["push", f.bare.to_str().unwrap(), "HEAD:main"]);
    git(&f.root, &["checkout", "main"]);
    let p = plan(&f);
    assert_eq!(p.behind(), 1);
    assert!(!p.can_push());
    let before = git(&f.bare, &["rev-parse", "main"]);
    assert!(matches!(execute(&p), Err(Error::InvalidInput(_))));
    assert_eq!(git(&f.bare, &["rev-parse", "main"]), before);
}
#[test]
fn hooks_are_honored_and_real_output_retained() {
    let f = fixture();
    let p = plan(&f);
    hook(
        &f.root.join(".git/hooks/pre-push"),
        "echo deliberate-hook-rejection >&2; exit 1",
    );
    let Err(Error::GitFailed(out)) = execute(&p) else {
        panic!()
    };
    assert!(String::from_utf8_lossy(&out.stderr).contains("deliberate-hook-rejection"));
}
#[test]
fn live_output_cancel_and_common_directory_lease() {
    let f = fixture();
    let p = plan(&f);
    let before = git(&f.bare, &["rev-parse", "main"]);
    hook(
        &f.root.join(".git/hooks/pre-push"),
        "echo live-hook >&2; sleep 30",
    );
    let cancel = Cancellation::default();
    let token = cancel.clone();
    let out = p.execute(Policy::default(), &cancel, &mut |bytes| {
        if String::from_utf8_lossy(bytes).contains("live-hook") {
            token.cancel();
        }
    });
    assert!(matches!(out, Err(Error::Cancelled(_))));
    assert_eq!(git(&f.bare, &["rev-parse", "main"]), before);
    let lease = f.repo.try_operation().unwrap();
    assert!(matches!(execute(&p), Err(Error::InvalidInput(_))));
    drop(lease);
}
#[test]
fn time_and_output_limits_reject_without_remote_write() {
    let f = fixture();
    let p = plan(&f);
    hook(&f.root.join(".git/hooks/pre-push"), "sleep 30");
    assert!(matches!(
        p.execute(
            Policy {
                timeout: Duration::from_millis(150),
                ..Default::default()
            },
            &Cancellation::default(),
            &mut |_| {}
        ),
        Err(Error::TimedOut(_))
    ));
    hook(&f.root.join(".git/hooks/pre-push"), "yes output >&2");
    assert!(matches!(
        p.execute(
            Policy {
                stderr_bytes: 128,
                ..Default::default()
            },
            &Cancellation::default(),
            &mut |_| {}
        ),
        Err(Error::OutputLimit(_))
    ));
}
#[test]
fn multiple_addresses_and_rewrite_rules_fail_closed() {
    let f = fixture();
    git(
        &f.root,
        &[
            "config",
            "--add",
            "remote.origin.pushurl",
            f.bare.to_str().unwrap(),
        ],
    );
    git(
        &f.root,
        &["config", "--add", "remote.origin.pushurl", "/missing"],
    );
    assert!(f
        .repo
        .push_targets(Policy::default(), &Cancellation::default())
        .is_err());
    git(&f.root, &["config", "--unset-all", "remote.origin.pushurl"]);
    let target = f
        .repo
        .push_targets(Policy::default(), &Cancellation::default())
        .unwrap()
        .remove(0);
    git(&f.root, &["config", "url./missing.insteadOf", "unrelated"]);
    assert!(matches!(
        f.repo.prepare_push(
            &target,
            Policy::default(),
            &Cancellation::default(),
            &mut |_| {}
        ),
        Err(Error::InvalidInput(_))
    ));
}
#[test]
fn repository_replacement_and_non_utf8_branch_are_safe() {
    use std::os::unix::ffi::OsStrExt;
    let f = fixture();
    let branch = std::ffi::OsStr::from_bytes(b"branch-\xff");
    let out = Command::new("/usr/bin/git")
        .current_dir(&f.root)
        .args([
            std::ffi::OsStr::new("checkout"),
            std::ffi::OsStr::new("-b"),
            branch,
        ])
        .output()
        .unwrap();
    assert!(out.status.success());
    let p = plan(&f);
    assert!(execute(&p).is_ok());
    let p = plan(&f);
    fs::rename(f.root.join(".git"), f.root.join("old.git")).unwrap();
    fs::create_dir(f.root.join(".git")).unwrap();
    assert!(matches!(execute(&p), Err(Error::StaleRepository)));
}
#[test]
fn server_ref_change_inside_pre_push_is_not_overwritten() {
    let f = fixture();
    let p = plan(&f);
    let old = git(&f.bare, &["rev-parse", "main"]);
    let expected = std::str::from_utf8(&old).unwrap().trim();
    hook(
        &f.root.join(".git/hooks/pre-push"),
        &format!(
            "git --git-dir='{}' update-ref -d refs/heads/main {}",
            f.bare.display(),
            expected
        ),
    );
    assert!(matches!(execute(&p), Err(Error::GitFailed(_))));
    assert!(git(&f.bare, &["for-each-ref", "refs/heads/main"]).is_empty());
}
#[test]
fn exact_lease_cannot_turn_a_false_ff_summary_into_force() {
    let f = fixture();
    let old = git(&f.root, &["rev-parse", "HEAD~1"]);
    git(
        &f.root,
        &[
            "checkout",
            "--detach",
            std::str::from_utf8(&old).unwrap().trim(),
        ],
    );
    commit(&f.root, "diverged");
    git(&f.root, &["push", f.bare.to_str().unwrap(), "HEAD:main"]);
    git(&f.root, &["checkout", "main"]);
    let mut p = plan(&f);
    p.behind = 0;
    let before = git(&f.bare, &["rev-parse", "main"]);
    assert!(matches!(execute(&p), Err(Error::GitFailed(_))));
    assert_eq!(git(&f.bare, &["rev-parse", "main"]), before);
}
#[test]
fn command_start_rewrite_and_remote_race_cannot_redirect_bound_address() {
    let mut f = fixture();
    let script = f.root.join("git-wrapper");
    hook(&script,"for arg in \"$@\"; do if [ \"$arg\" = push ]; then /usr/bin/git config url./missing.insteadOf /tmp/; /usr/bin/git config remote.origin.pushurl /missing; fi; done\nexec /usr/bin/git \"$@\"");
    f.repo = Git::new(script)
        .unwrap()
        .discover(&f.root, Policy::default(), &Cancellation::default())
        .unwrap();
    let p = plan(&f);
    assert!(execute(&p).is_ok());
    assert_eq!(
        git(&f.bare, &["rev-parse", "main"]),
        git(&f.root, &["rev-parse", "HEAD"])
    );
}
#[test]
fn configured_follow_tags_is_not_an_extra_remote_write() {
    let f = fixture();
    git(&f.root, &["tag", "-am", "tag fixture", "unapproved"]);
    git(&f.root, &["config", "push.followTags", "true"]);
    let p = plan(&f);
    assert!(execute(&p).is_ok());
    assert!(git(&f.bare, &["for-each-ref", "refs/tags"]).is_empty());
}
#[test]
fn linked_worktrees_share_push_operation_lease() {
    let f = fixture();
    let linked = f._temp.path().join("linked");
    git(
        &f.root,
        &[
            "worktree",
            "add",
            "-b",
            "linked",
            linked.to_str().unwrap(),
            "HEAD",
        ],
    );
    let repo = Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(&linked, Policy::default(), &Cancellation::default())
        .unwrap();
    let p = plan(&f);
    let lease = repo.try_operation().unwrap();
    assert!(matches!(execute(&p), Err(Error::InvalidInput(_))));
    drop(lease);
    assert!(execute(&p).is_ok());
}
#[test]
fn preview_fetch_never_imports_tags_or_prunes_refs_from_config() {
    let f = fixture();
    git(&f.bare, &["tag", "unapproved"]);
    git(&f.root, &["config", "fetch.prune", "true"]);
    git(&f.root, &["config", "fetch.pruneTags", "true"]);
    git(&f.root, &["config", "fetch.writeCommitGraph", "true"]);
    let before = git(&f.root, &["for-each-ref"]);
    let _p = plan(&f);
    assert_eq!(git(&f.root, &["for-each-ref"]), before);
    assert!(!f.root.join(".git/FETCH_HEAD").exists());
}
#[test]
fn another_remote_with_multiple_addresses_does_not_disable_selected_target() {
    let f = fixture();
    git(
        &f.root,
        &["remote", "add", "unsupported", f.bare.to_str().unwrap()],
    );
    git(
        &f.root,
        &[
            "config",
            "--add",
            "remote.unsupported.pushurl",
            "/missing-a",
        ],
    );
    git(
        &f.root,
        &[
            "config",
            "--add",
            "remote.unsupported.pushurl",
            "/missing-b",
        ],
    );
    let cancel = Cancellation::default();
    let target = f
        .repo
        .push_target(b"origin", Policy::default(), &cancel)
        .unwrap();
    let p = f
        .repo
        .prepare_push(&target, Policy::default(), &cancel, &mut |_| {})
        .unwrap();
    assert!(execute(&p).is_ok());
}

fn divergent(f: &Fixture) {
    git(&f.root, &["checkout", "--detach", "HEAD~1"]);
    commit(&f.root, "remote-one");
    commit(&f.root, "remote-two");
    git(&f.root, &["push", f.bare.to_str().unwrap(), "HEAD:main"]);
    git(&f.root, &["checkout", "main"]);
    commit(&f.root, "local-three");
}
fn force_plan(f: &Fixture) -> Result<PushPreview, Error> {
    let cancel = Cancellation::default();
    let target = f.repo.push_target(b"origin", Policy::default(), &cancel)?;
    f.repo
        .prepare_force_push(&target, Policy::default(), &cancel, &mut |_| {})
}
#[test]
fn force_divergent_complete_lists_exact_update_and_local_state_sha1_sha256() {
    for sha256 in [false, true] {
        let f = fixture_format(sha256);
        divergent(&f);
        let normal = plan(&f);
        assert!(!normal.force_with_lease());
        assert!(!normal.can_push());
        assert!(matches!(execute(&normal), Err(Error::InvalidInput(_))));
        let p = force_plan(&f).unwrap();
        assert!(p.force_with_lease() && p.can_push());
        assert_eq!((p.ahead(), p.behind()), (2, 2));
        let outgoing = String::from_utf8_lossy(&p.commits().stdout);
        let removed = String::from_utf8_lossy(&p.removed_commits().stdout);
        assert!(outgoing.contains("two") && outgoing.contains("local-three"));
        assert!(removed.contains("remote-one") && removed.contains("remote-two"));
        assert_eq!(outgoing.lines().count(), 2);
        assert_eq!(removed.lines().count(), 2);
        assert_eq!(p.source_oid().len(), if sha256 { 64 } else { 40 });
        let files = [".git/HEAD", ".git/index", ".git/config", "file"];
        let before = files.map(|name| fs::read(f.root.join(name)).unwrap());
        let refs = git(&f.root, &["for-each-ref"]);
        assert!(execute(&p).unwrap().success());
        assert_eq!(
            git(&f.bare, &["rev-parse", "main"]),
            git(&f.root, &["rev-parse", "HEAD"])
        );
        assert_eq!(
            before,
            files.map(|name| fs::read(f.root.join(name)).unwrap())
        );
        assert_eq!(refs, git(&f.root, &["for-each-ref"]));
    }
}
#[test]
fn force_remote_move_before_and_inside_pre_push_is_rejected() {
    for inside_hook in [false, true] {
        let f = fixture();
        divergent(&f);
        let p = force_plan(&f).unwrap();
        let old = String::from_utf8(git(&f.bare, &["rev-parse", "main~1"])).unwrap();
        if inside_hook {
            hook(
                &f.root.join(".git/hooks/pre-push"),
                &format!(
                    "git --git-dir='{}' update-ref refs/heads/main {}",
                    f.bare.display(),
                    old.trim()
                ),
            );
        } else {
            git(&f.bare, &["update-ref", "refs/heads/main", old.trim()]);
        }
        assert!(matches!(execute(&p), Err(Error::GitFailed(_))));
        assert_eq!(git(&f.bare, &["rev-parse", "main"]), old.as_bytes());
    }
}
#[test]
fn force_missing_noop_and_shallow_are_refused_but_rewind_is_explicit() {
    let f = fixture();
    let p = force_plan(&f).unwrap();
    assert!(p.removed_commits().stdout.is_empty());
    assert!(execute(&p).is_ok());
    assert!(matches!(force_plan(&f), Err(Error::InvalidInput(_))));
    git(&f.bare, &["update-ref", "-d", "refs/heads/main"]);
    assert!(matches!(force_plan(&f), Err(Error::InvalidInput(_))));
    git(&f.root, &["push", "origin", "main"]);
    git(&f.root, &["reset", "--hard", "HEAD~1"]);
    let p = force_plan(&f).unwrap();
    assert_eq!((p.ahead(), p.behind()), (0, 1));
    assert!(p.can_push());
    assert!(execute(&p).is_ok());
    let shallow = f._temp.path().join("shallow");
    git(
        f._temp.path(),
        &[
            "clone",
            "--depth=1",
            "--branch=main",
            &format!("file://{}", f.bare.display()),
            shallow.to_str().unwrap(),
        ],
    );
    let repo = Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(&shallow, Policy::default(), &Cancellation::default())
        .unwrap();
    let target = repo
        .push_target(b"origin", Policy::default(), &Cancellation::default())
        .unwrap();
    assert!(matches!(
        repo.prepare_force_push(
            &target,
            Policy::default(),
            &Cancellation::default(),
            &mut |_| {}
        ),
        Err(Error::InvalidInput(
            "force push requires complete non-shallow history"
        ))
    ));
}
#[test]
fn force_keeps_live_cancel_lease_and_literal_address_after_start_drift() {
    let mut f = fixture();
    divergent(&f);
    let p = force_plan(&f).unwrap();
    let before = git(&f.bare, &["rev-parse", "main"]);
    hook(
        &f.root.join(".git/hooks/pre-push"),
        "echo force-live >&2; sleep 30",
    );
    let cancel = Cancellation::default();
    let token = cancel.clone();
    assert!(matches!(
        p.execute(Policy::default(), &cancel, &mut |b| {
            if String::from_utf8_lossy(b).contains("force-live") {
                token.cancel();
            }
        }),
        Err(Error::Cancelled(_))
    ));
    assert_eq!(git(&f.bare, &["rev-parse", "main"]), before);
    fs::remove_file(f.root.join(".git/hooks/pre-push")).unwrap();
    let lease = f.repo.try_operation().unwrap();
    assert!(execute(&p).is_err());
    drop(lease);
    let wrapper = f.root.join("git-wrapper");
    hook(&wrapper, "for arg in \"$@\"; do if [ \"$arg\" = push ]; then /usr/bin/git config url./missing.insteadOf /tmp/; /usr/bin/git config remote.origin.pushurl /missing; fi; done\nexec /usr/bin/git \"$@\"");
    f.repo = Git::new(wrapper)
        .unwrap()
        .discover(&f.root, Policy::default(), &Cancellation::default())
        .unwrap();
    let p = force_plan(&f).unwrap();
    assert!(execute(&p).is_ok());
    assert_eq!(
        git(&f.bare, &["rev-parse", "main"]),
        git(&f.root, &["rev-parse", "HEAD"])
    );
}
#[test]
fn force_full_lists_ignore_replacements_and_grafts_and_fail_closed_on_limits() {
    let f = fixture();
    divergent(&f);
    let baseline = force_plan(&f).unwrap();
    let old = std::str::from_utf8(baseline.remote_oid().unwrap()).unwrap();
    let source = std::str::from_utf8(baseline.source_oid()).unwrap();
    git(&f.root, &["replace", old, source]);
    fs::write(f.root.join(".git/info/grafts"), format!("{old} {source}\n")).unwrap();
    let p = force_plan(&f).unwrap();
    assert_eq!(p.commits(), baseline.commits());
    assert_eq!(p.removed_commits(), baseline.removed_commits());
    assert_eq!((p.ahead(), p.behind()), (2, 2));
    let normal = plan(&f);
    assert!(!normal.can_push());
    let cancel = Cancellation::default();
    let target = f
        .repo
        .push_target(b"origin", Policy::default(), &cancel)
        .unwrap();
    assert!(matches!(
        f.repo.prepare_force_push(
            &target,
            Policy {
                stdout_bytes: 64,
                ..Default::default()
            },
            &cancel,
            &mut |_| {}
        ),
        Err(Error::OutputLimit(_))
    ));
    assert!(execute(&p).is_ok());
}
#[test]
fn force_source_target_and_shallow_drift_invalidate_before_native_push() {
    let f = fixture();
    divergent(&f);
    let p = force_plan(&f).unwrap();
    let before = git(&f.bare, &["rev-parse", "main"]);
    let initial = git(&f.root, &["rev-parse", "HEAD~2"]);
    fs::write(f.root.join(".git/shallow"), &initial).unwrap();
    assert!(matches!(
        execute(&p),
        Err(Error::InvalidInput(
            "force push requires complete non-shallow history"
        ))
    ));
    fs::remove_file(f.root.join(".git/shallow")).unwrap();
    commit(&f.root, "source-changed");
    assert!(matches!(execute(&p), Err(Error::StalePreview)));
    let p = force_plan(&f).unwrap();
    git(&f.root, &["config", "remote.origin.pushurl", "/missing"]);
    assert!(matches!(execute(&p), Err(Error::StalePreview)));
    assert_eq!(git(&f.bare, &["rev-parse", "main"]), before);
}
