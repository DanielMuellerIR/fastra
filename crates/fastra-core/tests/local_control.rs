use fastra_core::{local_control::*, Cancellation};
fn id(n: usize) -> UUID {
    UUID::parse(&format!("00000000-0000-4000-8000-{n:012X}")).unwrap()
}
fn request(op: &str, n: usize) -> Request {
    Request::new(op, id(n), 100.)
}
fn snapshot(n: usize) -> Request {
    let mut r = request("snapshot", n);
    r.path = Some("/source".into());
    r.sha256 = Some("a".repeat(64));
    r.location = Some(0);
    r.length = Some(0);
    r
}
#[test]
fn exact_operation_fields_and_deadline_boundaries() {
    for op in OPERATIONS {
        let mut r = request(op, 1);
        match op {
            "snapshot" => r = snapshot(1),
            "sourceSnapshot" => continue,
            "explanation" => r.path = Some("/manifest".into()),
            "navigate" => {
                r.session_id = Some(id(2));
                r.document_id = Some(id(3));
                r.sha256 = Some("f".repeat(64));
                r.location = Some(0);
                r.length = Some(0)
            }
            "status" | "cancel" => r.job_id = Some(id(2)),
            "close" => r.session_id = Some(id(2)),
            _ => {}
        }
        assert!(r.validate(100., false).is_ok(), "{op}");
        r.provenance = None;
        r.text_encoding = Some("utf-8".into());
        assert_eq!(r.validate(100., false).unwrap_err().code, "invalidRequest");
    }
    let mut r = snapshot(1);
    r.deadline = 100.;
    assert_eq!(r.validate(100., false).unwrap_err().code, "expired");
    assert!(r.validate(100., true).is_ok());
    r.deadline = 111.;
    assert!(r.validate(100., false).is_ok());
    r.deadline = 111.001;
    assert!(r.validate(100., true).is_err());
}
#[test]
fn null_unknown_duplicate_and_overflow_are_rejected() {
    let raw = serde_json::to_vec(&request("objects", 1)).unwrap();
    assert!(Request::decode(&raw).is_ok());
    let mut v: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    v["runtimeID"] = serde_json::Value::Null;
    assert!(Request::decode(&serde_json::to_vec(&v).unwrap()).is_err());
    v.as_object_mut().unwrap().remove("runtimeID");
    v["other"] = true.into();
    assert!(Request::decode(&serde_json::to_vec(&v).unwrap()).is_err());
    let text = String::from_utf8(raw)
        .unwrap()
        .replace("\"version\":1", "\"version\":1,\"version\":1");
    assert!(Request::decode(text.as_bytes()).is_err());
    let mut r = snapshot(1);
    r.location = Some(i64::MAX);
    r.length = Some(1);
    assert_eq!(r.validate(100., false).unwrap_err().code, "invalidRange");
    assert!(Request::decode(&vec![b' '; MAX_REQUEST + 1]).is_err());
}
#[test]
fn actual_unicode_utf16_ranges_include_eof_and_reject_split_characters() {
    let text = "A😀e\u{301}\r\n👩‍👩‍👧‍👦Z";
    let cancel = Cancellation::default();
    for (location, length) in [(0, 0), (1, 2), (3, 2), (5, 2), (7, 11), (19, 0)] {
        assert!(
            Selection { location, length }
                .validate(text, &cancel)
                .is_ok(),
            "{location}/{length}"
        )
    }
    for (location, length) in [(2, 0), (4, 0), (6, 0), (8, 0), (20, 0), (0, 2)] {
        assert!(
            Selection { location, length }
                .validate(text, &cancel)
                .is_err(),
            "{location}/{length}"
        )
    }
    cancel.cancel();
    assert!(Selection {
        location: 0,
        length: 0
    }
    .validate(text, &cancel)
    .is_err());
}
#[test]
fn replay_is_structural_expired_safe_and_runtime_bound() {
    let mut state = State::new(id(1));
    let r = snapshot(2);
    assert!(state.prepare(&r, 100.).unwrap().is_none());
    let j = Job::new(id(3), &r, id(4), id(5), id(6));
    state.insert(j.clone(), 100.).unwrap();
    let mut reply = Reply::new(Some(id(1)));
    reply.job = Some(j);
    state.record(&r, &reply, 100.);
    state.jobs.get_mut(&id(3)).unwrap().state = "ready".into();
    assert_eq!(
        state.prepare(&r, 120.).unwrap().unwrap().job.unwrap().state,
        "ready"
    );
    let mut changed = r.clone();
    changed.deadline += 1.;
    assert_eq!(
        state.prepare(&changed, 120.).unwrap_err().code,
        "invalidRequest"
    );
    let mut foreign = r.clone();
    foreign.runtime_id = Some(id(99));
    assert_eq!(state.prepare(&foreign, 120.).unwrap_err().code, "invalidID");
    assert_eq!(
        state.prepare(&snapshot(8), 120.).unwrap_err().code,
        "expired"
    );
    assert!(state.prepare(&r, 401.).is_err());
}
#[test]
fn capacity_never_evicts_work_but_cleanup_keeps_working() {
    let mut state = State::new(id(1));
    for n in 0..MAX_JOBS * 2 {
        let r = snapshot(n + 10);
        assert!(state.prepare(&r, 100.).is_ok());
        state.record(&r, &Reply::new(Some(id(1))), 100.);
    }
    assert_eq!(
        state.prepare(&snapshot(9999), 100.).unwrap_err().code,
        "capacity"
    );
    let mut cleanup = request("close", 10000);
    cleanup.session_id = Some(id(5));
    assert!(state.prepare(&cleanup, 100.).unwrap().is_none());
    for n in 0..300 {
        cleanup.id = id(10000 + n);
        state.record(&cleanup, &Reply::new(Some(id(1))), 100. + n as f64 / 1000.);
    }
    assert!(state.prepare(&snapshot(10), 120.).unwrap().is_some());
}
#[test]
fn jobs_timeout_cancel_and_retention_have_distinct_meaning() {
    let mut state = State::new(id(1));
    let r = snapshot(2);
    state
        .insert(Job::new(id(3), &r, id(4), id(5), id(6)), 100.)
        .unwrap();
    state.cancel(&id(3)).unwrap();
    state.prune(131.);
    assert_eq!(state.jobs[&id(3)].state, "cancelled");
    state
        .insert(Job::new(id(7), &r, id(4), id(5), id(6)), 100.)
        .unwrap();
    state.prune(130.);
    assert_eq!(state.jobs[&id(7)].error.as_ref().unwrap().code, "expired");
    state.prune(400.);
    assert!(state.jobs.is_empty());
}
fn provenance() -> Provenance {
    Provenance {
        schema_version: 1,
        run_id: id(1),
        kind: "archiveMaterialization".into(),
        hit_identity: HitIdentity {
            filesystem_path: "/outer.zip".into(),
            archive_members: vec!["é.txt".into()],
            archive_member_bytes: vec!["w6kudHh0".into()],
        },
        source_generation: SourceGeneration {
            device: 1,
            inode: 2,
            size: 3,
            modification_seconds: 4,
            modification_nanoseconds: 5,
            change_seconds: 6,
            change_nanoseconds: 7,
        },
        archive_binding: "generation".into(),
        outer_sha256: None,
        position_binding: "unboundHit".into(),
        search_evidence: Some("hit".into()),
    }
}
#[test]
fn provenance_preserves_byte_identity_and_weak_binding_is_explicit() {
    let s = Selection {
        location: 0,
        length: 0,
    };
    let mut p = provenance();
    assert!(p.validate("/materialized", &s).is_ok());
    p.hit_identity.archive_members[0] = "e\u{301}.txt".into();
    assert!(p.validate("/materialized", &s).is_err());
    p.hit_identity.archive_member_bytes[0] = "/y50eHQ=".into();
    assert!(p.validate("/materialized", &s).is_ok());
    p.hit_identity.archive_member_bytes[0] = "/y50eHR=".into();
    assert!(p.validate("/materialized", &s).is_err());
    p = provenance();
    p.outer_sha256 = Some("a".repeat(64));
    assert!(p.validate("/materialized", &s).is_err());
    p.archive_binding = "sha256".into();
    assert!(p.validate("/materialized", &s).is_ok());
    assert!(p
        .validate(
            "/materialized",
            &Selection {
                location: 1,
                length: 0
            }
        )
        .is_err());
}
#[test]
fn capabilities_and_failures_keep_wire_compatibility() {
    let c = serde_json::to_value(Capabilities::default()).unwrap();
    assert_eq!(c["maximumSessions"], 16);
    assert!(c.get("runtimeID").is_none());
    assert_eq!(c["operations"].as_array().unwrap().len(), 9);
    let f = serde_json::to_value(Failure::new("invalidID")).unwrap();
    assert_eq!(f["appleScriptNumber"], -1728);
}

#[test]
fn replay_uses_swift_canonical_string_equality_without_normalizing_source_paths() {
    let mut state = State::new(id(1));
    let mut original = snapshot(2);
    original.path = Some("/café".into());
    state.record(&original, &Reply::new(Some(id(1))), 100.);
    let mut repeated = original.clone();
    repeated.path = Some("/cafe\u{301}".into());
    assert!(state.prepare(&repeated, 120.).unwrap().is_some());
    assert_ne!(original.path, repeated.path);
}
#[test]
fn all_retained_jobs_count_toward_capacity_even_when_terminal() {
    let mut state = State::new(id(1));
    let r = snapshot(2);
    for n in 0..MAX_JOBS {
        let mut j = Job::new(id(100 + n), &r, id(4), id(5), id(6));
        j.state = "ready".into();
        state.insert(j, 100.).unwrap();
    }
    assert_eq!(
        state
            .insert(Job::new(id(999), &r, id(4), id(5), id(6)), 100.)
            .unwrap_err()
            .code,
        "capacity"
    );
    state.prune(400.);
    assert!(state
        .insert(Job::new(id(999), &r, id(4), id(5), id(6)), 400.)
        .is_ok());
}
