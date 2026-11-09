use fastra_core::{four_d::*, Cancellation};
#[test]
fn definitions_ignore_prose_sql_and_preserve_source_offsets() {
    let source="// Function fake()\r\n/*\nFunction hidden()\n*/\r\n\"Function string()\"\r\nBegin SQL\r\nFunction sql()\r\nEnd SQL\r\n  exposed Function get Grüße($name : Text)\r\nshared Class constructor()\r\nFunction orderBy ordre()";
    let analysis = Analysis::build(source, &Cancellation::default()).unwrap();
    assert_eq!(
        analysis
            .definitions
            .iter()
            .map(|d| d.name.as_str())
            .collect::<Vec<_>>(),
        ["Grüße", "Class constructor", "ordre"]
    );
    assert_eq!(analysis.definitions[0].kind, Kind::Getter);
    for d in &analysis.definitions {
        let part = &source[d.span.bytes.clone()];
        assert!(!part.contains('('));
        assert_eq!(
            source[..d.span.bytes.start].encode_utf16().count(),
            d.span.utf16.start
        );
        assert_eq!(
            source[..d.span.bytes.end].chars().count(),
            d.span.characters.end
        );
    }
    assert_eq!(analysis.definitions[0].span.line, 9);
}
#[test]
fn declaration_styles_match_swift_explicit_vectors() {
    let a=Analysis::build("\u{feff}//%attributes = {}\r// Liefert eine Grußformel.\r// Zweite Kopfzeile.\r#DECLARE($name_t : Text; $anzahl_i : Integer)->$gruss_t : Text",&Cancellation::default()).unwrap();
    assert_eq!(
        a.signature.header,
        "// Liefert eine Grußformel.\n// Zweite Kopfzeile."
    );
    assert_eq!(
        a.signature.parameters[0],
        Parameter {
            name: "$name_t".into(),
            type_name: Some("Text".into())
        }
    );
    assert_eq!(a.signature.returns.unwrap().name, "$gruss_t");
    let a=Analysis::build("C_BOOLEAN:C305($1)\nC_TEXT:C284($2;$4;$keinParameter_t;prozess;<>inter)\nC_LONGINT:C283($0)\nC_DATE:C307($1000000000)\nC_TEXT(${5})",&Cancellation::default()).unwrap();
    assert_eq!(a.signature.parameters.len(), 5);
    assert_eq!(a.signature.parameters[2].type_name, None);
    assert_eq!(a.signature.parameters[4].name, "${5}…");
    assert_eq!(
        a.signature.returns.unwrap().type_name,
        Some("Longint".into())
    );
}
#[test]
fn call_context_nested_arguments_strings_and_comments() {
    let source = "/* comment\r\nclosed */ Méthode longue(\"a;b\"; Inner(1;2); ";
    let a = Analysis::build(source, &Cancellation::default()).unwrap();
    let call = a
        .call_context(source.len(), &Cancellation::default())
        .unwrap()
        .unwrap();
    assert_eq!(call.method, "Méthode longue");
    assert_eq!(call.active_parameter, 2);
    assert_eq!(&source[call.open_paren.bytes], "(");
    let s = "Méthode( /* ; ) */ $1; \"inside";
    let a = Analysis::build(s, &Cancellation::default()).unwrap();
    assert_eq!(
        a.call_context(s.len(), &Cancellation::default())
            .unwrap()
            .unwrap()
            .active_parameter,
        1
    );
    let s = "Méthode(1; // prose";
    assert!(Analysis::build(s, &Cancellation::default())
        .unwrap()
        .call_context(s.len(), &Cancellation::default())
        .unwrap()
        .is_none());
}
#[test]
fn cancel_and_budgets_never_return_partial_results() {
    let c = Cancellation::default();
    c.cancel();
    assert!(matches!(
        Analysis::build("Function x()", &c),
        Err(Error::Cancelled)
    ));
    assert!(matches!(
        Analysis::build(&" ".repeat(MAX_SOURCE_BYTES + 1), &Cancellation::default()),
        Err(Error::Limit("source bytes"))
    ));
    let many = "Function x()\n".repeat(MAX_DEFINITIONS + 1);
    assert!(matches!(
        Analysis::build(&many, &Cancellation::default()),
        Err(Error::Limit("definitions"))
    ));
}
#[test]
fn comments_cannot_supply_signatures() {
    let a = Analysis::build(
        "/*\n#DECLARE($fake : Text)\n*/\n#DECLARE($real : cs.Kunde)",
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(a.signature.parameters[0].name, "$real");
}
#[test]
fn actual_swift_outputs_for_fifteen_synthetic_cases() {
    let rows: serde_json::Value =
        serde_json::from_slice(include_bytes!("fixtures/four-d-swift-reference.json")).unwrap();
    assert_eq!(rows.as_array().unwrap().len(), 15);
    for row in rows.as_array().unwrap() {
        let source = row["source"].as_str().unwrap();
        let a = Analysis::build(source, &Cancellation::default()).unwrap();
        let defs:Vec<_>=a.definitions.iter().map(|d|serde_json::json!({"name":d.name,"kind":match d.kind{Kind::Function=>"function",Kind::Getter=>"getter",Kind::Setter=>"setter",Kind::Query=>"query",Kind::OrderBy=>"orderBy",Kind::Constructor=>"constructor"},"line":d.span.line,"location":d.span.utf16.start,"length":d.span.utf16.end-d.span.utf16.start})).collect();
        assert_eq!(serde_json::json!(defs), row["definitions"], "{source}");
        let params: Vec<_> = a
            .signature
            .parameters
            .iter()
            .map(|p| serde_json::json!({"name":p.name,"type":p.type_name}))
            .collect();
        assert_eq!(serde_json::json!(params), row["parameters"], "{source}");
        assert_eq!(a.signature.header, row["header"].as_str().unwrap());
        assert_eq!(
            a.signature
                .returns
                .as_ref()
                .map(|p| serde_json::json!({"name":p.name,"type":p.type_name}))
                .unwrap_or(serde_json::Value::Null),
            row["returns"],
            "{source}"
        );
        let context=a.call_context(source.len(),&Cancellation::default()).unwrap().map(|c|serde_json::json!({"method":c.method,"parameter":c.active_parameter,"open":c.open_paren.utf16.start})).unwrap_or(serde_json::Value::Null);
        assert_eq!(context, row["call"], "{source}");
    }
}

#[test]
fn method_names_keep_canonical_unicode_equality() {
    assert_eq!(method_key("MÉTHODE"), method_key("Me\u{301}thode"));
}
#[test]
fn adversarial_header_names_parameters_and_call_nesting_are_bounded() {
    let c = Cancellation::default();
    let source = format!("{}Function x()", "shared ".repeat(100000));
    let started = std::time::Instant::now();
    assert_eq!(Analysis::build(&source, &c).unwrap().definitions.len(), 1);
    eprintln!(
        "4D_LONG_MODIFIERS bytes={} elapsed_ms={}",
        source.len(),
        started.elapsed().as_millis()
    );
    let name = format!("Function {}()", "a".repeat(1025));
    assert!(matches!(
        Analysis::build(&name, &c),
        Err(Error::Limit("definition name bytes"))
    ));
    let params = format!("#DECLARE({})", "$p : Text;".repeat(1025));
    assert!(matches!(
        Analysis::build(&params, &c),
        Err(Error::Limit("parameters"))
    ));
    let deep = format!("Method({}", "(".repeat(1025));
    let a = Analysis::build(&deep, &c).unwrap();
    assert!(matches!(
        a.call_context(deep.len(), &c),
        Err(Error::Limit("call nesting"))
    ));
}

#[test]
fn outline_profile_accepts_large_ordinary_sources_without_widening_other_tools() {
    let source = format!(
        "//{}\nFunction LargeSource()\n",
        "x".repeat(4 * 1024 * 1024)
    );
    let cancel = Cancellation::default();
    assert!(matches!(
        Analysis::build(&source, &cancel),
        Err(fastra_core::four_d::Error::Limit(_))
    ));
    let outline = Analysis::outline(&source, &cancel).unwrap();
    assert_eq!(outline.len(), 1);
    assert_eq!(outline[0].name, "LargeSource");
    assert_eq!(outline[0].span.line, 2);
    assert_eq!(
        &source[outline[0].span.bytes.clone()],
        "Function LargeSource"
    );
}
