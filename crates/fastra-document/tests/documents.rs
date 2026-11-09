#![cfg(target_os = "linux")]
use fastra_core::{
    encoding::{Encoding, EncodingError},
    Cancellation,
};
use fastra_document::{
    Document, Error, CLASSIFICATION_BYTES, EDITABLE_BYTES, HEX_SECTION_BYTES, TEXT_SECTION_BYTES,
};
use std::{
    fs::{self, File},
    io::{Seek, SeekFrom, Write},
    os::unix::fs::{symlink, MetadataExt},
};

#[test]
fn small_document_keeps_exact_original_baseline_and_encoding() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("document");
    let bytes = [
        0xef, 0xbb, 0xbf, b'a', b'\r', b'\n', 0xc3, 0xa9, b'\r', b'z', b'\n',
    ];
    fs::write(&path, bytes).unwrap();
    let Document::Text(document) = Document::open(&path, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    assert_eq!(document.text(), "a\r\né\rz\n");
    assert_eq!(document.snapshot().bytes(), bytes);
    assert_eq!(document.encode(document.text()).unwrap(), bytes);
    assert_eq!(document.identity().size(), bytes.len() as u64);
    assert_eq!(
        document.snapshot().file_identity().device,
        document.identity().device()
    );
    assert_eq!(
        document.snapshot().file_identity().inode,
        document.identity().inode()
    );
    document.verify_current(&Cancellation::default()).unwrap();
    fs::write(&path, b"external").unwrap();
    assert!(matches!(
        document.verify_current(&Cancellation::default()),
        Err(Error::Stale)
    ));
    assert_eq!(document.snapshot().bytes(), bytes);
}

#[test]
fn latin1_replacement_fails_without_touching_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("document");
    fs::write(&path, [0xe9]).unwrap();
    let Document::Text(document) = Document::open(&path, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    assert_eq!(
        document.encode("😀"),
        Err(EncodingError::Unrepresentable('😀'))
    );
    assert_eq!(fs::read(&path).unwrap(), [0xe9]);
}

#[test]
fn binary_probe_uses_read_only_route_before_requesting_a_save_snapshot() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("binary");
    fs::write(&path, [0, 1, 2, 3]).unwrap();
    // Ein Save-Snapshot weist Hardlinks ab; eine begrenzte Hex-Ansicht benötigt keinen.
    fs::hard_link(&path, dir.path().join("alias")).unwrap();
    let Document::Hex(document) = Document::open(&path, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    assert_eq!(
        document
            .read_hex(0, 4, &Cancellation::default())
            .unwrap()
            .bytes,
        [0, 1, 2, 3]
    );
}

#[test]
fn large_classification_does_not_mislabel_a_split_utf8_scalar() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("unicode");
    let mut file = File::create(&path).unwrap();
    file.write_all(&vec![b'a'; CLASSIFICATION_BYTES + 2])
        .unwrap();
    file.write_all("😀\n".as_bytes()).unwrap();
    file.set_len(EDITABLE_BYTES as u64 + 1).unwrap();
    let Document::Sections(document) =
        Document::open(&path, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    assert_eq!(document.encoding(), Some(Encoding::Utf8));
    let page = document.read_text(CLASSIFICATION_BYTES as u64, &Cancellation::default());
    // Der spätere NUL-Bereich bleibt ein Fehler; die Encoding-Erkennung ist dennoch UTF-8.
    assert!(matches!(page, Err(Error::Encoding(EncodingError::Binary))));
}

#[test]
fn long_single_line_uses_bounded_utf8_sections_without_missing_a_scalar() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("long");
    let text = format!("{}😀 tail\n", "a".repeat(TEXT_SECTION_BYTES - 1));
    fs::write(&path, &text).unwrap();
    let Document::Sections(document) =
        Document::open(&path, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    let first = document.read_text(0, &Cancellation::default()).unwrap();
    assert!(first.text.ends_with('a'));
    assert_eq!(first.byte_range, 0..(TEXT_SECTION_BYTES - 1) as u64);
    let next = document
        .read_text(first.next_offset, &Cancellation::default())
        .unwrap();
    assert!(next.text.starts_with('😀'));
    assert_eq!(first.text + &next.text, text);
    let middle = document
        .read_text(TEXT_SECTION_BYTES as u64 + 1, &Cancellation::default())
        .unwrap();
    assert_eq!(middle.byte_range.start, (TEXT_SECTION_BYTES - 1) as u64);
    assert!(middle.text.starts_with('😀'));
    assert_eq!(
        document
            .read_text(text.len() as u64, &Cancellation::default())
            .unwrap()
            .text,
        ""
    );
}

#[test]
fn expanded_single_byte_text_still_fits_the_editor_page_budget() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("cp1252");
    let bytes = vec![0x80; TEXT_SECTION_BYTES + 1];
    fs::write(&path, &bytes).unwrap();
    let Document::Sections(document) =
        Document::open(&path, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    let mut offset = 0;
    let mut count = 0;
    while offset < bytes.len() as u64 {
        let page = document
            .read_text(offset, &Cancellation::default())
            .unwrap();
        assert!(page.text.len() <= TEXT_SECTION_BYTES);
        assert!(page.next_offset > offset);
        assert_eq!(page.byte_range.start, offset);
        assert!(page.text.chars().all(|c| c == '€'));
        count += page.text.chars().count();
        offset = page.next_offset;
    }
    assert_eq!(count, bytes.len());
}

#[test]
fn sparse_multi_gigabyte_hex_read_is_bounded_and_uses_target_metadata() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sparse");
    let link = dir.path().join("link");
    let file = File::create(&path).unwrap();
    file.set_len(8 * 1024 * 1024 * 1024).unwrap();
    symlink(&path, &link).unwrap();
    let Document::Hex(document) = Document::open(&link, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    assert_eq!(document.identity().size(), 8 * 1024 * 1024 * 1024);
    assert_eq!(
        document.identity().inode(),
        fs::metadata(&path).unwrap().ino()
    );
    assert_eq!(document.path(), path.canonicalize().unwrap());
    let page = document
        .read_hex(
            7 * 1024 * 1024 * 1024,
            HEX_SECTION_BYTES,
            &Cancellation::default(),
        )
        .unwrap();
    assert_eq!(page.bytes.len(), HEX_SECTION_BYTES);
    assert!(page.bytes.iter().all(|&b| b == 0));
    assert!(matches!(
        document.read_hex(0, HEX_SECTION_BYTES + 1, &Cancellation::default()),
        Err(Error::Limit)
    ));
    assert!(matches!(
        document.read_text(0, &Cancellation::default()),
        Err(Error::NotText)
    ));
}

#[test]
fn utf16_and_utf32_pages_respect_code_units_and_surrogate_pairs() {
    let dir = tempfile::tempdir().unwrap();
    for (name, bom, encoding) in [
        ("le16", vec![0xff, 0xfe], Encoding::Utf16Le),
        ("be16", vec![0xfe, 0xff], Encoding::Utf16Be),
        ("le32", vec![0xff, 0xfe, 0, 0], Encoding::Utf32Le),
        ("be32", vec![0, 0, 0xfe, 0xff], Encoding::Utf32Be),
    ] {
        let path = dir.path().join(name);
        let mut file = File::create(&path).unwrap();
        file.write_all(&bom).unwrap();
        let text = if matches!(encoding, Encoding::Utf16Le | Encoding::Utf16Be) {
            format!("{}😀Z", "a".repeat(TEXT_SECTION_BYTES / 2 - 1))
        } else {
            "A😀Z".into()
        };
        let body: Vec<u8> = match encoding {
            Encoding::Utf16Le => text.encode_utf16().flat_map(u16::to_le_bytes).collect(),
            Encoding::Utf16Be => text.encode_utf16().flat_map(u16::to_be_bytes).collect(),
            Encoding::Utf32Le => text
                .chars()
                .flat_map(|c| (c as u32).to_le_bytes())
                .collect(),
            _ => text
                .chars()
                .flat_map(|c| (c as u32).to_be_bytes())
                .collect(),
        };
        file.write_all(&body).unwrap();
        file.set_len(EDITABLE_BYTES as u64 + 4).unwrap();
        let Document::Sections(document) =
            Document::open(&path, None, &Cancellation::default()).unwrap()
        else {
            panic!()
        };
        assert_eq!(document.encoding(), Some(encoding));
        assert_eq!(document.bom(), bom);
        let page = document.read_text(0, &Cancellation::default()).unwrap();
        assert_eq!(page.byte_range.start, bom.len() as u64);
        if matches!(encoding, Encoding::Utf16Le | Encoding::Utf16Be) {
            assert!(page.text.ends_with('😀'));
            assert_eq!(
                page.byte_range.end,
                (bom.len() + TEXT_SECTION_BYTES + 2) as u64
            );
            let inside = document
                .read_text(
                    (bom.len() + TEXT_SECTION_BYTES + 1) as u64,
                    &Cancellation::default(),
                )
                .unwrap();
            assert!(inside.text.starts_with('😀'));
        } else {
            assert!(page.text.starts_with("A😀Z"));
        }
    }
}

#[test]
fn later_binary_or_malformed_content_fails_instead_of_lossy_pages() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("late-nul");
    let mut file = File::create(&path).unwrap();
    file.write_all(&vec![b'a'; CLASSIFICATION_BYTES + 4])
        .unwrap();
    file.set_len(EDITABLE_BYTES as u64 + 8).unwrap();
    let Document::Sections(document) =
        Document::open(&path, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    assert!(matches!(
        document.read_text((CLASSIFICATION_BYTES + 8) as u64, &Cancellation::default()),
        Err(Error::Encoding(EncodingError::Binary))
    ));
    let malformed = dir.path().join("malformed");
    let mut file = File::create(&malformed).unwrap();
    file.write_all(&[0xff, 0xfe, 0, 0xd8, b'A', 0]).unwrap();
    file.set_len(EDITABLE_BYTES as u64 + 4).unwrap();
    let Document::Sections(document) =
        Document::open(&malformed, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    assert!(matches!(
        document.read_text(0, &Cancellation::default()),
        Err(Error::Encoding(EncodingError::Malformed))
    ));
}

#[test]
fn replacement_and_symlink_retargeting_invalidate_pages() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("old");
    let link = dir.path().join("link");
    let file = File::create(&path).unwrap();
    file.set_len(EDITABLE_BYTES as u64 + 1).unwrap();
    symlink(&path, &link).unwrap();
    let Document::Hex(document) = Document::open(&link, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    let replacement = dir.path().join("new");
    File::create(&replacement)
        .unwrap()
        .set_len(EDITABLE_BYTES as u64 + 1)
        .unwrap();
    fs::rename(&replacement, &path).unwrap();
    assert!(matches!(
        document.read_hex(0, 32, &Cancellation::default()),
        Err(Error::Stale)
    ));
    let Document::Hex(document) = Document::open(&link, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    let other = dir.path().join("other");
    File::create(&other)
        .unwrap()
        .set_len(EDITABLE_BYTES as u64 + 1)
        .unwrap();
    fs::remove_file(&link).unwrap();
    symlink(&other, &link).unwrap();
    assert!(matches!(
        document.read_hex(0, 32, &Cancellation::default()),
        Err(Error::Stale)
    ));
}

#[test]
fn cancellations_and_nonregular_inputs_fail_without_unbounded_reads() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("file");
    File::create(&path)
        .unwrap()
        .set_len(EDITABLE_BYTES as u64 + 1)
        .unwrap();
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(matches!(
        Document::open(&path, None, &cancel),
        Err(Error::Cancelled)
    ));
    let Document::Hex(document) = Document::open(&path, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    assert!(matches!(
        document.read_hex(0, 32, &cancel),
        Err(Error::Cancelled)
    ));
    assert!(matches!(
        Document::open(dir.path(), None, &Cancellation::default()),
        Err(Error::NotRegular)
    ));
    let fifo = dir.path().join("fifo");
    let name = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    assert!(matches!(
        Document::open(&fifo, None, &Cancellation::default()),
        Err(Error::NotRegular)
    ));
}

#[test]
fn explicit_nul_text_and_odd_units_are_handled_strictly() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("forced");
    fs::write(&path, b"A\0B").unwrap();
    assert!(matches!(
        Document::open(&path, None, &Cancellation::default()).unwrap(),
        Document::Hex(_)
    ));
    let Document::Text(document) =
        Document::open(&path, Some(Encoding::Utf8), &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    assert_eq!(document.text(), "A\0B");
    fs::write(&path, [0xff, 0xfe, b'A']).unwrap();
    assert!(matches!(
        Document::open(&path, None, &Cancellation::default()),
        Err(Error::Encoding(EncodingError::Malformed))
    ));
    let large = dir.path().join("odd-end");
    let mut file = File::create(&large).unwrap();
    file.write_all(&[0xff, 0xfe, b'A', 0]).unwrap();
    file.set_len(EDITABLE_BYTES as u64 + 1).unwrap();
    file.seek(SeekFrom::End(-1)).unwrap();
    file.write_all(b"A").unwrap();
    let Document::Sections(document) =
        Document::open(&large, None, &Cancellation::default()).unwrap()
    else {
        panic!()
    };
    assert!(matches!(
        document.read_text(EDITABLE_BYTES as u64, &Cancellation::default()),
        Err(Error::Encoding(EncodingError::Malformed))
    ));
}
