use fastra_git::*;
use std::{fs, path::Path, process::Command};
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
struct Fixture {
    t: tempfile::TempDir,
    r: Repository,
}
impl Fixture {
    fn new(diverge: bool, conflict: bool) -> Self {
        Self::with_format(diverge, conflict, "sha1")
    }
    fn with_format(diverge: bool, conflict: bool, format: &str) -> Self {
        let t = tempfile::tempdir().unwrap();
        let remote = t.path().join("remote");
        let root = t.path().join("work");
        fs::create_dir(&remote).unwrap();
        git(
            &remote,
            &["init", "-qb", "main", &format!("--object-format={format}")],
        );
        {
            let p = &remote;
            git(p, &["config", "user.name", "Fixture"]);
            git(p, &["config", "user.email", "fixture@example.invalid"]);
            git(p, &["config", "commit.gpgsign", "false"]);
        }
        fs::write(remote.join("file"), "old\n").unwrap();
        fs::write(remote.join("keep"), "keep\n").unwrap();
        git(&remote, &["add", "."]);
        git(&remote, &["commit", "-qm", "old"]);
        git(
            t.path(),
            &[
                "clone",
                "-q",
                remote.to_str().unwrap(),
                root.to_str().unwrap(),
            ],
        );
        git(&root, &["config", "user.name", "Fixture"]);
        git(&root, &["config", "user.email", "fixture@example.invalid"]);
        git(&root, &["config", "commit.gpgsign", "false"]);
        if diverge {
            fs::write(
                root.join(if conflict { "file" } else { "local" }),
                "local\n",
            )
            .unwrap();
            git(&root, &["add", "."]);
            git(&root, &["commit", "-qm", "local"]);
        }
        fs::write(remote.join("file"), "incoming Ω 😀\n").unwrap();
        git(&remote, &["commit", "-qam", "incoming"]);
        let r = Git::new("/usr/bin/git".into())
            .unwrap()
            .discover(&root, Policy::default(), &Cancellation::default())
            .unwrap();
        Self { t, r }
    }
    fn path(&self) -> &Path {
        self.r.root()
    }
    fn prepare(&self, s: PullStrategy) -> PullPreview {
        self.r
            .prepare_pull(
                b"origin".to_vec(),
                b"main".to_vec(),
                s,
                Policy::default(),
                &Cancellation::default(),
                &mut |_| {},
            )
            .unwrap()
    }
}
fn execute(p: PullPreview) -> PullReport {
    p.execute(Policy::default(), &Cancellation::default(), &mut |_| {})
}
#[test]
fn ff_preview_cancel_confirm_and_upstream_unchanged() {
    let f = Fixture::new(false, false);
    let old = git(f.path(), &["rev-parse", "HEAD"]);
    let upstream = git(f.path(), &["config", "--get", "branch.main.merge"]);
    let p = f.prepare(PullStrategy::FastForwardOnly);
    assert!(p.incoming().stdout.windows(8).any(|s| s == b"incoming"));
    assert!(!p.delta().stdout.is_empty());
    drop(p);
    assert_eq!(git(f.path(), &["rev-parse", "HEAD"]), old);
    let r = execute(f.prepare(PullStrategy::FastForwardOnly));
    assert!(r.result.is_ok(), "{r:?}");
    assert!(r.integrated());
    assert_eq!(
        git(f.path(), &["config", "--get", "branch.main.merge"]),
        upstream
    );
    assert_eq!(
        fs::read_to_string(f.path().join("file")).unwrap(),
        "incoming Ω 😀\n"
    );
}
#[test]
fn merge_rebase_ff_divergence_and_conflicts() {
    for s in [
        PullStrategy::FastForwardOnly,
        PullStrategy::Merge,
        PullStrategy::Rebase,
    ] {
        for conflict in [false, true] {
            let f = Fixture::new(true, conflict);
            let p = f.prepare(s);
            assert!(!p.local().stdout.is_empty());
            let r = execute(p);
            if s == PullStrategy::FastForwardOnly || conflict {
                assert!(r.result.is_err(), "{r:?}");
                if s != PullStrategy::FastForwardOnly {
                    assert!(!r.state.unwrap().operations.is_empty());
                }
            } else {
                assert!(r.result.is_ok(), "{r:?}");
                assert!(r.integrated());
                assert_eq!(fs::read(f.path().join("local")).unwrap(), b"local\n");
            }
        }
    }
}
#[test]
fn stale_index_files_refs_config_hooks_and_fetch_head_never_dispatch() {
    for drift in 0..6 {
        let f = Fixture::new(false, false);
        let p = f.prepare(PullStrategy::FastForwardOnly);
        let head = git(f.path(), &["rev-parse", "HEAD"]);
        match drift {
            0 => {
                fs::write(f.path().join("file"), "drift\n").unwrap();
            }
            1 => {
                fs::write(f.path().join("keep"), "staged\n").unwrap();
                git(f.path(), &["add", "keep"]);
            }
            2 => {
                git(f.path(), &["branch", "new"]);
            }
            3 => {
                git(f.path(), &["config", "merge.autoStash", "true"]);
            }
            4 => {
                use std::os::unix::fs::PermissionsExt;
                let p = f.path().join(".git/hooks/post-merge");
                fs::write(&p, "#!/bin/sh\nexit 0\n").unwrap();
                fs::set_permissions(p, fs::Permissions::from_mode(0o700)).unwrap();
            }
            _ => {
                fs::write(f.path().join(".git/FETCH_HEAD"), &head).unwrap();
            }
        }
        let r = execute(p);
        assert!(!r.started, "drift {drift}: {r:?}");
        assert!(r.result.is_err());
        assert_eq!(git(f.path(), &["rev-parse", "HEAD"]), head);
    }
}
#[test]
fn dirty_native_protection_and_no_autostash() {
    for strategy in [
        PullStrategy::FastForwardOnly,
        PullStrategy::Merge,
        PullStrategy::Rebase,
    ] {
        for collide in [false, true] {
            let f = Fixture::new(false, false);
            git(f.path(), &["config", "rebase.autoStash", "true"]);
            git(f.path(), &["config", "merge.autoStash", "true"]);
            let name = if collide { "file" } else { "keep" };
            fs::write(f.path().join(name), "dirty\n").unwrap();
            let r = execute(f.prepare(strategy));
            if collide || strategy == PullStrategy::Rebase {
                assert!(r.result.is_err(), "{r:?}");
            } else {
                assert!(r.result.is_ok(), "{r:?}");
            }
            assert_eq!(fs::read(f.path().join(name)).unwrap(), b"dirty\n");
            assert!(git(f.path(), &["stash", "list"]).is_empty());
        }
    }
}
#[test]
fn remote_can_advance_after_approved_preview_and_postscan_reports_actual() {
    let f = Fixture::new(false, false);
    let p = f.prepare(PullStrategy::FastForwardOnly);
    let seen = p.source().fetched_oid.clone().unwrap();
    let remote = f.t.path().join("remote");
    fs::write(remote.join("file"), "later\n").unwrap();
    git(&remote, &["commit", "-qam", "later"]);
    let r = execute(p);
    assert!(r.result.is_ok(), "{r:?}");
    assert!(r.integrated());
    assert!(r
        .delta
        .as_ref()
        .unwrap()
        .stdout
        .windows(6)
        .any(|v| v == b"+later"));
    assert_ne!(r.state.unwrap().fetched_oid.unwrap(), seen);
    assert_eq!(fs::read(f.path().join("file")).unwrap(), b"later\n");
}
#[test]
fn detached_markers_identity_limits_and_invalid_sources_block_before_fetch() {
    for case in 0..7 {
        let f = Fixture::new(false, false);
        match case {
            0 => {
                git(f.path(), &["switch", "--detach"]);
            }
            1 => {
                fs::write(
                    f.path().join(".git/MERGE_HEAD"),
                    git(f.path(), &["rev-parse", "HEAD"]),
                )
                .unwrap();
            }
            2 => {
                git(f.path(), &["config", "--unset", "user.name"]);
            }
            3 => {
                git(
                    f.path(),
                    &["config", "--add", "remote.origin.url", "/missing"],
                );
            }
            4 => {
                fs::write(f.path().join(".git/info/grafts"), b"legacy").unwrap();
            }
            _ => {}
        }
        let branch = if case == 5 {
            b"--upload-pack=bad".to_vec()
        } else {
            b"main".to_vec()
        };
        let policy = if case == 6 {
            Policy {
                stdout_bytes: 1,
                ..Default::default()
            }
        } else {
            Policy::default()
        };
        let result = f.r.prepare_pull(
            b"origin".to_vec(),
            branch,
            PullStrategy::Merge,
            policy,
            &Cancellation::default(),
            &mut |_| {},
        );
        assert!(result.is_err(), "case {case}");
        assert!(!f.path().join(".git/FETCH_HEAD").exists(), "case {case}");
    }
}
#[test]
fn timeout_and_cancel_still_scan_partial_success_and_keep_native_state() {
    use std::{os::unix::fs::PermissionsExt, time::Duration};
    for cancel in [false, true] {
        let f = Fixture::new(false, false);
        let marker = f.path().join(".git/started");
        let hook = f.path().join(".git/hooks/post-merge");
        fs::write(
            &hook,
            format!(
                "#!/bin/sh\nprintf started > '{}'\nsleep 30\n",
                marker.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o700)).unwrap();
        let p = f.prepare(PullStrategy::FastForwardOnly);
        let c = Cancellation::default();
        let cc = c.clone();
        if cancel {
            let marker = marker.clone();
            std::thread::spawn(move || {
                for _ in 0..1000 {
                    if marker.exists() {
                        cc.cancel();
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
            });
        }
        let r = p.execute(
            Policy {
                timeout: Duration::from_millis(if cancel { 5000 } else { 700 }),
                ..Default::default()
            },
            &c,
            &mut |_| {},
        );
        assert!(
            matches!(r.result, Err(Error::Cancelled(_) | Error::TimedOut(_))),
            "{r:?}"
        );
        assert!(r.started);
        assert!(r.state.is_ok(), "{r:?}");
        assert!(r.integrated());
        assert_eq!(
            fs::read_to_string(f.path().join("file")).unwrap(),
            "incoming Ω 😀\n"
        );
    }
}
#[test]
fn lease_and_index_lock_do_not_remove_foreign_locks() {
    let f = Fixture::new(false, false);
    let p = f.prepare(PullStrategy::FastForwardOnly);
    let lease = f.r.try_operation().unwrap();
    let r = execute(p);
    assert!(!r.started);
    drop(lease);
    let p = f.prepare(PullStrategy::FastForwardOnly);
    fs::write(f.path().join(".git/index.lock"), b"foreign").unwrap();
    let r = execute(p);
    assert!(r.result.is_err());
    assert_eq!(
        fs::read(f.path().join(".git/index.lock")).unwrap(),
        b"foreign"
    );
}
#[test]
fn missing_remote_and_disallowed_helper_fail_without_integration() {
    for address in ["/missing/remote", "ext::false"] {
        let f = Fixture::new(false, false);
        git(f.path(), &["remote", "set-url", "origin", address]);
        let old = git(f.path(), &["rev-parse", "HEAD"]);
        assert!(f
            .r
            .prepare_pull(
                b"origin".to_vec(),
                b"main".to_vec(),
                PullStrategy::FastForwardOnly,
                Policy::default(),
                &Cancellation::default(),
                &mut |_| {}
            )
            .is_err());
        assert_eq!(git(f.path(), &["rev-parse", "HEAD"]), old);
    }
}
#[test]
fn ignored_collision_is_blocked_but_unrelated_ignored_files_are_kept() {
    for collide in [false, true] {
        let f = Fixture::new(false, false);
        let remote = f.t.path().join("remote");
        fs::write(remote.join("added"), "incoming\n").unwrap();
        git(&remote, &["add", "added"]);
        git(&remote, &["commit", "-qm", "added"]);
        fs::write(f.path().join(".git/info/exclude"), "added\nunrelated\n").unwrap();
        let name = if collide { "added" } else { "unrelated" };
        fs::write(f.path().join(name), "ignored local\n").unwrap();
        let p = f.r.prepare_pull(
            b"origin".to_vec(),
            b"main".to_vec(),
            PullStrategy::FastForwardOnly,
            Policy::default(),
            &Cancellation::default(),
            &mut |_| {},
        );
        if collide {
            assert!(matches!(p, Err(Error::InvalidInput(_))));
        } else {
            let r = execute(p.unwrap());
            assert!(r.result.is_ok(), "{r:?}");
        }
        assert_eq!(fs::read(f.path().join(name)).unwrap(), b"ignored local\n");
    }
}
#[test]
fn local_auth_failure_output_redacts_credentials_and_never_integrates() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new(false, false);
    let address = "https://fixture:synthetic-password@example.invalid/repo?key=synthetic-token";
    git(f.path(), &["remote", "set-url", "origin", address]);
    let wrapper = f.t.path().join("git-wrapper");
    fs::write(&wrapper,format!("#!/bin/sh\nfor arg in \"$@\"; do\n if [ \"$arg\" = fetch ]; then printf '%s\\n' '{}' >&2; exit 128; fi\ndone\nexec /usr/bin/git \"$@\"\n",address)).unwrap();
    fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o700)).unwrap();
    let r = Git::new(wrapper)
        .unwrap()
        .discover(f.path(), Policy::default(), &Cancellation::default())
        .unwrap();
    let mut seen = Vec::new();
    let result = r.prepare_pull(
        b"origin".to_vec(),
        b"main".to_vec(),
        PullStrategy::FastForwardOnly,
        Policy::default(),
        &Cancellation::default(),
        &mut |b| seen.extend_from_slice(b),
    );
    let Err(Error::GitFailed(out)) = result else {
        panic!("expected auth failure")
    };
    for bytes in [&seen, &out.stderr] {
        let text = String::from_utf8_lossy(bytes);
        assert!(!text.contains("synthetic-password"));
        assert!(!text.contains("synthetic-token"));
        assert!(text.contains("https://example.invalid/repo"));
    }
    assert_eq!(fs::read(f.path().join("file")).unwrap(), b"old\n");
}
#[test]
fn large_or_incomplete_preview_never_yields_approval() {
    let f = Fixture::new(false, false);
    for n in 0..65_535 {
        fs::write(f.path().join(format!("untracked-{n}")), "bytes").unwrap();
    }
    let result = f.r.prepare_pull(
        b"origin".to_vec(),
        b"main".to_vec(),
        PullStrategy::FastForwardOnly,
        Policy::default(),
        &Cancellation::default(),
        &mut |_| {},
    );
    assert!(matches!(result, Err(Error::InvalidInput(_))));
    assert_eq!(fs::read(f.path().join("file")).unwrap(), b"old\n");
}
#[test]
fn up_to_date_is_a_verified_noop_and_sha256_is_supported() {
    let f = Fixture::with_format(false, false, "sha256");
    let r = execute(f.prepare(PullStrategy::FastForwardOnly));
    assert!(r.result.is_ok());
    let old = git(f.path(), &["rev-parse", "HEAD"]);
    let p = f.prepare(PullStrategy::FastForwardOnly);
    assert!(p.incoming().stdout.is_empty());
    assert!(p.local().stdout.is_empty());
    assert!(p.delta().stdout.is_empty());
    let r = execute(p);
    assert!(r.result.is_ok());
    assert!(r.integrated());
    assert_eq!(git(f.path(), &["rev-parse", "HEAD"]), old);
}
#[test]
fn hook_failure_preserves_partial_merge_and_output_limit_still_postscans() {
    use std::os::unix::fs::PermissionsExt;
    for limit in [false, true] {
        let f = Fixture::new(!limit, false);
        let hook = f.path().join(if limit {
            ".git/hooks/post-merge"
        } else {
            ".git/hooks/pre-merge-commit"
        });
        fs::write(
            &hook,
            if limit {
                "#!/bin/sh\nseq 1 10000\n"
            } else {
                "#!/bin/sh\nprintf 'deliberate local hook failure\\n' >&2\nexit 1\n"
            },
        )
        .unwrap();
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o700)).unwrap();
        let p = f.prepare(if limit {
            PullStrategy::FastForwardOnly
        } else {
            PullStrategy::Merge
        });
        let r = p.execute(
            Policy {
                stdout_bytes: 4096,
                stderr_bytes: 4096,
                ..Default::default()
            },
            &Cancellation::default(),
            &mut |_| {},
        );
        assert!(r.started);
        assert!(r.state.is_ok(), "{r:?}");
        if limit {
            assert!(matches!(r.result, Err(Error::OutputLimit(_))));
            assert!(r.integrated());
        } else {
            assert!(matches!(r.result, Err(Error::GitFailed(_))), "{r:?}");
            assert!(r
                .state
                .unwrap()
                .operations
                .iter()
                .any(|v| v == "MERGE_HEAD"));
        }
    }
}
#[test]
fn head_lock_failure_keeps_foreign_lock_and_reports_actual_written_files() {
    let f = Fixture::new(false, false);
    let p = f.prepare(PullStrategy::FastForwardOnly);
    let old = git(f.path(), &["rev-parse", "HEAD"]);
    let lock = f.path().join(".git/refs/heads/main.lock");
    fs::write(&lock, b"foreign owner").unwrap();
    let r = execute(p);
    assert!(r.started);
    assert!(matches!(r.result, Err(Error::GitFailed(_))));
    assert_eq!(git(f.path(), &["rev-parse", "HEAD"]), old);
    assert_eq!(fs::read(lock).unwrap(), b"foreign owner");
    let state = r.state.unwrap();
    assert!(!state.files.staged.stdout.is_empty() || !state.files.working.stdout.is_empty());
    assert_eq!(
        fs::read_to_string(f.path().join("file")).unwrap(),
        "incoming Ω 😀\n"
    );
}
#[test]
fn explicit_raw_ref_and_ff_without_commit_identity_work() {
    use std::os::unix::ffi::OsStringExt;
    let f = Fixture::new(false, false);
    let remote = f.t.path().join("remote");
    let raw = b"raw-\xff";
    let out = Command::new("/usr/bin/git")
        .current_dir(&remote)
        .arg("update-ref")
        .arg(std::ffi::OsString::from_vec(
            [b"refs/heads/".as_slice(), raw].concat(),
        ))
        .arg("HEAD")
        .output()
        .unwrap();
    assert!(out.status.success());
    git(f.path(), &["config", "--unset", "user.name"]);
    git(f.path(), &["config", "--unset", "user.email"]);
    let p =
        f.r.prepare_pull(
            b"origin".to_vec(),
            raw.to_vec(),
            PullStrategy::FastForwardOnly,
            Policy::default(),
            &Cancellation::default(),
            &mut |_| {},
        )
        .unwrap();
    assert_eq!(p.branch(), raw);
    let r = execute(p);
    assert!(r.result.is_ok());
    assert!(r.integrated());
}
#[test]
fn stale_preview_never_launches_native_pull_and_new_preview_does() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new(false, false);
    let wrapper = f.t.path().join("git-proof");
    fs::write(&wrapper,"#!/bin/sh\nfor arg in \"$@\"; do if [ \"$arg\" = pull ]; then printf native-pull > .git/pull-started; fi; done\nexec /usr/bin/git \"$@\"\n").unwrap();
    fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o700)).unwrap();
    let r = Git::new(wrapper)
        .unwrap()
        .discover(f.path(), Policy::default(), &Cancellation::default())
        .unwrap();
    let prepare = || {
        r.prepare_pull(
            b"origin".to_vec(),
            b"main".to_vec(),
            PullStrategy::FastForwardOnly,
            Policy::default(),
            &Cancellation::default(),
            &mut |_| {},
        )
        .unwrap()
    };
    let p = prepare();
    git(f.path(), &["config", "pull.ff", "only"]);
    let failed = execute(p);
    assert!(failed.result.is_err());
    assert!(!f.path().join(".git/pull-started").exists());
    let success = execute(prepare());
    assert!(success.result.is_ok());
    assert!(success.integrated());
    assert_eq!(
        fs::read(f.path().join(".git/pull-started")).unwrap(),
        b"native-pull"
    );
}
#[test]
fn larger_repositories_pull_small_change_and_bind_unrelated_hidden_stale_file() {
    for count in [129, 1024] {
        let f = Fixture::new(false, false);
        let remote = f.t.path().join("remote");
        for n in 0..count {
            fs::write(remote.join(format!("tiny-{n:04}")), "x\n").unwrap();
        }
        git(&remote, &["add", "."]);
        git(&remote, &["commit", "-qm", "larger fixture"]);
        git(f.path(), &["fetch", "origin"]);
        git(f.path(), &["reset", "--hard", "origin/main"]);
        fs::write(remote.join("file"), "small actual pull\n").unwrap();
        git(&remote, &["commit", "-qam", "small update"]);
        let r = execute(f.prepare(PullStrategy::FastForwardOnly));
        assert!(r.result.is_ok(), "count {count}");
        assert!(r.integrated());
        assert_eq!(
            fs::read(f.path().join("file")).unwrap(),
            b"small actual pull\n"
        );
        git(
            f.path(),
            &["update-index", "--assume-unchanged", "tiny-0000"],
        );
        fs::write(remote.join("file"), "next update\n").unwrap();
        git(&remote, &["commit", "-qam", "next"]);
        let p = f.prepare(PullStrategy::FastForwardOnly);
        fs::write(f.path().join("tiny-0000"), "unrelated hidden stale\n").unwrap();
        let status = Command::new("/usr/bin/git")
            .current_dir(f.path())
            .args(["status", "--porcelain"])
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        assert!(status.status.success());
        assert!(status.stdout.is_empty());
        let r = execute(p);
        assert!(matches!(r.result, Err(Error::StalePreview)));
        assert!(!r.started);
        assert_eq!(
            fs::read(f.path().join("file")).unwrap(),
            b"small actual pull\n"
        );
        assert_eq!(
            fs::read(f.path().join("tiny-0000")).unwrap(),
            b"unrelated hidden stale\n"
        );
    }
}
#[test]
fn path_bytes_and_working_bytes_limits_refuse_without_worktree_write() {
    for bytes in [false, true] {
        let f = Fixture::new(false, false);
        if bytes {
            let chunk = vec![b'x'; 1024 * 1024];
            for n in 0..65 {
                fs::write(f.path().join(format!("large-{n}")), &chunk).unwrap();
            }
        } else {
            for n in 0..5300 {
                fs::write(f.path().join(format!("{n:04}-{}", "x".repeat(200))), b"").unwrap();
            }
        }
        let result = f.r.prepare_pull(
            b"origin".to_vec(),
            b"main".to_vec(),
            PullStrategy::FastForwardOnly,
            Policy::default(),
            &Cancellation::default(),
            &mut |_| {},
        );
        assert!(matches!(result, Err(Error::InvalidInput(_))));
        assert_eq!(fs::read(f.path().join("file")).unwrap(), b"old\n");
    }
}

fn config_diagnostic_boundary(execute: bool) {
    let f = Fixture::new(false, false);
    let path = f.path().join(".git/config");
    let mut config = fs::read(&path).unwrap();
    config.extend_from_slice(b"\n[remote \"other\"]\n url = https://fixture:synthetic-password@example.invalid/repo?token=synthetic-token\n[http]\n extraHeader = Authorization: Bearer synthetic-opaque-token\n[probe]\n padding = ");
    config.extend(std::iter::repeat_n(
        b'x',
        if execute { 128 * 1024 } else { 5 * 1024 * 1024 },
    ));
    config.push(b'\n');
    fs::write(path, config).unwrap();
    let policy = Policy {
        stdout_bytes: 4 * 1024 * 1024,
        ..Policy::default()
    };
    let prepared = f.r.prepare_pull(
        b"origin".to_vec(),
        b"main".to_vec(),
        PullStrategy::FastForwardOnly,
        policy,
        &Cancellation::default(),
        &mut |_| {},
    );
    let error = if execute {
        let report = prepared.unwrap().execute(
            Policy {
                stdout_bytes: 64 * 1024,
                ..Policy::default()
            },
            &Cancellation::default(),
            &mut |_| {},
        );
        assert!(!report.started);
        assert!(report.state.is_ok());
        report.result.unwrap_err()
    } else {
        prepared.unwrap_err()
    };
    let Error::OutputLimit(output) = error else {
        panic!("expected bounded config capture failure")
    };
    assert!(
        output.stdout.is_empty(),
        "config failure must not expose any raw values, including opaque headers"
    );
    assert!(!String::from_utf8_lossy(&output.stderr).contains("synthetic-"));
    assert_eq!(fs::read(f.path().join("file")).unwrap(), b"old\n");
}
#[test]
fn prepare_config_capture_failure_omits_opaque_secrets() {
    config_diagnostic_boundary(false);
}
#[test]
fn execute_config_capture_failure_omits_opaque_secrets_without_dispatch() {
    config_diagnostic_boundary(true);
}
