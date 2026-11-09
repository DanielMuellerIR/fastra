use fastra_core::Cancellation;
use fastra_io::code_explanation::Package;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{fs, path::Path};
const SOURCE: &str = "22222222-2222-2222-2222-222222222222";
fn manifest(bytes: &[u8]) -> Value {
    json!({"schemaVersion":1,"id":"11111111-1111-1111-1111-111111111111","title":"Local code question","question":"How does this code work?","language":"en","createdAt":"2026-11-05T09:30:00Z","projectID":"33333333-3333-3333-3333-333333333333","projectName":"Synthetic project","sources":[{"id":SOURCE,"path":"src/source.swift","sha256":format!("{:x}",Sha256::digest(bytes)),"encoding":"utf8"}],"steps":[{"id":"44444444-4444-4444-4444-444444444444","title":"First","text":"First explanation","sourceID":SOURCE,"location":0,"length":1},{"id":"55555555-5555-5555-5555-555555555555","title":"Second","text":"Second explanation","sourceID":SOURCE,"location":1,"length":2}],"codeFontSize":12,"explanationFontSize":12})
}
fn write(root: &Path, value: &Value) {
    fs::write(
        root.join("question.json"),
        serde_json::to_vec(value).unwrap(),
    )
    .unwrap();
}
fn fixture(bytes: &[u8]) -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join("src")).unwrap();
    fs::write(root.path().join("src/source.swift"), bytes).unwrap();
    write(root.path(), &manifest(bytes));
    root
}
fn load(root: &Path) -> Result<Package, fastra_io::code_explanation::Error> {
    Package::load(&root.join("question.json"), &Cancellation::default())
}
#[test]
fn exact_bom_hashes_ranges_and_immutable_loaded_source() {
    let bytes = b"\xef\xbb\xbfa\xf0\x9f\x98\x80\r\nb";
    let root = fixture(bytes);
    let package = load(root.path()).unwrap();
    assert_eq!(
        package.sources.values().next().unwrap().text.as_ref(),
        "a😀\r\nb"
    );
    fs::write(root.path().join("src/source.swift"), b"later change").unwrap();
    assert_eq!(
        package.sources.values().next().unwrap().text.as_ref(),
        "a😀\r\nb"
    );
    assert!(load(root.path()).is_err());
}
#[test]
fn malformed_schema_paths_hashes_utf8_and_character_ranges_are_refused() {
    let bytes = "a😀\r\nb".as_bytes();
    let root = fixture(bytes);
    let valid = manifest(bytes);
    let mutations = [
        ("schemaVersion", json!(2)),
        ("language", json!("fr")),
        ("createdAt", json!("invalid")),
        ("title", json!("")),
        ("codeFontSize", json!(7)),
        ("explanationFontSize", json!(33)),
        ("unexpected", json!(true)),
        ("id", json!("not-uuid")),
    ];
    for (key, value) in mutations {
        let mut data = valid.clone();
        data[key] = value;
        write(root.path(), &data);
        assert!(load(root.path()).is_err(), "{key}");
    }
    for path in [
        "/outside",
        "../outside",
        "src/../source.swift",
        "src//source.swift",
        "src/./source.swift",
        "",
    ] {
        let mut data = valid.clone();
        data["sources"][0]["path"] = json!(path);
        write(root.path(), &data);
        assert!(load(root.path()).is_err(), "{path}");
    }
    for (start, length) in [(2, 0), (1, 1), (3, 1), (100, 0)] {
        let mut data = valid.clone();
        data["steps"][0]["location"] = json!(start);
        data["steps"][0]["length"] = json!(length);
        write(root.path(), &data);
        assert!(load(root.path()).is_err(), "{start}/{length}");
    }
    for bytes in [&b"a\0b"[..], &b"a\xffb"[..], &b"\xff\xfea\0"[..]] {
        fs::write(root.path().join("src/source.swift"), bytes).unwrap();
        write(root.path(), &manifest(bytes));
        assert!(load(root.path()).is_err());
    }
}
#[test]
fn symlink_root_parents_members_manifest_and_fifo_never_escape() {
    use std::os::unix::fs::symlink;
    let root = fixture("a😀\r\nb".as_bytes());
    let outside = tempfile::tempdir().unwrap();
    let marker = outside.path().join("source.swift");
    fs::write(&marker, b"external marker").unwrap();
    symlink(root.path(), outside.path().join("root-link")).unwrap();
    assert!(load(&outside.path().join("root-link")).is_err());
    fs::rename(root.path().join("src"), root.path().join("original-src")).unwrap();
    symlink(outside.path(), root.path().join("src")).unwrap();
    assert!(load(root.path()).is_err());
    fs::remove_file(root.path().join("src")).unwrap();
    fs::rename(root.path().join("original-src"), root.path().join("src")).unwrap();
    let member = root.path().join("src/source.swift");
    fs::remove_file(&member).unwrap();
    symlink(&marker, &member).unwrap();
    assert!(load(root.path()).is_err());
    fs::remove_file(&member).unwrap();
    let name = std::ffi::CString::new(member.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    assert!(load(root.path()).is_err());
    fs::rename(
        root.path().join("question.json"),
        root.path().join("original.json"),
    )
    .unwrap();
    symlink("original.json", root.path().join("question.json")).unwrap();
    assert!(load(root.path()).is_err());
    assert_eq!(fs::read(marker).unwrap(), b"external marker");
}
#[test]
fn per_source_aggregate_manifest_limits_and_cancel_hold() {
    let root = fixture(&vec![b'a'; 262145]);
    assert!(load(root.path()).is_err());
    fs::write(root.path().join("question.json"), vec![b' '; 65537]).unwrap();
    assert!(load(root.path()).is_err());
    let root = fixture("a😀\r\nb".as_bytes());
    let mut data = manifest("a😀\r\nb".as_bytes());
    let duplicate = data["sources"][0].clone();
    data["sources"].as_array_mut().unwrap().push(duplicate);
    write(root.path(), &data);
    assert!(load(root.path()).is_err());
    let large = vec![b'a'; 262144];
    let aggregate = fixture(&large);
    let mut data = manifest(&large);
    let source = data["sources"][0].clone();
    for index in 0..4 {
        let mut next = source.clone();
        next["id"] = json!(format!("90000000-0000-0000-0000-{index:012}"));
        data["sources"].as_array_mut().unwrap().push(next);
    }
    write(aggregate.path(), &data);
    assert!(load(aggregate.path()).is_err());
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(Package::load(&root.path().join("question.json"), &cancel).is_err());
}
