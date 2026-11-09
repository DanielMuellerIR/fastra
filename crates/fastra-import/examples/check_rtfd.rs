//! Isolierte Prüfung der additiven RTFD-Quellidentität; niemals Mitgliedspfade aus JSON öffnen.
use fastra_import::{Cancellation, Importer, Limits, OwnerBinding, Policy};
use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let executable = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .ok_or("pass absolute PMT CLI path")?;
    let importer = Importer::new(executable)?;
    let cancel = Cancellation::default();
    let (catalog, _) = importer.catalog(Policy::default(), Limits::default(), &cancel)?;
    let root = tempfile::tempdir()?;
    let source = root.path().join("source.rtfd");
    fs::create_dir(&source)?;
    let text = b"{\\rtf1\\ansi Synthetic RTFD identity \\b bold\\b0\\par Original text.}";
    fs::write(source.join("TXT.rtf"), text)?;
    fs::write(source.join("unreferenced.bin"), b"asset before")?;
    let destination = root.path().join("destination");
    fs::create_dir(&destination)?;
    let owner = OwnerBinding {
        document_id: "rtfd".into(),
        document_revision: 1,
        project_id: None,
        generation: 1,
    };
    let prepared = importer.prepare(
        &source,
        &destination,
        owner.clone(),
        Policy::default(),
        Limits::default(),
        &cancel,
    )?;
    let identity = prepared
        .preview()
        .response
        .source_identity
        .as_ref()
        .ok_or("sourceIdentity missing")?
        .clone();
    assert_eq!(identity["memberPath"].as_str(), Some("TXT.rtf"));
    let expected = format!("{:x}", Sha256::digest(text));
    assert_eq!(identity["sha256"].as_str(), Some(expected.as_str()));
    assert_eq!(identity["byteCount"].as_u64(), Some(text.len() as u64));
    assert_eq!(
        prepared.preview().response.input.as_deref(),
        source.canonicalize()?.to_str()
    );
    fs::write(source.join("unreferenced.bin"), b"asset after")?;
    let other = importer.prepare(
        &source,
        &destination,
        owner.clone(),
        Policy::default(),
        Limits::default(),
        &cancel,
    )?;
    assert_eq!(
        other.preview().response.source_identity.as_ref().unwrap()["sha256"],
        identity["sha256"]
    );
    drop(other);
    let entry = prepared.preview().entry.clone();
    let publication = prepared.adopt(&owner, "result", &cancel)?;
    assert_eq!(publication.markdown, publication.directory.join(entry));
    assert!(fs::read_to_string(&publication.markdown)?.contains("Synthetic RTFD identity"));
    assert_eq!(fs::read(source.join("TXT.rtf"))?, text);
    println!(
        "{}",
        serde_json::json!({"passed":true,"producerVersion":catalog.version,"memberPath":"TXT.rtf","originalTextSha256":expected,"inputRemainsPackage":true,"assetDoesNotChangeTextFingerprint":true,"adoptionEntryVerified":true})
    );
    Ok(())
}
