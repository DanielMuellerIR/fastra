use super::*;
use std::{fs, os::unix::fs::PermissionsExt, process::Command, sync::Arc, time::Instant};
fn git(p: &std::path::Path, a: &[&str]) -> Vec<u8> {
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
fn exe(p: &std::path::Path, s: &str) {
    fs::write(p, s).unwrap();
    fs::set_permissions(p, fs::Permissions::from_mode(0o700)).unwrap();
}
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    head: Vec<u8>,
    tree: Vec<u8>,
    index: Vec<u8>,
    marker: PathBuf,
}
fn collect(w: &gtk::Widget, out: &mut Vec<gtk::Widget>) {
    out.push(w.clone());
    let mut child = w.first_child();
    while let Some(w) = child {
        child = w.next_sibling();
        collect(&w, out);
    }
}
fn button(w: &impl IsA<gtk::Widget>, text: &str) -> gtk::Button {
    let mut all = Vec::new();
    collect(w.upcast_ref(), &mut all);
    all.into_iter()
        .filter_map(|w| w.downcast::<gtk::Button>().ok())
        .find(|b| b.label().as_deref() == Some(text))
        .unwrap()
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    support::background(
        move || {
            let temp = tempfile::tempdir().unwrap();
            let root = temp.path().join("work");
            fs::create_dir(&root).unwrap();
            for a in [
                &["init", "-q", "-b", "main"][..],
                &["config", "user.name", "Fixture"],
                &["config", "user.email", "fixture@example.invalid"],
            ] {
                git(&root, a);
            }
            fs::write(root.join("file"), "initial\n").unwrap();
            fs::write(root.join("other"), "stable\n").unwrap();
            git(&root, &["add", "."]);
            git(&root, &["commit", "-qm", "initial"]);
            let head = git(&root, &["rev-parse", "HEAD"])
                .strip_suffix(b"\n")
                .unwrap()
                .to_vec();
            fs::write(root.join("file"), "approved\n").unwrap();
            git(&root, &["add", "file"]);
            let tree = git(&root, &["write-tree"])
                .strip_suffix(b"\n")
                .unwrap()
                .to_vec();
            let index = fs::read(root.join(".git/index")).unwrap();
            let marker = root.join(".git/cancel-ready");
            let doc = fastra_document::Document::open(
                &root.join("file"),
                None,
                &fastra_core::Cancellation::default(),
            )
            .unwrap();
            let fastra_document::Document::Text(doc) = doc else {
                panic!("text");
            };
            Ok((
                Fixture {
                    _temp: temp,
                    root,
                    head,
                    tree,
                    index,
                    marker,
                },
                doc,
            ))
        },
        move |r| {
            let (f, d) = r.unwrap();
            check(ui, f, d);
        },
    );
}
fn check(ui: Rc<Ui>, fixture: Fixture, text: fastra_document::TextDocument) {
    let fixture = Arc::new(fixture);
    let doc = ui.add_loaded_text(
        "file",
        Arc::new(text.decoded().clone()),
        text.snapshot().clone(),
    );
    doc.buffer.set_text("unsaved editor stays\n");
    doc.buffer.set_modified(true);
    let revision = doc.revision.get();
    let _read = support::open(&ui, "/usr/bin/git".into());
    let read = ui
        .window
        .application()
        .unwrap()
        .windows()
        .into_iter()
        .find(|w| w.title().as_deref() == Some(ui.lang.text("Git · Lesen", "Git · Read")))
        .unwrap();
    let mut all = Vec::new();
    collect(read.upcast_ref(), &mut all);
    all.iter()
        .find_map(|w| w.downcast_ref::<gtk::Entry>())
        .unwrap()
        .set_text(fixture.root.to_str().unwrap());
    let entry = button(&read, ui.lang.text("Commit erstellen …", "Create commit …"));
    let state = RefCell::<Option<Rc<State>>>::new(None);
    let stage = Cell::new(0);
    let logged = Cell::new(u32::MAX);
    let started = Instant::now();
    let index_after_staging = Rc::new(RefCell::<Vec<u8>>::new(Vec::new()));
    let calls = Rc::new(Cell::new(0));
    let observed = calls.clone();
    let expected = fixture.root.clone();
    git_fetch::observe(&ui.window.clone().upcast(), move |root, _| {
        if root == expected {
            observed.set(observed.get() + 1);
        }
    });
    glib::timeout_add_local(Duration::from_millis(80), move || {
        if logged.replace(stage.get()) != stage.get() {
            println!("COMMIT_GUI_STAGE {}", stage.get());
        }
        assert!(
            started.elapsed() < Duration::from_secs(85),
            "commit GUI timeout {}",
            stage.get()
        );
        if stage.get() == 0 {
            if !entry.is_mapped() {
                return glib::ControlFlow::Continue;
            }
            if !support::try_capture(&read, "git-commit-entry") {
                return glib::ControlFlow::Continue;
            }
            support::test_click(&entry, &[]);
            stage.set(1);
            return glib::ControlFlow::Continue;
        }
        if state.borrow().is_none() {
            let found = DIALOGS.with_borrow(|all| all.iter().rev().find_map(Weak::upgrade));
            let Some(s) = found else {
                return glib::ControlFlow::Continue;
            };
            if let Ok(w) = std::env::var("FASTRA_TOOL_WIDTH")
                .unwrap_or_default()
                .parse::<i32>()
            {
                s.window.set_default_size(w, 900);
            }
            *state.borrow_mut() = Some(s);
        }
        let s = state.borrow().as_ref().unwrap().clone();
        let out = || {
            let b = s.output.buffer();
            b.text(&b.start_iter(), &b.end_iter(), true).to_string()
        };
        let idle = || s.job.get().is_none();
        match stage.get() {
            1 => {
                if !idle() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                s.message
                    .buffer()
                    .set_text("approved · Grüße 🚀\n\ncomplete body\n");
                if !support::try_capture(&s.window, "git-commit-loaded") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.prepare, &[]);
                stage.set(2);
            }
            2 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", out());
                assert!(out().contains(&visible(&fixture.head)));
                assert!(out().contains(&visible(&fixture.tree)));
                assert!(out().contains("Fixture <fixture@example.invalid>"));
                assert!(out().contains("complete body"));
                assert!(out().contains("+approved"));
                if !support::try_capture(&s.window, "git-commit-preview") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.approved, &[]);
                stage.set(3);
            }
            3 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                s.message.buffer().set_text("changed message\n");
                assert!(s.preview.borrow().is_none());
                assert!(!s.approved.is_active());
                assert!(!s.start.is_sensitive());
                s.message
                    .buffer()
                    .set_text("approved · Grüße 🚀\n\ncomplete body\n");
                support::test_click(&s.prepare, &[]);
                stage.set(4);
            }
            4 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", out());
                support::test_click(&s.approved, &[]);
                stage.set(5);
            }
            5 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                ui.add_document("other-owner", "temporary");
                ui.tabs.set_current_page(Some(1));
                assert!(s.owner.borrow().is_none());
                assert!(s.preview.borrow().is_none());
                assert!(!s.start.is_sensitive());
                stage.set(6);
            }
            6 => {
                if !support::try_capture(&s.window, "git-commit-owner-aba") {
                    return glib::ControlFlow::Continue;
                }
                project_view::open_path(&ui, fixture.root.clone());
                stage.set(7);
            }
            7 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                for w in ui.window.application().unwrap().windows() {
                    if w.title().as_deref() == Some(ui.lang.text("Projektdateien", "Project files"))
                    {
                        w.set_visible(false);
                    }
                }
                s.window.present();
                support::test_click(&s.reload, &[]);
                stage.set(8);
            }
            8 => {
                if !idle() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.prepare, &[]);
                stage.set(9);
            }
            9 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", out());
                support::test_click(&s.approved, &[]);
                stage.set(10);
            }
            10 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                project_view::open_path(&ui, fixture.root.parent().unwrap().to_owned());
                project_view::open_path(&ui, fixture.root.clone());
                assert!(s.owner.borrow().is_none());
                assert!(s.preview.borrow().is_none());
                assert!(!s.start.is_sensitive());
                stage.set(11);
            }
            11 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                for w in ui.window.application().unwrap().windows() {
                    if w.title().as_deref() == Some(ui.lang.text("Projektdateien", "Project files"))
                    {
                        w.set_visible(false);
                    }
                }
                s.window.present();
                if !support::try_capture(&s.window, "git-commit-project-aba") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.reload, &[]);
                stage.set(12);
            }
            12 => {
                if !idle() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.prepare, &[]);
                stage.set(13);
            }
            13 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", out());
                support::test_click(&s.approved, &[]);
                stage.set(14);
            }
            14 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                let f = fixture.clone();
                let s = s.clone();
                let index = index_after_staging.clone();
                support::background(
                    move || {
                        fs::write(f.root.join("other"), "later staging\n").unwrap();
                        git(&f.root, &["add", "other"]);
                        fs::write(f.root.join("other"), "later dirty\n").unwrap();
                        Ok(fs::read(f.root.join(".git/index")).unwrap())
                    },
                    move |r| {
                        *index.borrow_mut() = r.unwrap();
                        support::test_click(&s.start, &[]);
                    },
                );
                stage.set(15);
            }
            15 => {
                if !idle() || s.preview.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    s.status
                        .text()
                        .contains(s.lang().text("Commit bestätigt", "Commit confirmed")),
                    "{} {}",
                    s.status.text(),
                    out()
                );
                assert!(out().contains(s.lang().text("Validierter Commit", "Validated commit")));
                assert!(!s.approved.is_active());
                assert!(!s.start.is_sensitive());
                assert_eq!(
                    super::super::buffer_text(&doc.buffer),
                    "unsaved editor stays\n"
                );
                assert!(doc.buffer.is_modified());
                assert_eq!(doc.revision.get(), revision);
                assert_eq!(calls.get(), 1);
                if !support::try_capture(&s.window, "git-commit-success") {
                    return glib::ControlFlow::Continue;
                }
                let f = fixture.clone();
                let index = index_after_staging.borrow().clone();
                let s = s.clone();
                support::background(
                    move || {
                        assert_eq!(fs::read(f.root.join(".git/index")).unwrap(), index);
                        assert_ne!(index, f.index);
                        assert_eq!(
                            git(&f.root, &["rev-parse", "HEAD^{tree}"])
                                .strip_suffix(b"\n")
                                .unwrap(),
                            f.tree
                        );
                        assert_eq!(fs::read(f.root.join("other")).unwrap(), b"later dirty\n");
                        exe(
                            &f.root.join(".git/hooks/pre-commit"),
                            "#!/bin/sh\nprintf 'hook tree\\n' > file\ngit add file\n",
                        );
                        Ok(())
                    },
                    move |r| {
                        r.unwrap();
                        s.load();
                    },
                );
                stage.set(16);
            }
            16 => {
                if !idle() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                s.message
                    .buffer()
                    .set_text("hook must not change approved tree\n");
                support::test_click(&s.prepare, &[]);
                stage.set(17);
            }
            17 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", out());
                support::test_click(&s.approved, &[]);
                stage.set(18);
            }
            18 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.start, &[]);
                stage.set(19);
            }
            19 => {
                if !idle() || !out().contains("tree differs") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.approved.is_active());
                assert!(!s.start.is_sensitive());
                assert_eq!(
                    super::super::buffer_text(&doc.buffer),
                    "unsaved editor stays\n"
                );
                assert_eq!(doc.revision.get(), revision);
                let review = button(
                    &doc.container,
                    ui.lang
                        .text("Externe Änderung prüfen …", "Review external change …"),
                );
                if !review.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(&s.window, "git-commit-hook-rejected") {
                    return glib::ControlFlow::Continue;
                }
                let f = fixture.clone();
                let index = index_after_staging.borrow().clone();
                let s = s.clone();
                support::background(
                    move || {
                        assert_eq!(fs::read(f.root.join(".git/index")).unwrap(), index);
                        assert_eq!(
                            git(&f.root, &["rev-parse", "HEAD^{tree}"])
                                .strip_suffix(b"\n")
                                .unwrap(),
                            f.tree
                        );
                        fs::remove_file(f.root.join(".git/hooks/pre-commit")).unwrap();
                        exe(&f.root.join(".git/hooks/pre-commit"),"#!/bin/sh\necho commit-cancel-ready >&2\ntouch .git/cancel-ready\nsleep 30\n");
                        Ok(())
                    },
                    move |r| {
                        r.unwrap();
                        s.load();
                    },
                );
                stage.set(20);
            }
            20 => {
                if !idle() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                s.message.buffer().set_text("cancel native hook\n");
                support::test_click(&s.prepare, &[]);
                stage.set(21);
            }
            21 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", out());
                assert!(!fixture.marker.exists(), "preview ran original hook");
                support::test_click(&s.approved, &[]);
                stage.set(22);
            }
            22 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.start, &[]);
                stage.set(23);
            }
            23 => {
                if !fixture.marker.exists() || !out().contains("commit-cancel-ready") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!idle());
                if !support::try_capture(&s.window, "git-commit-live") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.cancel, &[]);
                stage.set(24);
            }
            24 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    out().contains(s.lang().text("abgebrochen", "cancelled")),
                    "{}",
                    out()
                );
                assert!(!s.start.is_sensitive());
                assert!(s.preview.borrow().is_none());
                assert_eq!(calls.get(), 3);
                assert_eq!(
                    super::super::buffer_text(&doc.buffer),
                    "unsaved editor stays\n"
                );
                assert_eq!(doc.revision.get(), revision);
                if !support::try_capture(&s.window, "git-commit-cancelled") {
                    return glib::ControlFlow::Continue;
                }
                let f = fixture.clone();
                let expected = index_after_staging.borrow().clone();
                let ui = ui.clone();
                let w = s.window.clone();
                support::background(
                    move || {
                        assert_eq!(fs::read(f.root.join(".git/index")).unwrap(), expected);
                        assert_eq!(
                            git(&f.root, &["rev-parse", "HEAD^{tree}"])
                                .strip_suffix(b"\n")
                                .unwrap(),
                            f.tree
                        );
                        assert!(!f.root.join(".git/index.lock").exists());
                        Ok(())
                    },
                    move |r| {
                        r.unwrap();
                        println!("PASS commit GUI: native entry; complete tree/parents/identities/message/diff; input invalidation; owner/project ABA; consumed approval; exact normal private-index commit; later staging and dirty editor retained; original hook tree rejection; watcher review; live native hook cancellation; actual scan and three refreshes");
                        support::finish(w, ui, "git-commit");
                    },
                );
                stage.set(25);
            }
            25 => return glib::ControlFlow::Break,
            _ => unreachable!(),
        };
        glib::ControlFlow::Continue
    });
}
