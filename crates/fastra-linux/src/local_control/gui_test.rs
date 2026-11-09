//! Echte CLI-Prozesse, Unixsocket und GTK-Ansichten auf isoliertem Display.
use super::*;
use serde_json::json;
use std::{
    fs,
    io::Write,
    process::{Command, Stdio},
};
enum Action {
    Inspect(UUID, String, Selection, &'static str, mpsc::SyncSender<()>),
    Next(UUID),
    Return(UUID),
    Explore(UUID),
    KeyInterrupt(UUID),
    ReassertSelection(UUID, mpsc::SyncSender<()>),
    ExploreProvenance(UUID),
    Visibility(UUID, bool, mpsc::SyncSender<()>),
    Paused(UUID, mpsc::SyncSender<()>),
    NulFailure(UUID, mpsc::SyncSender<()>),
    OpenUi(PathBuf, mpsc::SyncSender<UUID>),
    ExpiredCompletion(fastra_io::code_explanation::Package, mpsc::SyncSender<()>),
    Done,
}
fn cli(r: &Request) -> Reply {
    let binary = std::env::var_os("FASTRA_CONTROL_BINARY").expect("private CLI");
    let mut child = Command::new(binary)
        .args(["--no-launch", "--request", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(&serde_json::to_vec(r).unwrap())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    let reply: Reply = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(out.status.success(), reply.error.is_none());
    reply
}
fn fresh(op: &str) -> Request {
    Request::new(op, io::uuid(), io::now())
}
fn terminal(id: &UUID) -> Job {
    let started = Instant::now();
    loop {
        let mut r = fresh("status");
        r.job_id = Some(id.clone());
        let reply = cli(&r);
        assert!(reply.error.is_none(), "status {:?}", reply.error);
        let job = reply.job.unwrap();
        if job.terminal() {
            return job;
        }
        assert!(started.elapsed() < Duration::from_secs(12));
        std::thread::sleep(Duration::from_millis(20));
    }
}
fn ready(id: &UUID) -> Job {
    let job = terminal(id);
    assert_eq!(job.state, "ready", "{:?}", job.error);
    job
}
fn visibility(tx: &mpsc::Sender<Action>, id: &UUID, visible: bool) {
    let (done, rx) = mpsc::sync_channel(1);
    tx.send(Action::Visibility(id.clone(), visible, done))
        .unwrap();
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
}
fn snapshot(path: &Path, raw: &[u8]) -> Request {
    let mut r = fresh("snapshot");
    r.path = Some(path.to_str().unwrap().into());
    r.sha256 = Some(io::hash(raw));
    r.location = Some(1);
    r.length = Some(2);
    r
}
fn inspect(
    tx: &mpsc::Sender<Action>,
    j: &Job,
    text: &str,
    selection: Selection,
    name: &'static str,
) {
    let (done, rx) = mpsc::sync_channel(1);
    tx.send(Action::Inspect(
        j.session_id.clone(),
        text.into(),
        selection,
        name,
        done,
    ))
    .unwrap();
    rx.recv_timeout(Duration::from_secs(5)).unwrap();
}
fn close(id: &UUID) {
    let mut r = fresh("close");
    r.session_id = Some(id.clone());
    assert!(cli(&r).error.is_none());
}
fn worker(root: PathBuf, tx: mpsc::Sender<Action>) {
    let caps = cli(&fresh("capabilities"));
    let runtime = caps.runtime_id.clone().unwrap();
    assert_eq!(caps.capabilities.unwrap().maximum_sessions, 16);
    let inventory = cli(&fresh("objects"));
    assert!(inventory
        .objects
        .unwrap()
        .iter()
        .any(|o| o.kind == "document" && o.session_id.is_none()));
    let raw = "A😀e\u{301}\r\nZ".as_bytes();
    let path = root.join("snapshot.txt");
    fs::write(&path, raw).unwrap();
    let mut r = snapshot(&path, raw);
    r.deadline = io::now() + 1.;
    let accepted = cli(&r).job.unwrap();
    let j = ready(&accepted.id);
    assert_eq!(j.encoding, Some(4));
    assert_eq!(j.byte_count, Some(raw.len()));
    assert_eq!(j.sha256.as_deref(), Some(io::hash(raw).as_str()));
    inspect(
        &tx,
        &j,
        std::str::from_utf8(raw).unwrap(),
        r.selection(),
        "control-snapshot",
    );
    std::thread::sleep(Duration::from_millis(1050));
    assert_eq!(cli(&r).job.unwrap().id, j.id);
    let mut changed = r.clone();
    changed.length = Some(0);
    assert_eq!(cli(&changed).error.unwrap().code, "invalidRequest");
    let mut foreign = fresh("objects");
    foreign.runtime_id = Some(io::uuid());
    assert_eq!(cli(&foreign).error.unwrap().code, "invalidID");
    let mut nav = fresh("navigate");
    nav.session_id = Some(j.session_id.clone());
    nav.document_id = Some(j.document_id.clone());
    nav.sha256 = j.sha256.clone();
    nav.location = Some(2);
    nav.length = Some(0);
    assert_eq!(cli(&nav).error.unwrap().code, "invalidRange");
    nav.location = Some(0);
    nav.sha256 = Some("0".repeat(64));
    assert_eq!(cli(&nav).error.unwrap().code, "stale");
    nav.sha256 = j.sha256.clone();
    nav.document_id = Some(io::uuid());
    assert_eq!(cli(&nav).error.unwrap().code, "invalidID");
    nav.document_id = Some(j.document_id.clone());
    nav.location = Some(8);
    let eof = ready(&cli(&nav).job.unwrap().id);
    assert_eq!(
        eof.selection,
        Some(Selection {
            location: 8,
            length: 0
        })
    );
    // GTK darf dieselben Marken erneut melden, ohne einen Auftrag abzubrechen.
    visibility(&tx, &j.session_id, false);
    nav.id = io::uuid();
    nav.deadline = io::now() + 10.;
    nav.location = Some(0);
    let unchanged = cli(&nav).job.unwrap();
    let (done, rx) = mpsc::sync_channel(1);
    tx.send(Action::ReassertSelection(j.session_id.clone(), done))
        .unwrap();
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let mut status = fresh("status");
    status.job_id = Some(unchanged.id.clone());
    assert_eq!(
        cli(&status).job.unwrap().state,
        "presenting",
        "unchanged GTK marks keep pending navigation"
    );
    visibility(&tx, &j.session_id, true);
    ready(&unchanged.id);

    // Ohne sichtbare Quellansicht bleibt die Antwort sicher ausstehend,
    // bis die echte Tastatureingabe im Fenster angekommen ist.
    visibility(&tx, &j.session_id, false);
    let mut interrupted = false;
    for _ in 0..6 {
        let mut r = nav.clone();
        r.id = io::uuid();
        r.deadline = io::now() + 10.;
        r.location = Some(0);
        let pending = cli(&r).job.unwrap();
        tx.send(Action::KeyInterrupt(j.session_id.clone())).unwrap();
        std::thread::sleep(Duration::from_millis(180));
        let mut status = fresh("status");
        status.job_id = Some(pending.id);
        let job = cli(&status).job.unwrap();
        if job.state == "cancelled" {
            interrupted = true;
            break;
        }
    }
    assert!(
        interrupted,
        "real user input must cancel pending navigation"
    );
    visibility(&tx, &j.session_id, true);
    let mut c = fresh("cancel");
    c.job_id = Some(j.id.clone());
    assert_eq!(cli(&c).job.unwrap().state, "ready");
    let outer = root.join("outer.zip");
    let leaf = root.join("member.txt");
    fs::write(&outer, b"opaque archive bytes").unwrap();
    fs::write(&leaf, raw).unwrap();
    let mut a = snapshot(&leaf, raw);
    a.operation = "sourceSnapshot".into();
    a.provenance = Some(Provenance {
        schema_version: 1,
        run_id: io::uuid(),
        kind: "archiveMaterialization".into(),
        hit_identity: HitIdentity {
            filesystem_path: outer.to_str().unwrap().into(),
            archive_members: vec!["member.txt".into()],
            archive_member_bytes: vec!["bWVtYmVyLnR4dA==".into()],
        },
        source_generation: io::generation(&fs::metadata(&outer).unwrap()),
        archive_binding: "sha256".into(),
        outer_sha256: Some(io::hash(b"opaque archive bytes")),
        position_binding: "exactUTF16".into(),
        search_evidence: Some("Synthetic local hit".into()),
    });
    let owned = ready(&cli(&a).job.unwrap().id);
    assert_eq!(owned.adopted, Some(true));
    fs::remove_file(&leaf).unwrap();
    fs::write(&outer, b"later outer source").unwrap();
    inspect(
        &tx,
        &owned,
        std::str::from_utf8(raw).unwrap(),
        a.selection(),
        "control-provenance",
    );
    visibility(&tx, &owned.session_id, false);
    let mut pending = fresh("navigate");
    pending.session_id = Some(owned.session_id.clone());
    pending.document_id = Some(owned.document_id.clone());
    pending.sha256 = owned.sha256.clone();
    pending.location = Some(0);
    pending.length = Some(0);
    let provenance_job = cli(&pending).job.unwrap();
    tx.send(Action::ExploreProvenance(owned.session_id.clone()))
        .unwrap();
    assert_eq!(terminal(&provenance_job.id).state, "cancelled");
    pending.id = io::uuid();
    let pending_job = cli(&pending).job.unwrap();
    let mut cancel = fresh("cancel");
    cancel.job_id = Some(pending_job.id.clone());
    assert_eq!(cli(&cancel).job.unwrap().state, "cancelled");
    visibility(&tx, &owned.session_id, true);
    std::thread::sleep(Duration::from_millis(150));
    assert_eq!(terminal(&pending_job.id).state, "cancelled");
    assert_eq!(
        fs::read_dir(std::env::temp_dir())
            .unwrap()
            .flatten()
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("FastraSourceSnapshot-v1-")
                    && fs::read(entry.path().join("owner.json"))
                        .ok()
                        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
                        .is_some_and(|owner| {
                            owner["ownerPID"].as_u64() == Some(std::process::id() as u64)
                        })
            })
            .count(),
        1,
        "confirmed adopted copy survives later navigation cancellation"
    );
    let nul = root.join("nul.txt");
    let raw_nul = [0xff, 0xfe, b'A', 0, 0, 0, b'B', 0];
    fs::write(&nul, raw_nul).unwrap();
    let mut invalid = snapshot(&nul, &raw_nul);
    invalid.location = Some(0);
    invalid.length = Some(0);
    let failed = terminal(&cli(&invalid).job.unwrap().id);
    assert_eq!(failed.state, "failed");
    assert_eq!(failed.error.as_ref().unwrap().code, "sourceUnavailable");
    assert!(failed.error.as_ref().unwrap().message.contains("U+0000"));
    let (done, rx) = mpsc::sync_channel(1);
    tx.send(Action::NulFailure(failed.session_id.clone(), done))
        .unwrap();
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    close(&failed.session_id);
    let first = "let one = \"😀\"\r\n";
    let second = "let café = \"雪\"\n";
    fs::write(root.join("first.swift"), first).unwrap();
    fs::write(root.join("second.swift"), second).unwrap();
    let sid1 = io::uuid();
    let sid2 = io::uuid();
    let manifest = json!({"schemaVersion":1,"id":io::uuid(),"title":"Frozen local code question","question":"Inspect the exact immutable source and deliberately return.","language":"en","createdAt":"2026-11-05T10:00:00Z","projectID":io::uuid(),"projectName":"Synthetic project","sources":[{"id":sid1,"path":"first.swift","encoding":"utf8","sha256":io::hash(first.as_bytes())},{"id":sid2,"path":"second.swift","encoding":"utf8","sha256":io::hash(second.as_bytes())}],"steps":[{"id":io::uuid(),"title":"First source","text":"The first source is frozen.","sourceID":sid1,"location":0,"length":3},{"id":io::uuid(),"title":"Second source","text":"This step switches the document identity.","sourceID":sid2,"location":4,"length":4}],"codeFontSize":12,"explanationFontSize":12});
    let manifest_path = root.join("question.json");
    fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    let mut e = fresh("explanation");
    e.path = Some(manifest_path.to_str().unwrap().into());
    let explanation = ready(&cli(&e).job.unwrap().id);
    inspect(
        &tx,
        &explanation,
        first,
        Selection {
            location: 0,
            length: 3,
        },
        "control-player-first",
    );
    tx.send(Action::Next(explanation.session_id.clone()))
        .unwrap();
    let started = Instant::now();
    let document = loop {
        let inventory = cli(&fresh("objects"));
        let doc = inventory
            .objects
            .unwrap()
            .into_iter()
            .find(|o| {
                o.kind == "document" && o.session_id.as_ref() == Some(&explanation.session_id)
            })
            .unwrap();
        if doc.sha256.as_deref() == Some(io::hash(second.as_bytes()).as_str())
            && inventory.jobs.unwrap().iter().any(|j| {
                j.session_id == explanation.session_id
                    && j.document_id == doc.id
                    && j.state == "ready"
            })
        {
            break doc;
        }
        assert!(started.elapsed() < Duration::from_secs(8));
        std::thread::sleep(Duration::from_millis(30));
    };
    assert_ne!(document.id, explanation.document_id);
    let mut stale = fresh("navigate");
    stale.session_id = Some(explanation.session_id.clone());
    stale.document_id = Some(explanation.document_id.clone());
    stale.sha256 = explanation.sha256.clone();
    stale.location = Some(0);
    stale.length = Some(0);
    assert_eq!(cli(&stale).error.unwrap().code, "invalidID");
    tx.send(Action::Explore(explanation.session_id.clone()))
        .unwrap();
    std::thread::sleep(Duration::from_millis(200));
    let (done, rx) = mpsc::sync_channel(1);
    tx.send(Action::Paused(explanation.session_id.clone(), done))
        .unwrap();
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    tx.send(Action::Return(explanation.session_id.clone()))
        .unwrap();
    std::thread::sleep(Duration::from_millis(350));
    let mut current = explanation.clone();
    current.document_id = document.id;
    inspect(
        &tx,
        &current,
        second,
        Selection {
            location: 4,
            length: 4,
        },
        "control-player-return",
    );
    // Neue Fenster sind bereits während des Ladens reserviert, nicht erst bei ready.
    let (opened, rx) = mpsc::sync_channel(1);
    tx.send(Action::OpenUi(manifest_path.clone(), opened))
        .unwrap();
    let ui_session = rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let mut sessions = vec![
        j.session_id.clone(),
        owned.session_id.clone(),
        explanation.session_id.clone(),
        ui_session,
    ];
    for _ in sessions.len()..MAX_SESSIONS {
        let mut r = snapshot(&path, raw);
        r.location = Some(0);
        r.length = Some(0);
        sessions.push(cli(&r).job.unwrap().session_id);
    }
    assert_eq!(cli(&snapshot(&path, raw)).error.unwrap().code, "capacity");
    for session in sessions {
        close(&session);
    }
    assert!(cli(&fresh("objects"))
        .objects
        .unwrap()
        .iter()
        .all(|o| o.session_id.is_none()));
    let mut old = fresh("close");
    old.session_id = Some(j.session_id.clone());
    assert_eq!(cli(&old).error.unwrap().code, "invalidID");
    assert_eq!(fs::read(path).unwrap(), raw);
    assert_eq!(
        fs::read(root.join("first.swift")).unwrap(),
        first.as_bytes()
    );
    assert_eq!(
        fs::read(root.join("second.swift")).unwrap(),
        second.as_bytes()
    );
    assert!(runtime != io::uuid());
    let package = io::load_explanation(&manifest_path, &Cancellation::default()).unwrap();
    let (done, rx) = mpsc::sync_channel(1);
    tx.send(Action::ExpiredCompletion(package, done)).unwrap();
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    tx.send(Action::Done).unwrap();
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    ui.add_document("unsaved-control-work.txt", "untouched working text");
    let doc = ui.active().unwrap();
    doc.buffer.insert(&mut doc.buffer.end_iter(), " retained");
    let original = super::super::buffer_text(&doc.buffer);
    let count = ui.documents.borrow().len();
    let (tx, rx) = mpsc::channel();
    let started = Instant::now();
    glib::timeout_add_local_once(Duration::from_millis(500), move || {
        std::thread::spawn(move || worker(root, tx));
    });
    glib::timeout_add_local(Duration::from_millis(10), move || {
        assert!(
            started.elapsed() < Duration::from_secs(110),
            "local-control native test deadline"
        );
        assert_eq!(ui.documents.borrow().len(), count);
        assert_eq!(super::super::buffer_text(&doc.buffer), original);
        assert!(doc.buffer.is_modified());
        while let Ok(action) = rx.try_recv() {
            match action {
                Action::Inspect(id, text, selection, name, done) => {
                    let s = RUNTIME
                        .with(|r| r.borrow().as_ref().unwrap().borrow().sessions[&id].clone());
                    assert!(!s.view.borrow().source.is_editable());
                    assert!(!s.view.borrow().buffer.enables_undo());
                    assert_eq!(
                        s.view
                            .borrow()
                            .buffer
                            .text(
                                &s.view.borrow().buffer.start_iter(),
                                &s.view.borrow().buffer.end_iter(),
                                true
                            )
                            .as_str(),
                        text
                    );
                    assert!(s
                        .view
                        .borrow()
                        .confirms(s.loaded.borrow().as_ref().unwrap(), &selection));
                    support::test_size(&s.window);
                    glib::timeout_add_local_once(Duration::from_millis(250), move || {
                        if let Some(player) = s.player.borrow().as_ref() {
                            player.check_layout();
                        }
                        support::capture(&s.window, name);
                        done.send(()).unwrap();
                    });
                }
                Action::Next(id) => {
                    let p = RUNTIME.with(|r| {
                        r.borrow().as_ref().unwrap().borrow().sessions[&id]
                            .player
                            .borrow()
                            .clone()
                            .unwrap()
                    });
                    p.control_test_next();
                }
                Action::Return(id) => {
                    let p = RUNTIME.with(|r| {
                        r.borrow().as_ref().unwrap().borrow().sessions[&id]
                            .player
                            .borrow()
                            .clone()
                            .unwrap()
                    });
                    p.control_test_return();
                }
                Action::ExploreProvenance(id) => {
                    fn find(widget: &gtk::Widget) -> Option<gtk::TextView> {
                        if !widget.is::<sourceview5::View>() {
                            if let Some(view) = widget.downcast_ref::<gtk::TextView>() {
                                return Some(view.clone());
                            }
                        }
                        let mut child = widget.first_child();
                        while let Some(w) = child {
                            if let Some(view) = find(&w) {
                                return Some(view);
                            }
                            child = w.next_sibling();
                        }
                        None
                    }
                    let session = RUNTIME
                        .with(|r| r.borrow().as_ref().unwrap().borrow().sessions[&id].clone());
                    let text = find(session.window.upcast_ref()).expect("native provenance text");
                    support::test_click(&text, &["Down"]);
                }
                Action::Explore(id) => {
                    let s = RUNTIME
                        .with(|r| r.borrow().as_ref().unwrap().borrow().sessions[&id].clone());
                    support::test_click(&s.view.borrow().source, &["Down"]);
                }
                Action::KeyInterrupt(id) => {
                    let s = RUNTIME
                        .with(|r| r.borrow().as_ref().unwrap().borrow().sessions[&id].clone());
                    support::test_keys(&s.window, &["Down"]);
                }
                Action::ReassertSelection(id, done) => {
                    let s = RUNTIME
                        .with(|r| r.borrow().as_ref().unwrap().borrow().sessions[&id].clone());
                    let buffer = &s.view.borrow().buffer;
                    let insert = buffer.iter_at_mark(&buffer.get_insert());
                    let bound = buffer.iter_at_mark(&buffer.selection_bound());
                    buffer.select_range(&insert, &bound);
                    glib::timeout_add_local_once(Duration::from_millis(80), move || {
                        done.send(()).unwrap();
                    });
                }
                Action::Visibility(id, visible, done) => {
                    let session = RUNTIME
                        .with(|r| r.borrow().as_ref().unwrap().borrow().sessions[&id].clone());
                    session.view.borrow().source.set_visible(visible);
                    glib::timeout_add_local_once(Duration::from_millis(60), move || {
                        done.send(()).unwrap();
                    });
                }
                Action::Paused(id, done) => {
                    let player = RUNTIME.with(|r| {
                        r.borrow().as_ref().unwrap().borrow().sessions[&id]
                            .player
                            .borrow()
                            .clone()
                            .unwrap()
                    });
                    assert!(
                        player.control_test_paused(),
                        "own exploration stays paused after job cleanup"
                    );
                    done.send(()).unwrap();
                }
                Action::NulFailure(id, done) => {
                    let session = RUNTIME
                        .with(|r| r.borrow().as_ref().unwrap().borrow().sessions[&id].clone());
                    assert_eq!(session.view.borrow().buffer.char_count(), 0);
                    support::test_size(&session.window);
                    glib::timeout_add_local_once(Duration::from_millis(200), move || {
                        support::capture(&session.window, "control-nul-failure");
                        done.send(()).unwrap();
                    });
                }
                Action::OpenUi(path, done) => {
                    let before = RUNTIME.with(|r| {
                        r.borrow()
                            .as_ref()
                            .unwrap()
                            .borrow()
                            .sessions
                            .keys()
                            .cloned()
                            .collect::<Vec<_>>()
                    });
                    open_manifest(&ui, path);
                    let id = RUNTIME.with(|r| {
                        r.borrow()
                            .as_ref()
                            .unwrap()
                            .borrow()
                            .sessions
                            .keys()
                            .find(|id| !before.contains(id))
                            .unwrap()
                            .clone()
                    });
                    done.send(id).unwrap();
                }
                Action::ExpiredCompletion(package, done) => {
                    expired_completions(package);
                    done.send(()).unwrap();
                }
                Action::Done => {
                    println!("FASTRA_LOCAL_CONTROL_SELFTEST=PASS real-cli nine-ops runtime-id expired-replay readonly dirty-isolation hashes utf16-graphemes eof native-user-cancel adopted-copy player-source-switch return stale-document capacity close");
                    std::process::exit(0)
                }
            }
        }
        glib::ControlFlow::Continue
    });
}

// Die Completion läuft vor dem nächsten periodischen prune: abgelaufene Jobs
// dürfen weder Inhalt installieren noch eine bereits bestätigte Auswahl committen.
fn expired_completions(package: fastra_io::code_explanation::Package) {
    RUNTIME.with(|runtime| {
        let runtime = runtime.borrow();
        let mut r = runtime.as_ref().unwrap().borrow_mut();
        let loaded = Loaded::from_bytes(b"late content", "late.txt".into(), None,
            &Selection { location: 0, length: 0 }, &Cancellation::default()).unwrap();
        let payloads = [Payload::Snapshot(loaded.clone()), Payload::Explanation(package)];
        for payload in payloads {
            let request = fresh("snapshot");
            let s = r.create(&request).unwrap();
            let job = Job::new(io::uuid(), &request, s.id.clone(), s.window_id.clone(), s.document_id.borrow().clone());
            r.state.insert(job.clone(), io::now() - JOB_TIMEOUT - 1.).unwrap();
            r.loaded(s.id.clone(), job.id.clone(), s.generation.get(), Selection { location: 0, length: 0 }, Ok(payload));
            assert_eq!(r.state.jobs[&job.id].state, "failed");
            assert_eq!(r.state.jobs[&job.id].error.as_ref().unwrap().code, "expired");
            assert_eq!(s.view.borrow().buffer.char_count(), 0, "late content must not be installed");
            assert!(s.loaded.borrow().is_none());
            assert!(s.player.borrow().is_none(), "late explanation must not build a player");
            r.sessions.remove(&s.id);
            s.window.close();
        }
        let request = fresh("navigate");
        let s = r.create(&request).unwrap();
        s.install(loaded, None);
        let mut job = Job::new(io::uuid(), &request, s.id.clone(), s.window_id.clone(), s.document_id.borrow().clone());
        job.state = "presenting".into();
        r.state.insert(job.clone(), io::now() - JOB_TIMEOUT - 1.).unwrap();
        r.events.borrow_mut().push(Event::Complete(s.id.clone(), job.id.clone(), s.generation.get(), Ok(Selection { location: 0, length: 0 })));
        r.events();
        assert_eq!(r.state.jobs[&job.id].state, "failed");
        assert_eq!(r.state.jobs[&job.id].error.as_ref().unwrap().code, "expired");
        assert!(r.state.jobs[&job.id].selection.is_none(), "late ready must not commit");
        r.sessions.remove(&s.id);
        s.window.close();
        r.events();
        println!("FASTRA_LOCAL_CONTROL_DEADLINE=PASS expired-snapshot-no-install expired-explanation-no-player expired-ready-no-commit");
    });
}
