#[cfg(feature = "syntax-folding")]
#[path = "build/folding.rs"]
mod folding;
use std::{env, path::PathBuf, process::Command};

fn output(command: &mut Command) -> String {
    let result = command.output().expect("build tool unavailable");
    assert!(
        result.status.success(),
        "build tool failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    String::from_utf8(result.stdout).expect("tool output is not UTF-8")
}

fn main() {
    println!("cargo:rerun-if-changed=native/icu.c");
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_PATH");
    println!("cargo:rerun-if-env-changed=CC");
    println!("cargo:rerun-if-env-changed=AR");
    println!("cargo:rerun-if-env-changed=CXX");
    let version = output(Command::new("pkg-config").args(["--modversion", "icu-i18n"]));
    assert_eq!(
        version.trim(),
        "78.3",
        "Fastra requires the verified ICU 78.3 runtime"
    );
    let flags = output(Command::new("pkg-config").args(["--cflags", "icu-i18n", "icu-uc"]));
    let libs = output(Command::new("pkg-config").args(["--libs", "icu-i18n", "icu-uc"]));
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let object = out.join("icu.o");
    let mut cc = Command::new(env::var_os("CC").unwrap_or_else(|| "cc".into()));
    cc.args([
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-fPIC",
        "-O2",
        "-c",
        "native/icu.c",
        "-o",
    ])
    .arg(&object)
    .args(flags.split_whitespace());
    output(&mut cc);
    output(
        Command::new(env::var_os("AR").unwrap_or_else(|| "ar".into()))
            .arg("crs")
            .arg(out.join("libfastra_icu.a"))
            .arg(object),
    );
    println!("cargo:rerun-if-changed=native/four_d_macros.cpp");
    let macro_object = out.join("four_d_macros.o");
    let mut cpp = Command::new("c++");
    cpp.args([
        "-std=c++17",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-fPIC",
        "-O2",
        "-c",
        "native/four_d_macros.cpp",
        "-o",
    ])
    .arg(&macro_object)
    .args(flags.split_whitespace());
    output(&mut cpp);
    output(
        Command::new(env::var_os("AR").unwrap_or_else(|| "ar".into()))
            .arg("crs")
            .arg(out.join("libfastra_icu.a"))
            .arg(macro_object),
    );
    for (name, source, includes) in [
        (
            "syntax-runtime",
            "native/regex-syntax/runtime/src/lib.c",
            vec![
                "native/regex-syntax/runtime/include",
                "native/regex-syntax/runtime/src",
            ],
        ),
        (
            "syntax-grammar",
            "native/regex-syntax/grammar/parser.c",
            vec!["native/regex-syntax/grammar"],
        ),
        ("syntax-bridge", "native/regex_syntax.c", vec![]),
    ] {
        println!("cargo:rerun-if-changed={source}");
        let object = out.join(format!("{name}.o"));
        let mut cc = Command::new(env::var_os("CC").unwrap_or_else(|| "cc".into()));
        cc.args([
            "-std=c11",
            "-D_DEFAULT_SOURCE",
            "-D_DARWIN_C_SOURCE",
            "-fPIC",
            "-fvisibility=hidden",
            "-O2",
            "-c",
            source,
            "-o",
        ])
        .arg(&object);
        for include in includes {
            cc.arg("-I").arg(include);
        }
        output(&mut cc);
        output(
            Command::new(env::var_os("AR").unwrap_or_else(|| "ar".into()))
                .arg("crs")
                .arg(out.join("libfastra_icu.a"))
                .arg(object),
        );
    }
    println!("cargo:rerun-if-changed=native/regex-syntax");
    #[cfg(feature = "syntax-folding")]
    folding::build(&out);
    println!(
        "cargo:rustc-link-lib={}",
        if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
            "c++"
        } else {
            "stdc++"
        }
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=fastra_icu");
    for flag in libs.split_whitespace() {
        if let Some(lib) = flag.strip_prefix("-l") {
            println!("cargo:rustc-link-lib={lib}");
        } else if let Some(path) = flag.strip_prefix("-L") {
            println!("cargo:rustc-link-search=native={path}");
        } else {
            panic!("unsupported ICU linker flag: {flag}");
        }
    }
}
