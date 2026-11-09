use super::*;
fn fixture(text: &str) -> (tempfile::TempDir, PathBuf, PathBuf, Snapshot, Arc<Decoded>) {
    let root = std::env::var_os("FASTRA_IO_TEST_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let dir = tempfile::tempdir_in(root).unwrap();
    let source = dir.path().join("old");
    let destination = dir.path().join("new");
    std::fs::create_dir(&source).unwrap();
    std::fs::create_dir(&destination).unwrap();
    let path = source.join("document.md");
    std::fs::write(&path, text).unwrap();
    let snapshot = Snapshot::read(&path, &Cancellation::default()).unwrap();
    let format = Arc::new(fastra_core::encoding::decode(snapshot.bytes(), None).unwrap());
    (dir, path, destination.join("copy.md"), snapshot, format)
}
fn owner() -> Owner {
    Owner {
        document: "save-as-test".into(),
        revision: 1,
        generation: 1,
    }
}
#[test]
fn complete_used_images_are_deduplicated_and_original_blocks_preserved() {
    let text="Before\r\n\r\n![A](../old/a%23b.png)\r\n\r\n![B][used]\r\n\r\n`![code](missing.png)`\r\n\r\n$$ ![math](missing.png) $$\r\n\r\n[used]: a%23b.png \"title\"\r\n[unused]: missing.png\r\n";
    let (_dir, path, target, snapshot, format) = fixture(text);
    let bytes = include_bytes!("../../../tests/fixtures/pixel-1.png");
    std::fs::write(path.parent().unwrap().join("a#b.png"), bytes).unwrap();
    let prepared = prepare(
        snapshot,
        text.into(),
        format,
        target.clone(),
        true,
        owner(),
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(prepared.images.len(), 1);
    assert!(prepared.output.starts_with("Before\r\n\r\n"));
    assert!(prepared.output.contains("`![code](missing.png)`"));
    assert!(prepared.output.contains("$$ ![math](missing.png) $$"));
    assert!(prepared.output.ends_with("[unused]: missing.png\r\n"));
    assert!(!target.exists());
    assert!(!target.parent().unwrap().join("images").exists());
    let Outcome::Published {
        snapshot, assets, ..
    } = prepared.publish(&Cancellation::default())
    else {
        panic!("not published")
    };
    let receipt = assets.unwrap();
    assert_eq!(std::fs::read(path).unwrap(), text.as_bytes());
    assert_eq!(
        std::fs::read(
            target
                .parent()
                .unwrap()
                .join(&receipt.preview()[0].relative)
        )
        .unwrap(),
        bytes
    );
    assert_eq!(snapshot.path(), target);
}
#[test]
fn unclear_dependencies_and_missing_second_image_fail_before_writes() {
    for text in [
        "<img src='picture.png'>",
        "[attachment](report.pdf)",
        "![one](one.png)\n\n![two](missing.png)",
        "![unsupported](thing.svg)",
    ] {
        let (_dir, path, target, snapshot, format) = fixture(text);
        std::fs::write(path.parent().unwrap().join("one.png"), b"one").unwrap();
        std::fs::write(path.parent().unwrap().join("thing.svg"), b"svg").unwrap();
        assert!(prepare(
            snapshot,
            text.into(),
            format,
            target.clone(),
            true,
            owner(),
            &Cancellation::default()
        )
        .is_err());
        assert!(!target.exists());
        assert!(!target.parent().unwrap().join("images").exists());
        assert_eq!(std::fs::read(path).unwrap(), text.as_bytes());
    }
}
#[test]
fn encoded_bytes_and_mixed_line_endings_survive_save_as() {
    use fastra_core::encoding::{decode, Encoding};
    for encoding in [
        Encoding::Utf8,
        Encoding::Utf16Le,
        Encoding::Utf16Be,
        Encoding::Utf32Le,
        Encoding::Utf32Be,
        Encoding::Latin1,
        Encoding::Windows1252,
        Encoding::MacRoman,
    ] {
        let text = "é\r\nBefore\rAfter\n";
        let (_dir, path, target, _snapshot, _format) = fixture(text);
        let initial = match encoding {
            Encoding::Utf16Le => vec![0xff, 0xfe],
            Encoding::Utf16Be => vec![0xfe, 0xff],
            Encoding::Utf32Le => vec![0xff, 0xfe, 0, 0],
            Encoding::Utf32Be => vec![0, 0, 0xfe, 0xff],
            Encoding::Utf8 => vec![0xef, 0xbb, 0xbf],
            _ => vec![],
        };
        let format = decode(&initial, Some(encoding)).unwrap();
        let bytes = format.encode(text).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        let snapshot = Snapshot::read(&path, &Cancellation::default()).unwrap();
        let format = Arc::new(decode(snapshot.bytes(), Some(encoding)).unwrap());
        let prepared = prepare(
            snapshot,
            text.into(),
            format,
            target.clone(),
            false,
            owner(),
            &Cancellation::default(),
        )
        .unwrap();
        assert_eq!(prepared.encoded, bytes);
        let Outcome::Published { snapshot, .. } = prepared.publish(&Cancellation::default()) else {
            panic!()
        };
        assert_eq!(snapshot.bytes(), bytes);
        assert_eq!(std::fs::read(path).unwrap(), bytes);
    }
}
#[test]
fn post_asset_collision_is_reported_without_claiming_no_files_written() {
    let text = "![image](one.png)\n";
    let (_dir, path, target, snapshot, format) = fixture(text);
    std::fs::write(
        path.parent().unwrap().join("one.png"),
        b"original image bytes",
    )
    .unwrap();
    let prepared = prepare(
        snapshot,
        text.into(),
        format,
        target.clone(),
        true,
        owner(),
        &Cancellation::default(),
    )
    .unwrap();
    let result = prepared.publish_with(&Cancellation::default(), || {
        std::fs::write(&target, "Foreign target").unwrap()
    });
    let Outcome::Failed {
        possibly_published: false,
        assets: Some(mut receipt),
        ..
    } = result
    else {
        panic!()
    };
    assert!(receipt.is_applied());
    assert_eq!(std::fs::read(&target).unwrap(), b"Foreign target");
    receipt.undo(&owner(), &Cancellation::default()).unwrap();
    assert_eq!(
        std::fs::read(&receipt.recovery_paths()[0].1).unwrap(),
        b"original image bytes"
    );
    assert_eq!(std::fs::read(path).unwrap(), text.as_bytes());
}

#[test]
fn source_changes_before_and_after_asset_publication_never_publish_target_text() {
    for after_assets in [false, true] {
        let text = "![one](one.png)\n\n![two](two.png)\n";
        let (_dir, path, target, snapshot, format) = fixture(text);
        let one = path.parent().unwrap().join("one.png");
        let two = path.parent().unwrap().join("two.png");
        std::fs::write(&one, "one original").unwrap();
        std::fs::write(&two, "two original").unwrap();
        let prepared = prepare(
            snapshot,
            text.into(),
            format,
            target.clone(),
            true,
            owner(),
            &Cancellation::default(),
        )
        .unwrap();
        let mutate = || std::fs::write(&two, "Foreign second image edit").unwrap();
        let result = if after_assets {
            prepared.publish_with(&Cancellation::default(), mutate)
        } else {
            mutate();
            prepared.publish(&Cancellation::default())
        };
        let Outcome::Failed {
            possibly_published: false,
            assets,
            ..
        } = result
        else {
            panic!()
        };
        assert!(!target.exists());
        if after_assets {
            let (receipt, result) = crate::save_as::rollback::compensate(
                assets.unwrap(),
                &owner(),
                &target,
                &[],
                true,
                Language(false),
            );
            result.unwrap();
            assert!(!receipt.is_applied());
            assert!(receipt
                .recovery_paths()
                .iter()
                .all(|(_, path)| path.exists()));
        } else {
            assert!(assets.is_none());
            assert!(!target.parent().unwrap().join("images").exists());
        }
        assert_eq!(std::fs::read(path).unwrap(), text.as_bytes());
        assert_eq!(std::fs::read(one).unwrap(), b"one original");
        assert_eq!(std::fs::read(two).unwrap(), b"Foreign second image edit");
    }
}
#[test]
fn deduplicated_aliases_remain_individually_bound() {
    use std::os::unix::fs::symlink;
    let text = "![one](one.png)\n\n![alias](alias.png)\n";
    let (_dir, path, target, snapshot, format) = fixture(text);
    let one = path.parent().unwrap().join("one.png");
    let two = path.parent().unwrap().join("two.png");
    let alias = path.parent().unwrap().join("alias.png");
    std::fs::write(&one, "one").unwrap();
    std::fs::write(&two, "two").unwrap();
    symlink(&one, &alias).unwrap();
    let prepared = prepare(
        snapshot,
        text.into(),
        format,
        target.clone(),
        true,
        owner(),
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(prepared.images.len(), 1);
    std::fs::remove_file(&alias).unwrap();
    symlink(&two, &alias).unwrap();
    assert!(matches!(
        prepared.publish(&Cancellation::default()),
        Outcome::Failed {
            possibly_published: false,
            assets: None,
            ..
        }
    ));
    assert!(!target.exists());
    assert!(!target.parent().unwrap().join("images").exists());
}
#[test]
fn encoding_refusal_precedes_every_write_and_inline_whitelist_needs_no_relocation() {
    let (_dir, path, target, snapshot, _format) = fixture("Plain\n");
    std::fs::write(path.parent().unwrap().join("one.png"), "one").unwrap();
    let format = Arc::new(
        fastra_core::encoding::decode(
            snapshot.bytes(),
            Some(fastra_core::encoding::Encoding::Windows1252),
        )
        .unwrap(),
    );
    assert!(prepare(
        snapshot,
        "![image](one.png) 😀".into(),
        format,
        target.clone(),
        true,
        owner(),
        &Cancellation::default()
    )
    .is_err());
    assert!(!target.exists());
    assert!(!target.parent().unwrap().join("images").exists());
    let text =
        "<strong>Bold</strong> and <mark>Marked</mark>\n\n[web](HTTPS://example.invalid/x)\n";
    let (_dir, _path, target, snapshot, format) = fixture(text);
    let prepared = prepare(
        snapshot,
        text.into(),
        format,
        target,
        true,
        owner(),
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(prepared.output, text);
    assert!(prepared.assets.is_none());
    assert_eq!(fragment("name%23part.png#frame%202"), "#frame%202");
}

const SYMLINK_PARENT_TEXT: &str =
    "![through symlink](alias/../pic.png)\n\n![same actual file](../external/pic.png)\n";
fn symlink_parent_fixture() -> (tempfile::TempDir, PathBuf, PathBuf, Snapshot, Arc<Decoded>) {
    use std::os::unix::fs::symlink;
    let fixture = fixture(SYMLINK_PARENT_TEXT);
    let (dir, path, _, _, _) = &fixture;
    std::fs::create_dir_all(dir.path().join("external/sub")).unwrap();
    std::fs::create_dir_all(dir.path().join("other/sub")).unwrap();
    let shown = include_bytes!("../../../tests/fixtures/pixel-2.png");
    let lexical = include_bytes!("../../../tests/fixtures/pixel-1.png");
    assert_ne!(shown.as_slice(), lexical.as_slice());
    std::fs::write(dir.path().join("external/pic.png"), shown).unwrap();
    std::fs::write(dir.path().join("other/pic.png"), lexical).unwrap();
    std::fs::write(path.parent().unwrap().join("pic.png"), lexical).unwrap();
    symlink(
        dir.path().join("external/sub"),
        path.parent().unwrap().join("alias"),
    )
    .unwrap();
    fixture
}
#[test]
fn symlink_parent_paths_copy_the_rendered_raster_and_deduplicate_actual_targets() {
    let (_dir, path, target, snapshot, format) = symlink_parent_fixture();
    let prepared = prepare(
        snapshot,
        SYMLINK_PARENT_TEXT.into(),
        format,
        target.clone(),
        true,
        owner(),
        &Cancellation::default(),
    )
    .unwrap();
    let shown = include_bytes!("../../../tests/fixtures/pixel-2.png");
    assert_eq!(prepared.images[0].snapshot.bytes(), shown);
    assert_eq!(prepared.images.len(), 1);
    assert_eq!(prepared.source_links.len(), 2);
    assert_eq!(
        prepared.source_links[0].0,
        path.parent().unwrap().join("alias/../pic.png")
    );
    let Outcome::Published {
        assets: Some(receipt),
        ..
    } = prepared.publish(&Cancellation::default())
    else {
        panic!("not published")
    };
    assert_eq!(
        std::fs::read(
            target
                .parent()
                .unwrap()
                .join(&receipt.preview()[0].relative)
        )
        .unwrap(),
        shown
    );
    assert_eq!(std::fs::read(path).unwrap(), SYMLINK_PARENT_TEXT.as_bytes());
}

#[test]
fn symlink_parent_alias_drift_is_rejected_before_and_after_asset_publication() {
    use std::os::unix::fs::symlink;
    for after_assets in [false, true] {
        let (dir, path, target, snapshot, format) = symlink_parent_fixture();
        let prepared = prepare(
            snapshot,
            SYMLINK_PARENT_TEXT.into(),
            format,
            target.clone(),
            true,
            owner(),
            &Cancellation::default(),
        )
        .unwrap();
        let retarget = || {
            let alias = path.parent().unwrap().join("alias");
            std::fs::remove_file(&alias).unwrap();
            symlink(dir.path().join("other/sub"), alias).unwrap();
        };
        let result = if after_assets {
            prepared.publish_with(&Cancellation::default(), retarget)
        } else {
            retarget();
            prepared.publish(&Cancellation::default())
        };
        let Outcome::Failed {
            possibly_published: false,
            assets,
            ..
        } = result
        else {
            panic!("alias drift was accepted")
        };
        assert!(!target.exists());
        assert_eq!(
            std::fs::read(&path).unwrap(),
            SYMLINK_PARENT_TEXT.as_bytes()
        );
        if after_assets {
            let receipt = assets.unwrap();
            assert_eq!(receipt.preview().len(), 1);
            assert_eq!(
                std::fs::read(
                    target
                        .parent()
                        .unwrap()
                        .join(&receipt.preview()[0].relative)
                )
                .unwrap(),
                include_bytes!("../../../tests/fixtures/pixel-2.png")
            );
        } else {
            assert!(assets.is_none());
            assert!(!target.parent().unwrap().join("images").exists());
        }
    }
}

#[test]
#[ignore = "Native bounded image sandbox; isolated authorized Linux session"]
fn symlink_parent_native_source_read_and_published_destination_decode_match() {
    let (_dir, path, target, snapshot, format) = symlink_parent_fixture();
    let raw = path
        .parent()
        .unwrap()
        .join(markdown::decode_path("alias/../pic.png").unwrap());
    let native_cancel = crate::viewer::Cancellation::default();
    let crate::viewer::Loaded::Visual(source) =
        crate::viewer::load(&raw, None, &native_cancel).unwrap()
    else {
        panic!("not a visual source")
    };
    let shown = include_bytes!("../../../tests/fixtures/pixel-2.png");
    assert_eq!(source.snapshot().bytes(), shown);
    let source_image =
        crate::viewer::prepare_rich_image(source.snapshot().bytes(), "png", &native_cancel, true)
            .unwrap();
    assert_eq!((source_image.width, source_image.height), (2, 1));
    let prepared = prepare(
        snapshot,
        SYMLINK_PARENT_TEXT.into(),
        format,
        target.clone(),
        true,
        owner(),
        &Cancellation::default(),
    )
    .unwrap();
    let Outcome::Published {
        assets: Some(receipt),
        ..
    } = prepared.publish(&Cancellation::default())
    else {
        panic!("not published")
    };
    assert_eq!(receipt.preview().len(), 1);
    let destination = target
        .parent()
        .unwrap()
        .join(&receipt.preview()[0].relative);
    let crate::viewer::Loaded::Visual(copied) =
        crate::viewer::load(&destination, None, &native_cancel).unwrap()
    else {
        panic!("not a visual destination")
    };
    assert_eq!(copied.snapshot().bytes(), source.snapshot().bytes());
    let image =
        crate::viewer::prepare_rich_image(copied.snapshot().bytes(), "png", &native_cancel, true)
            .unwrap();
    assert_eq!((image.width, image.height), (2, 1));
    assert!(image.thumbnail.is_some());
}

#[test]
fn math_and_cr_fences_keep_original_bytes_during_actual_reference_relocation() {
    let lf="雪🙂\n\n```md\n![code](missing.png)\n```\n\n$$\na + b\n  \n![math](missing.png)\n$$\n\n==Before==\n\n![real][image]\n\n[image]: one.png\n";
    for eol in ["\n", "\r\n", "\r"] {
        let text = lf.replace('\n', eol);
        let (_dir, path, target, snapshot, format) = fixture(&text);
        std::fs::write(
            path.parent().unwrap().join("one.png"),
            include_bytes!("../../../tests/fixtures/pixel-1.png"),
        )
        .unwrap();
        let range = crate::rich_editor::asset_flow::references(&text)
            .unwrap()
            .pop()
            .unwrap()
            .range;
        assert_eq!(&text[range.clone()], "![real][image]");
        let prepared = prepare(
            snapshot,
            text.clone(),
            format,
            target.clone(),
            true,
            owner(),
            &Cancellation::default(),
        )
        .unwrap();
        assert_eq!(prepared.images.len(), 1);
        assert!(prepared.output.starts_with(&text[..range.start]));
        assert!(prepared.output.ends_with(&text[range.end..]));
        let output = prepared.output.clone();
        let Outcome::Published { snapshot, .. } = prepared.publish(&Cancellation::default()) else {
            panic!("not published")
        };
        assert_eq!(snapshot.path(), target);
        assert_eq!(std::fs::read(&target).unwrap(), output.as_bytes());
        assert_eq!(std::fs::read(&path).unwrap(), text.as_bytes());
    }
}

#[test]
fn literal_math_names_and_reference_ids_survive_actual_asset_relocation() {
    let literal = "FASTRAMATH00000000000000000000000000000000TOKEN.png";
    for occurrence in [
        format!("![alt $x$]({literal})"),
        "![picture][$x$]".into(),
        "![alt $x$][]".into(),
        "![alt $x$]".into(),
    ] {
        for eol in ["\n", "\r\n", "\r"] {
            let text = format!("雪🙂\n\n{occurrence}\n\n[$x$]: {literal}\n[alt $x$]: {literal}\n")
                .replace('\n', eol);
            let (_dir, path, target, snapshot, format) = fixture(&text);
            std::fs::write(
                path.parent().unwrap().join(literal),
                include_bytes!("../../../tests/fixtures/pixel-1.png"),
            )
            .unwrap();
            let refs = crate::rich_editor::asset_flow::references(&text).unwrap();
            assert_eq!(refs.len(), 1);
            let range = refs[0].range.clone();
            assert_eq!(&text[range.clone()], occurrence);
            let prepared = prepare(
                snapshot,
                text.clone(),
                format,
                target.clone(),
                true,
                owner(),
                &Cancellation::default(),
            )
            .unwrap();
            assert_eq!(prepared.images.len(), 1);
            assert!(prepared.output.starts_with(&text[..range.start]));
            assert!(prepared.output.ends_with(&text[range.end..]));
            let output = prepared.output.clone();
            let Outcome::Published { snapshot, .. } = prepared.publish(&Cancellation::default())
            else {
                panic!("not published")
            };
            assert_eq!(snapshot.path(), target);
            assert_eq!(std::fs::read(&target).unwrap(), output.as_bytes());
            assert_eq!(std::fs::read(&path).unwrap(), text.as_bytes());
        }
    }
}
