#![cfg(target_os = "linux")]
use fastra_core::{encoding::Encoding, Cancellation};
use fastra_document::{Document, Error, ReadOnlyTextDocument};
use std::{fs, os::unix::fs::symlink};

#[test]
fn read_only_unicode_hardlinks_keep_exact_bytes_and_never_grant_a_save_basis() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("unicode");
    let alias = dir.path().join("alias");
    let bytes = [0xff, 0xfe, 0xe9, 0, 13, 0, 10, 0];
    fs::write(&path, bytes).unwrap();
    fs::hard_link(&path, &alias).unwrap();
    let cancel = Cancellation::default();
    let text = ReadOnlyTextDocument::open(&path, None, &cancel).unwrap();
    let linked = ReadOnlyTextDocument::open(&alias, None, &cancel).unwrap();
    assert_eq!(text.text(), "é\r\n");
    assert_eq!(text.decoded().encoding(), Encoding::Utf16Le);
    assert_eq!(text.snapshot().bytes(), bytes);
    assert_eq!(text.identity(), linked.identity());
    assert!(!text.snapshot().same_source(linked.snapshot()));
    text.verify_current(&cancel).unwrap();
    assert!(matches!(
        Document::open(&path, None, &cancel),
        Ok(Document::ReadOnlyText(_))
    ));
    fs::write(&alias, "changed").unwrap();
    assert!(text.verify_current(&cancel).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"changed");
}

#[test]
fn resolved_read_alias_is_checked_again_before_using_the_result() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("original");
    let other = dir.path().join("other");
    let alias = dir.path().join("alias");
    fs::write(&path, "identical").unwrap();
    fs::write(&other, "identical").unwrap();
    symlink(&path, &alias).unwrap();
    let cancel = Cancellation::default();
    let text = ReadOnlyTextDocument::open(&alias, None, &cancel).unwrap();
    assert_eq!(text.path(), path);
    fs::remove_file(&alias).unwrap();
    symlink(&other, &alias).unwrap();
    assert!(matches!(text.verify_current(&cancel), Err(Error::Stale)));
}

#[test]
fn full_text_readers_reject_binary_large_paragraphs_and_over_budget_files() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("source");
    let cancel = Cancellation::default();
    fs::write(&path, b"a\0b").unwrap();
    assert!(matches!(
        ReadOnlyTextDocument::open(&path, None, &cancel),
        Err(Error::NotText)
    ));
    fs::write(&path, [b'x'; 65537]).unwrap();
    assert!(matches!(
        ReadOnlyTextDocument::open(&path, None, &cancel),
        Err(Error::NotText)
    ));
    fs::write(&path, "bounded").unwrap();
    assert!(matches!(
        ReadOnlyTextDocument::open_bounded(&path, None, 6, &cancel),
        Err(Error::Snapshot(fastra_io::Error::Limit))
    ));
    cancel.cancel();
    assert!(matches!(
        ReadOnlyTextDocument::open(&path, None, &cancel),
        Err(Error::Cancelled)
    ));
}

#[test]
fn hardlinked_long_lines_stay_in_bounded_sections_and_full_text_has_no_write_basis() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("source");
    fs::write(&path, "# Linked\r\ntext 😀\r\n").unwrap();
    fs::hard_link(&path, dir.path().join("alias")).unwrap();
    let cancel = Cancellation::default();
    let Document::ReadOnlyText(read) = Document::open(&path, None, &cancel).unwrap() else {
        panic!("hardlinks must never acquire an editable basis");
    };
    assert_eq!(read.text(), "# Linked\r\ntext 😀\r\n");
    read.verify_current(&cancel).unwrap();
    assert!(matches!(
        fastra_io::Snapshot::read(&path, &cancel),
        Err(fastra_io::Error::UnsupportedMetadata)
    ));
    fs::write(&path, [b'x'; 65537]).unwrap();
    let Document::Sections(section) = Document::open(&path, None, &cancel).unwrap() else {
        panic!("large paragraphs require the section path");
    };
    assert!(
        section.read_text(0, &cancel).unwrap().text.len() <= fastra_document::TEXT_SECTION_BYTES
    );
}

#[test]
fn decoded_text_expansion_uses_sections_before_reaching_a_gtk_buffer() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("legacy-charset");
    fs::write(&path, [0xe9, b'\n'].repeat(12 * 1024 * 1024)).unwrap();
    let cancel = Cancellation::default();
    assert!(matches!(
        ReadOnlyTextDocument::open(&path, Some(Encoding::Latin1), &cancel),
        Err(Error::Limit)
    ));
    for linked in [false, true] {
        if linked {
            fs::hard_link(&path, dir.path().join("alias")).unwrap();
        }
        let Document::Sections(section) =
            Document::open(&path, Some(Encoding::Latin1), &cancel).unwrap()
        else {
            panic!("24 MiB input expands beyond the full UTF8 source limit");
        };
        let part = section.read_text(0, &cancel).unwrap();
        assert!(part.text.starts_with("é\né\n"));
        assert!(
            part.byte_range.end - part.byte_range.start
                <= fastra_document::TEXT_SECTION_BYTES as u64
        );
        assert!(part.text.len() <= 2 * fastra_document::TEXT_SECTION_BYTES);
    }
}

#[test]
fn a_known_file_in_an_execute_only_parent_opens_readonly() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("search-only");
    fs::create_dir(&directory).unwrap();
    let path = directory.join("known");
    fs::write(&path, "readable\n").unwrap();
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o100)).unwrap();
    let listing_allowed = fs::File::open(&directory).is_ok();
    let result = Document::open(&path, None, &Cancellation::default());
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
    match result.unwrap() {
        Document::ReadOnlyText(source) => {
            assert!(!listing_allowed);
            assert_eq!(source.text(), "readable\n");
            source.verify_current(&Cancellation::default()).unwrap();
        }
        Document::Text(source) => {
            // Privilegierte Testprozesse dürfen die Verzeichnisrechte übergehen.
            assert!(listing_allowed);
            assert_eq!(source.text(), "readable\n");
        }
        _ => panic!("a small known text must remain fully readable"),
    }
}
