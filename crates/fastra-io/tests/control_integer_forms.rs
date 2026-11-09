use fastra_core::{local_control::*, Cancellation};
use fastra_io::local_control::{self as io, Adopted};
use std::fs;
#[test]
fn decimal_and_exponent_metadata_adopt_the_actual_unchanged_file_generation() {
    let root = std::env::var_os("FASTRA_IO_TEST_ROOT").unwrap_or_else(|| "/tmp".into());
    let dir = tempfile::tempdir_in(root).unwrap();
    let path = dir.path().join("source.txt");
    fs::write(&path, b"abc").unwrap();
    let generation = io::generation(&fs::metadata(&path).unwrap());
    let mut r = Request::new("sourceSnapshot", io::uuid(), io::now());
    r.path = Some(path.to_str().unwrap().into());
    r.sha256 = Some(io::hash(b"abc"));
    r.location = Some(0);
    r.length = Some(3);
    r.provenance = Some(Provenance {
        schema_version: 1,
        run_id: io::uuid(),
        kind: "original".into(),
        hit_identity: HitIdentity {
            filesystem_path: r.path.clone().unwrap(),
            archive_members: vec![],
            archive_member_bytes: vec![],
        },
        source_generation: generation.clone(),
        archive_binding: "notApplicable".into(),
        outer_sha256: None,
        position_binding: "exactUTF16".into(),
        search_evidence: None,
    });
    let mut raw = serde_json::to_string(&r)
        .unwrap()
        .replace("\"version\":1", "\"version\":1e0")
        .replace("\"schemaVersion\":1", "\"schemaVersion\":1.0")
        .replace("\"location\":0", "\"location\":0.0")
        .replace("\"length\":3", "\"length\":3e0");
    for (field, value) in [
        ("device", generation.device.to_string()),
        ("inode", generation.inode.to_string()),
        ("size", generation.size.to_string()),
        (
            "modificationSeconds",
            generation.modification_seconds.to_string(),
        ),
        (
            "modificationNanoseconds",
            generation.modification_nanoseconds.to_string(),
        ),
        ("changeSeconds", generation.change_seconds.to_string()),
        (
            "changeNanoseconds",
            generation.change_nanoseconds.to_string(),
        ),
    ] {
        raw = raw.replace(
            &format!("\"{field}\":{value}"),
            &format!("\"{field}\":{value}e0"),
        );
    }
    let request = Request::decode(raw.as_bytes()).unwrap();
    assert_eq!(
        request.provenance.as_ref().unwrap().source_generation,
        generation
    );
    let owned = Adopted::adopt(&request, dir.path(), &Cancellation::default()).unwrap();
    assert_eq!(owned.loaded.text.as_ref(), "abc");
    assert_eq!(fs::read(owned.path()).unwrap(), b"abc");
    drop(owned);
    assert_eq!(fs::read(path).unwrap(), b"abc");
}
