#![cfg(target_os = "linux")]
use fastra_io::{check_runtime_file, check_runtime_path, initialize_runtime_policy};
use std::{
    fs::{self, File},
    io,
    os::fd::AsRawFd,
    path::{Path, PathBuf},
    process::Command,
};

#[test]
fn activation_is_fail_closed_and_immutable() {
    let root = tempfile::tempdir().unwrap();
    let manifest = root.path().join("shadow.json");
    fs::write(&manifest, b"{}").unwrap();
    for case in ["default", "missing", "malformed", "marker", "manifest-only"] {
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "policy_child", "--nocapture"])
            .env_remove("FASTRA_NATIVE_RUNTIME")
            .env_remove("FASTRA_NATIVE_SHADOW_MANIFEST")
            .env("FASTRA_POLICY_TEST_CASE", case)
            .env("FASTRA_POLICY_TEST_MANIFEST", &manifest)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{case}: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn policy_child() {
    let Ok(case) = std::env::var("FASTRA_POLICY_TEST_CASE") else {
        return;
    };
    if case == "overlay" {
        overlay();
        return;
    }
    let manifest = std::env::var_os("FASTRA_POLICY_TEST_MANIFEST").unwrap();
    // Jeder Zweig läuft in einem eigenen Testprozess, nicht neben anderen Tests.
    match case.as_str() {
        "default" => {
            initialize_runtime_policy().unwrap();
            check_runtime_path(Path::new("/usr/bin/bwrap")).unwrap();
            check_runtime_path(Path::new("/does/not/exist")).unwrap();
            return;
        }
        "missing" => std::env::set_var("FASTRA_NATIVE_RUNTIME", "1"),
        "malformed" => {
            std::env::set_var("FASTRA_NATIVE_RUNTIME", "1");
            std::env::set_var("FASTRA_NATIVE_SHADOW_MANIFEST", &manifest);
        }
        "marker" => std::env::set_var("FASTRA_NATIVE_RUNTIME", "bad"),
        "manifest-only" => std::env::set_var("FASTRA_NATIVE_SHADOW_MANIFEST", &manifest),
        _ => panic!("unknown case"),
    }
    let error = initialize_runtime_policy().unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    assert!(error.to_string().contains("optional") || error.to_string().contains("Optional"));
    std::env::remove_var("FASTRA_NATIVE_RUNTIME");
    std::env::remove_var("FASTRA_NATIVE_SHADOW_MANIFEST");
    assert!(check_runtime_path(Path::new("/tmp")).is_err());
    assert!(check_runtime_file(&File::open("/").unwrap()).is_err());
    assert!(fastra_io::ReadSnapshot::read(
        Path::new("/etc/hostname"),
        &fastra_core::Cancellation::default()
    )
    .is_err());
}
fn overlay() {
    initialize_runtime_policy().unwrap();
    let root = PathBuf::from(std::env::var_os("FASTRA_POLICY_TEST_ROOT").unwrap());
    assert_eq!(
        fs::read("/usr/bin/bwrap").unwrap(),
        b"private runtime overlay\n"
    );
    for path in [
        "/usr/bin/bwrap",
        "/lib64/ld-linux-x86-64.so.2",
        "/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2",
        "/usr/lib/x86_64-linux-gnu/webkitgtk-6.0/new.txt",
    ] {
        assert_eq!(
            check_runtime_path(Path::new(path)).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
    }
    std::os::unix::fs::symlink("/usr/bin/bwrap", root.join("alias")).unwrap();
    std::os::unix::fs::symlink(
        "/usr/lib/x86_64-linux-gnu/webkitgtk-6.0",
        root.join("dir-alias"),
    )
    .unwrap();
    assert!(check_runtime_path(&root.join("alias")).is_err());
    assert!(check_runtime_path(&root.join("dir-alias/new.txt")).is_err());
    let file = File::open("/usr/bin/bwrap").unwrap();
    assert!(check_runtime_file(&file).is_err());
    assert!(check_runtime_path(&PathBuf::from(format!(
        "/proc/self/fd/{}",
        file.as_raw_fd()
    )))
    .is_err());
    check_runtime_path(Path::new("/usr/include")).unwrap();
    check_runtime_file(&File::open("/usr/include").unwrap()).unwrap();
    check_runtime_path(&root.join("allowed.txt")).unwrap();
    let cancel = fastra_core::Cancellation::default();
    assert!(fastra_io::Snapshot::read(Path::new("/usr/bin/bwrap"), &cancel).is_err());
    for path in [
        PathBuf::from("/usr/bin/bwrap"),
        root.join("alias"),
        PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd())),
    ] {
        assert!(fastra_io::ReadSnapshot::read(&path, &cancel).is_err());
    }
    assert!(fastra_io::save_target::Target::capture(
        Path::new("/usr/lib/x86_64-linux-gnu/webkitgtk-6.0/new.txt"),
        &cancel
    )
    .is_err());
    assert!(fastra_io::Transaction::save_new_document(
        Path::new("/usr/lib/x86_64-linux-gnu/webkitgtk-6.0/new.txt"),
        b"no",
        &cancel
    )
    .is_err());
    let saved = fastra_io::Transaction::save_new_document(
        &root.join("allowed.txt"),
        b"host bytes",
        &cancel,
    )
    .unwrap();
    assert_eq!(saved.bytes(), b"host bytes");
    assert_eq!(fs::read(root.join("allowed.txt")).unwrap(), b"host bytes");
    assert_eq!(
        fastra_io::ReadSnapshot::read(&root.join("allowed.txt"), &cancel)
            .unwrap()
            .bytes(),
        b"host bytes"
    );
    // Der einmal geladene Vertrag bleibt auch nach Datei-/Umgebungsänderungen bestehen.
    fs::write(
        std::env::var_os("FASTRA_NATIVE_SHADOW_MANIFEST").unwrap(),
        b"{}",
    )
    .unwrap();
    std::env::remove_var("FASTRA_NATIVE_RUNTIME");
    std::env::remove_var("FASTRA_NATIVE_SHADOW_MANIFEST");
    assert!(check_runtime_path(Path::new("/usr/bin/bwrap")).is_err());
    check_runtime_path(Path::new("/usr/include")).unwrap();
    println!("native runtime shadow overlay: paths, aliases, opened FD, new save target blocked; unchanged host directory/save allowed; loaded policy remains immutable");
}
