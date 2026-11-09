use super::*;
use std::{fs, os::unix::fs::PermissionsExt, process::Command, time::Instant};
fn git(path: &std::path::Path, args: &[&str]) -> Vec<u8> {
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
    bare: PathBuf,
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
            fs::write(root.join("file"), "one\n").unwrap();
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
            git(&root, &["remote", "add", "origin", bare.to_str().unwrap()]);
            fs::write(root.join("file"), "two\n").unwrap();
            git(&root, &["add", "file"]);
            git(&root, &["commit", "-qm", "Visible preview commit"]);
            git(
                &root,
                &["remote", "add", "unsupported", bare.to_str().unwrap()],
            );
            git(
                &root,
                &[
                    "config",
                    "--add",
                    "remote.unsupported.pushurl",
                    "/missing-a",
                ],
            );
            git(
                &root,
                &[
                    "config",
                    "--add",
                    "remote.unsupported.pushurl",
                    "/missing-b",
                ],
            );
            let head = git(&root, &["rev-parse", "HEAD"]);
            let index = fs::read(root.join(".git/index")).unwrap();
            Ok(Fixture {
                _temp: temp,
                root,
                bare,
                head,
                index,
            })
        },
        move |result| check(ui, result.unwrap()),
    );
}
fn check(ui: Rc<Ui>, fixture: Fixture) {
    let f = std::sync::Arc::new(fixture);
    let s = open(&ui, "/usr/bin/git".into(), f.root.clone());
    if let Ok(width) = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or_default()
        .parse::<i32>()
    {
        s.window.set_default_size(width, 700);
    }
    let stage = Cell::new(0);
    let started = Instant::now();
    let ready = Rc::new(Cell::new(false));
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            started.elapsed() < Duration::from_secs(45),
            "push GUI timeout stage {}: {}",
            stage.get(),
            s.status.text()
        );
        let text = || {
            let b = s.output.buffer();
            b.text(&b.start_iter(), &b.end_iter(), true).to_string()
        };
        match stage.get() {
            0 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.inspect.is_sensitive());
                assert!(!s.apply.is_sensitive());
                if !support::try_capture(&s.window, "git-push-selection") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.choice, &["End", "Return"]);
                stage.set(8);
            }
            8 => {
                if s.choice.selected() != 1 {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.inspect.is_sensitive());
                assert!(text().contains(s.lang().text("mehrere", "multiple")));
                if !support::try_capture(&s.window, "git-push-unsupported-target") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.choice, &["Home", "Return"]);
                stage.set(9);
            }
            9 => {
                if s.choice.selected() != 0 {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.inspect.is_sensitive());
                support::test_click(&s.inspect, &[]);
                stage.set(1);
            }
            1 => {
                if s.busy.get() || s.preview.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert!(text().contains("Visible preview commit"));
                assert!(text().contains("refs/heads/main"));
                assert!(s.apply.is_sensitive());
                if !support::try_capture(&s.window, "git-push-preview") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.apply, &[]);
                stage.set(2);
            }
            2 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    s.status
                        .text()
                        .contains(s.lang().text("abgeschlossen", "completed")),
                    "{}",
                    text()
                );
                assert!(!s.apply.is_sensitive());
                if !support::try_capture(&s.window, "git-push-success") {
                    return glib::ControlFlow::Continue;
                }
                let f = f.clone();
                let ready = ready.clone();
                support::background(
                    move || {
                        assert_eq!(git(&f.bare, &["rev-parse", "main"]), f.head);
                        assert_eq!(git(&f.root, &["rev-parse", "HEAD"]), f.head);
                        assert_eq!(fs::read(f.root.join(".git/index")).unwrap(), f.index);
                        fs::write(f.root.join("file"), "three\n").unwrap();
                        git(&f.root, &["add", "file"]);
                        git(&f.root, &["commit", "-qm", "cancel fixture"]);
                        let hook = f.root.join(".git/hooks/pre-push");
                        fs::write(&hook, "#!/bin/sh\necho live-push-ready >&2\nsleep 30\n")
                            .unwrap();
                        fs::set_permissions(hook, fs::Permissions::from_mode(0o700)).unwrap();
                        Ok(())
                    },
                    move |result| {
                        result.unwrap();
                        ready.set(true);
                    },
                );
                stage.set(3);
            }
            3 => {
                if !ready.get() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.inspect, &[]);
                stage.set(4);
            }
            4 => {
                if s.busy.get() || !s.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.apply, &[]);
                stage.set(5);
            }
            5 => {
                if !text().contains("live-push-ready") {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.busy.get());
                if !support::try_capture(&s.window, "git-push-running") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.cancel_button, &[]);
                stage.set(6);
            }
            6 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    text().contains(s.lang().text("abgebrochen", "cancelled")),
                    "{}",
                    text()
                );
                if !support::try_capture(&s.window, "git-push-cancelled") {
                    return glib::ControlFlow::Continue;
                }
                ui.add_document("changed-owner.txt", "");
                assert!(!s.inspect.is_sensitive());
                assert!(s.loaded.borrow().is_none());
                stage.set(7);
            }
            7 => {
                if !support::try_capture(&s.window, "git-push-stale-owner") {
                    return glib::ControlFlow::Continue;
                }
                let f = f.clone();
                let ui = ui.clone();
                let window = s.window.clone();
                support::background(
                    move || {
                        assert_eq!(git(&f.bare, &["rev-parse", "main"]), f.head);
                        Ok(f)
                    },
                    move |r| {
                        let f = r.unwrap();
                        println!("PASS Git push GUI: configured target; native preview and explicit execution; complete source and expected remote OIDs; real file remote updated; live hook output; native cancel; owner invalidation; no local HEAD/index changes during push");
                        window.close();
                        owner_cases(ui, f);
                    },
                );
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
fn owner_cases(ui: Rc<Ui>, f: std::sync::Arc<Fixture>) {
    let s = open(&ui, "/usr/bin/git".into(), f.root.clone());
    let stage = Cell::new(0);
    let started = Instant::now();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            started.elapsed() < Duration::from_secs(30),
            "revision timeout stage {}",
            stage.get()
        );
        match stage.get() {
            0 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.inspect, &[]);
                stage.set(1);
            }
            1 => {
                if s.busy.get() || !s.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.apply, &[]);
                stage.set(2);
            }
            2 => {
                let b = s.output.buffer();
                if !b
                    .text(&b.start_iter(), &b.end_iter(), true)
                    .contains("live-push-ready")
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.busy.get());
                ui.active().unwrap().buffer.set_text("revision changed");
                assert!(s.cancel.borrow().is_cancelled());
                assert!(!s.valid.get());
                assert!(!s.apply.is_sensitive());
                stage.set(3);
            }
            3 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s
                    .status
                    .text()
                    .contains(s.lang().text("geändert", "changed")));
                if !support::try_capture(&s.window, "git-push-revision-cancelled") {
                    return glib::ControlFlow::Continue;
                }
                s.window.close();
                project_view::open_path(&ui, f.root.clone());
                stage.set(4);
            }
            4 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                let next = open(&ui, "/usr/bin/git".into(), f.root.clone());
                let old = next.owner.project.as_ref().unwrap().owner_id();
                project_view::open_path(&ui, f._temp.path().to_owned());
                assert!(!next.valid.get());
                assert!(next.cancel.borrow().is_cancelled());
                project_view::open_path(&ui, f.root.clone());
                assert!(!next.valid.get());
                assert!(!next.inspect.is_sensitive());
                assert!(next.owner.project.as_ref().unwrap().owner_id() == old);
                next.window.present();
                let ui = ui.clone();
                let f = f.clone();
                let window = next.window.clone();
                support::background(
                    move || {
                        assert_eq!(git(&f.bare, &["rev-parse", "main"]), f.head);
                        Ok(())
                    },
                    move |r| {
                        r.unwrap();
                        println!("PASS Git push ownership: running hook cancelled synchronously by revision change; no delayed completion adoption; project A-B-A invalidates synchronously and stays invalid");
                        support::finish(window, ui, "git-push");
                    },
                );
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
