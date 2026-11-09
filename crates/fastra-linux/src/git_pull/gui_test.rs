mod mutual;
use super::*;
use std::{fs, path::Path, process::Command, sync::Arc, time::Instant};
fn git(p: &Path, a: &[&str]) -> Vec<u8> {
    let o = Command::new("/usr/bin/git")
        .current_dir(p)
        .args(a)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(
        o.status.success(),
        "{a:?}: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    o.stdout
}
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    old: Vec<u8>,
    new: Vec<u8>,
    text: fastra_document::TextDocument,
    mode: String,
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let mode = std::env::var("FASTRA_GIT_PULL_SELFTEST").unwrap();
    support::background(
        move || {
            let t = tempfile::Builder::new()
                .prefix("pull-native-")
                .tempdir_in(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap())
                .unwrap();
            let root = t.path().join("work");
            let remote = t.path().join("remote");
            fs::create_dir(&remote).unwrap();
            git(&remote, &["init", "-qb", "main"]);
            git(&remote, &["config", "user.name", "Fixture"]);
            git(
                &remote,
                &["config", "user.email", "fixture@example.invalid"],
            );
            if mode == "large" {
                for n in 0..1024 {
                    fs::write(remote.join(format!("tiny-{n:04}")), "x\n").unwrap();
                }
                git(&remote, &["add", "."]);
            }
            fs::write(remote.join("file"), "old\n").unwrap();
            git(&remote, &["add", "file"]);
            git(&remote, &["commit", "-qm", "old"]);
            git(
                t.path(),
                &[
                    "clone",
                    "-q",
                    remote.to_str().unwrap(),
                    root.to_str().unwrap(),
                ],
            );
            git(&root, &["config", "user.name", "Fixture"]);
            git(&root, &["config", "user.email", "fixture@example.invalid"]);
            git(&root, &["config", "commit.gpgsign", "false"]);
            if mode.contains("merge") || mode.contains("rebase") {
                fs::write(
                    root.join(if mode.starts_with("conflict") {
                        "file"
                    } else {
                        "local"
                    }),
                    "local\n",
                )
                .unwrap();
                git(&root, &["add", "."]);
                git(&root, &["commit", "-qm", "local"]);
            }
            let old = git(&root, &["rev-parse", "HEAD"]);
            fs::write(remote.join("file"), "new unicode Ω 😀\n").unwrap();
            git(&remote, &["commit", "-qam", "incoming"]);
            let new = git(&remote, &["rev-parse", "HEAD"]);
            if mode == "cancel" || mode == "cancel-owner" {
                use std::os::unix::fs::PermissionsExt;
                let hook = root.join(".git/hooks/post-merge");
                fs::write(
                    &hook,
                    "#!/bin/sh\nprintf started > .git/started\nsleep 30\n",
                )
                .unwrap();
                fs::set_permissions(&hook, fs::Permissions::from_mode(0o700)).unwrap();
            }
            let fastra_document::Document::Text(text) = fastra_document::Document::open(
                &root.join("file"),
                None,
                &fastra_core::Cancellation::default(),
            )
            .unwrap() else {
                panic!("text")
            };
            Ok(Fixture {
                _temp: t,
                root,
                old,
                new,
                text,
                mode,
            })
        },
        move |f| {
            let f = Arc::new(f.unwrap());
            let doc = ui.add_loaded_text(
                "file",
                Arc::new(f.text.decoded().clone()),
                f.text.snapshot().clone(),
            );
            doc.buffer.set_text("unsaved source Ω 😀\n");
            doc.buffer.set_modified(true);
            let revision = doc.revision.get();
            let other = if f.mode.starts_with("mutual") || f.mode == "busy-source" {
                std::env::remove_var("FASTRA_GIT_PULL_SELFTEST");
                ui.window.application().unwrap().activate();
                let other = crate::application_lifecycle::ordinary_windows()
                    .unwrap()
                    .into_iter()
                    .find(|other| !Rc::ptr_eq(other, &ui))
                    .unwrap();
                std::env::set_var("FASTRA_GIT_PULL_SELFTEST", &f.mode);
                let peer = f._temp.path().join("peer.txt");
                fs::write(&peer, "peer old\n").unwrap();
                let fastra_document::Document::Text(text) = fastra_document::Document::open(
                    &peer,
                    None,
                    &fastra_core::Cancellation::default(),
                )
                .unwrap() else {
                    panic!("peer")
                };
                let document = other.add_loaded_text(
                    "peer.txt",
                    Arc::new(text.decoded().clone()),
                    text.snapshot().clone(),
                );
                document.buffer.set_text("peer dirty\n");
                document.buffer.set_modified(true);
                Some((other, document, peer))
            } else {
                None
            };
            let mutual = if matches!(
                f.mode.as_str(),
                "mutual-folder" | "mutual-undo" | "mutual-hex" | "mutual-assets"
            ) {
                Some(mutual::Case::new(
                    other.as_ref().unwrap().0.clone(),
                    &f.mode,
                    f._temp.path(),
                ))
            } else {
                None
            };
            let state = RefCell::new(open(&ui, "/usr/bin/git".into(), f.root.clone()));
            let read_window = RefCell::<Option<gtk::Window>>::new(None);
            let phase = Cell::new(if mutual.is_some() { 40 } else { 0u8 });
            let started = Instant::now();
            let pause = Cell::new(started);
            glib::timeout_add_local(Duration::from_millis(60), move || {
                assert!(
                    started.elapsed() < Duration::from_secs(35),
                    "Pull phase {}: {} · {}",
                    phase.get(),
                    state.borrow().status.text(),
                    state
                        .borrow()
                        .output
                        .buffer()
                        .text(
                            &state.borrow().output.buffer().start_iter(),
                            &state.borrow().output.buffer().end_iter(),
                            false
                        )
                        .chars()
                        .take(3000)
                        .collect::<String>()
                );
                let s = state.borrow().clone();
                if s.job.get().is_some() && !matches!(phase.get(), 6 | 7 | 9 | 30 | 31 | 32) {
                    return glib::ControlFlow::Continue;
                }
                match phase.get() {
                    0 => {
                        assert!(
                            s.loaded.borrow().is_some(),
                            "{}",
                            s.output.buffer().text(
                                &s.output.buffer().start_iter(),
                                &s.output.buffer().end_iter(),
                                false
                            )
                        );
                        if f.mode == "busy-source" {
                            let (other, _, _) = other.as_ref().unwrap();
                            support::test_click(&other.save, &[]);
                            phase.set(30);
                            return glib::ControlFlow::Continue;
                        }
                        if f.mode == "entry" {
                            let _read = support::open(&ui, "/usr/bin/git".into());
                            let w = ui
                                .window
                                .application()
                                .unwrap()
                                .windows()
                                .into_iter()
                                .find(|w| {
                                    w.title().as_deref()
                                        == Some(ui.lang.text("Git · Lesen", "Git · Read"))
                                })
                                .unwrap();
                            let entry = mutual::all(&w)
                                .into_iter()
                                .filter_map(|w| w.downcast::<gtk::Entry>().ok())
                                .next()
                                .unwrap();
                            entry.set_text(f.root.to_str().unwrap());
                            s.window.close();
                            support::test_size(&w);
                            *read_window.borrow_mut() = Some(w);
                            pause.set(Instant::now());
                            phase.set(62);
                            return glib::ControlFlow::Continue;
                        }
                        support::test_size(&s.window);
                        s.strategy.set_selected(if f.mode.contains("merge") {
                            1
                        } else if f.mode.contains("rebase") {
                            2
                        } else {
                            0
                        });
                        pause.set(Instant::now());
                        phase.set(12);
                    }
                    12 | 13 => {
                        if pause.get().elapsed() < Duration::from_millis(180) {
                            return glib::ControlFlow::Continue;
                        }
                        support::test_click(&s.prepare, &[]);
                        phase.set(if phase.get() == 12 { 1 } else { 3 });
                    }
                    1 => {
                        if s.preview.borrow().is_none() {
                            return glib::ControlFlow::Continue;
                        }
                        assert!(
                            s.preview.borrow().is_some(),
                            "{} {}",
                            s.status.text(),
                            s.output.buffer().text(
                                &s.output.buffer().start_iter(),
                                &s.output.buffer().end_iter(),
                                false
                            )
                        );
                        assert!(!s.start.is_sensitive());
                        assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), f.old);
                        if !support::try_capture(&s.window, "pull-preview") {
                            return glib::ControlFlow::Continue;
                        }
                        s.window.close();
                        assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), f.old);
                        *state.borrow_mut() = open(&ui, "/usr/bin/git".into(), f.root.clone());
                        phase.set(2);
                    }
                    2 => {
                        support::test_size(&s.window);
                        s.strategy.set_selected(if f.mode.contains("merge") {
                            1
                        } else if f.mode.contains("rebase") {
                            2
                        } else {
                            0
                        });
                        pause.set(Instant::now());
                        phase.set(13);
                    }
                    3 => {
                        if s.preview.borrow().is_none() {
                            return glib::ControlFlow::Continue;
                        }
                        assert!(s.preview.borrow().is_some());
                        if f.mode == "drift-file" {
                            fs::write(f.root.join("file"), "late drift\n").unwrap();
                        }
                        if f.mode == "owner-revision" {
                            doc.buffer.insert_at_cursor("new");
                            phase.set(10);
                            return glib::ControlFlow::Continue;
                        }
                        if f.mode == "owner-tab" {
                            ui.add_document("Other", "other");
                            ui.tabs.set_current_page(ui.tabs.page_num(&doc.container));
                            phase.set(10);
                            return glib::ControlFlow::Continue;
                        }
                        if f.mode == "selection" {
                            s.branch.set_text("other");
                            s.branch.set_text("main");
                            assert!(s.preview.borrow().is_none());
                            assert!(!s.start.is_sensitive());
                            s.execute();
                            assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), f.old);
                            println!(
                                "PASS native Pull source-field ABA consumes preview and approval"
                            );
                            support::finish(s.window.clone(), ui.clone(), "git-pull");
                            return glib::ControlFlow::Break;
                        }

                        support::test_click(&s.approved, &[]);
                        phase.set(5);
                    }
                    5 => {
                        if !s.approved.is_active() {
                            return glib::ControlFlow::Continue;
                        }
                        assert!(s.start.is_sensitive());
                        if f.mode.starts_with("receipt") || f.mode.starts_with("mutual") {
                            let root = PathBuf::from(
                                std::env::var_os("FASTRA_GIT_PULL_RECEIPT_TEST_DIR").unwrap(),
                            );
                            fs::write(root.join("pause-main"), b"").unwrap();
                        }
                        support::test_click(&s.start, &[]);
                        phase.set(
                            if f.mode.starts_with("receipt") || f.mode.starts_with("mutual") {
                                6
                            } else if f.mode == "cancel" || f.mode == "cancel-owner" {
                                9
                            } else {
                                4
                            },
                        );
                    }
                    62 => {
                        if pause.get().elapsed() < Duration::from_millis(250) {
                            return glib::ControlFlow::Continue;
                        }
                        support::test_click(
                            &mutual::button(read_window.borrow().as_ref().unwrap(), "Status"),
                            &[],
                        );
                        phase.set(60);
                    }
                    60 => {
                        let w = read_window.borrow();
                        let w = w.as_ref().unwrap();
                        let text = mutual::all(w)
                            .into_iter()
                            .filter_map(|w| w.downcast::<gtk::TextView>().ok())
                            .map(|view| {
                                view.buffer()
                                    .text(
                                        &view.buffer().start_iter(),
                                        &view.buffer().end_iter(),
                                        false,
                                    )
                                    .to_string()
                            })
                            .collect::<String>();
                        if !text.contains(std::str::from_utf8(&f.old).unwrap().trim()) {
                            return glib::ControlFlow::Continue;
                        }
                        if !support::try_capture(w, "git-read-pull-entry") {
                            return glib::ControlFlow::Continue;
                        }
                        support::test_click(&mutual::button(w, "Pull …"), &[]);
                        phase.set(61);
                    }
                    61 => {
                        let next = DIALOGS.with_borrow(|dialogs| {
                            dialogs
                                .iter()
                                .filter_map(Weak::upgrade)
                                .find(|dialog| dialog.window.is_visible())
                        });
                        let Some(next) = next else {
                            return glib::ControlFlow::Continue;
                        };
                        *state.borrow_mut() = next;
                        phase.set(2);
                    }
                    40 => {
                        if !mutual.as_ref().unwrap().setup() || !State::available(&ui) {
                            return glib::ControlFlow::Continue;
                        }
                        mutual.as_ref().unwrap().hide_for_pull();
                        s.load();
                        phase.set(33);
                    }
                    44 => {
                        if !mutual.as_ref().unwrap().finished() {
                            return glib::ControlFlow::Continue;
                        }
                        println!("PASS two-window native {}: Pull pending blocks action and retains draft/approval/transaction; explicit retry succeeds",f.mode);
                        support::finish(s.window.clone(), ui.clone(), "git-pull");
                        return glib::ControlFlow::Break;
                    }
                    30 => {
                        let (other, peer, path) = other.as_ref().unwrap();
                        if !peer.saving.get() || fs::read(path).unwrap() != b"peer dirty\n" {
                            return glib::ControlFlow::Continue;
                        }
                        other.window.set_visible(false);
                        assert!(!State::available(&ui));
                        support::test_click(&s.reload, &[]);
                        pause.set(Instant::now());
                        phase.set(31);
                    }
                    31 => {
                        if pause.get().elapsed() < Duration::from_millis(250) {
                            return glib::ControlFlow::Continue;
                        }
                        let (other, peer, path) = other.as_ref().unwrap();
                        assert!(!other.window.is_visible());
                        assert!(peer.saving.get());
                        assert!(!State::available(&ui));
                        assert!(!s.prepare.is_sensitive());
                        assert!(s.preview.borrow().is_none());
                        assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), f.old);
                        assert_eq!(fs::read(path).unwrap(), b"peer dirty\n");
                        println!("PASS hidden second window: actual source bytes published, pending Main receipt blocks Pull preparation");
                        phase.set(32);
                    }
                    32 => {
                        let (_, peer, _) = other.as_ref().unwrap();
                        if peer.saving.get() {
                            return glib::ControlFlow::Continue;
                        }
                        assert!(State::available(&ui));
                        support::test_click(&s.reload, &[]);
                        phase.set(33);
                    }
                    33 => {
                        if s.loaded.borrow().is_none() {
                            return glib::ControlFlow::Continue;
                        }
                        phase.set(2);
                    }
                    10 => {
                        if s.owner.borrow().is_some() {
                            return glib::ControlFlow::Continue;
                        }
                        s.execute();
                        assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), f.old);
                        assert!(!s.start.is_sensitive());
                        println!("PASS native Pull {} invalidates before dispatch", f.mode);
                        support::finish(s.window.clone(), ui.clone(), "git-pull");
                        return glib::ControlFlow::Break;
                    }
                    6 => {
                        let root = PathBuf::from(
                            std::env::var_os("FASTRA_GIT_PULL_RECEIPT_TEST_DIR").unwrap(),
                        );
                        if !root.join("ready-main").exists() {
                            return glib::ControlFlow::Continue;
                        }
                        assert!(pending());
                        assert!(s.job.get().is_some());
                        assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), f.new);
                        if let Some(case) = mutual.as_ref() {
                            case.attempt();
                        } else if f.mode == "mutual-source" {
                            let (other, peer, _) = other.as_ref().unwrap();
                            support::test_click(&other.save, &[]);
                            let completed = Rc::new(Cell::new(false));
                            let done = completed.clone();
                            other.save_to_done(
                                peer.clone(),
                                super::super::SaveTarget::New(
                                    f._temp.path().join("must-not-exist.txt"),
                                ),
                                Box::new(move |result| {
                                    assert!(matches!(
                                        result,
                                        super::super::close_protocol::SaveOutcome::Failed
                                    ));
                                    done.set(true);
                                }),
                            );
                            assert!(completed.get());
                            let called = Rc::new(Cell::new(false));
                            let done = called.clone();
                            super::super::save_as::request(
                                other,
                                Box::new(move |result| {
                                    assert!(matches!(
                                        result,
                                        super::super::save_as::Terminal::Failed(_)
                                    ));
                                    done.set(true);
                                }),
                            );
                            assert!(called.get());
                        } else if f.mode == "receipt-close" {
                            ui.window.close();
                        } else {
                            support::test_click(&ui.status, &["ctrl+shift+q"]);
                        }
                        pause.set(Instant::now());
                        phase.set(7);
                    }
                    7 => {
                        if pause.get().elapsed() < Duration::from_millis(400) {
                            return glib::ControlFlow::Continue;
                        }
                        assert!(ui.window.is_visible());
                        assert!(pending());
                        if let Some(case) = mutual.as_ref() {
                            if !case.verify_blocked() {
                                return glib::ControlFlow::Continue;
                            }
                        } else if f.mode == "mutual-source" {
                            let (other, peer, path) = other.as_ref().unwrap();
                            assert!(!peer.saving.get());
                            assert!(peer.buffer.is_modified());
                            assert_eq!(fs::read(path).unwrap(), b"peer old\n");
                            assert!(other.status.text().contains("Git"));
                            assert!(!f._temp.path().join("must-not-exist.txt").exists());
                        } else {
                            assert!(ui.status.text().contains("Git"), "{}", ui.status.text());
                        }
                        let root = PathBuf::from(
                            std::env::var_os("FASTRA_GIT_PULL_RECEIPT_TEST_DIR").unwrap(),
                        );
                        fs::write(root.join("release-main"), b"").unwrap();
                        phase.set(4);
                    }
                    9 => {
                        if !f.root.join(".git/started").exists() {
                            return glib::ControlFlow::Continue;
                        }
                        if f.mode == "cancel-owner" {
                            ui.add_document("Other.txt", "new active document");
                        } else {
                            support::test_click(&s.cancel, &[]);
                        }
                        phase.set(4);
                    }
                    4 => {
                        if f.mode.starts_with("receipt")
                            && pause.get().elapsed() < Duration::from_millis(1000)
                        {
                            return glib::ControlFlow::Continue;
                        }
                        if s.loaded.borrow().is_some() {
                            return glib::ControlFlow::Continue;
                        }
                        if f.mode == "conflict-merge" || f.mode == "drift-file" {
                            assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), f.old);
                        } else if f.mode == "merge" || f.mode == "rebase" {
                            assert_ne!(git(&f.root, &["rev-parse", "HEAD"]), f.old);
                            assert_eq!(fs::read(f.root.join("local")).unwrap(), b"local\n");
                        } else {
                            assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), f.new);
                        }
                        assert!(ui.window.is_visible());
                        assert!(!pending());
                        assert_eq!(
                            doc.buffer.text(
                                &doc.buffer.start_iter(),
                                &doc.buffer.end_iter(),
                                false
                            ),
                            "unsaved source Ω 😀\n"
                        );
                        assert_eq!(doc.revision.get(), revision);
                        assert!(doc.buffer.is_modified());
                        if f.mode == "entry" {
                            let w = read_window.borrow();
                            let w = w.as_ref().unwrap();
                            let text = mutual::all(w)
                                .into_iter()
                                .filter_map(|w| w.downcast::<gtk::TextView>().ok())
                                .map(|view| {
                                    view.buffer()
                                        .text(
                                            &view.buffer().start_iter(),
                                            &view.buffer().end_iter(),
                                            false,
                                        )
                                        .to_string()
                                })
                                .collect::<String>();
                            if !text.contains(std::str::from_utf8(&f.new).unwrap().trim()) {
                                return glib::ControlFlow::Continue;
                            }
                        }
                        assert!(s.preview.borrow().is_none());
                        assert!(!s.approved.is_active());
                        if f.mode == "cancel-owner" || f.mode == "mutual-assets" {
                            assert!(s
                                .status
                                .text()
                                .contains(ui.lang.text("Kontextwechsel", "context changed")));
                        } else if f.mode.starts_with("conflict")
                            || f.mode == "cancel"
                            || f.mode == "drift-file"
                        {
                            assert!(
                                s.status
                                    .text()
                                    .contains(ui.lang.text("Versuch beendet", "Attempt ended")),
                                "{}",
                                s.status.text()
                            );
                        } else {
                            assert!(s.status.text().contains("Pull"));
                        }
                        if f.mode == "conflict-merge" {
                            assert!(f.root.join(".git/MERGE_HEAD").exists());
                        }
                        if f.mode == "conflict-rebase" {
                            assert!(f.root.join(".git/rebase-merge").exists());
                        }

                        if !support::try_capture(&s.window, "pull-result") {
                            return glib::ControlFlow::Continue;
                        }
                        if let Some(case) = mutual.as_ref() {
                            case.attempt();
                            phase.set(44);
                            return glib::ControlFlow::Continue;
                        }
                        println!(
                            "LAYOUT native window {}x{}",
                            s.window.width(),
                            s.window.height()
                        );
                        println!(
                            "PASS native Pull {}: explicit request/approval/postscan; unsaved source+revision preserved",f.mode
                        );
                        support::finish(s.window.clone(), ui.clone(), "git-pull");
                        return glib::ControlFlow::Break;
                    }
                    _ => unreachable!(),
                };
                glib::ControlFlow::Continue
            });
        },
    );
}
