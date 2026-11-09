use super::*;
use std::{fs, os::unix::fs::PermissionsExt, process::Command, time::Instant};
fn git(path: &Path, args: &[&str]) -> Vec<u8> {
    let out = Command::new("/usr/bin/git")
        .current_dir(path)
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
    head: Vec<u8>,
    index: Vec<u8>,
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
            fs::write(root.join("file"), "unchanged\n").unwrap();
            git(&root, &["add", "file"]);
            git(&root, &["commit", "-qm", "initial"]);
            let bare = temp.path().join("remote.git");
            git(
                temp.path(),
                &[
                    "clone",
                    "--bare",
                    root.to_str().unwrap(),
                    bare.to_str().unwrap(),
                ],
            );
            git(&bare, &["branch", "extra", "main"]);
            git(&root, &["remote", "add", "origin", bare.to_str().unwrap()]);
            git(
                &root,
                &[
                    "remote",
                    "add",
                    "second",
                    temp.path().join("missing.git").to_str().unwrap(),
                ],
            );
            let head = git(&root, &["rev-parse", "HEAD"]);
            let index = fs::read(root.join(".git/index")).unwrap();
            Ok(Fixture {
                _temp: temp,
                root,
                head,
                index,
            })
        },
        move |result| {
            check(ui, result.unwrap());
        },
    );
}
fn check(ui: Rc<Ui>, fixture: Fixture) {
    let fixture = std::sync::Arc::new(fixture);
    let _read = support::open(&ui, "/usr/bin/git".into());
    let read_window = ui
        .window
        .application()
        .unwrap()
        .windows()
        .into_iter()
        .find(|w| w.title().as_deref() == Some(ui.lang.text("Git · Lesen", "Git · Read")))
        .unwrap();
    fn collect(widget: &gtk::Widget, out: &mut Vec<gtk::Widget>) {
        out.push(widget.clone());
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            collect(&widget, out);
        }
    }
    let mut widgets = Vec::new();
    collect(read_window.upcast_ref(), &mut widgets);
    let path = widgets
        .iter()
        .find_map(|w| w.downcast_ref::<gtk::Entry>())
        .unwrap();
    path.set_text(fixture.root.to_str().unwrap());
    let read_view = widgets
        .iter()
        .find_map(|w| w.downcast_ref::<gtk::TextView>())
        .unwrap()
        .clone();
    widgets
        .iter()
        .filter_map(|w| w.downcast_ref::<gtk::Button>())
        .find(|b| b.label().as_deref() == Some("Branches"))
        .unwrap()
        .emit_clicked();
    let s = open(&ui, "/usr/bin/git".into(), fixture.root.clone());
    if let Ok(width) = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or_default()
        .parse::<i32>()
    {
        s.window.set_default_size(width, 640);
    }
    let refreshes = Rc::new(Cell::new(0));
    let seen = refreshes.clone();
    let expected = fixture.root.clone();
    observe(&ui.window.clone().upcast(), move |root, _identity| {
        assert_eq!(root, expected);
        seen.set(seen.get() + 1);
    });
    let stage = Cell::new(0);
    let started = Instant::now();
    let check_pending = Rc::new(Cell::new(false));
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "fetch GUI timeout at {}: {}",
            stage.get(),
            s.status.text()
        );
        let text = || {
            let b = s.output.buffer();
            b.text(&b.start_iter(), &b.end_iter(), true).to_string()
        };
        let read_text = || {
            let b = read_view.buffer();
            b.text(&b.start_iter(), &b.end_iter(), true).to_string()
        };
        match stage.get() {
            0 => {
                if !read_text().contains("refs/heads/main") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!read_text().contains("refs/remotes/origin/extra"));
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s
                    .loaded
                    .borrow()
                    .as_ref()
                    .is_some_and(|l| l.remotes.len() == 2));
                assert!(s.basis.text().contains(fixture.root.to_str().unwrap()));
                assert!(s.prune.is_active());
                if !support::try_capture(&s.window, "git-fetch-selection") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.choice, &["Home", "Down", "Return"]);
                stage.set(1);
            }
            1 => {
                if s.choice.selected() != 1 {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.start, &[]);
                stage.set(2);
            }
            2 => {
                if !s.busy.get() && !text().contains("refs/remotes/origin") {
                    return glib::ControlFlow::Continue;
                }
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(text().contains("refs/remotes/origin/extra"), "{}", text());
                assert!(!text().contains("Remote: second"));
                assert_eq!(refreshes.get(), 1);
                if !read_text().contains("refs/remotes/origin/extra") {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(&read_window, "git-fetch-refreshed-branches") {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(&s.window, "git-fetch-one") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.choice, &["Home", "Return"]);
                stage.set(3);
            }
            3 => {
                if s.choice.selected() != 0 {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.start, &[]);
                stage.set(4);
            }
            4 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                if !text().contains("second") {
                    return glib::ControlFlow::Continue;
                }
                assert!(s
                    .status
                    .text()
                    .contains(s.lang().text("unvollständig", "incomplete")));
                assert!(text().contains("origin"));
                assert!(text().contains("does not appear to be a git repository"));
                assert_eq!(refreshes.get(), 2);
                if !support::try_capture(&s.window, "git-fetch-partial") {
                    return glib::ControlFlow::Continue;
                }
                let root = fixture.root.clone();
                let ready = check_pending.clone();
                support::background(
                    move || {
                        let script = root.join("slow-upload-pack");
                        fs::write(
                            &script,
                            "#!/bin/sh\nprintf 'fetch ready\\n' >&2\nsleep 30\n",
                        )
                        .unwrap();
                        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
                        git(
                            &root,
                            &[
                                "config",
                                "remote.origin.uploadpack",
                                script.to_str().unwrap(),
                            ],
                        );
                        Ok(())
                    },
                    move |result| {
                        result.unwrap();
                        ready.set(true);
                    },
                );
                stage.set(5);
            }
            5 => {
                if !check_pending.get() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.choice, &["Home", "Down", "Return"]);
                stage.set(6);
            }
            6 => {
                if s.choice.selected() != 1 {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.start, &[]);
                stage.set(7);
            }
            7 => {
                if !text().contains("fetch ready") {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.busy.get(), "output must appear before completion");
                if !support::try_capture(&s.window, "git-fetch-running") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.cancel_button, &[]);
                stage.set(8);
            }
            8 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    text().contains(s.lang().text("abgebrochen", "cancelled")),
                    "{}",
                    text()
                );
                assert!(text().contains("fetch ready"));
                assert_eq!(refreshes.get(), 3);
                if !support::try_capture(&s.window, "git-fetch-cancelled") {
                    return glib::ControlFlow::Continue;
                }
                ui.add_document("changed-owner.txt", "");
                assert!(s.loaded.borrow().is_none());
                assert!(!s.start.is_sensitive());
                stage.set(9);
            }
            9 => {
                if !support::try_capture(&s.window, "git-fetch-stale-owner") {
                    return glib::ControlFlow::Continue;
                }
                let fixture = fixture.clone();
                let weak = Rc::downgrade(&s);
                let ui = ui.clone();
                support::background(
                    move || {
                        assert_eq!(fixture.head, git(&fixture.root, &["rev-parse", "HEAD"]));
                        assert_eq!(
                            fixture.index,
                            fs::read(fixture.root.join(".git/index")).unwrap()
                        );
                        assert_eq!(fs::read(fixture.root.join("file")).unwrap(), b"unchanged\n");
                        assert!(!git(
                            &fixture.root,
                            &["for-each-ref", "refs/remotes/origin/extra"]
                        )
                        .is_empty());
                        Ok(())
                    },
                    move |result| {
                        result.unwrap();
                        println!("PASS Git fetch GUI: native configured source selection and start; one/all; prune visible; real per-remote diagnostics; live bounded stderr; native cancel; owner invalidation; refresh notification and actual open branches view; unchanged HEAD/index/worktree");
                        if let Some(s) = weak.upgrade() {
                            support::finish(s.window.clone(), ui, "git-fetch");
                        }
                    },
                );
                stage.set(10);
            }
            10 => return glib::ControlFlow::Break,
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
