use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fs, io::Read, path::Path, process::Command};
fn strings(value: &Value) -> impl Iterator<Item = &str> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap())
}
fn verified(data: &[u8], expected: &str) {
    assert_eq!(
        format!("{:x}", Sha256::digest(data)),
        expected,
        "folding grammar source hash mismatch"
    );
}
pub fn build(out: &Path) {
    let base = Path::new("native/folding");
    println!("cargo:rerun-if-changed=native/folding");
    println!("cargo:rerun-if-changed=native/folding.c");
    let catalog: Value =
        serde_json::from_slice(&fs::read(base.join("catalog.json")).unwrap()).unwrap();
    assert_eq!(catalog["runtime"], "0.25.10");
    let mut declarations = String::from("#include <tree_sitter/api.h>\n");
    let mut dispatch =
        String::from("static const TSLanguage *fold_language(unsigned index) { switch(index) {\n");
    let mut names = BTreeSet::new();
    for language in catalog["languages"].as_array().unwrap() {
        if let Some(symbol) = language["symbol"].as_str() {
            names.insert(symbol.to_owned());
        }
    }
    let mut rust = String::from("pub const GRAMMARS: &[(&str,u32,u32)] = &[\n");
    for (index, symbol) in names.iter().enumerate() {
        declarations += &format!("extern const TSLanguage *fastra_fold_{symbol}(void);\n");
        dispatch += &format!("case {index}: return fastra_fold_{symbol}();\n");
        let abi = catalog["grammars"]
            .as_array()
            .unwrap()
            .iter()
            .find_map(|grammar| {
                grammar["abi_by_symbol"]
                    .get(symbol)
                    .and_then(|value| value.as_u64())
            })
            .expect("grammar ABI in catalog");
        for language in catalog["languages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|l| l["symbol"] == symbol.as_str())
        {
            rust += &format!(
                "({:?},{index},{abi}),\n",
                language["mac_id"].as_str().unwrap()
            );
        }
    }
    rust += "];\n";
    fs::write(out.join("folding_catalog.rs"), rust).unwrap();
    dispatch += "default: return NULL; }}\n";
    declarations += &dispatch;
    fs::write(out.join("folding_catalog.h"), declarations).unwrap();
    for grammar in catalog["grammars"].as_array().unwrap() {
        let name = grammar["repository"].as_str().unwrap();
        let destination = out.join("folding").join(name);
        for (file, hash) in grammar["license_sha256"].as_object().unwrap() {
            verified(
                &fs::read(base.join(name).join(file)).unwrap(),
                hash.as_str().unwrap(),
            );
        }
        for file in grammar["files"].as_array().unwrap() {
            let relative = file["path"].as_str().unwrap();
            assert!(Path::new(relative)
                .components()
                .all(|c| matches!(c, std::path::Component::Normal(_))));
            let zipped = fs::read(base.join(name).join(format!("{relative}.gz"))).unwrap();
            verified(&zipped, file["gzip_sha256"].as_str().unwrap());
            let length = file["bytes"].as_u64().unwrap();
            assert!(length <= 80 * 1024 * 1024);
            let mut data = Vec::new();
            flate2::read::GzDecoder::new(zipped.as_slice())
                .take(length + 1)
                .read_to_end(&mut data)
                .unwrap();
            assert_eq!(data.len() as u64, length);
            verified(&data, file["sha256"].as_str().unwrap());
            let path = destination.join(relative);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, data).unwrap();
        }
        for (index, source) in strings(&grammar["sources"]).enumerate() {
            let object = out.join(format!("{name}-{index}.o"));
            let cpp = source.ends_with(".cc") || source.ends_with(".cpp");
            let mut command = Command::new(if cpp {
                std::env::var_os("CXX").unwrap_or_else(|| "c++".into())
            } else {
                std::env::var_os("CC").unwrap_or_else(|| "cc".into())
            });
            command
                .args([
                    if cpp { "-std=c++17" } else { "-std=c11" },
                    "-D_DEFAULT_SOURCE",
                    "-D_DARWIN_C_SOURCE",
                    "-fPIC",
                    "-fvisibility=hidden",
                    "-O2",
                    "-c",
                ])
                .arg(destination.join(source))
                .arg("-o")
                .arg(&object);
            command
                .arg("-I")
                .arg(destination.join(source).parent().unwrap());
            for include in strings(&grammar["includes"]) {
                command.arg("-I").arg(destination.join(include));
            }
            for symbol in strings(&grammar["symbols"]) {
                command.arg(format!("-D{symbol}=fastra_fold_{symbol}"));
            }
            super::output(&mut command);
            super::output(
                Command::new(std::env::var_os("AR").unwrap_or_else(|| "ar".into()))
                    .arg("crs")
                    .arg(out.join("libfastra_icu.a"))
                    .arg(object),
            );
        }
    }
    let object = out.join("folding-bridge.o");
    super::output(
        Command::new(std::env::var_os("CC").unwrap_or_else(|| "cc".into()))
            .args([
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-fPIC",
                "-fvisibility=hidden",
                "-O2",
                "-c",
                "native/folding.c",
                "-I",
                "native/regex-syntax/runtime/include",
                "-I",
            ])
            .arg(out)
            .arg("-o")
            .arg(&object),
    );
    super::output(
        Command::new(std::env::var_os("AR").unwrap_or_else(|| "ar".into()))
            .arg("crs")
            .arg(out.join("libfastra_icu.a"))
            .arg(object),
    );
}
