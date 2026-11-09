use fastra_core::{
    four_d::{learned_suffixes, retokenize, transform_tokens, TokenTransform},
    Cancellation, Error, Limits,
};
fn roundtrip(original: &str) {
    let c = Cancellation::default();
    let limits = Limits::default();
    let learned = learned_suffixes(original, limits, &c).unwrap();
    let plain = transform_tokens(original, TokenTransform::Detokenize, limits, &c).unwrap();
    assert_eq!(retokenize(&plain, &learned, limits, &c).unwrap(), original);
}
#[test]
fn original_swift_macro_roundtrips() {
    for original in [
        "var $t : Text\nvar $d : Date\nvar $time : Time\n#DECLARE -> $result : Date\nALERT:C41(Char:C90(13))\nIf (Application type:C494=tool4d:K5:70)\nEnd if",
        "FutureCommand:C9998(1)\nIf (x=Futureconst:K91:2)\nEnd if",
        "If (x=Future:K91:1)\nIf (y=Future const:K91:2)\nEnd if",
        "If (x=Future Tail:K91:2)\nIf (y=Tail:K92:3)\nEnd if",
        "Date:C102\nTime:C179\nvar $date : Date\n#DECLARE($time : Time)",
    ]{roundtrip(original);}
}
#[test]
fn comments_strings_members_and_new_commands_follow_original_contract() {
    let c = Cancellation::default();
    let limits = Limits::default();
    let learned = learned_suffixes(
        "// ALERT:C9999\n\"Fake:K1:2\"\nFutureCommand:C9999()\nTime:C178()",
        limits,
        &c,
    )
    .unwrap();
    assert!(!learned.contains_key("alert"));
    assert!(!learned.contains_key("fake"));
    let source="$o. /* member comment */ Time()\n$o. /* unknown */ FutureCommand()\nTime()\nFutureCommand()\nALERT(\"FutureCommand:C1\")\n// Time()";
    assert_eq!(retokenize(source,&learned,limits,&c).unwrap(),"$o. /* member comment */ Time()\n$o. /* unknown */ FutureCommand()\nTime:C178()\nFutureCommand:C9999()\nALERT:C41(\"FutureCommand:C1\")\n// Time()");
}
#[test]
fn cancellation_limits_and_invalid_suffix_fail_without_partial_result() {
    let c = Cancellation::default();
    let learned = learned_suffixes("Future:C9999()", Limits::default(), &c).unwrap();
    c.cancel();
    assert!(matches!(
        retokenize("Future()", &learned, Limits::default(), &c),
        Err(Error::Cancelled)
    ));
    let c = Cancellation::default();
    assert!(matches!(
        retokenize(
            "ALERT",
            &Default::default(),
            Limits {
                max_output_bytes: 4,
                ..Default::default()
            },
            &c
        ),
        Err(Error::Limit)
    ));
    assert!(retokenize(
        "Future()",
        &[("future".into(), ":X12".into())].into(),
        Limits::default(),
        &c
    )
    .is_err());
}
