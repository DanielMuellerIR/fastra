//! Gekoppelter Regressionseinstieg für echte Runtime-Bindmounts (eigener Testprozess).
use std::path::{Path, PathBuf};

#[test]
fn native_overlay_document_search_import_and_markdown() {
    if std::env::var("FASTRA_POLICY_TEST_CASE").as_deref() != Ok("overlay") {
        return;
    }
    fastra_io::initialize_runtime_policy().unwrap();
    let root = PathBuf::from(std::env::var_os("FASTRA_POLICY_TEST_ROOT").unwrap());
    let shadow = Path::new("/usr/bin/bwrap");
    let cancel = fastra_core::Cancellation::default();
    assert!(
        matches!(fastra_document::Document::open(shadow, None, &cancel), Err(fastra_document::Error::Io(error)) if error.kind() == std::io::ErrorKind::PermissionDenied)
    );
    assert!(
        matches!(fastra_document::Document::open_hex(shadow, &cancel), Err(fastra_document::Error::Io(error)) if error.kind() == std::io::ErrorKind::PermissionDenied)
    );
    let load_error = crate::loader::read(shadow).unwrap_err();
    for de in [true, false] {
        let message = load_error.message(de);
        assert!(
            message.contains("überlagert") && message.contains("runtime shadows"),
            "{message}"
        );
    }
    let request = fastra_search::Request {
        roots: vec![PathBuf::from("/usr/bin")],
        search: fastra_core::SearchRequest {
            pattern: "overlay".into(),
            replacement: "host".into(),
            mode: fastra_core::SearchMode::Literal,
            case_sensitive: true,
            range: None,
        },
        flags: fastra_core::SearchFlags::default(),
        exclusions: vec!["bwrap".into()],
        include_hidden: false,
        known_text_only: true,
    };
    let error = fastra_search::preview(&request, 1, &cancel).err().unwrap();
    assert!(error.to_string().contains("runtime shadows"), "{error}");
    assert!(
        matches!(fastra_io::code_explanation::Package::load(shadow, &cancel), Err(fastra_io::code_explanation::Error::Io(error)) if error.kind() == std::io::ErrorKind::PermissionDenied)
    );
    let importer =
        fastra_import::Importer::new(PathBuf::from("/nonexistent/runtime-policy-test-tool"))
            .unwrap();
    let owner = fastra_import::OwnerBinding {
        document_id: "test".into(),
        document_revision: 0,
        project_id: None,
        generation: 0,
    };
    let process_cancel = fastra_import::Cancellation::default();
    for (source, destination) in [
        (shadow, root.as_path()),
        (
            root.as_path(),
            Path::new("/usr/lib/x86_64-linux-gnu/webkitgtk-6.0"),
        ),
    ] {
        let result = importer.prepare(
            source,
            destination,
            owner.clone(),
            fastra_import::Policy::default(),
            fastra_import::Limits::default(),
            &process_cancel,
        );
        assert!(
            matches!(result, Err(fastra_import::Error::Io(message)) if message.contains("runtime shadows"))
        );
    }
    for source in [
        "![blocked](/usr/bin/bwrap)",
        "<img src=\"/usr/bin/bwrap\" alt=\"blocked\">",
    ] {
        assert!(
            matches!(crate::markdown::render(source, Some(&root.join("document.md")), true, true, &cancel), Err(crate::markdown::RenderError::RuntimePath(message)) if message.contains("runtime shadows"))
        );
    }
    println!("native overlay routes: section/hex/document loader (DE+EN), filtered directory search, explanation sources, import input/output and Markdown/HTML assets denied without partial result");
}
