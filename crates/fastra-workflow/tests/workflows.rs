use fastra_core::{Cancellation, Utf16Range};
use fastra_workflow::{
    store::{Library, Store},
    *,
};
use std::{
    collections::BTreeMap,
    os::unix::fs::{symlink, MetadataExt, PermissionsExt},
};
fn fixture() -> WorkflowArchive {
    WorkflowArchive::decode(include_bytes!("fixtures/swift-workflows.json")).unwrap()
}
fn flow(kinds: &[&str]) -> Workflow {
    Workflow {
        id: new_id().unwrap(),
        revision: new_id().unwrap(),
        name: "Test".into(),
        steps: kinds.iter().map(|k| Step::new(k).unwrap()).collect(),
        extra: Default::default(),
    }
}
fn range(source: &str, part: &str) -> Utf16Range {
    let start = source.find(part).unwrap();
    Utf16Range {
        location: source[..start].encode_utf16().count(),
        length: part.encode_utf16().count(),
    }
}
#[test]
fn swift_sequence_selection_and_binding() {
    let workflow = fixture().workflows.remove(0);
    let source = "Davor 😀\r\nb\r\na\r\nb\r\nDanach";
    let selection = Some(range(source, "b\r\na\r\nb"));
    let cancel = Cancellation::default();
    let preview = preview(&workflow, source, selection, 7, 9, &cancel).unwrap();
    assert_eq!(preview.output(), "Davor 😀\r\n> a\r\n> b\r\nDanach");
    assert_eq!(preview.steps.len(), 3);
    assert_eq!(preview.steps[0].after, preview.steps[1].before);
    assert_eq!(
        preview
            .apply(source, 7, 9, &workflow, selection, &cancel)
            .unwrap(),
        preview.output()
    );
    assert!(matches!(
        preview.apply(source, 8, 9, &workflow, selection, &cancel),
        Err(Error::Stale)
    ));
    assert!(matches!(
        preview.apply(source, 7, 10, &workflow, selection, &cancel),
        Err(Error::Stale)
    ));
    assert!(matches!(
        preview.apply(source, 7, 9, &workflow, None, &cancel),
        Err(Error::Stale)
    ));
    let mut edited = workflow.clone();
    edited.steps[0].enabled = false;
    assert!(matches!(
        preview.apply(source, 7, 9, &edited, selection, &cancel),
        Err(Error::Stale)
    ));
    assert_eq!(source, "Davor 😀\r\nb\r\na\r\nb\r\nDanach");
}
#[test]
fn swift_json_roundtrip_keeps_all_fields_and_unknown_settings() {
    let bytes = include_bytes!("fixtures/swift-workflows.json");
    let original: serde_json::Value = serde_json::from_slice(bytes).unwrap();
    let archive = fixture();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&archive.encode().unwrap()).unwrap(),
        original
    );
    let mut value = original;
    value["futureArchive"] = "keep".into();
    value["workflows"][0]["futureWorkflow"] = serde_json::json!({"nested":[true,42]});
    value["workflows"][0]["steps"][0]["futureStep"] = serde_json::json!(["x"]);
    let roundtrip = WorkflowArchive::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&roundtrip.encode().unwrap()).unwrap(),
        value
    );
    let mut unknown = flow(&["uppercase", "futureTransformation"]);
    assert!(
        matches!(preview(&unknown,"abc",None,0,0,&Cancellation::default()),Err(Error::Unsupported(steps))if steps==vec!["2: futureTransformation"])
    );
    unknown.steps[1].enabled = false;
    assert_eq!(
        preview(&unknown, "abc", None, 0, 0, &Cancellation::default())
            .unwrap()
            .output(),
        "ABC"
    );
}
#[test]
fn mixed_endings_and_protected_filter_match_swift_contract() {
    let cancel = Cancellation::default();
    for kind in [
        "trimTrailing",
        "prefixLines",
        "removeDuplicateLines",
        "keepLinesMatching",
    ] {
        let mut workflow = flow(&[kind]);
        workflow.steps[0].argument = ".".into();
        if kind == "prefixLines" {
            workflow.steps[0].argument = "".into();
        }
        assert_eq!(
            preview(&workflow, "a\r\nb\nc\rd", None, 0, 0, &cancel)
                .unwrap()
                .output(),
            "a\r\nb\nc\rd"
        );
    }
    let mut workflow = flow(&["keepLinesMatching"]);
    workflow.steps[0].argument = "never".into();
    let result = preview(&workflow, "a\nb", None, 0, 0, &cancel).unwrap();
    assert_eq!(result.output(), "a\nb");
    assert_eq!(result.steps[0].before, result.steps[0].after);
    let mut workflow = flow(&["suffixLines"]);
    workflow.steps[0].argument = "\r\n".into();
    assert_eq!(
        preview(&workflow, "a", None, 0, 0, &cancel)
            .unwrap()
            .output(),
        "a\r\n"
    );
}
#[test]
fn replace_steps_reuse_core_wildcard_regex_and_whole_word() {
    let mut workflow = flow(&["replace", "uppercase"]);
    workflow.steps[0].find = "*=*".into();
    workflow.steps[0].replacement = "*:*".into();
    let result = preview(
        &workflow,
        "abc=12\ndef=34",
        None,
        0,
        0,
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(result.steps[0].after.as_ref(), "abc:12\ndef:34");
    assert_eq!(result.output(), "ABC:12\nDEF:34");
    assert_eq!(result.steps[0].matches, Some(2));
    workflow.steps[0].regex = true;
    workflow.steps[0].find = "([a-z]+)=(\\d+)".into();
    workflow.steps[0].replacement = "\\U$1\\E:$2".into();
    assert_eq!(
        preview(&workflow, "abc=12", None, 0, 0, &Cancellation::default())
            .unwrap()
            .output(),
        "ABC:12"
    );
    workflow.steps[0].regex = false;
    workflow.steps[0].literal_wildcard = true;
    workflow.steps[0].whole_word = true;
    workflow.steps[0].find = "cat".into();
    workflow.steps[0].replacement = "dog".into();
    assert_eq!(
        preview(
            &workflow,
            "cat scatter",
            None,
            0,
            0,
            &Cancellation::default()
        )
        .unwrap()
        .output(),
        "DOG SCATTER"
    );
}
#[test]
fn invalid_steps_limits_and_cancel_never_return_partial_preview() {
    let mut workflow = flow(&["uppercase", "replace"]);
    workflow.steps[1].regex = true;
    workflow.steps[1].find = "[".into();
    assert!(preview(&workflow, "abc", None, 0, 0, &Cancellation::default()).is_err());
    workflow = flow(&["uppercase"]);
    assert!(preview(
        &workflow,
        "😀x",
        Some(Utf16Range {
            location: 1,
            length: 1
        }),
        0,
        0,
        &Cancellation::default()
    )
    .is_err());
    assert!(preview(
        &workflow,
        "x",
        Some(Utf16Range {
            location: 0,
            length: 0
        }),
        0,
        0,
        &Cancellation::default()
    )
    .is_err());
    assert!(matches!(
        preview(
            &workflow,
            &"x".repeat(4 * 1024 * 1024 + 1),
            None,
            0,
            0,
            &Cancellation::default()
        ),
        Err(Error::Limit)
    ));
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(matches!(
        preview(&workflow, "abc", None, 0, 0, &cancel),
        Err(Error::Core(fastra_core::Error::Cancelled))
    ));
    workflow.steps = std::iter::repeat_with(|| Step::new("uppercase").unwrap())
        .take(32)
        .collect();
    assert!(matches!(
        preview(
            &workflow,
            &"a".repeat(1024 * 1024),
            None,
            0,
            0,
            &Cancellation::default()
        ),
        Err(Error::Limit)
    ));
}
#[test]
fn snippet_swift_fixture_repeated_names_literal_values_and_roundtrip() {
    let archive = SnippetArchive::decode(include_bytes!("fixtures/swift-snippets.json")).unwrap();
    let snippet = &archive.snippets[0];
    let template = Template::parse(&snippet.template).unwrap();
    assert_eq!(template.names, vec!["Name", "Ort"]);
    let values = BTreeMap::from([
        ("Name".into(), "😀 e\u{301}\r\n{{Ort}}".into()),
        ("Ort".into(), "Köln".into()),
    ]);
    assert_eq!(
        template.render(&values).unwrap(),
        "😀 e\u{301}\r\n{{Ort}} / Köln / 😀 e\u{301}\r\n{{Ort}}"
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&archive.encode().unwrap()).unwrap(),
        serde_json::from_slice::<serde_json::Value>(include_bytes!("fixtures/swift-snippets.json"))
            .unwrap()
    );
    assert!(matches!(
        template.render(&BTreeMap::new()),
        Err(Error::Missing(_))
    ));
    for invalid in ["{{", "{{}}", "{{a\nb}}", "{{a{{b}}", "{{a\0b}}"] {
        assert!(Template::parse(invalid).is_err());
    }
    assert!(Template::parse(&"x".repeat(16 * 1024 + 1)).is_err());
    let repeated = Template::parse(&"{{Name}}".repeat(17)).unwrap();
    assert!(matches!(
        repeated.render(&BTreeMap::from([("Name".into(), "x".repeat(16 * 1024))])),
        Err(Error::Limit)
    ));
}
#[test]
fn imports_merge_without_overwrite_and_conflicting_extensions_are_rejected() {
    let archive = fixture();
    let merged = archive.merged(&archive).unwrap();
    assert_eq!(merged.workflows.len(), 2);
    assert_ne!(merged.workflows[0].id, merged.workflows[1].id);
    assert_ne!(
        merged.workflows[0].steps[0].id,
        merged.workflows[1].steps[0].id
    );
    assert_eq!(merged.workflows[1].name, "Liste (2)");
    let mut spaced = archive.clone();
    spaced.workflows[0].name = "  Liste  ".into();
    assert_eq!(
        WorkflowArchive::empty().merged(&spaced).unwrap().workflows[0].name,
        "  Liste  "
    );
    let mut a = archive.clone();
    let mut b = archive;
    a.extra.insert("future".into(), 1.into());
    b.extra.insert("future".into(), 2.into());
    assert!(a.merged(&b).is_err());
    let mut bad = serde_json::to_value(a).unwrap();
    bad["schemaVersion"] = 2.into();
    assert!(WorkflowArchive::decode(&serde_json::to_vec(&bad).unwrap()).is_err());
}
#[test]
fn private_store_cas_reload_corruption_and_symlinks() {
    let root = tempfile::tempdir().unwrap();
    let store = Store::open(root.path()).unwrap();
    let other = Store::open(root.path()).unwrap();
    let first = store.load().unwrap();
    let stale = other.load().unwrap();
    let library = Library {
        workflows: fixture(),
        ..Library::default()
    };
    let saved = store.save(&first, &library).unwrap();
    assert_eq!(saved.library, library);
    assert!(matches!(
        other.save(&stale, &Library::default()),
        Err(Error::Stale)
    ));
    assert_eq!(other.load().unwrap().library, library);
    let path = root.path().join("fastra-workflow/library.json");
    assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
    assert_eq!(
        std::fs::metadata(path.parent().unwrap()).unwrap().mode() & 0o777,
        0o700
    );
    std::fs::write(&path, b"broken").unwrap();
    assert!(store.load().is_err());
    assert!(store.save(&saved, &library).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"broken");
    std::fs::remove_file(&path).unwrap();
    let foreign = root.path().join("foreign");
    std::fs::write(&foreign, b"untouched").unwrap();
    symlink(&foreign, &path).unwrap();
    assert!(store.load().is_err());
    assert_eq!(std::fs::read(&foreign).unwrap(), b"untouched");
    let another = tempfile::tempdir().unwrap();
    let dir = another.path().join("fastra-workflow");
    std::fs::create_dir(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(Store::open(another.path()).is_err());
}
#[test]
fn swift_unicode_names_and_grapheme_selection() {
    let vectors: serde_json::Value =
        serde_json::from_slice(include_bytes!("fixtures/swift-unicode-vectors.json")).unwrap();
    for vector in vectors.as_array().unwrap() {
        let source = vector["source"].as_str().unwrap();
        let parsed = Template::parse(source);
        assert_eq!(
            parsed.is_ok(),
            vector["valid"].as_bool().unwrap(),
            "{source:?}"
        );
        if let Ok(parsed) = parsed {
            assert_eq!(serde_json::to_value(parsed.names).unwrap(), vector["names"]);
        }
    }
    let name = "e\u{301}".repeat(80);
    let snippet = Snippet {
        id: new_id().unwrap(),
        revision: new_id().unwrap(),
        name,
        template: "ok".into(),
        extra: Default::default(),
    };
    snippet.validate().unwrap();
    let workflow = flow(&["uppercase"]);
    assert!(preview(
        &workflow,
        "e\u{301}",
        Some(Utf16Range {
            location: 0,
            length: 1
        }),
        0,
        0,
        &Cancellation::default()
    )
    .is_err());
    let json = String::from_utf8(fixture().encode().unwrap()).unwrap();
    let json = json.replacen(
        "{",
        "{\"numericExtension\":1.2345678901234567890123456789,",
        1,
    );
    let archive = WorkflowArchive::decode(json.as_bytes()).unwrap();
    assert!(String::from_utf8(archive.encode().unwrap())
        .unwrap()
        .contains("1.2345678901234567890123456789"));
}
#[test]
fn active_cancel_and_unknown_semantic_fields_block_all_output() {
    let mut workflow = flow(&["uppercase", "keepLinesMatching"]);
    workflow.steps[1].argument = "(a+)+$".into();
    let source = format!("{}!", "a".repeat(1000));
    let cancel = Cancellation::default();
    let worker_cancel = cancel.clone();
    let task = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(5));
        worker_cancel.cancel();
    });
    let result = preview(&workflow, &source, None, 0, 0, &cancel);
    task.join().unwrap();
    assert!(matches!(
        result,
        Err(Error::Core(fastra_core::Error::Cancelled))
    ));
    let mut workflow = flow(&["uppercase"]);
    workflow.steps[0]
        .extra
        .insert("futureSemanticFlag".into(), true.into());
    assert!(
        matches!(preview(&workflow,"abc",None,0,0,&Cancellation::default()),Err(Error::Unsupported(fields))if fields==vec!["1.futureSemanticFlag"])
    );
}
#[test]
fn nul_fields_are_rejected_before_native_text_rendering_or_import() {
    let mut archive = fixture();
    let mut bad = flow(&["suffixLines"]);
    bad.steps[0].argument = "\0hidden".into();
    archive.workflows.push(bad);
    let bytes = serde_json::to_vec(&archive).unwrap();
    assert!(
        matches!(WorkflowArchive::decode(&bytes),Err(Error::Unsupported(fields))if fields==vec!["1.argument: U+0000"])
    );
    let mut snippets =
        SnippetArchive::decode(include_bytes!("fixtures/swift-snippets.json")).unwrap();
    snippets.snippets[0].template = "before\0after".into();
    assert!(matches!(
        SnippetArchive::decode(&serde_json::to_vec(&snippets).unwrap()),
        Err(Error::Unsupported(_))
    ));
    assert!(matches!(
        preview(
            &flow(&["uppercase"]),
            "before\0after",
            None,
            0,
            0,
            &Cancellation::default()
        ),
        Err(Error::Unsupported(_))
    ));
}
