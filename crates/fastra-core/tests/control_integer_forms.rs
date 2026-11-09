use fastra_core::{code_explanation::Manifest, local_control::*};
fn request(version: &str, location: &str, length: &str) -> String {
    format!(
        r#"{{"version":{version},"id":"11111111-1111-4111-8111-111111111111","deadline":110,"operation":"snapshot","path":"/source","sha256":"{}","location":{location},"length":{length}}}"#,
        "a".repeat(64)
    )
}
#[test]
fn complete_requests_accept_integral_decimal_and_exponent_forms() {
    for (v, l, n) in [
        ("1.0", "10e-1", "0.0"),
        ("1e0", "1.00", "-0e0"),
        (
            "1",
            "1000000000000000000000000000000000000000e-37",
            "0e999999",
        ),
    ] {
        let r = Request::decode(request(v, l, n).as_bytes()).unwrap();
        assert_eq!(r.version, 1);
        assert!(r.validate(100., false).is_ok());
        assert_eq!(r.length, Some(0));
    }
    let r = Request::decode(request("1", "9007199254740993.0", "0").as_bytes()).unwrap();
    assert_eq!(r.location, Some(9_007_199_254_740_993));
}
#[test]
fn large_supported_int64_protocol_versions_reach_unsupported() {
    for raw in [
        "4294967296",
        "4294967296.0",
        "4.294967296e9",
        "9223372036854775807",
        "-9223372036854775808",
    ] {
        let r = Request::decode(request(raw, "0", "0").as_bytes()).unwrap();
        assert_eq!(
            r.validate(100., false).unwrap_err().code,
            "unsupported",
            "{raw}"
        );
    }
    for raw in [
        "9223372036854775808",
        "9223372036854775807.0",
        "-9223372036854775808.0",
        "1.1",
        "true",
        "\"1\"",
    ] {
        assert_eq!(
            Request::decode(request(raw, "0", "0").as_bytes())
                .unwrap_err()
                .code,
            "invalidRequest",
            "{raw}"
        );
    }
}
fn provenance() -> String {
    r#"{"schemaVersion":1.0,"runID":"22222222-2222-4222-8222-222222222222","kind":"original","hitIdentity":{"filesystemPath":"/source","archiveMembers":[],"archiveMemberBytes":[]},"sourceGeneration":{"device":9007199254740993.0,"inode":18446744073709550591.0,"size":0e999999,"modificationSeconds":-9223372036854775807.0,"modificationNanoseconds":10e-1,"changeSeconds":0.0,"changeNanoseconds":0e0},"archiveBinding":"notApplicable","positionBinding":"exactUTF16"}"#.into()
}
#[test]
fn provenance_preserves_u64_and_signed_generation_without_float_rounding() {
    let raw = provenance();
    let p: Provenance = serde_json::from_str(&raw).unwrap();
    assert_eq!(p.schema_version, 1);
    assert_eq!(p.hit_identity.filesystem_path, "/source");
    assert_eq!(p.source_generation.device, 9_007_199_254_740_993);
    assert_eq!(p.source_generation.inode, 18_446_744_073_709_550_591);
    assert_eq!(
        p.source_generation.modification_seconds,
        -9_223_372_036_854_775_807
    );
    assert_eq!(p.source_generation.size, 0);
    assert!(p
        .validate(
            "/source",
            &Selection {
                location: 0,
                length: 0
            }
        )
        .is_ok());
    let p: Provenance =
        serde_json::from_str(&raw.replace("18446744073709550591.0", "18446744073709551615"))
            .unwrap();
    assert_eq!(p.source_generation.inode, u64::MAX);
    assert!(serde_json::from_str::<Provenance>(
        &raw.replace("18446744073709550591.0", "18446744073709551615.0")
    )
    .is_err());
    let p: Provenance = serde_json::from_str(
        &raw.replace("\"schemaVersion\":1.0", "\"schemaVersion\":4294967296.0"),
    )
    .unwrap();
    assert_eq!(p.schema_version, 4_294_967_296);
    assert!(p
        .validate(
            "/source",
            &Selection {
                location: 0,
                length: 0
            }
        )
        .is_err());
}
#[test]
fn null_unknown_and_duplicate_protection_survives_removal_of_value_prepass() {
    let empty = r#"{"version":1.0,"id":"11111111-1111-4111-8111-111111111111","deadline":110,"operation":"objects"}"#;
    for key in [
        "runtimeID",
        "path",
        "sha256",
        "location",
        "length",
        "sessionID",
        "documentID",
        "jobID",
        "provenance",
        "textEncoding",
    ] {
        let json = empty.replacen('{', &format!("{{\"{key}\":null,"), 1);
        assert!(Request::decode(json.as_bytes()).is_err(), "{key}");
    }
    assert!(Request::decode(
        empty
            .replace("\"version\":1.0", "\"version\":1.0,\"version\":1e0")
            .as_bytes()
    )
    .is_err());
    assert!(Request::decode(
        empty
            .replace("\"version\":1.0", "\"version\":1.0,\"unknown\":1")
            .as_bytes()
    )
    .is_err());
    let p = provenance();
    for key in ["outerSHA256", "searchEvidence"] {
        let json = p.replacen('{', &format!("{{\"{key}\":null,"), 1);
        assert!(serde_json::from_str::<Provenance>(&json).is_err(), "{key}");
    }
    for bad in [
        p.replace("\"device\":9007199254740993.0", "\"device\":null"),
        p.replace(
            "\"device\":9007199254740993.0",
            "\"device\":1.0,\"device\":1e0",
        ),
        p.replace(
            "\"device\":9007199254740993.0",
            "\"device\":1,\"unknown\":1",
        ),
    ] {
        assert!(serde_json::from_str::<Provenance>(&bad).is_err());
    }
}
fn manifest(schema: &str, location: &str) -> String {
    format!(
        r#"{{"schemaVersion":{schema},"id":"11111111-1111-4111-8111-111111111111","title":"Numbers","question":"Why?","language":"en","createdAt":"2026-11-05T12:00:00Z","projectID":"22222222-2222-4222-8222-222222222222","projectName":"Fixture","sources":[{{"id":"33333333-3333-4333-8333-333333333333","path":"source.txt","sha256":"{}","encoding":"utf8"}}],"steps":[{{"id":"44444444-4444-4444-8444-444444444444","title":"One","text":"One","sourceID":"33333333-3333-4333-8333-333333333333","location":{location},"length":0.0}},{{"id":"55555555-5555-4555-8555-555555555555","title":"Two","text":"Two","sourceID":"33333333-3333-4333-8333-333333333333","location":10e-1,"length":0e0}}],"codeFontSize":12,"explanationFontSize":12}}"#,
        "a".repeat(64)
    )
}
#[test]
fn saved_explanation_schema_and_step_coordinates_share_the_exact_helper() {
    let m: Manifest = serde_json::from_str(&manifest("1e0", "9007199254740993.0")).unwrap();
    assert_eq!(m.schema_version, 1);
    assert_eq!(m.steps[0].location, 9_007_199_254_740_993);
    assert_eq!(m.steps[1].location, 1);
    assert_eq!(m.steps[0].length, 0);
    let m: Manifest = serde_json::from_str(&manifest("4294967296.0", "0")).unwrap();
    assert_eq!(m.schema_version, 4_294_967_296);
    for raw in [
        "1.1",
        "true",
        "9223372036854775808",
        "9223372036854775807.0",
    ] {
        assert!(
            serde_json::from_str::<Manifest>(&manifest("1", raw)).is_err(),
            "{raw}"
        );
    }
}

#[test]
fn equivalent_integer_spellings_replay_the_original_accepted_job() {
    let original = Request::decode(request("1.0", "10e-1", "0.0").as_bytes()).unwrap();
    let repeated = Request::decode(request("1e0", "1.00", "-0e0").as_bytes()).unwrap();
    let id = |n| UUID::parse(&format!("22222222-2222-4222-8222-{n:012X}")).unwrap();
    let mut state = State::new(id(1));
    let job = Job::new(id(2), &original, id(3), id(4), id(5));
    state.insert(job.clone(), 100.).unwrap();
    let mut reply = Reply::new(Some(id(1)));
    reply.job = Some(job.clone());
    state.record(&original, &reply, 100.);
    let replay = state.prepare(&repeated, 120.).unwrap().unwrap();
    assert_eq!(replay.job.unwrap().id, job.id);
}
