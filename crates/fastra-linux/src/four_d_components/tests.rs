use super::*;
use std::{fs::File, io::Write, os::unix::fs::symlink};
fn fixture() -> tempfile::TempDir {
    std::env::var_os("FASTRA_IO_TEST_ROOT").map_or_else(
        || tempfile::tempdir().unwrap(),
        |p| tempfile::tempdir_in(p).unwrap(),
    )
}
fn zip(path: &Path, entries: &[(&str, &[u8])], method: zip::CompressionMethod) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut writer = zip::ZipWriter::new(File::create(path).unwrap());
    for (name, data) in entries {
        writer
            .start_file(
                *name,
                zip::write::SimpleFileOptions::default().compression_method(method),
            )
            .unwrap();
        writer.write_all(data).unwrap();
    }
    writer.finish().unwrap();
}
#[test]
fn interpreted_shared_sources_both_folder_cases_and_collision_order() {
    let temp = fixture();
    let root = temp.path();
    for (component, folder, method, shared) in [
        ("A", "Components", "Shared", true),
        ("Z", "components", "Shared", true),
        ("B", "components", "Private", false),
    ] {
        let dir = root
            .join(folder)
            .join(format!("{component}.4dbase/Sources/Methods"));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(format!("{method}.4dm")),format!("//%attributes={{\"shared\":{shared}}}\r\n#DECLARE($text : Text) -> $result : Boolean")).unwrap();
    }
    let index = scan(root, &Cancellation::default()).unwrap();
    assert_eq!(index.methods.len(), 1);
    assert_eq!(index.methods[0].name, "Shared");
    assert_eq!(index.methods[0].component, "A");
    assert!(index.methods[0]
        .signature
        .as_ref()
        .unwrap()
        .contains("$text : Text"));
}
#[test]
fn stored_and_deflated_source_archives_prefer_sources_to_catalogs() {
    for compression in [
        zip::CompressionMethod::Stored,
        zip::CompressionMethod::Deflated,
    ] {
        let temp = fixture();
        let path = temp.path().join("Components/Source.4DZ");
        zip(
            &path,
            &[
                (
                    "Project/Sources/Methods/ÉShared.4dm",
                    b"//%attributes={\"shared\":true}\n#DECLARE($one : Text)",
                ),
                (
                    "Project/Sources/Methods/Private.4dm",
                    b"//%attributes={\"shared\":false}",
                ),
                (
                    "Project/DerivedData/methodAttributes.json",
                    br#"{"methods":{"MustNotAppear":{"attributes":{"shared":true}}}}"#,
                ),
            ],
            compression,
        );
        // 4D-/Mac-Lesen beruht auf den UTF-8-Namensbytes, nicht auf einem zuverlässigen ZIP-Flag.
        let mut bytes = fs::read(&path).unwrap();
        for offset in 0..bytes.len().saturating_sub(10) {
            if &bytes[offset..offset + 4] == b"PK\x03\x04" {
                bytes[offset + 7] &= !0x08;
            }
            if &bytes[offset..offset + 4] == b"PK\x01\x02" {
                bytes[offset + 9] &= !0x08;
            }
        }
        fs::write(&path, bytes).unwrap();
        let index = scan(temp.path(), &Cancellation::default()).unwrap();
        assert_eq!(index.methods.len(), 1);
        assert_eq!(index.methods[0].name, "ÉShared");
        assert!(index.methods[0]
            .signature
            .as_ref()
            .unwrap()
            .contains("$one"));
    }
}
#[test]
fn compiled_bundle_catalog_uses_exported_documentation_and_name_only_fallback() {
    let temp = fixture();
    let bundle = temp.path().join("Components/Built.4dbase");
    let docs = bundle.join("Contents/Documentation/Methods");
    fs::create_dir_all(&docs).unwrap();
    fs::write(
        docs.join("Known.md"),
        "// exported\n#DECLARE($value : Integer) -> $result : Text",
    )
    .unwrap();
    zip(&bundle.join("Contents/Built.4DZ"),&[("Project/DerivedData/methodAttributes.json",br#"{"methods":{"Known":{"attributes":{"shared":true}},"NameOnly":{"attributes":{"shared":true}},"Private":{"attributes":{"shared":false}}}}"#)],zip::CompressionMethod::Deflated);
    let index = scan(temp.path(), &Cancellation::default()).unwrap();
    assert_eq!(index.methods.len(), 2);
    assert!(index
        .methods
        .iter()
        .find(|m| m.name == "Known")
        .unwrap()
        .signature
        .as_ref()
        .unwrap()
        .contains("$value"));
    assert!(index
        .methods
        .iter()
        .find(|m| m.name == "NameOnly")
        .unwrap()
        .signature
        .is_none());
}
#[test]
fn corrupted_crc_unsafe_names_size_cancel_and_symlink_never_publish_partial_index() {
    let temp = fixture();
    let path = temp.path().join("Components/Test.4DZ");
    let source = b"//%attributes={\"shared\":true}\n#DECLARE($test : Text)";
    zip(
        &path,
        &[("Project/Sources/Methods/Test.4dm", source)],
        zip::CompressionMethod::Stored,
    );
    let mut bytes = fs::read(&path).unwrap();
    let at = bytes
        .windows(source.len())
        .position(|s| s == source)
        .unwrap();
    bytes[at + source.len() - 1] ^= 1;
    fs::write(&path, bytes).unwrap();
    assert!(scan(temp.path(), &Cancellation::default()).is_err());
    zip(
        &path,
        &[("../outside", b"unused")],
        zip::CompressionMethod::Stored,
    );
    assert!(scan(temp.path(), &Cancellation::default()).is_err());
    assert!(!temp.path().join("outside").exists());
    zip(
        &path,
        &[(
            "Project/Sources/Methods/Large.4dm",
            &vec![b'x'; ENTRY_BYTES + 1],
        )],
        zip::CompressionMethod::Deflated,
    );
    assert!(scan(temp.path(), &Cancellation::default()).is_err());
    fs::remove_file(&path).unwrap();
    symlink("/etc/passwd", &path).unwrap();
    assert!(scan(temp.path(), &Cancellation::default()).is_err());
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(scan(temp.path(), &cancel).is_err());
}

#[test]
fn discovery_honors_a_callers_remaining_directory_budget() {
    let temp = fixture();
    let folder = temp.path().join("Components");
    fs::create_dir_all(folder.join("A.4dbase")).unwrap();
    fs::create_dir_all(folder.join("B.4dbase")).unwrap();
    assert!(discover_with_budget(temp.path(), &Cancellation::default(), 1).is_err());
    assert!(discover_with_budget(temp.path(), &Cancellation::default(), 0).is_err());
    let discovery = discover_with_budget(temp.path(), &Cancellation::default(), 10).unwrap();
    assert_eq!(discovery.visited, 2);
    assert_eq!(discovery.bundles.len(), 2);
}

#[test]
fn excessive_declared_directory_and_zip64_are_rejected_before_index_construction() {
    let temp = fixture();
    let path = temp.path().join("Components/Metadata.4DZ");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut writer = zip::ZipWriter::new(File::create(&path).unwrap());
    for index in 0..=MAX_ENTRIES {
        writer
            .start_file(
                format!("unused/{index}"),
                zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Stored),
            )
            .unwrap();
    }
    writer.finish().unwrap();
    assert!(scan(temp.path(), &Cancellation::default())
        .err()
        .unwrap()
        .contains("declared metadata limit"));
    let mut header = vec![0; 22];
    header[..4].copy_from_slice(b"PK\x05\x06");
    header[8..12].fill(0xff);
    header[16..20].fill(0xff);
    fs::write(&path, header).unwrap();
    assert!(scan(temp.path(), &Cancellation::default())
        .err()
        .unwrap()
        .contains("declared metadata limit"));
}

fn forged_directory_size(path: &Path, extra_entries: usize) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut writer = zip::ZipWriter::new(File::create(path).unwrap());
    writer
        .start_file(
            "Project/Sources/Methods/Shared.4dm",
            zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Stored),
        )
        .unwrap();
    let header = b"//%attributes={\"shared\":true}\n";
    let mut source = vec![b' '; ENTRY_BYTES];
    source[..header.len()].copy_from_slice(header);
    writer.write_all(&source).unwrap();
    let mut options =
        zip::write::FullFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    options
        .add_extra_data(0xcafe, vec![0; 32768].into_boxed_slice(), true)
        .unwrap();
    for index in 0..extra_entries {
        writer
            .start_file(format!("unused/{index:04}"), options.clone())
            .unwrap();
    }
    writer.finish().unwrap();
    let mut bytes = fs::read(path).unwrap();
    let end = bytes.len() - 22;
    assert_eq!(&bytes[end..end + 4], b"PK\x05\x06");
    bytes[end + 12..end + 16].fill(0);
    fs::write(path, bytes).unwrap();
}
#[test]
fn actual_central_directory_bytes_are_bounded_despite_a_false_declared_size() {
    let temp = fixture();
    let path = temp.path().join("Components/ActualMetadata.4DZ");
    forged_directory_size(&path, 1000);
    let index = scan(temp.path(), &Cancellation::default()).unwrap();
    assert_eq!(index.methods.len(), 1);
    assert_eq!(index.methods[0].name, "Shared");
    // >32 MiB echte zentrale Extra-Daten, aber directory_size=0 und nur 1031 Einträge.
    forged_directory_size(&path, 1030);
    let error = scan(temp.path(), &Cancellation::default())
        .err()
        .expect("actual metadata must be bounded before an index can escape");
    assert!(error.contains("actual metadata input limit"), "{error}");
}
