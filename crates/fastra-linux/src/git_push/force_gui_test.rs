use super::*;
use std::{fs, process::Command, time::Instant};
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
fn commit(root: &std::path::Path, message: &str) {
    fs::write(root.join("file"), message).unwrap();
    git(root, &["add", "file"]);
    git(root, &["commit", "-qm", message]);
}
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    bare: PathBuf,
    source: Vec<u8>,
    old: Vec<u8>,
    initial: Vec<u8>,
    index: Vec<u8>,
    config: Vec<u8>,
    head: Vec<u8>,
}
fn button(widget: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(b) = widget
        .downcast_ref::<gtk::Button>()
        .filter(|b| b.label().as_deref() == Some(label))
    {
        return Some(b.clone());
    }
    let mut child = widget.first_child();
    while let Some(w) = child {
        if let Some(b) = button(&w, label) {
            return Some(b);
        }
        child = w.next_sibling();
    }
    None
}
fn warning(s: &State, accept: bool) -> Option<(gtk::Window, gtk::Button)> {
    let label = if accept {
        s.lang().text("Mit Lease erzwingen", "Force with lease")
    } else {
        s.lang().text("Abbrechen", "Cancel")
    };
    gtk::Window::list_toplevels()
        .iter()
        .filter_map(|w| w.clone().downcast::<gtk::Window>().ok())
        .filter(|w| w.is_visible() && w.is_modal() && w != &s.window)
        .find_map(|w| button(w.upcast_ref(), label).map(|b| (w, b)))
}
fn text(s: &State) -> String {
    let b = s.output.buffer();
    b.text(&b.start_iter(), &b.end_iter(), true).into()
}
fn oid(bytes: &[u8]) -> &str {
    std::str::from_utf8(bytes).unwrap().trim()
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
            commit(&root, "initial");
            let initial = git(&root, &["rev-parse", "HEAD"]);
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
            commit(&root, "remote-one");
            commit(&root, "remote-two");
            git(&root, &["push", "origin", "main"]);
            let old = git(&root, &["rev-parse", "HEAD"]);
            git(&root, &["reset", "--hard", oid(&initial)]);
            commit(&root, "local-one");
            commit(&root, "local-two");
            let source = git(&root, &["rev-parse", "HEAD"]);
            let index = fs::read(root.join(".git/index")).unwrap();
            let config = fs::read(root.join(".git/config")).unwrap();
            let head = fs::read(root.join(".git/HEAD")).unwrap();
            Ok(Fixture {
                _temp: temp,
                root,
                bare,
                source,
                old,
                initial,
                index,
                config,
                head,
            })
        },
        move |r| check(ui, std::sync::Arc::new(r.unwrap())),
    );
}
fn check(ui: Rc<Ui>, f: std::sync::Arc<Fixture>) {
    let s = open(&ui, "/usr/bin/git".into(), f.root.clone());
    if let Ok(width) = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or_default()
        .parse::<i32>()
    {
        s.window.set_default_size(width, 740);
    }
    let stage = Cell::new(0);
    let ready = Rc::new(Cell::new(false));
    let started = Instant::now();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "force GUI timeout {}: {} / {}",
            stage.get(),
            s.status.text(),
            text(&s)
        );
        match stage.get() {
            0 => {
                if s.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.force_mode.is_active());
                support::test_click(&s.inspect, &[]);
                stage.set(1);
            }
            1 => {
                if s.busy.get() || s.preview.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.apply.is_sensitive());
                assert!(!s.preview.borrow().as_ref().unwrap().force_with_lease());
                support::test_click(&s.force_mode, &[]);
                stage.set(101);
            }
            101 => {
                if !s.force_mode.is_active() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_none());
                support::test_click(&s.inspect, &[]);
                stage.set(2);
            }
            2 => {
                if s.busy.get() || !s.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                let t = text(&s);
                for value in [
                    "local-one",
                    "local-two",
                    "remote-one",
                    "remote-two",
                    oid(&f.source),
                    oid(&f.old),
                ] {
                    assert!(t.contains(value), "{value}: {t}");
                }
                assert!(s.preview.borrow().as_ref().unwrap().force_with_lease());
                if !support::try_capture(&s.window, "git-force-preview") {
                    return glib::ControlFlow::Continue;
                }
                // Sichtbarer Moduswechsel verwirft auch eine bereits gültige Vorschau.
                support::test_click(&s.force_mode, &[]);
                stage.set(102);
            }
            102 => {
                if s.force_mode.is_active() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_none() && !s.apply.is_sensitive());
                support::test_click(&s.force_mode, &[]);
                stage.set(103);
            }
            103 => {
                if !s.force_mode.is_active() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.inspect, &[]);
                stage.set(3);
            }
            3 => {
                if s.busy.get() || !s.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.apply, &[]);
                stage.set(4);
            }
            4 => {
                let Some((w, b)) = warning(&s, false) else {
                    return glib::ControlFlow::Continue;
                };
                assert!(s.confirming.get() && s.preview.borrow().is_none());
                if !support::try_capture(&w, "git-force-warning-cancel") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&b, &[]);
                stage.set(5);
            }
            5 => {
                if s.confirming.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.busy.get() && !s.apply.is_sensitive());
                let bare = f.bare.clone();
                let expected = f.old.clone();
                let r = ready.clone();
                support::background(
                    move || {
                        assert_eq!(git(&bare, &["rev-parse", "main"]), expected);
                        Ok(())
                    },
                    move |v| {
                        v.unwrap();
                        r.set(true);
                    },
                );
                stage.set(6);
            }
            6 => {
                if !ready.get() {
                    return glib::ControlFlow::Continue;
                }
                ready.set(false);
                support::test_click(&s.inspect, &[]);
                stage.set(7);
            }
            7 => {
                if s.busy.get() || !s.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.apply, &[]);
                stage.set(8);
            }
            8 => {
                let Some((w, b)) = warning(&s, true) else {
                    return glib::ControlFlow::Continue;
                };
                if !support::try_capture(&w, "git-force-warning-apply") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&b, &[]);
                stage.set(9);
            }
            9 => {
                if s.busy.get() || s.confirming.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    s.status
                        .text()
                        .contains(s.lang().text("abgeschlossen", "completed")),
                    "{}",
                    text(&s)
                );
                if !support::try_capture(&s.window, "git-force-success") {
                    return glib::ControlFlow::Continue;
                }
                let root = f.root.clone();
                let bare = f.bare.clone();
                let source = f.source.clone();
                let old = f.old.clone();
                let r = ready.clone();
                support::background(
                    move || {
                        assert_eq!(git(&bare, &["rev-parse", "main"]), source);
                        git(&bare, &["update-ref", "refs/heads/main", oid(&old)]);
                        assert!(!root.join(".git/FETCH_HEAD").exists());
                        Ok(())
                    },
                    move |v| {
                        v.unwrap();
                        r.set(true);
                    },
                );
                stage.set(10);
            }
            10 => {
                if !ready.get() {
                    return glib::ControlFlow::Continue;
                }
                ready.set(false);
                support::test_click(&s.inspect, &[]);
                stage.set(11);
            }
            11 => {
                if s.busy.get() || !s.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.apply, &[]);
                stage.set(12);
            }
            12 => {
                if warning(&s, true).is_none() {
                    return glib::ControlFlow::Continue;
                }
                let bare = f.bare.clone();
                let initial = f.initial.clone();
                let r = ready.clone();
                support::background(
                    move || {
                        git(&bare, &["update-ref", "refs/heads/main", oid(&initial)]);
                        Ok(())
                    },
                    move |v| {
                        v.unwrap();
                        r.set(true);
                    },
                );
                stage.set(13);
            }
            13 => {
                if !ready.get() {
                    return glib::ControlFlow::Continue;
                }
                ready.set(false);
                let Some((_, b)) = warning(&s, true) else {
                    return glib::ControlFlow::Continue;
                };
                support::test_click(&b, &[]);
                stage.set(14);
            }
            14 => {
                if s.busy.get() || s.confirming.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(text(&s).contains("stale info"), "{}", text(&s));
                if !support::try_capture(&s.window, "git-force-remote-drift") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.inspect, &[]);
                stage.set(15);
            }
            15 => {
                if s.busy.get() || !s.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.apply, &[]);
                stage.set(16);
            }
            16 => {
                if warning(&s, true).is_none() {
                    return glib::ControlFlow::Continue;
                }
                // Programmatische Benachrichtigung während modalem Dialog schützt auch ABA.
                s.force_mode.set_active(false);
                s.force_mode.set_active(true);
                assert!(!s.confirming.get() && s.warning.borrow().is_none());
                stage.set(17);
            }
            17 => {
                if warning(&s, true).is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.busy.get() && !s.apply.is_sensitive());
                support::test_click(&s.inspect, &[]);
                stage.set(18);
            }
            18 => {
                if s.busy.get() || !s.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.apply, &[]);
                stage.set(19);
            }
            19 => {
                if warning(&s, true).is_none() {
                    return glib::ControlFlow::Continue;
                }
                ui.add_document("new-owner.txt", "untouched editor");
                assert!(!s.valid.get() && !s.confirming.get() && s.warning.borrow().is_none());
                stage.set(20);
            }
            20 => {
                if warning(&s, true).is_some() {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(&s.window, "git-force-owner-stale") {
                    return glib::ControlFlow::Continue;
                }
                let keep_fixture = f.clone();
                let bare = f.bare.clone();
                let expected = f.initial.clone();
                let root = f.root.clone();
                let source = f.source.clone();
                let index = f.index.clone();
                let config = f.config.clone();
                let head = f.head.clone();
                let window = s.window.clone();
                let ui = ui.clone();
                support::background(
                    move || {
                        let _keep_fixture = keep_fixture;
                        assert_eq!(git(&bare, &["rev-parse", "main"]), expected);
                        assert_eq!(git(&root, &["rev-parse", "HEAD"]), source);
                        assert_eq!(fs::read(root.join(".git/index")).unwrap(), index);
                        assert_eq!(fs::read(root.join(".git/config")).unwrap(), config);
                        assert_eq!(fs::read(root.join(".git/HEAD")).unwrap(), head);
                        assert_eq!(fs::read(root.join("file")).unwrap(), b"local-two");
                        Ok(())
                    },
                    move |v| {
                        v.unwrap();
                        println!("PASS Force GUI: normal divergence refused; default off; complete outgoing/removed OIDs; mode invalidation; native warning Cancel consumes/nochange; fresh warning Apply exact; remote drift CAS rejected; mode ABA/owner cancels warning; local HEAD/index/worktree/config preserved");
                        support::finish(window, ui, "git-force-push");
                    },
                );
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
