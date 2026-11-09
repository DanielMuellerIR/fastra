#![cfg(target_os = "linux")]
use fastra_diff_helper::*;
use gio::glib::{self, prelude::*};
use std::{
    fs,
    os::unix::fs::{symlink, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};
fn wait_for(mut f: impl FnMut() -> bool) {
    let at = Instant::now();
    while !f() {
        assert!(at.elapsed() < Duration::from_secs(4));
        std::thread::sleep(Duration::from_millis(10));
    }
}
#[test]
fn bus_driver() {
    let Some(role) = std::env::var_os("FASTRA_DIFF_TARGET_TEST_ROLE") else {
        return;
    };
    let native = role == "native";
    let root = PathBuf::from(std::env::var_os("FASTRA_DIFF_TARGET_TEST_ROOT").unwrap());
    let name = bus().unwrap();
    assert_eq!(name, if native { NATIVE_BUS } else { BUS });
    let context = glib::MainContext::default();
    context.with_thread_default(||{
        let connection=gio::bus_get_sync(gio::BusType::Session,None::<&gio::Cancellable>).unwrap();
        let owned=connection.call_sync(Some("org.freedesktop.DBus"),"/org/freedesktop/DBus","org.freedesktop.DBus","RequestName",Some(&(name,0u32).to_variant()),None,gio::DBusCallFlags::NONE,2000,None::<&gio::Cancellable>).unwrap();assert_eq!(owned.get::<(u32,)>().unwrap().0,1);
        let info=gio::DBusNodeInfo::for_xml("<node><interface name='org.fastra.Diff1'><method name='Deliver'><arg type='s' direction='in'/><arg type='i' direction='out'/></method></interface></node>").unwrap();
        let loop_=glib::MainLoop::new(Some(&context),false);let done=loop_.clone();let delivered=root.join(if native{"native-delivered"}else{"system-delivered"});let recorded=delivered.clone();
        let registration=connection.register_object(PATH,&info.interfaces()[0]).method_call(move|_,_,_,_,method,params,invocation|{
            assert_eq!(method,"Deliver");let(payload,)=params.get::<(String,)>().unwrap();let request=Request::decode(&payload).unwrap();assert_eq!(request.left_label,if native{"native"}else{"system"});fs::write(&recorded,"delivered").unwrap();invocation.return_value(Some(&(0i32,).to_variant()));let done=done.clone();glib::timeout_add_local_once(Duration::from_millis(80),move||done.quit());
        }).build().unwrap();
        fs::write(root.join(if native{"native-ready"}else{"system-ready"}),"ready").unwrap();let timeout=loop_.clone();let source=glib::timeout_add_local_once(Duration::from_secs(5),move||timeout.quit());loop_.run();if delivered.exists(){source.remove();}assert!(delivered.exists());connection.unregister_object(registration).unwrap();
    }).unwrap();
}
fn manifest(root: &Path) {
    let own = root.join("app/libexec/fastra-diff");
    let launcher = root.join("bin/fastra-native");
    let value = serde_json::json!({"format":1,"kind":"fastra-optional-native-package","sha256":{"app/libexec/fastra-diff":fastra_io::local_control::hash(&fs::read(own).unwrap()),"bin/fastra-native":fastra_io::local_control::hash(&fs::read(launcher).unwrap())}});
    fs::write(
        root.join("native-package.json"),
        serde_json::to_vec(&value).unwrap(),
    )
    .unwrap();
}
fn command(root: &Path, native: bool) -> Command {
    let elf = root.join("app/libexec/fastra-diff");
    let mut c = if native {
        let mut c = Command::new("/lib64/ld-linux-x86-64.so.2");
        c.arg("--argv0")
            .arg(&elf)
            .arg("--library-path")
            .arg(root.join("app/lib"))
            .arg(&elf);
        c.env("FASTRA_INTERNAL_NATIVE_SERVICE", "1");
        c
    } else {
        let mut c = Command::new(elf);
        c.env_remove("FASTRA_INTERNAL_NATIVE_SERVICE");
        c
    };
    c.args([
        "--left-label",
        if native { "native" } else { "system" },
        "--",
    ])
    .arg(root.join("left"))
    .arg(root.join("right"))
    .env_remove("FASTRA_NATIVE_RUNTIME")
    .env_remove("FASTRA_NATIVE_SHADOW_MANIFEST");
    c
}
#[test]
fn simultaneous_bus_targets_and_manifest_only_native_coldstart() {
    if std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_none() {
        println!("SKIP: this integration gate requires an explicitly private dbus-run-session");
        return;
    }
    let temp = tempfile::tempdir_in("/tmp").unwrap();
    let root = temp.path();
    fs::create_dir_all(root.join("app/libexec")).unwrap();
    fs::create_dir(root.join("bin")).unwrap();
    symlink("/runtime/lib", root.join("app/lib")).unwrap();
    fs::copy(
        std::env::var_os("FASTRA_TEST_DIFF_ELF")
            .unwrap_or_else(|| env!("CARGO_BIN_EXE_fastra-diff").into()),
        root.join("app/libexec/fastra-diff"),
    )
    .unwrap();
    for name in ["left", "right"] {
        fs::write(root.join(name), name).unwrap();
    }
    let launcher = root.join("bin/fastra-native");
    fs::write(&launcher,"#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$FASTRA_DIFF_TARGET_TEST_ROOT/launched\"\nexec \"$FASTRA_DIFF_TARGET_TEST_BINARY\" --exact bus_driver --nocapture\n").unwrap();
    fs::set_permissions(&launcher, fs::Permissions::from_mode(0o700)).unwrap();
    let gui = root.join("app/libexec/fastra-linux");
    fs::write(&gui, "#!/bin/sh\nexit 97\n").unwrap();
    fs::set_permissions(&gui, fs::Permissions::from_mode(0o700)).unwrap();
    manifest(root);
    let server = |native: bool| {
        let mut c = Command::new(std::env::current_exe().unwrap());
        c.args(["--exact", "bus_driver", "--nocapture"])
            .env(
                "FASTRA_DIFF_TARGET_TEST_ROLE",
                if native { "native" } else { "system" },
            )
            .env("FASTRA_DIFF_TARGET_TEST_ROOT", root)
            .env_remove("FASTRA_NATIVE_RUNTIME")
            .env_remove("FASTRA_NATIVE_SHADOW_MANIFEST");
        if native {
            c.env("FASTRA_INTERNAL_NATIVE_SERVICE", "1");
        } else {
            c.env_remove("FASTRA_INTERNAL_NATIVE_SERVICE");
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
    assert!(!bad.status.success());
    assert!(!root.join("system-delivered").exists());
    assert!(!root.join("native-delivered").exists());
    let sys = command(root, false).output().unwrap();
    assert!(
        sys.status.success(),
        "{}",
        String::from_utf8_lossy(&sys.stderr)
    );
    let nat = command(root, true).output().unwrap();
    assert!(
        nat.status.success(),
        "{}",
        String::from_utf8_lossy(&nat.stderr)
    );
    assert!(!root.join("launched").exists());
    assert!(system.wait_with_output().unwrap().status.success());
    assert!(native.wait_with_output().unwrap().status.success());
    fs::remove_file(root.join("native-delivered")).unwrap();
    fs::remove_file(root.join("native-ready")).unwrap();
    let cold = command(root, true)
        .env("FASTRA_DIFF_TARGET_TEST_ROLE", "native")
        .env("FASTRA_DIFF_TARGET_TEST_ROOT", root)
        .env(
            "FASTRA_DIFF_TARGET_TEST_BINARY",
            std::env::current_exe().unwrap(),
        )
        .output()
        .unwrap();
    assert!(
        cold.status.success(),
        "{}",
        String::from_utf8_lossy(&cold.stderr)
    );
    assert_eq!(
        fs::read_to_string(root.join("launched")).unwrap().trim(),
        "--external-diff-service"
    );
    assert!(root.join("native-delivered").exists());
    fs::remove_file(launcher).unwrap();
    let no = command(root, true).output().unwrap();
    assert_eq!(no.status.code(), Some(5));
    println!("NATIVE_DIFF_GATE simultaneous_private_dbus_system_native explicit_loader_argv0 native_only_coldstart missing_launcher_failclosed PASS");
}
