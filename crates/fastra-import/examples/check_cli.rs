//! Isolierter Integrationscheck gegen ein ausdrücklich übergebenes lokales CLI.
use fastra_import::{Cancellation, Importer, Limits, OwnerBinding, Policy};
use std::{fs, path::PathBuf};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let executable = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .ok_or("pass an absolute PMT CLI path")?;
    let importer = Importer::new(executable)?;
    let cancel = Cancellation::default();
    let (catalog, _) = importer.catalog(Policy::default(), Limits::default(), &cancel)?;
    println!(
        "catalog {}: {} formats",
        catalog.version,
        catalog.formats.len()
    );
    let root = tempfile::tempdir()?;
    for (name, content) in [
        ("table.csv", "Name,Value\nCafé,😀\nSecond,2\n"),
        ("mail.mbox", "From a@example.invalid Sat Jan  1 00:00:00 2022\nFrom: a@example.invalid\nTo: b@example.invalid\nSubject: One\nDate: Sat, 1 Jan 2022 00:00:00 +0000\nContent-Type: text/plain; charset=UTF-8\n\nFirst café.\n\nFrom b@example.invalid Sun Jan  2 00:00:00 2022\nFrom: b@example.invalid\nTo: a@example.invalid\nSubject: Two\nDate: Sun, 2 Jan 2022 00:00:00 +0000\nContent-Type: text/plain; charset=UTF-8\n\nSecond message.\n"),
    ] {
        let source = root.path().join(name); fs::write(&source, content)?;
        let destination = root.path().join(format!("destination-{name}")); fs::create_dir(&destination)?;
        let owner = OwnerBinding { document_id: name.into(), document_revision: 1, project_id: None, generation: 1 };
        let prepared = importer.prepare(&source, &destination, owner.clone(), Policy::default(), Limits::default(), &cancel)?;
        let relative = prepared.preview().entry.clone(); let documents = prepared.preview().documents.len(); let files = prepared.preview().files.len();
        let published = prepared.adopt(&owner, "result", &cancel)?;
        assert_eq!(published.markdown, published.directory.join(&relative));
        assert!(published.markdown.is_file()); assert!(!fs::read_to_string(&published.markdown)?.is_empty());
        assert_eq!(fs::read_to_string(&source)?, content);
        if name.ends_with("mbox") { assert_eq!(relative.to_str(), Some("index.md")); assert_eq!(documents, 2); }
        println!("PASS {name}: {} files, {documents} documents, entry {}", files, relative.display());
    }
    Ok(())
}
