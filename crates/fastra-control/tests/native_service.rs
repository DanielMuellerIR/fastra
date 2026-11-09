use fastra_core::local_control::{Reply, Request, UUID};
use fastra_io::local_control::{self as control, transport};
use std::{
    fs,
    os::unix::fs::{symlink, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};
const SYSTEM: &str = "11111111-1111-4111-8111-111111111111";
const NATIVE: &str = "22222222-2222-4222-8222-222222222222";
fn wait_for(mut f: impl FnMut() -> bool) {
    let start = Instant::now();
    while !f() {
        assert!(start.elapsed() < Duration::from_secs(4));
        std::thread::sleep(Duration::from_millis(10));
    }
}
#[test]
fn native_driver() {
    let Some(role) = std::env::var_os("FASTRA_SERVICE_TEST_ROLE") else {
        return;
    };
    let root = PathBuf::from(std::env::var_os("FASTRA_SERVICE_TEST_ROOT").unwrap());
    let native = role == "native";
    let endpoint = transport::endpoint().unwrap();
    assert_eq!(
        endpoint.file_name().unwrap(),
        if native {
            "org.fastra.Fastra.NativeCandidate.control.v1.sock"
        } else {
            "org.fastra.Fastra.Development.control.v1.sock"
        }
    );
    let (_server, rx) = transport::Server::start(&endpoint).unwrap();
    fs::write(
        root.join(if native {
            "native-ready"
        } else {
            "system-ready"
        }),
        "ready",
    )
    .unwrap();
    let delivery = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    Request::decode(&delivery.request).unwrap();
    delivery
        .reply
        .send(Reply::new(Some(
            UUID::parse(if native { NATIVE } else { SYSTEM }).unwrap(),
        )))
        .unwrap();
    // Der Worker überträgt die bereits angenommene Antwort vor dem Serverdrop.
    std::thread::sleep(Duration::from_millis(80));
    fs::write(
        root.join(if native { "native-done" } else { "system-done" }),
        "done",
    )
    .unwrap();
}
fn shadow_manifest(root: &Path) -> PathBuf {
    let paths = [
        ("/lib64/ld-linux-x86-64.so.2", "file"),
        ("/usr/lib/x86_64-linux-gnu/webkitgtk-6.0", "directory"),
        ("/usr/bin/bwrap", "file"),
        ("/usr/bin/xdg-dbus-proxy", "file"),
    ];
    let items:Vec<_>=paths.into_iter().map(|(p,k)|serde_json::json!({"path":p,"canonical_target":fs::canonicalize(p).unwrap(),"kind":k})).collect();
    let path = root.join("shadow.json");
    fs::write(&path,serde_json::to_vec(&serde_json::json!({"format":1,"scope":"known-runtime-shadow-paths","shadowed_paths":items})).unwrap()).unwrap();
    path
}
fn manifest(root: &Path) {
    let cli = root.join("app/libexec/fastra-control");
    let app = root.join("bin/fastra-native");
    let value = serde_json::json!({"format":1,"kind":"fastra-optional-native-package","sha256":{"app/libexec/fastra-control":control::hash(&fs::read(cli).unwrap()),"bin/fastra-native":control::hash(&fs::read(app).unwrap())},"padding":"x".repeat(2_100_000)});
    fs::write(
        root.join("native-package.json"),
        serde_json::to_vec(&value).unwrap(),
    )
    .unwrap();
}
fn command(root: &Path, native: bool) -> Command {
    let request = Request::new("objects", control::uuid(), control::now());
    fs::write(
        root.join("request.json"),
        serde_json::to_vec(&request).unwrap(),
    )
    .unwrap();
    let cli = root.join("app/libexec/fastra-control");
    let mut cmd = if native {
        let mut c = Command::new("/lib64/ld-linux-x86-64.so.2");
        c.arg("--argv0")
            .arg(&cli)
            .arg("--library-path")
            .arg(root.join("app/lib"))
            .arg(&cli);
        c.env("FASTRA_INTERNAL_NATIVE_SERVICE", "1");
        c
    } else {
        let mut c = Command::new(&cli);
        c.env_remove("FASTRA_INTERNAL_NATIVE_SERVICE");
        c
    };
    cmd.arg("--request")
        .arg(root.join("request.json"))
        .env_remove("FASTRA_NATIVE_RUNTIME")
        .env_remove("FASTRA_NATIVE_SHADOW_MANIFEST")
        .env("XDG_RUNTIME_DIR", root.join("run"));
    cmd
}
fn reply(out: std::process::Output) -> serde_json::Value {
    serde_json::from_slice(&out.stdout).unwrap()
}
#[test]
fn parallel_targets_loader_anchor_manifest_and_native_coldstart() {
    let temp = tempfile::tempdir_in("/tmp").unwrap();
    let root = temp.path();
    fs::create_dir_all(root.join("app/libexec")).unwrap();
    fs::create_dir(root.join("bin")).unwrap();
    fs::create_dir(root.join("run")).unwrap();
    fs::set_permissions(root.join("run"), fs::Permissions::from_mode(0o700)).unwrap();
    symlink("/runtime/lib", root.join("app/lib")).unwrap();
    fs::copy(
        std::env::var_os("FASTRA_TEST_CONTROL_ELF")
            .unwrap_or_else(|| env!("CARGO_BIN_EXE_fastra-control").into()),
        root.join("app/libexec/fastra-control"),
    )
    .unwrap();
    let launcher = root.join("bin/fastra-native");
    fs::write(&launcher,"#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$FASTRA_SERVICE_TEST_ROOT/launched\"\nunset FASTRA_INTERNAL_NATIVE_SERVICE\nexport FASTRA_NATIVE_RUNTIME=1 FASTRA_NATIVE_SHADOW_MANIFEST=\"$FASTRA_SERVICE_TEST_MANIFEST\"\nexec \"$FASTRA_SERVICE_TEST_BINARY\" --exact native_driver --nocapture\n").unwrap();
    fs::set_permissions(&launcher, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(
        root.join("app/libexec/fastra-linux"),
        "#!/bin/sh\nexit 97\n",
    )
    .unwrap();
    fs::set_permissions(
        root.join("app/libexec/fastra-linux"),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    manifest(root);
    let policy = shadow_manifest(root);
    let request = Request::new("objects", control::uuid(), control::now());
    fs::write(
        root.join("request.json"),
        serde_json::to_vec(&request).unwrap(),
    )
    .unwrap();
    let server = |native: bool| {
        let mut c = Command::new(std::env::current_exe().unwrap());
        c.args(["--exact", "native_driver", "--nocapture"])
            .env("FASTRA_SERVICE_TEST_ROOT", root)
            .env(
                "FASTRA_SERVICE_TEST_ROLE",
                if native { "native" } else { "system" },
            )
            .env("XDG_RUNTIME_DIR", root.join("run"))
            .env_remove("FASTRA_INTERNAL_NATIVE_SERVICE");
        if native {
            c.env("FASTRA_NATIVE_RUNTIME", "1")
                .env("FASTRA_NATIVE_SHADOW_MANIFEST", &policy);
        } else {
            c.env_remove("FASTRA_NATIVE_RUNTIME")
                .env_remove("FASTRA_NATIVE_SHADOW_MANIFEST");
        }
        c.stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    };
    let system = server(false);
    let native = server(true);
    wait_for(|| root.join("system-ready").exists() && root.join("native-ready").exists());
    let bad = command(root, false)
        .env("FASTRA_INTERNAL_NATIVE_SERVICE", "invalid")
        .output()
        .unwrap();
    assert_eq!(reply(bad)["error"]["code"], "delivery");
    let bad = command(root, false)
        .env("FASTRA_NATIVE_RUNTIME", "1")
        .output()
        .unwrap();
    assert_eq!(reply(bad)["error"]["code"], "delivery");
    let bad = command(root, false)
        .env("FASTRA_NATIVE_RUNTIME", "1")
        .env("FASTRA_NATIVE_SHADOW_MANIFEST", &policy)
        .output()
        .unwrap();
    assert_eq!(
        reply(bad)["error"]["code"],
        "delivery",
        "GUI markers must not retarget a default CLI even with a valid policy"
    );
    for marker in ["3", ""] {
        let bad = command(root, true)
            .env("FASTRA_INTERNAL_HOST_FD", marker)
            .output()
            .unwrap();
        assert_eq!(
            reply(bad)["error"]["code"],
            "delivery",
            "GUI/prototype host-channel markers must not enter a CLI"
        );
    }
    let caps = Command::new(root.join("app/libexec/fastra-control"))
        .args(["--capabilities", "--json"])
        .env("FASTRA_INTERNAL_HOST_FD", "3")
        .output()
        .unwrap();
    assert_eq!(
        reply(caps)["error"]["code"],
        "delivery",
        "role check must precede offline capabilities too"
    );
    let good = fs::read(root.join("native-package.json")).unwrap();
    for field in ["format", "kind", "own-hash", "launcher-hash"] {
        let mut value: serde_json::Value = serde_json::from_slice(&good).unwrap();
        match field {
            "format" => value["format"] = 2.into(),
            "kind" => value["kind"] = "system-package".into(),
            "own-hash" => value["sha256"]["app/libexec/fastra-control"] = "0".repeat(64).into(),
            _ => value["sha256"]["bin/fastra-native"] = "0".repeat(64).into(),
        }
        fs::write(
            root.join("native-package.json"),
            serde_json::to_vec(&value).unwrap(),
        )
        .unwrap();
        assert_eq!(
            reply(command(root, true).output().unwrap())["error"]["code"],
            "delivery",
            "{field}"
        );
    }
    fs::write(root.join("native-package.json"), &good).unwrap();
    let sys = command(root, false).output().unwrap();
    assert!(sys.status.success());
    assert_eq!(reply(sys)["runtimeID"], SYSTEM);
    let nat = command(root, true).output().unwrap();
    assert!(
        nat.status.success(),
        "{}",
        String::from_utf8_lossy(&nat.stderr)
    );
    assert_eq!(reply(nat)["runtimeID"], NATIVE);
    assert!(!root.join("launched").exists());
    assert!(system.wait_with_output().unwrap().status.success());
    assert!(native.wait_with_output().unwrap().status.success());
    fs::remove_file(root.join("native-done")).unwrap();
    let cold = command(root, true)
        .env("FASTRA_SERVICE_TEST_ROOT", root)
        .env("FASTRA_SERVICE_TEST_ROLE", "native")
        .env("FASTRA_SERVICE_TEST_MANIFEST", &policy)
        .env(
            "FASTRA_SERVICE_TEST_BINARY",
            std::env::current_exe().unwrap(),
        )
        .output()
        .unwrap();
    assert!(
        cold.status.success(),
        "{}",
        String::from_utf8_lossy(&cold.stderr)
    );
    assert_eq!(reply(cold)["runtimeID"], NATIVE);
    assert_eq!(
        fs::read_to_string(root.join("launched")).unwrap().trim(),
        "--local-control-service"
    );
    wait_for(|| root.join("native-done").exists());
    fs::remove_file(&launcher).unwrap();
    let no = command(root, true).output().unwrap();
    assert_eq!(reply(no)["error"]["code"], "delivery");
    println!("NATIVE_CONTROL_GATE simultaneous_system_native validated_gui_policy explicit_host_loader_argv0 manifest_2MiB_plus invalid_kind_format_cli_launcher_hash_rejected native_only_coldstart missing_launcher_failclosed PASS");
}
