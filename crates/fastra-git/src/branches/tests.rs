use super::*;
use std::{
    os::unix::{ffi::OsStringExt, fs::PermissionsExt},
    process::Command,
    time::{Duration, Instant},
};
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    repo: Repository,
    target: Vec<u8>,
}
fn git(root: &Path, args: &[&str]) -> Vec<u8> {
    let out = Command::new("/usr/bin/git")
        .current_dir(root)
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
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("work");
    fs::create_dir(&root).unwrap();
    for args in [
        &["init", "-q", "-b", "main"][..],
        &["config", "user.name", "Synthetic"],
        &["config", "user.email", "test@example.invalid"],
        &["config", "commit.gpgsign", "false"],
    ] {
        git(&root, args);
    }
    fs::write(root.join("file"), "main\n").unwrap();
    git(&root, &["add", "file"]);
    git(&root, &["commit", "-qm", "initial"]);
    git(&root, &["switch", "-c", "target"]);
    fs::write(root.join("file"), "target\n").unwrap();
    git(&root, &["commit", "-qam", "Grüße 🚀 target"]);
    let target = git(&root, &["rev-parse", "HEAD"])
        .strip_suffix(b"\n")
        .unwrap()
        .to_vec();
    git(&root, &["switch", "main"]);
    let repo = Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(&root, Policy::default(), &Cancellation::default())
        .unwrap();
    Fixture {
        _temp: temp,
        root,
        repo,
        target,
    }
}
fn prepare(f: &Fixture, name: &[u8]) -> BranchCreationPreview {
    f.repo
        .prepare_branch_creation(
            name.to_vec(),
            f.target.clone(),
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap()
}
fn exists(f: &Fixture, name: &str) -> bool {
    !git(&f.root, &["for-each-ref", &format!("refs/heads/{name}")]).is_empty()
}
#[test]
fn creation_binds_full_commit_and_keeps_dirty_head_index_and_files() {
    let f = fixture();
    fs::write(f.root.join("file"), "staged\n").unwrap();
    git(&f.root, &["add", "file"]);
    fs::write(f.root.join("file"), "dirty\n").unwrap();
    fs::write(f.root.join("untracked"), "untracked").unwrap();
    let before = fs::read(f.root.join(".git/index")).unwrap();
    let head = git(&f.root, &["symbolic-ref", "HEAD"]);
    let preview = prepare(&f, b"created");
    assert_eq!(preview.subject(), "Grüße 🚀 target".as_bytes());
    git(&f.root, &["branch", "-f", "target", "main"]);
    let out = f
        .repo
        .create_branch(preview, Policy::default(), &Cancellation::default())
        .unwrap();
    assert!(out.success());
    assert_eq!(
        git(&f.root, &["rev-parse", "created"])
            .strip_suffix(b"\n")
            .unwrap(),
        f.target
    );
    assert_eq!(head, git(&f.root, &["symbolic-ref", "HEAD"]));
    assert_eq!(before, fs::read(f.root.join(".git/index")).unwrap());
    assert_eq!(fs::read(f.root.join("file")).unwrap(), b"dirty\n");
    assert_eq!(fs::read(f.root.join("untracked")).unwrap(), b"untracked");
    let list = f
        .repo
        .local_branches(Policy::default(), &Cancellation::default())
        .unwrap();
    assert!(list
        .value
        .branches
        .iter()
        .any(|b| b.full_name == b"refs/heads/created" && b.oid == f.target));
    assert_eq!(
        list.value.current_branch.as_deref(),
        Some(b"main".as_slice())
    );
}
#[test]
fn existing_branch_is_never_overwritten_even_when_created_after_preview() {
    let f = fixture();
    let preview = prepare(&f, b"created");
    git(&f.root, &["branch", "created", "main"]);
    let before = git(&f.root, &["rev-parse", "created"]);
    let out = f
        .repo
        .create_branch(preview, Policy::default(), &Cancellation::default());
    assert!(matches!(out,Err(Error::GitFailed(out))if !out.stderr.is_empty()));
    assert_eq!(before, git(&f.root, &["rev-parse", "created"]));
}
#[test]
fn invalid_names_aliases_short_ids_and_noncommits_are_rejected() {
    let f = fixture();
    for name in [
        b"".as_slice(),
        b"bad\0name",
        b"-option",
        b"has space",
        b"@{-1}",
        b"topic..bad",
    ] {
        assert!(
            f.repo
                .prepare_branch_creation(
                    name.to_vec(),
                    f.target.clone(),
                    Policy::default(),
                    &Cancellation::default()
                )
                .is_err(),
            "{name:?}"
        );
    }
    let blob = git(&f.root, &["rev-parse", "main:file"])
        .strip_suffix(b"\n")
        .unwrap()
        .to_vec();
    for oid in [f.target[..12].to_vec(), blob, vec![b'x'; 40]] {
        assert!(f
            .repo
            .prepare_branch_creation(
                b"created".to_vec(),
                oid,
                Policy::default(),
                &Cancellation::default()
            )
            .is_err());
    }
    assert!(!exists(&f, "created"));
}
#[test]
fn raw_branch_names_remain_exact_argv_data() {
    let f = fixture();
    let name = b"topic-\xff";
    f.repo
        .create_branch(
            prepare(&f, name),
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    let out = Command::new("/usr/bin/git")
        .current_dir(&f.root)
        .arg("rev-parse")
        .arg(OsString::from_vec(
            [b"refs/heads/".as_slice(), name].concat(),
        ))
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(out.stdout.strip_suffix(b"\n").unwrap(), f.target);
}
#[test]
fn repository_exchange_and_shared_lease_block_creation() {
    let f = fixture();
    let preview = prepare(&f, b"created");
    let lease = f.repo.try_operation().unwrap();
    assert!(f
        .repo
        .create_branch(preview, Policy::default(), &Cancellation::default())
        .is_err());
    drop(lease);
    assert!(!exists(&f, "created"));
    let preview = prepare(&f, b"created");
    fs::rename(f.root.join(".git"), f.root.join(".git-old")).unwrap();
    git(&f.root, &["init", "-q", "-b", "main"]);
    assert!(matches!(
        f.repo
            .create_branch(preview, Policy::default(), &Cancellation::default()),
        Err(Error::StaleRepository)
    ));
}
#[test]
fn configured_reference_hooks_are_rejected_before_they_run() {
    let f = fixture();
    let preview = prepare(&f, b"created");
    let hooks = f.root.join("custom-hooks");
    fs::create_dir(&hooks).unwrap();
    let hook = hooks.join("reference-transaction");
    fs::write(&hook, "#!/bin/sh\nprintf touched > hook-ran\n").unwrap();
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o700)).unwrap();
    git(
        &f.root,
        &["config", "core.hooksPath", hooks.to_str().unwrap()],
    );
    assert!(matches!(
        f.repo.prepare_branch_creation(
            b"created".to_vec(),
            f.target.clone(),
            Policy::default(),
            &Cancellation::default()
        ),
        Err(Error::InvalidInput(
            "reference-transaction hook requires the Git CLI"
        ))
    ));
    assert!(matches!(
        f.repo
            .create_branch(preview, Policy::default(), &Cancellation::default()),
        Err(Error::InvalidInput(
            "reference-transaction hook requires the Git CLI"
        ))
    ));
    assert!(!f.root.join("hook-ran").exists());
    assert!(!exists(&f, "created"));
}
#[test]
fn precancel_and_output_limits_never_create_a_ref() {
    let f = fixture();
    let preview = prepare(&f, b"created");
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(matches!(
        f.repo.create_branch(preview, Policy::default(), &cancel),
        Err(Error::Cancelled(_))
    ));
    assert!(!exists(&f, "created"));
    assert!(matches!(
        f.repo.prepare_branch_creation(
            b"created".to_vec(),
            f.target.clone(),
            Policy {
                stdout_bytes: 8,
                ..Policy::default()
            },
            &Cancellation::default()
        ),
        Err(Error::OutputLimit(_))
    ));
}
#[test]
fn in_flight_cancel_and_timeout_preserve_real_diagnostics() {
    for timeout in [false, true] {
        let f = fixture();
        let marker = f.root.join("started");
        let wrapper = f.root.join("git-wrapper");
        fs::write(&wrapper,format!("#!/usr/bin/python3\nimport os,sys,time\nif 'branch' in sys.argv[1:]:\n os.write(2,b'branch ready\\n')\n open({:?},'w').write('ready')\n time.sleep(30)\nos.execv('/usr/bin/git',['git']+sys.argv[1:])\n",marker.to_str().unwrap())).unwrap();
        fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o700)).unwrap();
        let repo = Git::new(wrapper)
            .unwrap()
            .discover(&f.root, Policy::default(), &Cancellation::default())
            .unwrap();
        let preview = repo
            .prepare_branch_creation(
                b"created".to_vec(),
                f.target.clone(),
                Policy::default(),
                &Cancellation::default(),
            )
            .unwrap();
        let cancel = Cancellation::default();
        let worker_cancel = cancel.clone();
        let worker = std::thread::spawn(move || {
            repo.create_branch(
                preview,
                Policy {
                    timeout: Duration::from_millis(if timeout { 180 } else { 2000 }),
                    ..Policy::default()
                },
                &worker_cancel,
            )
        });
        let started = Instant::now();
        while !marker.exists() && started.elapsed() < Duration::from_secs(1) {
            std::thread::sleep(Duration::from_millis(2));
        }
        assert!(marker.exists());
        if !timeout {
            cancel.cancel();
        }
        let out = worker.join().unwrap();
        assert!(if timeout {
            matches!(out,Err(Error::TimedOut(out))if out.stderr==b"branch ready\n")
        } else {
            matches!(out,Err(Error::Cancelled(out))if out.stderr==b"branch ready\n")
        });
        assert!(!exists(&f, "created"));
    }
}

#[test]
fn sha256_commit_ids_are_created_without_a_checkout() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    git(
        root,
        &["init", "-q", "--object-format=sha256", "-b", "main"],
    );
    git(root, &["config", "user.name", "Synthetic"]);
    git(root, &["config", "user.email", "test@example.invalid"]);
    git(root, &["config", "commit.gpgsign", "false"]);
    fs::write(root.join("file"), "keep\n").unwrap();
    git(root, &["add", "file"]);
    git(root, &["commit", "-qm", "SHA256"]);
    let oid = git(root, &["rev-parse", "HEAD"])
        .strip_suffix(b"\n")
        .unwrap()
        .to_vec();
    assert_eq!(oid.len(), 64);
    let repository = Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(root, Policy::default(), &Cancellation::default())
        .unwrap();
    let preview = repository
        .prepare_branch_creation(
            b"created".to_vec(),
            oid.clone(),
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    repository
        .create_branch(preview, Policy::default(), &Cancellation::default())
        .unwrap();
    assert_eq!(
        git(root, &["rev-parse", "created"])
            .strip_suffix(b"\n")
            .unwrap(),
        oid
    );
    assert_eq!(git(root, &["symbolic-ref", "HEAD"]), b"refs/heads/main\n");
}

#[test]
fn common_directory_exchange_cannot_redirect_creation() {
    let f = fixture();
    let linked = f._temp.path().join("linked");
    let foreign = f._temp.path().join("foreign.git");
    git(
        &f.root,
        &[
            "clone",
            "--bare",
            f.root.to_str().unwrap(),
            foreign.to_str().unwrap(),
        ],
    );
    git(
        &f.root,
        &["worktree", "add", "-b", "linked", linked.to_str().unwrap()],
    );
    let repository = Git::new("/usr/bin/git".into())
        .unwrap()
        .discover(&linked, Policy::default(), &Cancellation::default())
        .unwrap();
    let preview = repository
        .prepare_branch_creation(
            b"created".to_vec(),
            f.target.clone(),
            Policy::default(),
            &Cancellation::default(),
        )
        .unwrap();
    fs::write(
        repository.git_directory().join("commondir"),
        format!("{}\n", foreign.display()),
    )
    .unwrap();
    assert!(matches!(
        repository.create_branch(preview, Policy::default(), &Cancellation::default()),
        Err(Error::StaleRepository)
    ));
    assert!(git(&foreign, &["for-each-ref", "refs/heads/created"]).is_empty());
}
