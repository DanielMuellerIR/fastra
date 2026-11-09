use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    process::{Command, Stdio},
    time::{Duration, Instant},
};
fn binary() -> Command {
    Command::new(env!("CARGO_BIN_EXE_fastra-control"))
}
fn json(output: &std::process::Output) -> serde_json::Value {
    serde_json::from_slice(&output.stdout).unwrap()
}
#[test]
fn offline_capabilities_need_no_display_and_never_create_an_endpoint() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let out = binary()
        .args(["--capabilities", "--json"])
        .env_remove("DISPLAY")
        .env_remove("WAYLAND_DISPLAY")
        .env("XDG_RUNTIME_DIR", dir.path())
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_eq!(json(&out)["capabilities"]["readOnly"], true);
    assert!(json(&out).get("runtimeID").is_none());
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
}
#[test]
fn malformed_files_fifos_and_oversized_stdin_return_json_errors() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("request");
    fs::write(&path, b"{}").unwrap();
    let out = binary().arg("--request").arg(&path).output().unwrap();
    assert!(!out.status.success());
    assert_eq!(json(&out)["error"]["code"], "invalidRequest");
    let fifo = dir.path().join("fifo");
    use std::os::unix::ffi::OsStrExt;
    let name = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let started = Instant::now();
    let out = binary().arg("--request").arg(fifo).output().unwrap();
    assert_eq!(json(&out)["error"]["code"], "invalidRequest");
    assert!(started.elapsed() < Duration::from_secs(2));
    let mut child = binary()
        .args(["--request", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let _ = child.stdin.take().unwrap().write_all(&vec![b' '; 65_537]);
    let out = child.wait_with_output().unwrap();
    assert_eq!(json(&out)["error"]["code"], "invalidRequest");
}
#[test]
fn no_launch_reports_delivery_without_starting_an_app() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let request = fastra_core::local_control::Request::new(
        "objects",
        fastra_io::local_control::uuid(),
        fastra_io::local_control::now(),
    );
    let path = dir.path().join("request.json");
    fs::write(&path, serde_json::to_vec(&request).unwrap()).unwrap();
    let out = binary()
        .args(["--no-launch", "--request"])
        .arg(path)
        .env("XDG_RUNTIME_DIR", dir.path())
        .output()
        .unwrap();
    assert_eq!(json(&out)["error"]["code"], "delivery");
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
}
#[test]
fn stdin_without_eof_is_part_of_the_total_ten_second_deadline() {
    let mut child = binary()
        .args(["--no-launch", "--request", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    input.write_all(b"{").unwrap();
    let started = Instant::now();
    let out = child.wait_with_output().unwrap();
    assert_eq!(json(&out)["error"]["code"], "delivery");
    assert!(started.elapsed() >= Duration::from_secs(9));
    assert!(started.elapsed() < Duration::from_secs(13));
    drop(input);
}
