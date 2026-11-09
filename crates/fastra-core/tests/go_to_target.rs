use fastra_core::{go_to_target::*, Cancellation, Error};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
fn range(value: Option<fastra_core::Utf16Range>) -> Value {
    value.map_or(Value::Null, |r| json!([r.location, r.length]))
}
fn notice(value: &Notice) -> &'static str {
    match value {
        Notice::Limit => "limit",
        Notice::MultipleFunctions(_) => "multiple-functions",
        Notice::MissingTarget(_) => "missing-target",
        Notice::MissingHeading(_) => "missing-heading",
        Notice::RelativeNeedsFile => "relative-needs-file",
        Notice::MissingFile(_) => "missing-file",
        Notice::InvalidAddress(_) => "invalid-address",
    }
}
#[test]
fn actual_foundation_provider_contracts() {
    let cases: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/swift-go-to-target.json")).unwrap();
    assert_eq!(cases.len(), 620);
    let files = [
        "Project/Sources/Methods/Ziel Methode.4dm",
        "Project/Sources/Classes/Kunde.4dm",
        "Sources/Classes/OtherClass.4dm",
        "docs/ziel.md",
        "docs/space#name.md",
        "docs/malformed%ZZ.md",
    ]
    .map(|s| Path::new("/fixture").join(s));
    let dirs = ["Project/Sources", "Sources"].map(|s| Path::new("/fixture").join(s));
    for case in cases {
        let input = &case["input"];
        let source = input["source"]
            .as_str()
            .unwrap()
            .replace("$ROOT", "/fixture");
        let offset = input["location"].as_u64().unwrap_or(0) as usize;
        let cancel = Cancellation::default();
        let expected = &case["expected"];
        let actual = match input["op"].as_str().unwrap() {
            "format" => format(input["name"].as_str().unwrap()).map_or(Value::Null, |f| {
                json!(if f == Format::FourD { "4d" } else { "md" })
            }),
            "phrase" => range(phrase(&source, offset, &cancel).unwrap()),
            "link" => link_target(&source, offset, &cancel)
                .unwrap()
                .map_or(Value::Null, |s| json!(s)),
            "heading" => {
                range(heading_range(&source, input["anchor"].as_str().unwrap(), &cancel).unwrap())
            }
            _ => {
                let document = input["document"]
                    .as_str()
                    .map(|s| Path::new("/fixture").join(s));
                let action = resolve(
                    Context {
                        source: &source,
                        location: offset,
                        format: if input["format"] == "4d" {
                            Format::FourD
                        } else {
                            Format::Markdown
                        },
                        document: document.as_deref(),
                        project: input["project"]
                            .as_bool()
                            .unwrap()
                            .then_some(Path::new("/fixture")),
                    },
                    |p| dirs.iter().any(|v| v == p),
                    |p| files.iter().find(|v| v == &p).cloned(),
                    &cancel,
                )
                .unwrap();
                match action {
                    None => Value::Null,
                    Some(Action::Jump(r)) => json!({"range":[r.location,r.length]}),
                    Some(Action::OpenFile(p)) => {
                        json!({"file":p.to_str().unwrap().replace("/fixture","$ROOT")})
                    }
                    // Foundation bewahrt zusätzlich die kanonische URI. Deren Plattformprüfung
                    // erfolgt an der nativen Grenze; hier bleibt das unveränderte Linkziel geprüft.
                    Some(Action::OpenUrl(s)) => {
                        assert_eq!(s, expected["literal"], "{input}");
                        expected.clone()
                    }
                    Some(Action::SearchProject(s)) => json!({"search":s}),
                    Some(Action::NotFound(reason)) => {
                        assert_eq!(notice(&reason), expected["issue"], "{input}");
                        let argument = match &reason {
                            Notice::MultipleFunctions(s)
                            | Notice::MissingTarget(s)
                            | Notice::MissingHeading(s)
                            | Notice::MissingFile(s)
                            | Notice::InvalidAddress(s) => Some(s.as_str()),
                            _ => None,
                        };
                        assert_eq!(argument, expected["argument"].as_str(), "{input}");
                        expected.clone()
                    }
                }
            }
        };
        assert_eq!(&actual, expected, "{input}");
    }
}
#[test]
fn cancellation_limits_and_path_decoding_are_explicit() {
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(phrase("name", 0, &cancel), Err(Error::Cancelled));
    assert_eq!(link_target("[x](#a)", 1, &cancel), Err(Error::Cancelled));
    assert_eq!(heading_range("# a", "a", &cancel), Err(Error::Cancelled));
    let huge = "x".repeat(10 * 1024 * 1024 + 1);
    assert_eq!(
        phrase(&huge, 0, &Cancellation::default()),
        Err(Error::Limit)
    );
    for target in ["a%FF.md", "a%ZZ.md", "a%.md"] {
        let source = format!("[x]({target})");
        let action = resolve(
            Context {
                source: &source,
                location: 1,
                format: Format::Markdown,
                document: Some(Path::new("/fixture/main.md")),
                project: None,
            },
            |_| false,
            |p| Some(p.to_path_buf()),
            &Cancellation::default(),
        )
        .unwrap();
        assert_eq!(
            action,
            Some(Action::OpenFile(PathBuf::from("/fixture").join(target)))
        );
    }
}
#[test]
fn long_keyword_prefixes_and_late_unicode_headings_complete_without_quadratic_prefix_scans() {
    let source = format!("{}Unknown()", "if ".repeat(10_000));
    assert_eq!(
        resolve(
            Context {
                source: &source,
                location: 0,
                format: Format::FourD,
                document: None,
                project: None
            },
            |_| false,
            |_| None,
            &Cancellation::default()
        )
        .unwrap(),
        Some(Action::NotFound(Notice::MissingTarget("Unknown".into())))
    );
    let source = format!(
        "{}## Letzter e\u{301}intrag🙂\r\n",
        "# ordinary 🙂\r\n".repeat(20_000)
    );
    let found = heading_range(&source, "letzter-e\u{301}intrag", &Cancellation::default())
        .unwrap()
        .unwrap();
    assert_eq!(
        found.location,
        "# ordinary 🙂\r\n".encode_utf16().count() * 20_000
    );
}
