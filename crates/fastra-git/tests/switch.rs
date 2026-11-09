use fastra_git::*;
use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command, time::Duration};
use tempfile::TempDir;
fn git(p: &Path, a: &[&str]) -> Vec<u8> {
    let o = Command::new("/usr/bin/git")
        .current_dir(p)
        .args(a)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(
        o.status.success(),
        "{a:?}: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    o.stdout
}
fn fixture(format: &str) -> TempDir {
    let d = tempfile::tempdir().unwrap();
    let p = d.path();
    git(
        p,
        &[
            "init",
            "-q",
            "-b",
            "main",
            &format!("--object-format={format}"),
        ],
    );
    git(p, &["config", "user.name", "Fixture"]);
    git(p, &["config", "user.email", "fixture@example.invalid"]);
    git(p, &["config", "commit.gpgsign", "false"]);
    fs::write(p.join("file"), "main\n").unwrap();
    fs::write(p.join("keep"), "keep\n").unwrap();
    git(p, &["add", "."]);
    git(p, &["commit", "-qm", "main"]);
    git(p, &["switch", "-c", "target"]);
    fs::write(p.join("file"), "target\n").unwrap();
    fs::write(p.join("added"), "added\n").unwrap();
    git(p, &["add", "."]);
    git(p, &["commit", "-qm", "target"]);
    git(p, &["switch", "main"]);
    d
}
fn repo(p: &Path) -> Repository {
    Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(p, Policy::default(), &Cancellation::default())
        .unwrap()
}
fn prepare(r: &Repository) -> SwitchPreview {
    r.prepare_switch(
        b"refs/heads/target".to_vec(),
        Policy::default(),
        &Cancellation::default(),
    )
    .unwrap()
}
fn execute(p: SwitchPreview) -> SwitchReport {
    p.execute(Policy::default(), &Cancellation::default(), &mut |_| {})
}
fn script(p: &Path, text: &str) {
    fs::write(p, text).unwrap();
    fs::set_permissions(p, fs::Permissions::from_mode(0o700)).unwrap();
}
#[test]
fn complete_preview_and_success_preserve_nonconflicting_dirty_and_untracked() {
    let d = fixture("sha1");
    let p = d.path();
    fs::write(p.join("keep"), "staged\n").unwrap();
    git(p, &["add", "keep"]);
    fs::write(p.join("keep"), "unstaged\n").unwrap();
    fs::write(p.join("untracked"), "memory\n").unwrap();
    let r = repo(p);
    let preview = prepare(&r);
    assert!(preview.delta().stdout.windows(7).any(|s| s == b"+target"));
    assert_eq!(preview.target_oid().len(), 40);
    assert!(!preview.source().staged.stdout.is_empty());
    assert!(!preview.source().working.stdout.is_empty());
    let report = execute(preview);
    assert!(report.result.is_ok(), "{report:?}");
    assert!(report.target_reached());
    assert_eq!(fs::read(p.join("file")).unwrap(), b"target\n");
    assert_eq!(fs::read(p.join("keep")).unwrap(), b"unstaged\n");
    assert_eq!(git(p, &["show", ":keep"]), b"staged\n");
    assert_eq!(fs::read(p.join("untracked")).unwrap(), b"memory\n");
}
#[test]
fn conflicting_dirty_and_ignored_files_keep_native_protection() {
    for ignored in [false, true] {
        let d = fixture("sha1");
        let p = d.path();
        if ignored {
            git(p, &["config", "core.excludesfile", ".git/ignore-fixture"]);
            fs::write(p.join(".git/ignore-fixture"), "added\n").unwrap();
            fs::write(p.join("added"), "ignored local\n").unwrap();
        } else {
            fs::write(p.join("file"), "dirty\n").unwrap();
        }
        let preview = prepare(&repo(p));
        let report = execute(preview);
        assert!(
            matches!(report.result, Err(Error::GitFailed(_))),
            "{report:?}"
        );
        assert!(!report.target_reached());
        assert_eq!(
            fs::read(p.join(if ignored { "added" } else { "file" })).unwrap(),
            if ignored {
                b"ignored local\n".as_slice()
            } else {
                b"dirty\n"
            }
        );
    }
}
#[test]
fn preflight_rejects_head_target_index_file_and_config_drift() {
    for drift in 0..5 {
        let d = fixture("sha1");
        let p = d.path();
        let preview = prepare(&repo(p));
        match drift {
            0 => {
                git(p, &["switch", "--detach", "target"]);
            }
            1 => {
                git(p, &["update-ref", "refs/heads/target", "main"]);
            }
            2 => {
                fs::write(p.join("keep"), "staged drift").unwrap();
                git(p, &["add", "keep"]);
            }
            3 => {
                fs::write(p.join("file"), "drift").unwrap();
            }
            _ => {
                git(p, &["config", "core.autocrlf", "true"]);
            }
        }
        let before = git(p, &["rev-parse", "HEAD"]);
        let report = execute(preview);
        assert!(
            matches!(report.result, Err(Error::StalePreview)),
            "{drift} {report:?}"
        );
        assert_eq!(git(p, &["rev-parse", "HEAD"]), before);
        assert!(report.state.is_ok());
    }
}
#[test]
fn failed_head_lock_reports_already_changed_index_and_files() {
    let d = fixture("sha1");
    let p = d.path();
    let preview = prepare(&repo(p));
    fs::write(p.join(".git/HEAD.lock"), "external lock").unwrap();
    let report = execute(preview);
    assert!(
        matches!(report.result, Err(Error::GitFailed(_))),
        "{report:?}"
    );
    assert!(!report.target_reached());
    assert_eq!(fs::read(p.join("file")).unwrap(), b"target\n");
    assert_eq!(git(p, &["show", ":file"]), b"target\n");
    let state = report.state.unwrap();
    assert!(!state.staged.stdout.is_empty());
    assert_eq!(
        fs::read(p.join(".git/HEAD.lock")).unwrap(),
        b"external lock"
    );
}
#[test]
fn post_checkout_hook_error_is_not_rollback() {
    let d = fixture("sha1");
    let p = d.path();
    script(
        &p.join(".git/hooks/post-checkout"),
        "#!/bin/sh\necho native-post-checkout >&2\nexit 1\n",
    );
    let report = execute(prepare(&repo(p)));
    assert!(
        matches!(&report.result,Err(Error::GitFailed(out)) if out.stderr.windows(20).any(|b|b==b"native-post-checkout"))
    );
    assert!(report.target_reached());
    assert_eq!(fs::read(p.join("file")).unwrap(), b"target\n");
}
#[test]
fn live_cancel_after_hook_output_still_scans_actual_state() {
    let d = fixture("sha1");
    let p = d.path();
    script(
        &p.join(".git/hooks/post-checkout"),
        "#!/bin/sh\necho cancel-ready >&2\nsleep 30\n",
    );
    let c = Cancellation::default();
    let mut live = Vec::new();
    let started = std::time::Instant::now();
    let report = prepare(&repo(p)).execute(Policy::default(), &c, &mut |b| {
        live.extend_from_slice(b);
        c.cancel();
    });
    assert!(
        matches!(report.result, Err(Error::Cancelled(_))),
        "{report:?}"
    );
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(!live.is_empty());
    assert!(report.target_reached());
    assert!(report.state.is_ok());
    assert!(!p.join(".git/index.lock").exists());
}
#[test]
fn precancel_and_timeout_are_bounded_and_return_actual_state() {
    let d = fixture("sha1");
    let p = d.path();
    let preview = prepare(&repo(p));
    let c = Cancellation::default();
    c.cancel();
    let report = preview.execute(Policy::default(), &c, &mut |_| {});
    assert!(matches!(report.result, Err(Error::Cancelled(_))));
    assert!(report.state.is_ok());
    script(
        &p.join(".git/hooks/post-checkout"),
        "#!/bin/sh\necho timeout-ready >&2\nsleep 30\n",
    );
    let report = prepare(&repo(p)).execute(
        Policy {
            timeout: Duration::from_millis(180),
            ..Default::default()
        },
        &Cancellation::default(),
        &mut |_| {},
    );
    assert!(
        matches!(report.result, Err(Error::TimedOut(_))),
        "{report:?}"
    );
    assert!(report.state.is_ok());
}
#[test]
fn lease_repository_exchange_and_linked_commondir_are_checked() {
    let d = fixture("sha1");
    let p = d.path();
    let r = repo(p);
    let preview = prepare(&r);
    let lease = r.try_operation().unwrap();
    assert!(matches!(
        execute(preview).result,
        Err(Error::InvalidInput(_))
    ));
    drop(lease);
    let linked_parent = tempfile::tempdir().unwrap();
    let linked = linked_parent.path().join("linked");
    git(
        p,
        &[
            "worktree",
            "add",
            "--detach",
            linked.to_str().unwrap(),
            "main",
        ],
    );
    let lr = repo(&linked);
    let preview = prepare(&lr);
    let lease = r.try_operation().unwrap();
    assert!(matches!(
        execute(preview).result,
        Err(Error::InvalidInput(_))
    ));
    drop(lease);
    let preview = prepare(&r);
    fs::rename(p.join(".git"), p.join("oldgit")).unwrap();
    fs::create_dir(p.join(".git")).unwrap();
    assert!(execute(preview).result.is_err());
}
#[test]
fn detached_sha256_and_literal_raw_branch_targets_work() {
    for format in ["sha1", "sha256"] {
        let d = fixture(format);
        let p = d.path();
        git(p, &["switch", "--detach", "main"]);
        git(p, &["branch", "topic;literal", "target"]);
        let preview = repo(p)
            .prepare_switch(
                b"refs/heads/topic;literal".to_vec(),
                Policy::default(),
                &Cancellation::default(),
            )
            .unwrap();
        assert_eq!(
            preview.target_oid().len(),
            if format == "sha1" { 40 } else { 64 }
        );
        let report = execute(preview);
        assert!(report.result.is_ok(), "{report:?}");
        assert!(report.target_reached());
    }
}
#[test]
fn no_remote_guess_same_branch_missing_and_unborn_are_refused() {
    let d = fixture("sha1");
    let p = d.path();
    let r = repo(p);
    for target in [
        b"target".as_slice(),
        b"refs/heads/main",
        b"refs/heads/missing",
        b"refs/heads/-dash",
    ] {
        assert!(r
            .prepare_switch(target.to_vec(), Policy::default(), &Cancellation::default())
            .is_err());
    }
    git(p, &["update-ref", "refs/heads/HEAD", "target"]);
    assert!(r
        .prepare_switch(
            b"refs/heads/HEAD".to_vec(),
            Policy::default(),
            &Cancellation::default()
        )
        .is_err());
    git(p, &["switch", "--orphan", "unborn"]);
    assert!(r
        .prepare_switch(
            b"refs/heads/target".to_vec(),
            Policy::default(),
            &Cancellation::default()
        )
        .is_err());
    git(p, &["update-ref", "-d", "refs/heads/HEAD"]);
    assert!(r
        .prepare_switch(
            b"refs/heads/target".to_vec(),
            Policy::default(),
            &Cancellation::default()
        )
        .is_err());
}
#[test]
fn external_after_preflight_race_is_detected_in_actual_state_not_claimed_atomic() {
    let d = fixture("sha1");
    let p = d.path();
    let wrapper = p.join(".git/git-wrapper");
    script(&wrapper,"#!/usr/bin/python3\nimport os,sys,subprocess\nif 'switch' in sys.argv[1:]: subprocess.check_call(['/usr/bin/git','update-ref','refs/heads/target','refs/heads/main'])\nos.execv('/usr/bin/git',['git']+sys.argv[1:])\n");
    let r = Git::new(wrapper)
        .unwrap()
        .discover(p, Policy::default(), &Cancellation::default())
        .unwrap();
    let report = execute(prepare(&r));
    assert!(report.result.is_ok(), "{report:?}");
    assert!(!report.target_reached());
    assert_eq!(fs::read(p.join("file")).unwrap(), b"main\n");
}
#[test]
fn limited_preview_never_publishes_and_native_output_limit_still_scans() {
    let d = fixture("sha1");
    let p = d.path();
    assert!(repo(p)
        .prepare_switch(
            b"refs/heads/target".to_vec(),
            Policy {
                stdout_bytes: 30,
                ..Default::default()
            },
            &Cancellation::default()
        )
        .is_err());
    script(
        &p.join(".git/hooks/post-checkout"),
        "#!/bin/sh\nhead -c 10000 /dev/zero >&2\nsleep 30\n",
    );
    let report = prepare(&repo(p)).execute(
        Policy {
            stderr_bytes: 100,
            ..Default::default()
        },
        &Cancellation::default(),
        &mut |_| {},
    );
    assert!(
        matches!(report.result, Err(Error::OutputLimit(_))),
        "{report:?}"
    );
    assert!(report.state.is_ok());
}


#[test]
fn config_output_limit_hides_opaque_values_without_switch_dispatch() {
    let fixture = fixture("sha1");
    let root = fixture.path();
    let path = root.join(".git/config");
    let mut config = fs::read(&path).unwrap();
    config.extend_from_slice(b"\n[remote \"other\"]\n url = https://fixture:synthetic-password@example.invalid/repo?token=synthetic-token\n[http]\n extraHeader = Authorization: Bearer synthetic-opaque-token\n[probe]\n padding = ");
    config.extend(std::iter::repeat_n(b'x', 5 * 1024 * 1024));
    config.push(b'\n');
    fs::write(&path, &config).unwrap();
    let before_head = git(root, &["rev-parse", "HEAD"]);
    let before_index = fs::read(root.join(".git/index")).unwrap();
    let before_file = fs::read(root.join("file")).unwrap();
    let result = repo(root).prepare_switch(b"refs/heads/target".to_vec(), Policy { stdout_bytes: 4 * 1024 * 1024, ..Policy::default() }, &Cancellation::default());
    let Error::OutputLimit(output) = result.unwrap_err() else { panic!("expected config output cap") };
    assert!(output.stdout.is_empty(), "config failure must omit opaque values");
    assert_eq!(git(root, &["rev-parse", "HEAD"]), before_head);
    assert_eq!(fs::read(root.join(".git/index")).unwrap(), before_index);
    assert_eq!(fs::read(root.join("file")).unwrap(), before_file);
    assert!(fs::read(path).unwrap() == config, "configuration must remain unchanged");
}
