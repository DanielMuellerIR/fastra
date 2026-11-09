use super::*;
use std::{fs, os::unix::fs::PermissionsExt, process::Command, sync::Arc, time::Instant};
fn git(root: &std::path::Path, args: &[&str]) -> Vec<u8> {
    let out = Command::new("/usr/bin/git")
        .current_dir(root)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out.stdout
}
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    target: Vec<u8>,
    head: Vec<u8>,
    index: Vec<u8>,
    wrapper: PathBuf,
    marker: PathBuf,
}
fn collect(widget: &gtk::Widget, out: &mut Vec<gtk::Widget>) {
    out.push(widget.clone());
    let mut child = widget.first_child();
    while let Some(widget) = child {
        child = widget.next_sibling();
        collect(&widget, out);
    }
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    support::background(
        move || {
            let temp = tempfile::tempdir().unwrap();
            let root = temp.path().join("work");
            fs::create_dir(&root).unwrap();
            for args in [
                &["init", "-q", "-b", "main"][..],
                &["config", "user.name", "Synthetic"],
                &["config", "user.email", "test@example.invalid"],
                &["config", "commit.gpgsign", "false"],
            ] {
                git(&root, args);
            }
            fs::write(root.join("file"), "main\n").unwrap();
            git(&root, &["add", "file"]);
            git(&root, &["commit", "-qm", "main"]);
            git(&root, &["switch", "-c", "target"]);
            fs::write(root.join("file"), "target\n").unwrap();
            git(&root, &["commit", "-qam", "Grüße 🚀 target"]);
            let target = git(&root, &["rev-parse", "HEAD"])
                .strip_suffix(b"\n")
                .unwrap()
                .to_vec();
            git(&root, &["switch", "main"]);
            fs::write(root.join("file"), "staged\n").unwrap();
            git(&root, &["add", "file"]);
            fs::write(root.join("file"), "dirty\n").unwrap();
            fs::write(root.join("untracked"), "keep\n").unwrap();
            let head = git(&root, &["symbolic-ref", "HEAD"]);
            let index = fs::read(root.join(".git/index")).unwrap();
            let marker = root.join("prepare-started");
            let wrapper = root.join("git-wrapper");
            fs::write(&wrapper,format!("#!/usr/bin/python3\nimport os,sys,time\nif 'check-ref-format' in sys.argv[1:]:\n os.write(2,b'branch prepare ready\\n')\n open({:?},'w').write('ready')\n time.sleep(30)\nos.execv('/usr/bin/git',['git']+sys.argv[1:])\n",marker.to_str().unwrap())).unwrap();
            fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o700)).unwrap();
            Ok(Fixture {
                _temp: temp,
                root,
                target,
                head,
                index,
                wrapper,
                marker,
            })
        },
        move |result| check(ui, result.unwrap()),
    );
}
fn check(ui: Rc<Ui>, fixture: Fixture) {
    let fixture = Arc::new(fixture);
    ui.add_document("unsaved-memory.txt", "unsaved memory stays");
    let memory = ui.active().unwrap();
    memory.buffer.set_modified(true);
    let memory_revision = memory.revision.get();
    let _read = support::open(&ui, "/usr/bin/git".into());
    let read = ui
        .window
        .application()
        .unwrap()
        .windows()
        .into_iter()
        .find(|w| w.title().as_deref() == Some(ui.lang.text("Git · Lesen", "Git · Read")))
        .unwrap();
    let mut widgets = Vec::new();
    collect(read.upcast_ref(), &mut widgets);
    widgets
        .iter()
        .find_map(|w| w.downcast_ref::<gtk::Entry>())
        .unwrap()
        .set_text(fixture.root.to_str().unwrap());
    let entry = widgets
        .iter()
        .filter_map(|w| w.downcast_ref::<gtk::Button>())
        .find(|b| {
            b.label().as_deref() == Some(ui.lang.text("Lokale Branches …", "Local branches …"))
        })
        .unwrap();
    let entry = entry.clone();
    let launched = Cell::new(false);
    let state = RefCell::<Option<Rc<State>>>::new(None);
    let stage = Cell::new(0);
    let started = Instant::now();
    let observer_calls = Rc::new(Cell::new(0));
    let observed = observer_calls.clone();
    let expected = fixture.root.clone();
    git_fetch::observe(&ui.window.clone().upcast(), move |root, _| {
        if root == expected {
            observed.set(observed.get() + 1);
        }
    });
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            started.elapsed() < Duration::from_secs(50),
            "branch GUI timeout at {}",
            stage.get()
        );
        if !launched.get() {
            if !entry.is_mapped() || entry.width() == 0 {
                return glib::ControlFlow::Continue;
            }
            if !support::try_capture(&read, "git-branches-entry") {
                return glib::ControlFlow::Continue;
            }
            support::test_click(&entry, &[]);
            launched.set(true);
            return glib::ControlFlow::Continue;
        }
        if state.borrow().is_none() {
            let found = DIALOGS.with_borrow(|all| all.iter().rev().find_map(Weak::upgrade));
            let Some(found) = found else {
                return glib::ControlFlow::Continue;
            };
            if let Ok(width) = std::env::var("FASTRA_TOOL_WIDTH")
                .unwrap_or_default()
                .parse::<i32>()
            {
                found.window.set_default_size(width, 850);
            }
            *state.borrow_mut() = Some(found);
        }
        let s = state.borrow().as_ref().unwrap().clone();
        let output = || {
            let b = s.output.buffer();
            b.text(&b.start_iter(), &b.end_iter(), true).to_string()
        };
        let listing = || {
            let b = s.list.buffer();
            b.text(&b.start_iter(), &b.end_iter(), true).to_string()
        };
        match stage.get() {
            0 => {
                if s.job.get().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.loaded.borrow().is_some(), "{}", output());
                assert!(listing().contains("main") && listing().contains("target"));
                assert!(s.basis.text().contains(fixture.root.to_str().unwrap()));
                if !support::try_capture(&s.window, "git-branches-list") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.name, &["ctrl+a", "c", "r", "e", "a", "t", "e", "d"]);
                stage.set(1);
            }
            1 => {
                if s.name.text().as_str() != "created" {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.source, &["Home", "Down", "Down", "Return"]);
                stage.set(101);
            }
            101 => {
                if s.oid.text().as_bytes() != fixture.target {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.prepare, &[]);
                stage.set(2);
            }
            2 => {
                if s.job.get().is_some() || s.preview.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert!(output().contains(std::str::from_utf8(&fixture.target).unwrap()));
                assert!(!s.create.is_sensitive());
                s.create.emit_clicked();
                assert!(s.job.get().is_none());
                assert!(s.preview.borrow().is_some());
                if !support::try_capture(&s.window, "git-branches-preview") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.approved, &[]);
                stage.set(3);
            }
            3 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.create.is_sensitive());
                s.name.set_text("changed");
                assert!(s.preview.borrow().is_none());
                assert!(!s.approved.is_active());
                assert!(!s.create.is_sensitive());
                stage.set(4);
            }
            4 => {
                if !support::try_capture(&s.window, "git-branches-input-invalidated") {
                    return glib::ControlFlow::Continue;
                }
                s.name.set_text("created");
                support::test_click(&s.prepare, &[]);
                stage.set(5);
            }
            5 => {
                if s.job.get().is_some() || s.preview.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.approved, &[]);
                stage.set(6);
            }
            6 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.create, &[]);
                stage.set(7);
            }
            7 => {
                if s.job.get().is_some() || !listing().contains("created") {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    s.status
                        .text()
                        .contains(s.lang().text("Branch erstellt", "branch created")),
                    "{}",
                    s.status.text()
                );
                assert!(s.preview.borrow().is_none());
                assert!(!s.approved.is_active());
                assert!(!s.create.is_sensitive());
                assert_eq!(observer_calls.get(), 1);
                assert_eq!(
                    s.sources.borrow().get(s.source.selected() as usize),
                    Some(&fixture.target)
                );
                assert!(memory.buffer.is_modified());
                assert_eq!(memory.revision.get(), memory_revision);
                assert_eq!(
                    memory.buffer.text(
                        &memory.buffer.start_iter(),
                        &memory.buffer.end_iter(),
                        true
                    ),
                    "unsaved memory stays"
                );
                if !support::try_capture(&s.window, "git-branches-created") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.prepare, &[]);
                stage.set(8);
            }
            8 => {
                if s.job.get().is_some() || s.preview.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.approved, &[]);
                stage.set(9);
            }
            9 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.create, &[]);
                stage.set(10);
            }
            10 => {
                if s.job.get().is_some() || !output().contains("already exists") {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(observer_calls.get(), 2);
                if !support::try_capture(&s.window, "git-branches-existing-error") {
                    return glib::ControlFlow::Continue;
                }
                s.name.set_text("stale-owner");
                support::test_click(&s.prepare, &[]);
                stage.set(11);
            }
            11 => {
                if s.job.get().is_some() || s.preview.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                ui.add_document("owner-changed.txt", "other memory");
                assert!(s.preview.borrow().is_none());
                assert!(!s.create.is_sensitive());
                stage.set(12);
            }
            12 => {
                if !support::try_capture(&s.window, "git-branches-owner-invalidated") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.reload, &[]);
                stage.set(13);
            }
            13 => {
                if s.job.get().is_some() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                s.name.set_text("late-owner");
                s.prepare.emit_clicked();
                ui.add_document("late-owner.txt", "late memory");
                stage.set(14);
            }
            14 => {
                if s.job.get().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_none());
                assert!(!s.create.is_sensitive());
                s.window.close();
                let slow = open(&ui, fixture.wrapper.clone(), fixture.root.clone());
                if let Ok(width) = std::env::var("FASTRA_TOOL_WIDTH")
                    .unwrap_or_default()
                    .parse::<i32>()
                {
                    slow.window.set_default_size(width, 850);
                }
                *state.borrow_mut() = Some(slow);
                stage.set(15);
            }
            15 => {
                if s.job.get().is_some() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                s.name.set_text("cancelled");
                support::test_click(&s.prepare, &[]);
                stage.set(16);
            }
            16 => {
                if !fixture.marker.exists() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.job.get().is_some());
                support::test_click(&s.cancel_button, &[]);
                stage.set(17);
            }
            17 => {
                if s.job.get().is_some() || !output().contains("branch prepare ready") {
                    return glib::ControlFlow::Continue;
                }
                assert!(output().contains(s.lang().text("abgebrochen", "cancelled")));
                assert!(s.preview.borrow().is_none());
                if !support::try_capture(&s.window, "git-branches-cancelled") {
                    return glib::ControlFlow::Continue;
                }
                let fixture = fixture.clone();
                let ui = ui.clone();
                let window = s.window.clone();
                support::background(
                    move || {
                        assert_eq!(
                            fixture.target,
                            git(&fixture.root, &["rev-parse", "created"])
                                .strip_suffix(b"\n")
                                .unwrap()
                        );
                        for name in ["stale-owner", "late-owner", "cancelled"] {
                            assert!(git(
                                &fixture.root,
                                &["for-each-ref", &format!("refs/heads/{name}")]
                            )
                            .is_empty());
                        }
                        assert_eq!(fixture.head, git(&fixture.root, &["symbolic-ref", "HEAD"]));
                        assert_eq!(
                            fixture.index,
                            fs::read(fixture.root.join(".git/index")).unwrap()
                        );
                        assert_eq!(fs::read(fixture.root.join("file")).unwrap(), b"dirty\n");
                        assert_eq!(fs::read(fixture.root.join("untracked")).unwrap(), b"keep\n");
                        Ok(())
                    },
                    move |result| {
                        result.unwrap();
                        println!("PASS local branches GUI: native entry/name/source/preview/approval/create; consumed approval; input and owner invalidation; late result; actual Git collision; native cancellation; unchanged dirty index/worktree/HEAD and unsaved editor; refresh notification; no switch/delete");
                        support::finish(window, ui, "git-branches");
                    },
                );
                stage.set(18);
            }
            18 => return glib::ControlFlow::Break,
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
