use super::*;
use std::{
    fs,
    os::unix::ffi::OsStringExt,
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;

fn owner() -> OwnerBinding {
    OwnerBinding {
        document_id: "document".into(),
        document_revision: 7,
        project_id: Some("project".into()),
        generation: 11,
    }
}
struct Fixture {
    directory: TempDir,
    source: PathBuf,
    destination: PathBuf,
    importer: Importer,
}
impl Fixture {
    fn new(mode: &str) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("-source: name.mbox");
        fs::write(&source, mode).unwrap();
        let destination = directory.path().join("destination");
        fs::create_dir(&destination).unwrap();
        let foreign = directory.path().join("foreign");
        fs::create_dir(&foreign).unwrap();
        fs::write(foreign.join("valuable.txt"), "FOREIGN").unwrap();
        let script = directory.path().join("fake_cli.py");
        fs::write(&script, include_str!("../tests/fixtures/fake_cli.py")).unwrap();
        let importer = Importer {
            executable: "/usr/bin/python3".into(),
            argument_prefix: vec![script.into_os_string()],
        };
        Self {
            directory,
            source,
            destination,
            importer,
        }
    }
    fn prepare(&self) -> Result<PreparedImport, Error> {
        self.importer.prepare(
            &self.source,
            &self.destination,
            owner(),
            Policy::default(),
            Limits::default(),
            &Cancellation::default(),
        )
    }
    fn assert_foreign_untouched(&self) {
        assert_eq!(
            fs::read_to_string(self.directory.path().join("foreign/valuable.txt")).unwrap(),
            "FOREIGN"
        );
    }
    fn assert_no_staging(&self) {
        assert_eq!(fs::read_dir(&self.destination).unwrap().count(), 0);
    }
}
#[test]
fn real_producer_json_contract_is_accepted_without_schema_invention() {
    let catalog = Catalog::decode(
        include_bytes!("../tests/fixtures/producer-catalog.json"),
        Limits::default(),
    )
    .unwrap();
    assert!(catalog.formats.len() > 10);
    let mbox = catalog.format_for(".MBOX", true).unwrap();
    assert!(mbox.supports_directory(false));
    let conversion = Conversion::decode(
        include_bytes!("../tests/fixtures/producer-mbox.json"),
        Limits::default(),
    )
    .unwrap();
    assert_eq!(conversion.documents.unwrap().len(), 2);
    assert!(conversion.markdown_file.ends_with("/index.md"));
}
#[test]
fn catalog_is_driven_by_cli_and_preserves_unavailable_tools() {
    let fixture = Fixture::new("valid");
    let (catalog, output) = fixture
        .importer
        .catalog(
            Policy::default(),
            Limits::default(),
            &Cancellation::default(),
        )
        .unwrap();
    assert!(output.success());
    assert!(catalog.format_for("mbox", true).unwrap().available);
    assert_eq!(
        catalog
            .format_for("docx", false)
            .unwrap()
            .unavailable_reason
            .as_deref(),
        Some("missing required tool: pandoc")
    );
}
#[test]
fn collection_keeps_all_files_and_relative_entry_across_collision_then_reopens() {
    let fixture = Fixture::new("valid");
    fs::create_dir(fixture.destination.join("source")).unwrap();
    fs::write(fixture.destination.join("source/keep"), "UNCHANGED").unwrap();
    let prepared = fixture.prepare().unwrap();
    assert_eq!(prepared.preview().entry, Path::new("index.md"));
    assert_eq!(prepared.preview().documents.len(), 2);
    assert_eq!(prepared.preview().files.len(), 5);
    assert_eq!(prepared.preview().markdown_text.len(), 3);
    assert_eq!(
        prepared.preview().markdown_text[Path::new("docs/two.md")],
        "é😀\n"
    );
    assert!(prepared.preview().markdown_text[Path::new("index.md")].contains("docs/one.md"));
    assert!(prepared.preview().assets.is_empty()); // Vollständiger Baum hängt nicht von dieser Liste ab.
    assert_eq!(
        prepared.preview().response.diagnostics.as_ref().unwrap()[0]["kind"],
        "contentLoss"
    );
    assert_eq!(
        prepared.preview().response.extra["futureField"]["must"],
        "survive"
    );
    let published = prepared
        .adopt(&owner(), "source", &Cancellation::default())
        .unwrap();
    assert_eq!(published.directory, fixture.destination.join("source-2"));
    assert_eq!(published.markdown, published.directory.join("index.md"));
    assert_eq!(
        fs::read_to_string(fixture.destination.join("source/keep")).unwrap(),
        "UNCHANGED"
    );
    // Producer und Staging sind weg; neue Handles lesen die relativen Ziele.
    let index = fs::read_to_string(&published.markdown).unwrap();
    assert!(index.contains("docs/one.md"));
    assert!(fs::read_to_string(published.directory.join("docs/one.md"))
        .unwrap()
        .contains("../images/pixel.bin"));
    assert_eq!(
        fs::read(published.directory.join("docs/../images/pixel.bin")).unwrap(),
        (0u8..=255).collect::<Vec<_>>()
    );
    assert_eq!(
        fs::read_to_string(published.directory.join("docs/two.md")).unwrap(),
        "é😀\n"
    );
    assert!(published.directory.join("report.json").is_file());
    let reopened = std::process::Command::new("/usr/bin/python3")
        .args(["-c", "import pathlib,sys; root=pathlib.Path(sys.argv[1]); assert (root/'index.md').read_text().find('docs/one.md')>=0; assert (root/'docs'/'..'/'images'/'pixel.bin').read_bytes()==bytes(range(256)); print('fresh reopen passed')"])
        .arg(&published.directory).current_dir("/").output().unwrap();
    assert!(reopened.status.success());
    assert_eq!(reopened.stdout, b"fresh reopen passed\n");
    assert_eq!(fs::read_dir(&fixture.destination).unwrap().count(), 2);
    fixture.assert_foreign_untouched();
}
#[test]
fn minimal_and_null_optional_fields_still_preserve_complete_tree() {
    for mode in ["minimal", "null"] {
        let fixture = Fixture::new(mode);
        let prepared = fixture.prepare().unwrap();
        assert_eq!(prepared.preview().files.len(), 5);
        let published = prepared
            .adopt(&owner(), "result", &Cancellation::default())
            .unwrap();
        assert!(published.directory.join("docs/two.md").is_file());
    }
}
#[test]
fn full_tree_rejects_unreported_symlinks_fifo_socket_hardlink_and_bad_names() {
    for mode in [
        "rootlink",
        "assetlink",
        "directorylink",
        "hardlink",
        "fifo",
        "socket",
        "nonutf8",
    ] {
        let fixture = Fixture::new(mode);
        assert!(fixture.prepare().is_err(), "accepted {mode}");
        fixture.assert_foreign_untouched();
        fixture.assert_no_staging();
    }
}
#[test]
fn foreign_missing_or_inconsistent_reported_files_and_mappings_are_rejected() {
    for mode in [
        "outside",
        "outdir",
        "missing",
        "hash",
        "mapping",
        "mappingoverflow",
        "duplicateindex",
        "missingdoc",
    ] {
        let fixture = Fixture::new(mode);
        assert!(fixture.prepare().is_err(), "accepted {mode}");
        fixture.assert_foreign_untouched();
        fixture.assert_no_staging();
    }
}
#[test]
fn exit_status_false_json_malformed_and_truncated_json_cannot_publish() {
    for mode in ["toolerror", "false", "nonzero", "brokenjson"] {
        let fixture = Fixture::new(mode);
        let result = fixture.prepare();
        assert!(result.is_err(), "accepted {mode}");
        if mode == "toolerror" {
            match result {
                Err(Error::Tool { message, output }) => {
                    assert_eq!(message.as_deref(), Some("missing required tool: fixture"));
                    assert_eq!(output.exit_code, Some(69));
                    assert_eq!(output.stderr, b"exact failure\xff\n");
                }
                _ => panic!("wrong tool error"),
            }
        }
        fixture.assert_no_staging();
    }
    let fixture = Fixture::new("hugejson");
    let limits = Limits {
        max_json_bytes: 1024,
        ..Limits::default()
    };
    assert!(matches!(
        fixture.importer.prepare(
            &fixture.source,
            &fixture.destination,
            owner(),
            Policy::default(),
            limits,
            &Cancellation::default()
        ),
        Err(Error::Process(fastra_process::Error::OutputLimit(_)))
    ));
    fixture.assert_no_staging();
}
#[test]
fn each_owner_axis_rejects_stale_adoption() {
    for axis in 0..4 {
        let fixture = Fixture::new("valid");
        let prepared = fixture.prepare().unwrap();
        let mut changed = owner();
        match axis {
            0 => changed.document_id.push('x'),
            1 => changed.document_revision += 1,
            2 => changed.project_id = None,
            _ => changed.generation += 1,
        }
        assert!(matches!(
            prepared.adopt(&changed, "result", &Cancellation::default()),
            Err(Error::StaleOwner)
        ));
        fixture.assert_no_staging();
    }
}
#[test]
fn bounded_tree_counts_depth_and_bytes_fail_without_publishing() {
    for (mode, limits) in [
        (
            "many",
            Limits {
                max_entries: 10,
                ..Limits::default()
            },
        ),
        (
            "deep",
            Limits {
                max_depth: 2,
                ..Limits::default()
            },
        ),
        (
            "large",
            Limits {
                max_file_bytes: 1000,
                ..Limits::default()
            },
        ),
        (
            "valid",
            Limits {
                max_total_bytes: 100,
                ..Limits::default()
            },
        ),
    ] {
        let fixture = Fixture::new(mode);
        assert!(
            matches!(
                fixture.importer.prepare(
                    &fixture.source,
                    &fixture.destination,
                    owner(),
                    Policy::default(),
                    limits,
                    &Cancellation::default()
                ),
                Err(Error::Limit(_))
            ),
            "{mode}"
        );
        fixture.assert_no_staging();
    }
}
#[test]
fn stale_private_copy_and_symlink_collision_never_replace_foreign_data() {
    let fixture = Fixture::new("valid");
    let prepared = fixture.prepare().unwrap();
    fs::write(
        prepared.staging.path().join("prepared/docs/two.md"),
        "tampered",
    )
    .unwrap();
    assert!(matches!(
        prepared.adopt(&owner(), "result", &Cancellation::default()),
        Err(Error::StalePrepared)
    ));
    fixture.assert_no_staging();
    let prepared = fixture.prepare().unwrap();
    std::os::unix::fs::symlink(
        fixture.directory.path().join("foreign"),
        fixture.destination.join("result"),
    )
    .unwrap();
    let published = prepared
        .adopt(&owner(), "result", &Cancellation::default())
        .unwrap();
    assert_eq!(published.directory, fixture.destination.join("result-2"));
    fixture.assert_foreign_untouched();
}
#[test]
fn non_utf8_sources_are_rejected_before_cli_start() {
    let fixture = Fixture::new("valid");
    let raw = fixture
        .directory
        .path()
        .join(OsString::from_vec(b"source\xff".to_vec()));
    fs::write(&raw, "valid").unwrap();
    assert!(matches!(
        fixture.importer.prepare(
            &raw,
            &fixture.destination,
            owner(),
            Policy::default(),
            Limits::default(),
            &Cancellation::default()
        ),
        Err(Error::InvalidPath(_))
    ));
    fixture.assert_no_staging();
}
#[test]
fn utf8_mapping_math_covers_emoji_and_overflow_without_guessing() {
    assert_eq!(
        utf8_to_utf16("é😀x", 2, 4).unwrap(),
        Utf16Span {
            location: 1,
            length: 2
        }
    );
    assert!(utf8_to_utf16("é😀x", 3, 1).is_err());
    assert!(utf8_to_utf16("é", u64::MAX, 1).is_err());
    assert!(utf8_to_utf16("é", 2, 1).is_err());
}
#[test]
fn timeout_and_cancellation_remove_staging_and_stop_descendants() {
    let fixture = Fixture::new("timeout");
    let policy = Policy {
        timeout: Duration::from_millis(100),
        termination_grace: Duration::from_millis(20),
        ..Policy::default()
    };
    assert!(matches!(
        fixture.importer.prepare(
            &fixture.source,
            &fixture.destination,
            owner(),
            policy,
            Limits::default(),
            &Cancellation::default()
        ),
        Err(Error::Process(fastra_process::Error::TimedOut(_)))
    ));
    assert_pids_dead(&fixture.source.with_extension("pids"));
    fixture.assert_no_staging();
    let fixture = Fixture::new("cancel");
    let source = fixture.source.clone();
    let destination = fixture.destination.clone();
    let importer = fixture.importer.clone();
    let cancel = Cancellation::default();
    let worker_cancel = cancel.clone();
    let worker = thread::spawn(move || {
        importer.prepare(
            &source,
            &destination,
            owner(),
            Policy::default(),
            Limits::default(),
            &worker_cancel,
        )
    });
    let deadline = Instant::now() + Duration::from_secs(2);
    while !fixture.source.with_extension("pids").exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(2));
    }
    cancel.cancel();
    assert!(matches!(
        worker.join().unwrap(),
        Err(Error::Process(fastra_process::Error::Cancelled(_)))
    ));
    assert_pids_dead(&fixture.source.with_extension("pids"));
    fixture.assert_no_staging();
}
fn assert_pids_dead(path: &Path) {
    for pid in fs::read_to_string(path).unwrap().split_whitespace() {
        let dead = |pid| {
            fs::read_to_string(format!("/proc/{pid}/stat")).map_or(true, |s| {
                s.rsplit_once(')')
                    .is_some_and(|(_, rest)| rest.starts_with(" Z") || rest.starts_with(" X"))
            })
        };
        let deadline = Instant::now() + Duration::from_secs(1);
        while !dead(pid) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
        }
        assert!(dead(pid), "live descendant {pid}");
    }
}

#[test]
fn replaced_staging_is_never_cleaned_as_owned_data() {
    let fixture = Fixture::new("stagingreplace");
    assert!(matches!(fixture.prepare(), Err(Error::UnsafeTree(_))));
    let marker = fs::read_dir(&fixture.destination)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.path().join("foreign-marker"))
        .find(|path| path.exists())
        .unwrap();
    assert_eq!(fs::read_to_string(marker).unwrap(), "MUST REMAIN");
    fixture.assert_foreign_untouched();
}
#[test]
fn replaced_destination_is_not_a_valid_adoption_target() {
    let fixture = Fixture::new("valid");
    let prepared = fixture.prepare().unwrap();
    fs::rename(
        &fixture.destination,
        fixture.directory.path().join("previous-destination"),
    )
    .unwrap();
    fs::create_dir(&fixture.destination).unwrap();
    fs::write(fixture.destination.join("foreign-marker"), "MUST REMAIN").unwrap();
    assert!(prepared
        .adopt(&owner(), "result", &Cancellation::default())
        .is_err());
    assert_eq!(
        fs::read_to_string(fixture.destination.join("foreign-marker")).unwrap(),
        "MUST REMAIN"
    );
}
#[test]
fn concurrent_adoptions_do_not_overwrite_each_other() {
    let fixture = Fixture::new("valid");
    let first = fixture.prepare().unwrap();
    let second = fixture.prepare().unwrap();
    let worker = thread::spawn(move || first.adopt(&owner(), "result", &Cancellation::default()));
    let second = second
        .adopt(&owner(), "result", &Cancellation::default())
        .unwrap();
    let first = worker.join().unwrap().unwrap();
    assert_ne!(first.directory, second.directory);
    for publication in [first, second] {
        assert!(publication.markdown.is_file());
        assert_eq!(
            fs::read(publication.directory.join("images/pixel.bin"))
                .unwrap()
                .len(),
            256
        );
    }
}
#[test]
fn cancellation_after_conversion_still_blocks_adoption() {
    let fixture = Fixture::new("valid");
    let prepared = fixture.prepare().unwrap();
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(matches!(
        prepared.adopt(&owner(), "result", &cancel),
        Err(Error::Cancelled)
    ));
    fixture.assert_no_staging();
}

#[test]
fn complete_preview_text_has_an_aggregate_budget() {
    let fixture = Fixture::new("valid");
    let limits = Limits {
        max_markdown_bytes: 90,
        ..Limits::default()
    };
    assert!(matches!(
        fixture.importer.prepare(
            &fixture.source,
            &fixture.destination,
            owner(),
            Policy::default(),
            limits,
            &Cancellation::default()
        ),
        Err(Error::Limit("preview text bytes"))
    ));
    fixture.assert_no_staging();
}

#[test]
fn project_selection_generation_rejects_return_to_same_project() {
    let fixture = Fixture::new("valid");
    let prepared = fixture.prepare().unwrap();
    let mut returned = owner();
    returned.project_id = Some("project-return-generation".into());
    assert!(matches!(
        prepared.adopt(&returned, "result", &Cancellation::default()),
        Err(Error::StaleOwner)
    ));
    fixture.assert_no_staging();
}
#[test]
fn raw_utf8_replacement_collision_never_runs_a_different_source_or_target() {
    let fixture = Fixture::new("valid");
    let raw = fixture
        .directory
        .path()
        .join(OsString::from_vec(b"source-\xff.mbox".to_vec()));
    let replacement = fixture.directory.path().join("source-�.mbox");
    fs::write(&raw, "raw bytes").unwrap();
    fs::write(&replacement, "valid").unwrap();
    assert_eq!(raw.to_string_lossy(), replacement.to_string_lossy());
    for (source, destination) in [(&raw, &fixture.destination), (&replacement, &raw)] {
        assert!(matches!(
            fixture.importer.prepare(
                source,
                destination,
                owner(),
                Policy::default(),
                Limits::default(),
                &Cancellation::default()
            ),
            Err(Error::InvalidPath(_))
        ));
    }
    assert!(Importer::new(raw.clone()).is_err());
    assert_eq!(fs::read(&raw).unwrap(), b"raw bytes");
    assert_eq!(fs::read(&replacement).unwrap(), b"valid");
    fixture.assert_no_staging();
}

#[test]
fn symlink_source_uses_canonical_name_for_fragmented_progress_and_keeps_diagnostics() {
    let fixture = Fixture::new("valid");
    let probe = fixture
        .importer
        .probe_cached(
            Policy::default(),
            Limits::default(),
            &Cancellation::default(),
        )
        .unwrap();
    assert!(probe.supports_progress);
    let alias = fixture.directory.path().join("different-name.mbox");
    std::os::unix::fs::symlink(&fixture.source, &alias).unwrap();
    let mut observed = Vec::new();
    let prepared = fixture
        .importer
        .prepare_observed(
            &alias,
            &fixture.destination,
            owner(),
            Policy::default(),
            Limits::default(),
            &Cancellation::default(),
            probe.supports_progress,
            &mut |progress| observed.push(progress),
        )
        .unwrap();
    assert_eq!(
        observed.last().unwrap().counts.as_ref().unwrap().unit,
        Unit::Message
    );
    assert!(
        String::from_utf8_lossy(&prepared.preview().process_output.stderr)
            .contains("Unknown diagnostic retained")
    );
}
#[test]
fn catalog_cache_is_invalidated_by_same_path_tool_replacement() {
    let fixture = Fixture::new("valid");
    use std::os::unix::fs::PermissionsExt;
    let tool = fixture.directory.path().join("tool");
    let body = |name| {
        format!("#!/usr/bin/python3\nimport json,sys\nif '--help' in sys.argv: print(' --progress Report'); sys.exit(0)\nprint(json.dumps({{'ok':True,'version':'{name}','formats':[{{'format':'a','extensions':['a'],'container':'file'}}]}}))\n")
    };
    fs::write(&tool, body("first")).unwrap();
    fs::set_permissions(&tool, fs::Permissions::from_mode(0o700)).unwrap();
    let importer = Importer::new(tool.clone()).unwrap();
    let get = || {
        importer
            .probe_cached(
                Policy::default(),
                Limits::default(),
                &Cancellation::default(),
            )
            .unwrap()
    };
    assert_eq!(get().catalog.version, "first");
    let replacement = tool.with_extension("replacement");
    fs::write(&replacement, body("second")).unwrap();
    fs::set_permissions(&replacement, fs::Permissions::from_mode(0o700)).unwrap();
    fs::rename(&replacement, &tool).unwrap();
    assert_eq!(get().catalog.version, "second");
}

#[test]
fn catalog_text_and_cached_result_respect_display_and_caller_limits() {
    assert!(Catalog::decode(br#"{"ok":true,"formats":[{"format":"a","extensions":["a"],"unavailableReason":"bad\u0000reason"}]}"#,Limits::default()).is_err());
    let fixture = Fixture::new("valid");
    fixture
        .importer
        .probe_cached(
            Policy::default(),
            Limits::default(),
            &Cancellation::default(),
        )
        .unwrap();
    assert!(fixture
        .importer
        .probe_cached(
            Policy::default(),
            Limits {
                max_json_bytes: 8,
                ..Default::default()
            },
            &Cancellation::default()
        )
        .is_err());
}

#[test]
fn optional_source_member_is_preserved_without_path_authority() {
    for (mode, member) in [
        ("identity-member", "TXT.rtf"),
        ("identity-unknown-member", "../foreign/valuable.txt"),
    ] {
        let fixture = Fixture::new(mode);
        let prepared = fixture.prepare().unwrap();
        let identity = prepared
            .preview()
            .response
            .source_identity
            .as_ref()
            .unwrap();
        assert_eq!(identity["memberPath"], member);
        assert_eq!(identity["futureIdentityField"]["preserve"], true);
        let publication = prepared
            .adopt(&owner(), "result", &Cancellation::default())
            .unwrap();
        assert_eq!(
            publication
                .preview
                .response
                .source_identity
                .as_ref()
                .unwrap()["memberPath"],
            member
        );
        fixture.assert_foreign_untouched();
    }
}
