use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    process::{Command, Stdio},
};
#[test]
fn real_cli_preserves_valid_number_forms_and_large_version_error_codes() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    for (version, expected) in [
        ("1.0", "delivery"),
        ("1e0", "delivery"),
        ("4294967296.0", "unsupported"),
        ("4.294967296e9", "unsupported"),
        ("1.1", "invalidRequest"),
        ("true", "invalidRequest"),
    ] {
        let request = format!(
            r#"{{"version":{version},"id":"11111111-1111-4111-8111-111111111111","operation":"objects","deadline":{}}}"#,
            fastra_io::local_control::now() + 10.
        );
        let mut child = Command::new(env!("CARGO_BIN_EXE_fastra-control"))
            .args(["--no-launch", "--request", "-"])
            .env("XDG_RUNTIME_DIR", dir.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(request.as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(!out.status.success());
        let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(reply["error"]["code"], expected, "{version}");
    }
}
