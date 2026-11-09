use super::*;
#[test]
fn mixed_xml_boundary_preserves_source_and_normalizes_method_name() {
    let source="<!DOCTYPE macros SYSTEM \"http://www.4d.com/dtd/2007/macros.dtd\"><macros><macro name=\"If /Ü\"><text>If (<caret/>)\n\t<selection/><![CDATA[\nEnd if]]></text></macro><macro name=\"Runtime\"><text><caret/><method>MAO_MethodeKomplettierenNeu(\"&lt;method_name/&gt;\")</method></text></macro></macros>";
    let m = parse(
        source,
        "Macros.xml",
        "/a/Macros.xml",
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(m.len(), 2);
    assert_eq!(m[0].shortcut.as_deref(), Some("ü"));
    assert_eq!(
        m[0].parts,
        vec![
            Part::Literal("If (".into()),
            Part::Caret,
            Part::Literal(")\n\t".into()),
            Part::Selection,
            Part::Literal("\nEnd if".into())
        ]
    );
    assert_eq!(
        m[1].method_call.as_deref(),
        Some("MAO_MethodeKomplettierenNeu(\"<method_name/>\")")
    );
    assert_eq!(capability(&m[1]), Capability::Runtime("komplettieren"));
}
#[test]
fn original_macos_parser_goldens_match() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../tests/fixtures/four-d-macros-macos.json"
    ))
    .unwrap();
    for case in fixture["parser"].as_array().unwrap() {
        let key = case["name"].as_str().unwrap();
        let macros = parse(
            case["xml"].as_str().unwrap(),
            "Macros.xml",
            &format!("source:{key}"),
            Limits::default(),
            &Cancellation::default(),
        )
        .unwrap_or_default();
        let mut actual = serde_json::to_value(&macros).unwrap();
        for (m, json) in macros.iter().zip(actual.as_array_mut().unwrap()) {
            json["capability"] = match capability(m) {
                Capability::NativeText => "nativeText".into(),
                Capability::Runtime(v) => format!("runtime:{v}").into(),
                Capability::Unsupported(_) => "unsupported".into(),
            };
        }
        assert_eq!(&actual, &case["macros"], "{key}");
    }
}
#[test]
fn original_macos_date_time_goldens_match() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../tests/fixtures/four-d-macros-macos.json"
    ))
    .unwrap();
    let mut differences = Vec::new();
    for case in fixture["dateTime"].as_array().unwrap() {
        let actual = date_time(
            case["millis"].as_f64().unwrap(),
            case["locale"].as_str().unwrap(),
            "UTC",
            case["time"].as_bool().unwrap(),
            case["format"].as_u64().unwrap() as u8,
        )
        .unwrap();
        if actual != case["value"].as_str().unwrap() {
            differences.push(format!(
                "{} {} time={} format={}: {:?} != {:?}",
                case["millis"], case["locale"], case["time"], case["format"], actual, case["value"]
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}
fn one(body: &str) -> Macro {
    parse(
        &format!("<macros><macro name=\"Text /#\"><text>{body}</text></macro></macros>"),
        "a",
        "a",
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap()
    .remove(0)
}
#[test]
fn insertion_preserves_emoji_nfc_fulltext_user_and_first_caret() {
    let m = one("// <method_name/>:<selection/><caret/>X<caret/><user_os/>|<text/>");
    let dates = std::array::from_fn(|_| String::new());
    let times = std::array::from_fn(|_| String::new());
    let rendered = render(
        &m,
        &Context {
            full_text: "a😀b",
            selection: 1..5,
            method_name: &normalized_method_name("U\u{308}bersicht.4DM"),
            user_os: "test-user",
            dates: &dates,
            times: &times,
        },
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(rendered.text, "// Übersicht:😀Xtest-user|a😀b");
    assert_eq!(
        rendered.caret_utf16,
        Some("// Übersicht:😀".encode_utf16().count())
    );
    assert!(render(
        &m,
        &Context {
            full_text: "a😀b",
            selection: 2..5,
            method_name: "M",
            user_os: "u",
            dates: &dates,
            times: &times
        },
        Limits::default(),
        &Cancellation::default()
    )
    .is_err());
}
#[test]
fn unknown_tags_clipboard_bad_formats_and_runtime_never_expand() {
    let dates = std::array::from_fn(|_| "date".into());
    let times = std::array::from_fn(|_| "time".into());
    let context = Context {
        full_text: "original",
        selection: 0..0,
        method_name: "M",
        user_os: "u",
        dates: &dates,
        times: &times,
    };
    for body in [
        "before<future/>after",
        "<clipboard/>",
        "<date format=\"9\"/>",
        "<time format=\"x\"/>",
        "<method>MAO_MethodeKomplettierenNeu(<method_name/>)</method>",
        "<method>Unknown(<future/>)</method>",
    ] {
        assert!(
            render(
                &one(body),
                &context,
                Limits::default(),
                &Cancellation::default()
            )
            .is_err(),
            "{body}"
        );
    }
}
#[test]
fn all_parser_budgets_cancel_and_expansion_fail_without_partial_result() {
    let xml = "<macros><macro name=\"A\"><text>x<selection/><selection/></text></macro></macros>";
    for limits in [
        Limits {
            source_bytes: 8,
            ..Default::default()
        },
        Limits {
            macro_count: 0,
            ..Default::default()
        },
        Limits {
            text_utf16: 0,
            ..Default::default()
        },
        Limits {
            parts: 1,
            ..Default::default()
        },
    ] {
        assert!(parse(xml, "a", "a", limits, &Cancellation::default()).is_err());
    }
    let xml="<macros><macro name=\"R\"><text><method><method_name/><method_name/></method></text></macro></macros>";
    assert!(parse(
        xml,
        "a",
        "a",
        Limits {
            text_utf16: 20,
            ..Default::default()
        },
        &Cancellation::default()
    )
    .is_err());
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(
        parse(xml, "a", "a", Limits::default(), &cancel),
        Err(Error::Cancelled)
    );
    let dates = std::array::from_fn(|_| String::new());
    let times = std::array::from_fn(|_| String::new());
    assert!(render(
        &one("<text/><text/>"),
        &Context {
            full_text: "123456",
            selection: 0..0,
            method_name: "M",
            user_os: "u",
            dates: &dates,
            times: &times
        },
        Limits {
            output_bytes: 8,
            ..Default::default()
        },
        &Cancellation::default()
    )
    .is_err());
}
#[test]
fn source_ids_and_shortcuts_remain_distinct_and_reserved() {
    let mut macros = vec![one("first"), one("second")];
    macros[1].id = "b#0".into();
    assert_ne!(macros[0].id, macros[1].id);
    resolve_shortcuts(&mut macros, &HashSet::new());
    assert_eq!(macros[0].shortcut.as_deref(), Some("#"));
    assert_eq!(macros[1].shortcut, None);
    resolve_shortcuts(&mut macros, &HashSet::from(["#".into()]));
    assert_eq!(macros[0].shortcut, None);
    assert_eq!(split_name("Name /ab"), ("Name /ab".into(), None));
}
#[test]
fn external_entities_are_never_resolved() {
    let xml="<!DOCTYPE macros [<!ENTITY remote SYSTEM 'file:///etc/passwd'>]><macros><macro name='a'><text>&remote;</text></macro></macros>";
    assert!(parse(xml, "a", "a", Limits::default(), &Cancellation::default()).is_err());
}
#[test]
fn encoded_xml_is_explicit_and_does_not_guess_invalid_utf8() {
    let xml="<?xml version='1.0' encoding='UTF-16'?><macros><macro name='Ü'><text>é😀\t</text></macro></macros>";
    let mut bytes = vec![0xff, 0xfe];
    for unit in xml.encode_utf16() {
        bytes.extend(unit.to_le_bytes());
    }
    let m = parse_bytes(
        &bytes,
        "a",
        "a",
        Limits::default(),
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(m[0].display_name, "Ü");
    assert_eq!(m[0].parts, vec![Part::Literal("é😀\t".into())]);
    let xml=b"<?xml version='1.0' encoding='ISO-8859-1'?><macros><macro name='\xdc'><text>\xe9</text></macro></macros>";
    let m = parse_bytes(xml, "a", "a", Limits::default(), &Cancellation::default()).unwrap();
    assert_eq!(m[0].display_name, "Ü");
    assert_eq!(m[0].parts, vec![Part::Literal("é".into())]);
    assert!(parse_bytes(
        b"<macros><macro name='\xff'/></macros>",
        "a",
        "a",
        Limits::default(),
        &Cancellation::default()
    )
    .is_err());
}
#[test]
fn qualified_placeholders_cannot_become_known_unqualified_tags() {
    let m = one("a<p:selection xmlns:p='urn:test'/>b");
    assert_eq!(m.unknown_placeholder.as_deref(), Some("p:selection"));
    assert_ne!(capability(&m), Capability::NativeText);
}
#[test]
fn a_later_empty_method_cannot_hide_an_earlier_executable_call() {
    let m = one("prefix<method>Other()</method><method/>suffix");
    assert_eq!(
        capability(&m),
        Capability::Unsupported("multiple-method-calls".into())
    );
}

#[test]
fn original_macos_encoded_xml_goldens_match() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../tests/fixtures/four-d-macros-macos.json"
    ))
    .unwrap();
    for case in fixture["encoded"].as_array().unwrap() {
        let key = case["name"].as_str().unwrap();
        let bytes: &[u8] = match key {
            "utf16" => include_bytes!("../../tests/fixtures/four-d-macros-utf16.xml"),
            "latin1" => include_bytes!("../../tests/fixtures/four-d-macros-latin1.xml"),
            _ => panic!("Unknown encoded oracle fixture"),
        };
        let macros = parse_bytes(
            bytes,
            "Macros.xml",
            &format!("source:{key}"),
            Limits::default(),
            &Cancellation::default(),
        )
        .unwrap();
        let mut actual = serde_json::to_value(&macros).unwrap();
        for (m, json) in macros.iter().zip(actual.as_array_mut().unwrap()) {
            json["capability"] = match capability(m) {
                Capability::NativeText => "nativeText".into(),
                Capability::Runtime(v) => format!("runtime:{v}").into(),
                Capability::Unsupported(_) => "unsupported".into(),
            };
        }
        assert_eq!(&actual, &case["macros"], "{key}");
    }
}
