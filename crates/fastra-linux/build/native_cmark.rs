use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    env, fs,
    path::{Component, Path, PathBuf},
    process::Command,
};
const REVISION: &str = "924936d0427cb25a61169739a7660230bffa6ea6";
fn files(root: &Path, relative: &Path, output: &mut BTreeSet<String>) {
    for entry in fs::read_dir(root.join(relative)).expect("cmark vendor directory") {
        let entry = entry.expect("cmark vendor entry");
        let path = relative.join(entry.file_name());
        let metadata = fs::symlink_metadata(entry.path()).expect("cmark vendor metadata");
        assert!(
            !metadata.file_type().is_symlink(),
            "cmark vendor symlink: {}",
            path.display()
        );
        if metadata.is_dir() {
            files(root, &path, output);
        } else {
            assert!(metadata.is_file(), "cmark vendor file type");
            output.insert(path.to_str().expect("UTF8 vendor path").replace('\\', "/"));
        }
    }
}
pub fn build() {
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("Cargo manifest"));
    let native = root.join("native");
    let cmark = native.join("cmark");
    let vendor = cmark.join("vendor");
    println!("cargo:rerun-if-changed=native");
    println!("cargo:rerun-if-env-changed=CC");
    println!("cargo:rerun-if-env-changed=AR");
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(cmark.join("UPSTREAM.json")).expect("cmark manifest"))
            .expect("cmark manifest JSON");
    assert_eq!(
        manifest["revision"].as_str(),
        Some(REVISION),
        "Unverified cmark revision"
    );
    let entries = manifest["files"].as_object().expect("cmark file manifest");
    let mut actual = BTreeSet::new();
    files(&vendor, Path::new(""), &mut actual);
    let expected = entries.keys().cloned().collect::<BTreeSet<_>>();
    assert_eq!(actual, expected, "cmark vendor file set changed");
    for (name, hashes) in entries {
        assert!(
            Path::new(name)
                .components()
                .all(|part| matches!(part, Component::Normal(_))),
            "Invalid cmark manifest path"
        );
        let bytes = fs::read(vendor.join(name)).expect("cmark source file");
        let hash = format!("{:x}", Sha256::digest(&bytes));
        assert_eq!(
            Some(hash.as_str()),
            hashes["patched"].as_str(),
            "cmark source hash mismatch: {name}"
        );
    }
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo OUT_DIR")).join("cmark");
    fs::create_dir_all(&output).expect("cmark output");
    let cc = env::var_os("CC").unwrap_or_else(|| "cc".into());
    let ar = env::var_os("AR").unwrap_or_else(|| "ar".into());
    let core = [
        "arena",
        "blocks",
        "buffer",
        "cmark",
        "cmark_ctype",
        "commonmark",
        "fastra_metadata",
        "footnotes",
        "houdini_href_e",
        "houdini_html_e",
        "houdini_html_u",
        "html",
        "inlines",
        "iterator",
        "latex",
        "linked_list",
        "man",
        "map",
        "node",
        "plaintext",
        "plugin",
        "references",
        "registry",
        "render",
        "scanners",
        "syntax_extension",
        "utf8",
        "xml",
    ];
    let extensions = [
        "core-extensions",
        "autolink",
        "strikethrough",
        "table",
        "tagfilter",
        "tasklist",
        "ext_scanners",
    ];
    let mut sources = core
        .iter()
        .map(|name| vendor.join("src").join(format!("{name}.c")))
        .chain(
            extensions
                .iter()
                .map(|name| vendor.join("extensions").join(format!("{name}.c"))),
        )
        .collect::<Vec<_>>();
    sources.push(native.join("markdown_autolinks.c"));
    let mut objects = Vec::new();
    for (index, source) in sources.iter().enumerate() {
        let object = output.join(format!("{index}.o"));
        let mut command = Command::new(&cc);
        command.args([
            "-std=c11",
            "-O2",
            "-fPIC",
            "-pthread",
            "-DCMARK_THREADING=1",
            "-DCMARK_GFM_STATIC_DEFINE",
            "-DCMARK_GFM_EXTENSIONS_STATIC_DEFINE",
        ]);
        for include in [
            native.clone(),
            vendor.join("src/include"),
            vendor.join("extensions/include"),
        ] {
            command.arg("-I").arg(include);
        }
        command.arg("-c").arg(source).arg("-o").arg(&object);
        let status = command.status().expect("native C compiler unavailable");
        assert!(
            status.success(),
            "cmark compilation failed: {}",
            source.display()
        );
        objects.push(object);
    }
    let archive = output.join("libfastra_cmark.a");
    let status = Command::new(ar)
        .arg("crs")
        .arg(&archive)
        .args(&objects)
        .status()
        .expect("native archiver unavailable");
    assert!(status.success(), "cmark archive failed");
    let binding = serde_json::json!({"revision":REVISION,"manifest_sha256":format!("{:x}",Sha256::digest(fs::read(cmark.join("UPSTREAM.json")).expect("cmark manifest"))),"bridge_sha256":format!("{:x}",Sha256::digest(fs::read(native.join("markdown_autolinks.c")).expect("cmark bridge"))),"header_sha256":format!("{:x}",Sha256::digest(fs::read(native.join("markdown_autolinks.h")).expect("cmark header"))),"threading":true});
    fs::write(
        output.join("binding.json"),
        serde_json::to_vec_pretty(&binding).expect("native binding JSON"),
    )
    .expect("native binding write");
    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-lib=static=fastra_cmark");
    println!("cargo:rustc-link-lib=pthread");
}
