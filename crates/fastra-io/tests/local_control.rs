use fastra_core::{local_control::*, Cancellation};
use fastra_io::local_control::{self as io, transport};
use std::{
    fs,
    io::Write,
    os::unix::{
        fs::{symlink, PermissionsExt},
        net::UnixStream,
    },
    sync::atomic::AtomicBool,
    thread,
    time::{Duration, Instant},
};
fn root() -> tempfile::TempDir {
    let root = std::env::var_os("FASTRA_IO_TEST_ROOT").unwrap_or_else(|| "/tmp".into());
    tempfile::tempdir_in(root).unwrap()
}
fn request(path: &std::path::Path, bytes: &[u8]) -> Request {
    let mut r = Request::new("snapshot", io::uuid(), io::now());
    r.path = Some(path.to_str().unwrap().into());
    r.sha256 = Some(io::hash(bytes));
    r.location = Some(0);
    r.length = Some(0);
    r
}
#[test]
fn reads_regular_hardlinked_and_symlinked_sources_without_writes() {
    let dir = root();
    let path = dir.path().join("text");
    let raw = "A😀e\u{301}\r\n".as_bytes();
    fs::write(&path, raw).unwrap();
    let link = dir.path().join("link");
    symlink(&path, &link).unwrap();
    fs::hard_link(&path, dir.path().join("hard")).unwrap();
    let loaded = io::load(&request(&link, raw), &Cancellation::default()).unwrap();
    assert_eq!(loaded.text.as_ref(), "A😀e\u{301}\r\n");
    assert_eq!(loaded.byte_count, raw.len());
    assert_eq!(loaded.encoding, 4);
    assert_eq!(fs::read(path).unwrap(), raw);
}
#[test]
fn hash_limits_binary_devices_and_cancel_fail_without_partial_text() {
    let dir = root();
    let path = dir.path().join("text");
    fs::write(&path, b"abc").unwrap();
    let mut r = request(&path, b"wrong");
    assert_eq!(
        io::load(&r, &Cancellation::default()).unwrap_err().code,
        "stale"
    );
    r.sha256 = Some(io::hash(b"abc"));
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(io::load(&r, &cancel).is_err());
    fs::write(&path, vec![b'x'; MAX_SNAPSHOT + 1]).unwrap();
    assert!(io::load(&r, &Cancellation::default()).is_err());
    fs::write(&path, b"a\0b").unwrap();
    r.sha256 = Some(io::hash(b"a\0b"));
    assert!(io::load(&r, &Cancellation::default()).is_err());
    r.path = Some("/dev/zero".into());
    assert!(io::load(&r, &Cancellation::default()).is_err());
}
fn provenance(path: &std::path::Path) -> Provenance {
    Provenance {
        schema_version: 1,
        run_id: io::uuid(),
        kind: "archiveMaterialization".into(),
        hit_identity: HitIdentity {
            filesystem_path: path.to_str().unwrap().into(),
            archive_members: vec!["member".into()],
            archive_member_bytes: vec!["bWVtYmVy".into()],
        },
        source_generation: io::generation(&fs::metadata(path).unwrap()),
        archive_binding: "sha256".into(),
        outer_sha256: Some(io::hash(&fs::read(path).unwrap())),
        position_binding: "exactUTF16".into(),
        search_evidence: None,
    }
}
#[test]
fn owned_materialization_survives_sender_deletion_and_cleans_only_its_own_copy() {
    let dir = root();
    let outer = dir.path().join("outer");
    let materialized = dir.path().join("member");
    fs::write(&outer, b"archive").unwrap();
    fs::write(&materialized, b"frozen").unwrap();
    let mut r = request(&materialized, b"frozen");
    r.operation = "sourceSnapshot".into();
    r.provenance = Some(provenance(&outer));
    let a = io::Adopted::adopt(&r, dir.path(), &Cancellation::default()).unwrap();
    let copy = a.path();
    assert_eq!(
        fs::metadata(copy.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(&copy).unwrap().permissions().mode() & 0o777,
        0o400
    );
    fs::remove_file(materialized).unwrap();
    assert_eq!(fs::read(&copy).unwrap(), b"frozen");
    assert_eq!(a.loaded.text.as_ref(), "frozen");
    drop(a);
    assert!(!copy.exists());
    assert_eq!(fs::read(outer).unwrap(), b"archive");
}
#[test]
fn changed_outer_and_conflicting_bom_never_downgrade() {
    let dir = root();
    let outer = dir.path().join("outer");
    let leaf = dir.path().join("leaf");
    fs::write(&outer, b"archive").unwrap();
    fs::write(&leaf, [0xff, 0xfe, 65, 0]).unwrap();
    let mut r = request(&leaf, &[0xff, 0xfe, 65, 0]);
    r.operation = "sourceSnapshot".into();
    r.provenance = Some(provenance(&outer));
    r.text_encoding = Some("utf-8".into());
    assert!(io::Adopted::adopt(&r, dir.path(), &Cancellation::default()).is_err());
    r.text_encoding = Some("utf-16-le".into());
    let a = io::Adopted::adopt(&r, dir.path(), &Cancellation::default()).unwrap();
    assert_eq!(a.loaded.text.as_ref(), "A");
    assert_eq!(a.loaded.encoding, 0x94000100);
    drop(a);
    fs::write(&outer, b"new").unwrap();
    assert_eq!(
        io::Adopted::adopt(&r, dir.path(), &Cancellation::default())
            .err()
            .unwrap()
            .code,
        "stale"
    );
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 2);
}
#[test]
fn socket_fragmentation_single_owner_and_real_roundtrip() {
    let dir = root();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let path = dir.path().join("control.sock");
    let (server, rx) = transport::Server::start(&path).unwrap();
    assert!(transport::Server::start(&path).is_err());
    let worker = thread::spawn(move || {
        let d = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let r = Request::decode(&d.request).unwrap();
        assert_eq!(r.operation, "objects");
        d.reply.send(Reply::new(Some(io::uuid()))).unwrap();
    });
    let mut stream = UnixStream::connect(&path).unwrap();
    let raw = serde_json::to_vec(&Request::new("objects", io::uuid(), io::now())).unwrap();
    let framed = [(raw.len() as u32).to_be_bytes().as_slice(), raw.as_slice()].concat();
    for bytes in framed.chunks(3) {
        stream.write_all(bytes).unwrap();
    }
    let reply = transport::read_frame(
        &mut stream,
        MAX_REPLY,
        Instant::now() + Duration::from_secs(2),
        &AtomicBool::new(false),
    )
    .unwrap();
    assert!(serde_json::from_slice::<Reply>(&reply)
        .unwrap()
        .runtime_id
        .is_some());
    worker.join().unwrap();
    drop(server);
    assert!(!path.exists());
}
#[test]
fn frame_and_reply_budgets_are_enforced_before_partial_delivery() {
    let (mut a, mut b) = UnixStream::pair().unwrap();
    a.write_all(&((MAX_REQUEST + 1) as u32).to_be_bytes())
        .unwrap();
    assert_eq!(
        transport::read_frame(
            &mut b,
            MAX_REQUEST,
            Instant::now() + Duration::from_secs(1),
            &AtomicBool::new(false)
        )
        .unwrap_err()
        .code,
        "invalidRequest"
    );
    let mut reply = Reply::new(Some(io::uuid()));
    reply.error = Some(Failure {
        code: "test".into(),
        message: "x".repeat(MAX_REPLY),
        apple_script_number: 0,
    });
    let bytes = transport::encode_reply(&reply);
    let bounded: Reply = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(bounded.error.unwrap().code, "capacity");
    assert!(bounded.objects.is_none());
}
#[test]
fn slow_frame_honors_total_deadline_and_shutdown_is_prompt() {
    let (_a, mut b) = UnixStream::pair().unwrap();
    let start = Instant::now();
    assert!(transport::read_frame(
        &mut b,
        MAX_REQUEST,
        start + Duration::from_millis(75),
        &AtomicBool::new(false)
    )
    .is_err());
    assert!(start.elapsed() < Duration::from_secs(1));
}
#[test]
fn malformed_unowned_or_live_markers_are_never_deleted() {
    let dir = root();
    let alien = dir
        .path()
        .join(format!("FastraSourceSnapshot-v1-{}", io::uuid().as_str()));
    fs::create_dir(&alien).unwrap();
    fs::write(alien.join("foreign"), b"keep").unwrap();
    let id = io::uuid();
    let live = dir
        .path()
        .join(format!("FastraSourceSnapshot-v1-{}", id.as_str()));
    fs::create_dir(&live).unwrap();
    fs::write(
        live.join("owner.json"),
        serde_json::to_vec(
            &serde_json::json!({"schema":1,"ownerPID":std::process::id(),"identifier":id}),
        )
        .unwrap(),
    )
    .unwrap();
    let link = dir
        .path()
        .join(format!("FastraSourceSnapshot-v1-{}", io::uuid().as_str()));
    symlink(&alien, &link).unwrap();
    io::prune_abandoned(dir.path());
    assert!(alien.join("foreign").exists());
    assert!(live.exists());
    assert!(fs::symlink_metadata(link).unwrap().file_type().is_symlink());
}
#[test]
fn socket_untrusted_existing_files_are_preserved() {
    let dir = root();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let path = dir.path().join("control.sock");
    fs::write(&path, b"foreign").unwrap();
    assert!(transport::Server::start(&path).is_err());
    assert_eq!(fs::read(path).unwrap(), b"foreign");
}

#[test]
fn decoded_nul_is_refused_before_gtk_without_replacement_text_or_owned_copy() {
    let dir = root();
    let path = dir.path().join("nul");
    for raw in [b"A\0B".as_slice(), &[0xff, 0xfe, b'A', 0, 0, 0, b'B', 0]] {
        fs::write(&path, raw).unwrap();
        let mut r = request(&path, raw);
        if !raw.starts_with(&[0xff, 0xfe]) {
            r.operation = "sourceSnapshot".into();
            r.text_encoding = Some("utf-8".into());
        }
        let e = io::load(&r, &Cancellation::default()).unwrap_err();
        assert_eq!(e.code, "sourceUnavailable");
        if raw.starts_with(&[0xff, 0xfe]) {
            assert!(e.message.contains("U+0000"));
        }
        assert_eq!(fs::read(&path).unwrap(), raw);
    }
}
fn package_fixture(dir: &std::path::Path, count: usize, size: usize) -> std::path::PathBuf {
    let mut sources = Vec::new();
    let mut ids = Vec::new();
    for n in 0..count {
        let raw = vec![b'a'; size];
        let name = format!("source{n}.txt");
        fs::write(dir.join(&name), &raw).unwrap();
        let id = io::uuid();
        ids.push(id.clone());
        sources.push(
            serde_json::json!({"id":id,"path":name,"encoding":"utf8","sha256":io::hash(&raw)}),
        );
    }
    let path = dir.join("manifest.json");
    let value = serde_json::json!({"schemaVersion":1,"id":io::uuid(),"title":"Local","question":"Why?","language":"en","createdAt":"2026-11-05T12:00:00Z","projectID":io::uuid(),"projectName":"Fixture","sources":sources,"steps":[{"id":io::uuid(),"title":"One","text":"One","sourceID":ids[0],"location":0,"length":1},{"id":io::uuid(),"title":"Two","text":"Two","sourceID":ids[0],"location":1,"length":1}],"codeFontSize":12,"explanationFontSize":12});
    fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
    path
}
#[test]
fn explanation_detail_preserves_old_errors_and_exposes_correct_control_failures() {
    use fastra_io::code_explanation::{Error, Package};
    let dir = root();
    let path = package_fixture(dir.path(), 1, 10);
    let cancel = Cancellation::default();
    assert!(Package::load(&path, &cancel).is_ok());
    fs::write(dir.path().join("source0.txt"), b"different!").unwrap();
    assert!(matches!(Package::load(&path, &cancel), Err(Error::Changed)));
    assert!(matches!(
        Package::load_detailed(&path, &cancel),
        Err(Error::HashMismatch)
    ));
    assert_eq!(
        io::load_explanation(&path, &cancel).unwrap_err().code,
        "stale"
    );
    let path = package_fixture(dir.path(), 5, MAX_SNAPSHOT);
    assert!(matches!(Package::load(&path, &cancel), Err(Error::Limit)));
    assert!(matches!(
        Package::load_detailed(&path, &cancel),
        Err(Error::TotalLimit)
    ));
    assert_eq!(
        io::load_explanation(&path, &cancel).unwrap_err().code,
        "capacity"
    );
    let path = package_fixture(dir.path(), 1, MAX_SNAPSHOT + 1);
    assert_eq!(
        io::load_explanation(&path, &cancel).unwrap_err().code,
        "sourceUnavailable"
    );
    let path = package_fixture(dir.path(), 1, 10);
    let mut value: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    value["unexpected"] = true.into();
    fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
    assert_eq!(
        io::load_explanation(&path, &cancel).unwrap_err().code,
        "invalidRequest"
    );
}

#[test]
fn saturated_listener_connect_never_exceeds_total_deadline() {
    use std::os::fd::AsRawFd;
    let dir = root();
    let path = dir.path().join("busy.sock");
    let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
    assert_eq!(unsafe { libc::listen(listener.as_raw_fd(), 1) }, 0);
    let _a = UnixStream::connect(&path).unwrap();
    let _b = UnixStream::connect(&path).unwrap();
    let started = Instant::now();
    assert!(transport::request(&path, b"{}", started + Duration::from_millis(75)).is_err());
    assert!(started.elapsed() < Duration::from_secs(1));
}
#[test]
fn dead_owned_marker_is_removed_while_invalid_identity_is_preserved() {
    let dir = root();
    let id = io::uuid();
    let dead = dir
        .path()
        .join(format!("FastraSourceSnapshot-v1-{}", id.as_str()));
    fs::create_dir(&dead).unwrap();
    let marker = serde_json::json!({"schema":1,"ownerPID":i32::MAX,"identifier":id});
    fs::write(
        dead.join("owner.json"),
        serde_json::to_vec(&marker).unwrap(),
    )
    .unwrap();
    let other = dir
        .path()
        .join(format!("FastraSourceSnapshot-v1-{}", io::uuid().as_str()));
    fs::create_dir(&other).unwrap();
    fs::write(
        other.join("owner.json"),
        serde_json::to_vec(&marker).unwrap(),
    )
    .unwrap();
    io::prune_abandoned(dir.path());
    assert!(!dead.exists());
    assert!(other.exists());
}
#[test]
fn strong_outer_limit_never_falls_back_but_explicit_generation_mode_remains_available() {
    let dir = root();
    let outer = dir.path().join("large-outer");
    fs::File::create(&outer)
        .unwrap()
        .set_len((MAX_OUTER + 1) as u64)
        .unwrap();
    let leaf = dir.path().join("leaf");
    fs::write(&leaf, b"abc").unwrap();
    let mut r = request(&leaf, b"abc");
    r.operation = "sourceSnapshot".into();
    let mut p = Provenance {
        schema_version: 1,
        run_id: io::uuid(),
        kind: "archiveMaterialization".into(),
        hit_identity: HitIdentity {
            filesystem_path: outer.to_str().unwrap().into(),
            archive_members: vec!["member".into()],
            archive_member_bytes: vec!["bWVtYmVy".into()],
        },
        source_generation: io::generation(&fs::metadata(&outer).unwrap()),
        archive_binding: "sha256".into(),
        outer_sha256: Some("a".repeat(64)),
        position_binding: "exactUTF16".into(),
        search_evidence: None,
    };
    r.provenance = Some(p.clone());
    assert_eq!(
        io::Adopted::adopt(&r, dir.path(), &Cancellation::default())
            .err()
            .unwrap()
            .code,
        "sourceUnavailable"
    );
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 2);
    p.archive_binding = "generation".into();
    p.outer_sha256 = None;
    r.provenance = Some(p);
    let adopted = io::Adopted::adopt(&r, dir.path(), &Cancellation::default()).unwrap();
    assert_eq!(adopted.loaded.text.as_ref(), "abc");
    drop(adopted);
    let cancel = Cancellation::default();
    cancel.cancel();
    assert!(io::Adopted::adopt(&r, dir.path(), &cancel).is_err());
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 2);
}
