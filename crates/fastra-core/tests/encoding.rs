use fastra_core::encoding::{decode, decode_payload, Encoding, EncodingError, LineEnding};

#[test]
fn native_foundation_single_byte_mappings_are_exact_and_reversible() {
    let reference: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/swift-encoding-reference.json")).unwrap();
    for (name, encoding) in [
        ("Windows1252", Encoding::Windows1252),
        ("Latin1", Encoding::Latin1),
        ("MacRoman", Encoding::MacRoman),
    ] {
        for byte in 0..=255u8 {
            let expected = &reference[name][byte as usize];
            let result = decode(&[byte], Some(encoding));
            if expected.is_null() {
                assert_eq!(result, Err(EncodingError::Malformed));
            } else {
                let result = result.unwrap();
                assert_eq!(
                    result.text().chars().map(u32::from).collect::<Vec<_>>(),
                    [expected.as_u64().unwrap() as u32],
                    "{name} {byte}"
                );
                assert_eq!(
                    result.encode(result.text()).unwrap(),
                    [byte],
                    "{name} {byte}"
                );
            }
        }
    }
}

#[test]
fn unicode_codecs_preserve_bom_content_bom_and_mixed_line_endings() {
    for text in [
        "😀 café\r\nline\rfinal\n",
        "\u{feff}😀 café\r\nline\rfinal\n",
    ] {
        for encoding in [
            Encoding::Utf8,
            Encoding::Utf16Le,
            Encoding::Utf16Be,
            Encoding::Utf32Le,
            Encoding::Utf32Be,
        ] {
            let bom: &[u8] = match encoding {
                Encoding::Utf8 => &[0xef, 0xbb, 0xbf],
                Encoding::Utf16Le => &[0xff, 0xfe],
                Encoding::Utf16Be => &[0xfe, 0xff],
                Encoding::Utf32Le => &[0xff, 0xfe, 0, 0],
                _ => &[0, 0, 0xfe, 0xff],
            };
            for with_bom in [false, true] {
                let mut expected = if with_bom { bom.to_vec() } else { vec![] };
                match encoding {
                    Encoding::Utf8 => expected.extend(text.as_bytes()),
                    Encoding::Utf16Le | Encoding::Utf16Be => {
                        for unit in text.encode_utf16() {
                            expected.extend(if encoding == Encoding::Utf16Le {
                                unit.to_le_bytes()
                            } else {
                                unit.to_be_bytes()
                            });
                        }
                    }
                    _ => {
                        for c in text.chars() {
                            expected.extend(if encoding == Encoding::Utf32Le {
                                (c as u32).to_le_bytes()
                            } else {
                                (c as u32).to_be_bytes()
                            });
                        }
                    }
                }
                // Ohne Datei-BOM beginnt der gewählte Inhalt selbst mit einer BOM;
                // die explizite Dekodierung trennt wie der Mac genau die erste ab.
                let decoded = decode(&expected, Some(encoding)).unwrap();
                assert_eq!(decoded.encode(decoded.text()).unwrap(), expected);
                if with_bom || !text.starts_with('\u{feff}') {
                    assert_eq!(decoded.text(), text);
                }
                if with_bom {
                    assert_eq!(decoded.bom(), bom);
                }
            }
        }
    }
}

#[test]
fn malformed_unicode_never_falls_back_after_explicit_choice_or_bom() {
    for (encoding, bytes) in [
        (Encoding::Utf8, vec![0xc0, 0x80]),
        (Encoding::Utf8, vec![0xed, 0xa0, 0x80]),
        (Encoding::Utf16Le, vec![0x41]),
        (Encoding::Utf16Le, vec![0, 0xd8]),
        (Encoding::Utf16Le, vec![0, 0xdc]),
        (Encoding::Utf16Le, vec![0, 0xd8, 0x41, 0]),
        (Encoding::Utf16Be, vec![0xd8, 0]),
        (Encoding::Utf32Le, vec![0, 0, 0x11, 0]),
        (Encoding::Utf32Be, vec![0, 0, 0xd8, 0]),
        (Encoding::Utf32Le, vec![0x41, 0, 0]),
    ] {
        assert_eq!(
            decode(&bytes, Some(encoding)),
            Err(EncodingError::Malformed)
        );
    }
    assert_eq!(
        decode(&[0xff, 0xfe, 0x41], None),
        Err(EncodingError::Malformed)
    );
    assert_eq!(
        decode(&[0xef, 0xbb, 0xbf, 0xff], None),
        Err(EncodingError::Malformed)
    );
    assert_eq!(
        decode_payload(&[0xef, 0xbb, 0xbf], Encoding::Utf8).unwrap(),
        "\u{feff}"
    );
}

#[test]
fn automatic_detection_matches_mac_c1_policy_and_nul_boundary() {
    assert_eq!(
        decode("€".as_bytes(), None).unwrap().encoding(),
        Encoding::Utf8
    );
    assert_eq!(
        decode(&[0x80, b'!'], None).unwrap().encoding(),
        Encoding::Windows1252
    );
    assert_eq!(decode(&[0x81], None).unwrap().encoding(), Encoding::Latin1);
    assert_eq!(
        decode(&[0x80, 0x81], None).unwrap().encoding(),
        Encoding::Latin1
    );
    assert_eq!(decode(&[0xe9], None).unwrap().encoding(), Encoding::Latin1);
    assert_eq!(decode(b"A\0B", None), Err(EncodingError::Binary));
    assert_eq!(
        decode(&[0xef, 0xbb, 0xbf, 0], None),
        Err(EncodingError::Binary)
    );
    assert_eq!(decode(&[0xff, 0xfe, 0x41, 0], None).unwrap().text(), "A");
    assert_eq!(
        decode(b"A\0B", Some(Encoding::Utf8)).unwrap().text(),
        "A\0B"
    );
}

#[test]
fn explicit_encoding_and_unrepresentable_replacement_are_strict() {
    let latin = decode(&[0x80], Some(Encoding::Latin1)).unwrap();
    assert_eq!(latin.text(), "\u{80}");
    assert_eq!(latin.encode("€"), Err(EncodingError::Unrepresentable('€')));
    assert_eq!(
        latin.encode("😀"),
        Err(EncodingError::Unrepresentable('😀'))
    );
    let mac = decode(&[0x80], Some(Encoding::MacRoman)).unwrap();
    assert_eq!(mac.text(), "Ä");
    assert_eq!(mac.encode("Ä"), Ok(vec![0x80]));
    assert_eq!(mac.encode("😀"), Err(EncodingError::Unrepresentable('😀')));
    let forced = decode(&[0xff, 0xfe, b'A'], Some(Encoding::Utf8)).unwrap();
    assert_eq!(forced.text(), "A");
    assert_eq!(forced.encode("B").unwrap(), [0xff, 0xfe, b'B']);
}

#[test]
fn line_ending_detection_and_explicit_conversion_match_mac() {
    assert_eq!(LineEnding::detect("a\rb\nc\r\n"), LineEnding::CrLf);
    assert_eq!(LineEnding::detect("a\rb\n"), LineEnding::Cr);
    assert_eq!(LineEnding::detect("plain"), LineEnding::Lf);
    for (ending, expected) in [
        (LineEnding::Lf, "a\nb\nc\n"),
        (LineEnding::CrLf, "a\r\nb\r\nc\r\n"),
        (LineEnding::Cr, "a\rb\rc\r"),
    ] {
        assert_eq!(ending.convert("a\r\nb\rc\n"), expected);
    }
}
