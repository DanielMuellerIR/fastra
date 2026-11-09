#[path = "build/native_cmark.rs"]
mod native_cmark;
use std::{env, path::PathBuf, process::Command};
fn main() {
    let metadata = "../../app/Info.plist";
    println!("cargo:rerun-if-changed={metadata}");
    let info = std::fs::read_to_string(metadata).expect("App Info.plist");
    let date = info
        .split("<key>FastraVersionDate</key>")
        .nth(1)
        .and_then(|tail| tail.split("<string>").nth(1))
        .and_then(|tail| tail.split("</string>").next())
        .expect("FastraVersionDate");
    assert!(
        date.len() == 10
            && date
                .bytes()
                .enumerate()
                .all(|(index, value)| if index == 4 || index == 7 {
                    value == b'-'
                } else {
                    value.is_ascii_digit()
                }),
        "ISO version date"
    );
    println!("cargo:rustc-env=FASTRA_VERSION_DATE={date}");
    native_cmark::build();
    let resource = "resources/fastra.gresource.xml";
    println!("cargo:rerun-if-changed={resource}");
    println!("cargo:rerun-if-changed=resources/language-specs/fastra-4d.lang");
    println!("cargo:rerun-if-changed=resources/icons");
    let target =
        PathBuf::from(env::var_os("OUT_DIR").expect("Cargo OUT_DIR")).join("fastra.gresource");
    let status = Command::new("glib-compile-resources")
        .args([resource, "--sourcedir=resources", "--target"])
        .arg(target)
        .status()
        .expect("glib-compile-resources is required (GLib development tools)");
    assert!(
        status.success(),
        "Cannot compile bundled Fastra language resources"
    );
}
