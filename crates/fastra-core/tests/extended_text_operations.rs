use fastra_core::{
    text_operations::{self, CharacterOperation as C, IndentOptions, LineOperation as L},
    Cancellation, Error, Limits, Utf16Range,
};
use serde::Deserialize;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Vector {
    name: String,
    kind: String,
    text: String,
    selection: [usize; 2],
    tab_width: usize,
    indent_width: usize,
    uses_tabs: bool,
    wrap_column: usize,
    expected: Option<String>,
    affected_range: Option<[usize; 2]>,
    line_count: Option<usize>,
}
#[test]
fn exact_original_swift_vectors() {
    let cases: Vec<Vector> =
        serde_json::from_slice(include_bytes!("fixtures/swift-extended-text.json")).unwrap();
    assert_eq!(cases.len(), 203);
    for v in cases {
        let selection = Utf16Range {
            location: v.selection[0],
            length: v.selection[1],
        };
        let profile = IndentOptions {
            uses_tabs: v.uses_tabs,
            indent_width: v.indent_width,
            tab_width: v.tab_width,
        };
        let line = match v.kind.as_str() {
            "detab" => Some(L::Detab {
                tab_width: v.tab_width,
            }),
            "entab" => Some(L::Entab {
                tab_width: v.tab_width,
            }),
            "shiftRight" => Some(L::ShiftRight(profile)),
            "shiftLeft" => Some(L::ShiftLeft(profile)),
            "hardWrap" => Some(L::HardWrap {
                column: v.wrap_column,
            }),
            _ => None,
        };
        let cancel = Cancellation::default();
        let result = if let Some(line) = line {
            text_operations::transform_lines(&v.text, selection, &line, Limits::default(), &cancel)
        } else {
            let op = match v.kind.as_str() {
                "straightenQuotes" => C::StraightenQuotes,
                "educateQuotes" => C::EducateQuotes,
                "convertEscapeSequences" => C::ConvertEscapes,
                "exchangeCharacters" => C::ExchangeCharacters,
                "exchangeWords" => C::ExchangeWords,
                "stripDiacriticals" => C::StripDiacriticals,
                "addEmojiPresentation" => C::AddEmojiPresentation,
                "removeEmojiPresentation" => C::RemoveEmojiPresentation,
                _ => panic!("{}", v.kind),
            };
            text_operations::transform_characters(
                &v.text,
                selection,
                op,
                Limits::default(),
                &cancel,
            )
        }
        .unwrap_or_else(|error| panic!("{} {:?}: {error:?}", v.name, v.text));
        assert_eq!(
            result.as_ref().map(|r| r.text.as_str()),
            v.expected.as_deref(),
            "{} {:?} {:?}",
            v.name,
            v.text,
            v.selection
        );
        assert_eq!(
            result
                .as_ref()
                .map(|r| [r.affected_range.location, r.affected_range.length]),
            v.affected_range,
            "{}",
            v.name
        );
        assert_eq!(
            result.as_ref().map(|r| r.line_count),
            v.line_count,
            "{}",
            v.name
        );
    }
}
#[test]
fn bounded_growth_and_cancel_no_partial_output() {
    let cancel = Cancellation::default();
    let tiny = Limits {
        max_output_bytes: 8,
        ..Limits::default()
    };
    let zero = Utf16Range {
        location: 0,
        length: 0,
    };
    assert_eq!(
        text_operations::transform_lines(
            "\t\t\t",
            zero,
            &L::Detab { tab_width: 16 },
            tiny,
            &cancel
        )
        .unwrap_err(),
        Error::Limit
    );
    assert_eq!(
        text_operations::transform_characters("▶▶▶", zero, C::AddEmojiPresentation, tiny, &cancel)
            .unwrap_err(),
        Error::Limit
    );
    let lines = Limits {
        max_matches: 3,
        ..Limits::default()
    };
    assert_eq!(
        text_operations::transform_lines(
            "a b c d e",
            zero,
            &L::HardWrap { column: 1 },
            lines,
            &cancel
        )
        .unwrap_err(),
        Error::Limit
    );
    cancel.cancel();
    assert_eq!(
        text_operations::transform_characters(
            "x",
            zero,
            C::ConvertEscapes,
            Limits::default(),
            &cancel
        )
        .unwrap_err(),
        Error::Cancelled
    );
    assert_eq!(
        text_operations::transform_lines(
            "x",
            zero,
            &L::Entab { tab_width: 4 },
            Limits::default(),
            &cancel
        )
        .unwrap_err(),
        Error::Cancelled
    );
}
#[test]
fn invalid_utf8_percent_runs_stay_linear_and_keep_swift_suffix_rule() {
    let source = "%FF".repeat(300_000) + "%41";
    let cancel = Cancellation::default();
    let result = text_operations::transform_characters(
        &source,
        Utf16Range {
            location: 0,
            length: 0,
        },
        C::ConvertEscapes,
        Limits::default(),
        &cancel,
    )
    .unwrap()
    .unwrap();
    assert_eq!(result.text, "%FF".repeat(300_000) + "A");
}
