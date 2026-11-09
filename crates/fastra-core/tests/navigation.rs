use fastra_core::{
    navigation::{self, Position},
    Cancellation, Error,
};
use serde::Deserialize;
#[derive(Deserialize)]
struct Parse {
    input: String,
    line: Option<usize>,
    column: Option<usize>,
}
#[derive(Deserialize)]
struct Jump {
    text: String,
    line: usize,
    column: Option<usize>,
    offset: usize,
}
#[derive(Deserialize)]
struct Reference {
    parses: Vec<Parse>,
    jumps: Vec<Jump>,
}
#[test]
fn unchanged_swift_parser_and_392_cursor_positions() {
    let reference: Reference =
        serde_json::from_str(include_str!("fixtures/swift-navigation.json")).unwrap();
    assert_eq!(reference.parses.len(), 24);
    assert_eq!(reference.jumps.len(), 392);
    for case in reference.parses {
        assert_eq!(
            navigation::parse(&case.input),
            case.line.map(|line| Position {
                line,
                column: case.column
            }),
            "{:?}",
            case.input
        );
    }
    let mut rounded = 0;
    for case in reference.jumps {
        let actual = navigation::destination(
            &case.text,
            Position {
                line: case.line,
                column: case.column,
            },
            &Cancellation::default(),
        )
        .unwrap();
        let units: Vec<_> = case.text.encode_utf16().collect();
        let split = case.offset > 0
            && case.offset < units.len()
            && (0xd800..=0xdbff).contains(&units[case.offset - 1])
            && (0xdc00..=0xdfff).contains(&units[case.offset]);
        let expected = case.offset - usize::from(split);
        rounded += usize::from(split);
        assert_eq!(
            actual.utf16_offset, expected,
            "{:?} {} {:?}",
            case.text, case.line, case.column
        );
        assert_eq!(actual.rounded_to_scalar, split);
        assert_eq!(
            case.text
                .chars()
                .take(actual.character_offset)
                .map(char::len_utf16)
                .sum::<usize>(),
            actual.utf16_offset
        );
    }
    assert!(rounded > 0);
}
#[test]
fn huge_positions_are_bounded_and_cancellation_never_returns_a_partial_jump() {
    let source = "a\r\n🙂tail\u{2028}last";
    let end = navigation::destination(
        source,
        Position {
            line: usize::MAX,
            column: Some(usize::MAX),
        },
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(end.utf16_offset, source.encode_utf16().count());
    assert_eq!(end.character_offset, source.chars().count());
    let line = navigation::destination(
        source,
        Position {
            line: 2,
            column: Some(usize::MAX),
        },
        &Cancellation::default(),
    )
    .unwrap();
    assert_eq!(line.utf16_offset, 9);
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(
        navigation::destination(
            source,
            Position {
                line: 1,
                column: None
            },
            &cancel
        ),
        Err(Error::Cancelled)
    );
    assert!(navigation::parse(&" ".repeat(257)).is_none());
}
