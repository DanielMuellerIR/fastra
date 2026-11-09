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
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    target: Vec<u8>,
    source: Vec<u8>,
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
        .unwrap_or_else(|| panic!("button {text}"))
}
fn review_window(ui: &Ui) -> Option<gtk::Window> {
    ui.window
        .application()
        .unwrap()
        .windows()
        .into_iter()
        .find(|w| {
            w.title().as_deref()
                == Some(
                    ui.lang
                        .text("Externe Änderung prüfen", "Review external change"),
                )
        })
}
fn review_controls(w: &gtk::Window) -> (gtk::CheckButton, gtk::Button) {
    let mut all = Vec::new();
    collect(w.upcast_ref(), &mut all);
    let c = all
        .iter()
        .find_map(|w| w.downcast_ref::<gtk::CheckButton>())
        .unwrap()
        .clone();
    let b = all
        .iter()
        .filter_map(|w| w.downcast_ref::<gtk::Button>())
        .find(|b| {
            b.label().as_deref() == Some("Neu laden") || b.label().as_deref() == Some("Reload")
        })
        .unwrap()
        .clone();
    (c, b)
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
                &["config", "user.name", "Synthetic"],
                &["config", "user.email", "test@example.invalid"],
                &["config", "commit.gpgsign", "false"],
            ] {
                git(&root, a);
            }
            fs::write(root.join("file"), "main\n").unwrap();
            git(&root, &["add", "."]);
            git(&root, &["commit", "-qm", "main"]);
            let source = git(&root, &["rev-parse", "HEAD"])
                .strip_suffix(b"\n")
                .unwrap()
                .to_vec();
            git(&root, &["switch", "-c", "target"]);
            fs::write(root.join("file"), "target\n").unwrap();
            git(&root, &["commit", "-qam", "target"]);
            let target = git(&root, &["rev-parse", "HEAD"])
                .strip_suffix(b"\n")
                .unwrap()
                .to_vec();
            git(&root, &["branch", "other", "main"]);
            git(&root, &["switch", "main"]);
            let marker = root.join(".git/hook-started");
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
                    target,
                    source,
                    marker,
                },
                doc,
            ))
        },
        move |result| {
            let (fixture, doc) = result.unwrap();
            check(ui, fixture, doc);
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
    doc.buffer.set_text("unsaved buffer stays\n");
    doc.buffer.set_modified(true);
    let revision = doc.revision.get();
    let read = support::open(&ui, "/usr/bin/git".into());
    let read_window = ui
        .window
        .application()
        .unwrap()
        .windows()
        .into_iter()
        .find(|w| w.title().as_deref() == Some(ui.lang.text("Git · Lesen", "Git · Read")))
        .unwrap();
    let mut all = Vec::new();
    collect(read_window.upcast_ref(), &mut all);
    all.iter()
        .find_map(|w| w.downcast_ref::<gtk::Entry>())
        .unwrap()
        .set_text(fixture.root.to_str().unwrap());
    let entry = button(
        &read_window,
        ui.lang.text("Branch wechseln …", "Switch branch …"),
    );
    let state = RefCell::<Option<Rc<State>>>::new(None);
    let stage = Cell::new(0);
    let logged_stage = Cell::new(u32::MAX);
    let started = Instant::now();
    let review = RefCell::<Option<gtk::Window>>::new(None);
    let observer_calls = Rc::new(Cell::new(0));
    let observed = observer_calls.clone();
    let expected = fixture.root.clone();
    git_fetch::observe(&ui.window.clone().upcast(), move |r, _| {
        if r == expected {
            observed.set(observed.get() + 1);
        }
    });
    let _keep = read;
    glib::timeout_add_local(Duration::from_millis(70), move || {
        if logged_stage.replace(stage.get()) != stage.get() {
            println!("SWITCH_GUI_STAGE {}", stage.get());
        }
        assert!(
            started.elapsed() < Duration::from_secs(80),
            "switch GUI timeout {}",
            stage.get()
        );
        if stage.get() == 0 {
            if !entry.is_mapped() {
                return glib::ControlFlow::Continue;
            }
            if !support::try_capture(&read_window, "git-switch-entry") {
                return glib::ControlFlow::Continue;
            }
            support::test_click(&entry, &[]);
            stage.set(1);
            return glib::ControlFlow::Continue;
        }
        if state.borrow().is_none() {
            let s = DIALOGS.with_borrow(|all| all.iter().rev().find_map(Weak::upgrade));
            let Some(s) = s else {
                return glib::ControlFlow::Continue;
            };
            if let Ok(w) = std::env::var("FASTRA_TOOL_WIDTH")
                .unwrap_or_default()
                .parse::<i32>()
            {
                s.window.set_default_size(w, 850);
            }
            *state.borrow_mut() = Some(s);
        }
        let s = state.borrow().as_ref().unwrap().clone();
        let out = || {
            let b = s.output.buffer();
            b.text(&b.start_iter(), &b.end_iter(), true).to_string()
        };
        let idle = || s.job.get().is_none();
        let select = |name: &[u8]| {
            let index = s.targets.borrow().iter().position(|n| n == name).unwrap();
            s.target.set_selected(index as u32);
        };
        match stage.get() {
            1 => {
                if !idle() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                select(b"refs/heads/target");
                if !support::try_capture(&s.window, "git-switch-loaded") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.start.is_sensitive());
                support::test_click(&s.prepare, &[]);
                stage.set(2);
            }
            2 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", out());
                assert!(out().contains(&visible(&fixture.source)));
                assert!(out().contains(&visible(&fixture.target)));
                assert!(out().contains("+target"));
                if !support::try_capture(&s.window, "git-switch-preview") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.approved, &[]);
                stage.set(3);
            }
            3 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                select(b"refs/heads/other");
                assert!(s.preview.borrow().is_none());
                assert!(!s.approved.is_active());
                assert!(!s.start.is_sensitive());
                select(b"refs/heads/target");
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
                support::test_click(&s.start, &[]);
                stage.set(6);
            }
            6 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    s.status.text().contains(
                        s.lang()
                            .text("Zielbranch bestätigt", "Target branch confirmed")
                    ),
                    "{} {}",
                    s.status.text(),
                    out()
                );
                assert!(out().contains(&visible(&fixture.target)));
                assert_eq!(doc.revision.get(), revision);
                assert!(doc.buffer.is_modified());
                assert_eq!(
                    super::super::buffer_text(&doc.buffer),
                    "unsaved buffer stays\n"
                );
                assert_eq!(observer_calls.get(), 1);
                if !support::try_capture(&s.window, "git-switch-success") {
                    return glib::ControlFlow::Continue;
                }
                let b = button(
                    &doc.container,
                    ui.lang
                        .text("Externe Änderung prüfen …", "Review external change …"),
                );
                if !b.is_sensitive() || !b.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                s.window.set_visible(false);
                read_window.set_visible(false);
                ui.window.present();
                stage.set(60);
            }
            60 => {
                let b = button(
                    &doc.container,
                    ui.lang
                        .text("Externe Änderung prüfen …", "Review external change …"),
                );
                if !b.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(&ui.window.clone().upcast(), "git-switch-editor-retained")
                {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&b, &[]);
                stage.set(7);
            }
            7 => {
                let Some(w) = review_window(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                if !support::try_capture(&w, "git-switch-reload-review") {
                    return glib::ControlFlow::Continue;
                }
                let (c, _) = review_controls(&w);
                support::test_click(&c, &[]);
                *review.borrow_mut() = Some(w);
                stage.set(8);
            }
            8 => {
                let w = review.borrow().as_ref().unwrap().clone();
                let (c, b) = review_controls(&w);
                if !c.is_active() {
                    return glib::ControlFlow::Continue;
                }
                doc.buffer.set_text("changed while reviewing\n");
                support::test_click(&b, &[]);
                assert_eq!(
                    super::super::buffer_text(&doc.buffer),
                    "changed while reviewing\n"
                );
                stage.set(80);
            }
            80 => {
                let w = review.borrow().as_ref().unwrap().clone();
                let mut all = Vec::new();
                collect(w.upcast_ref(), &mut all);
                if !all
                    .iter()
                    .filter_map(|w| w.downcast_ref::<gtk::Label>())
                    .any(|l| {
                        l.text()
                            .contains(ui.lang.text("Vorschau veraltet", "Preview stale"))
                    })
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    super::super::buffer_text(&doc.buffer),
                    "changed while reviewing\n"
                );
                if !support::try_capture(&w, "git-switch-reload-stale") {
                    return glib::ControlFlow::Continue;
                }
                w.close();
                stage.set(9);
            }
            9 => {
                let b = button(
                    &doc.container,
                    ui.lang
                        .text("Externe Änderung prüfen …", "Review external change …"),
                );
                if !b.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&b, &[]);
                stage.set(10);
            }
            10 => {
                let Some(w) = review_window(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                if !support::try_capture(&w, "git-switch-reload-fresh") {
                    return glib::ControlFlow::Continue;
                }
                let (c, _) = review_controls(&w);
                support::test_click(&c, &[]);
                *review.borrow_mut() = Some(w);
                stage.set(11);
            }
            11 => {
                let w = review.borrow().as_ref().unwrap().clone();
                let (c, b) = review_controls(&w);
                if !c.is_active() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&b, &[]);
                stage.set(12);
            }
            12 => {
                if super::super::buffer_text(&doc.buffer) != "target\n" {
                    return glib::ControlFlow::Continue;
                }
                assert!(!doc.buffer.is_modified());
                s.window.close();
                let fresh = open(&ui, "/usr/bin/git".into(), fixture.root.clone());
                if let Ok(width) = std::env::var("FASTRA_TOOL_WIDTH")
                    .unwrap_or_default()
                    .parse::<i32>()
                {
                    fresh.window.set_default_size(width, 850);
                }
                *state.borrow_mut() = Some(fresh);
                stage.set(13);
            }
            13 => {
                if !idle() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                select(b"refs/heads/main");
                support::test_click(&s.prepare, &[]);
                stage.set(14);
            }
            14 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some());
                support::test_click(&s.approved, &[]);
                stage.set(15);
            }
            15 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                ui.add_document("other-owner", "temporary");
                ui.tabs.set_current_page(Some(1));
                assert!(s.owner.borrow().is_none());
                assert!(s.preview.borrow().is_none());
                assert!(!s.start.is_sensitive());
                stage.set(150);
            }
            150 => {
                if !support::try_capture(&s.window, "git-switch-owner-aba") {
                    return glib::ControlFlow::Continue;
                }
                project_view::open_path(&ui, fixture.root.clone());
                stage.set(151);
            }
            151 => {
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
                stage.set(16);
            }
            16 => {
                if !idle() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                select(b"refs/heads/main");
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
                assert!(project_view::current_binding(&ui).is_some());
                project_view::open_path(&ui, fixture.root.parent().unwrap().to_owned());
                project_view::open_path(&ui, fixture.root.clone());
                assert!(s.owner.borrow().is_none());
                assert!(s.preview.borrow().is_none());
                assert!(!s.start.is_sensitive());
                stage.set(180);
            }
            180 => {
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
                if !support::try_capture(&s.window, "git-switch-project-aba") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&s.reload, &[]);
                stage.set(181);
            }
            181 => {
                if !idle() || s.loaded.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                select(b"refs/heads/main");
                support::test_click(&s.prepare, &[]);
                stage.set(182);
            }
            182 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", out());
                support::test_click(&s.approved, &[]);
                stage.set(183);
            }
            183 => {
                if !s.approved.is_active() {
                    return glib::ControlFlow::Continue;
                }
                let f = fixture.clone();
                let s = s.clone();
                support::background(
                    move || {
                        fs::write(f.root.join(".git/HEAD.lock"), "external lock").unwrap();
                        Ok(())
                    },
                    move |r| {
                        r.unwrap();
                        s.start.emit_clicked();
                    },
                );
                stage.set(19);
            }
            19 => {
                if !idle() || !out().contains("HEAD.lock") {
                    return glib::ControlFlow::Continue;
                }
                assert!(out().contains("-target"));
                assert!(out().contains("+main"));
                assert!(!s.start.is_sensitive());
                if !support::try_capture(&s.window, "git-switch-partial-error") {
                    return glib::ControlFlow::Continue;
                }
                let f = fixture.clone();
                let s = s.clone();
                support::background(
                    move || {
                        fs::remove_file(f.root.join(".git/HEAD.lock")).unwrap();
                        let hook = f.root.join(".git/hooks/post-checkout");
                        fs::write(
                            &hook,
                            format!(
                                "#!/bin/sh\necho native-cancel-ready >&2\ntouch '{}'\nsleep 30\n",
                                f.marker.display()
                            ),
                        )
                        .unwrap();
                        fs::set_permissions(hook, fs::Permissions::from_mode(0o700)).unwrap();
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
                select(b"refs/heads/main");
                support::test_click(&s.prepare, &[]);
                stage.set(21);
            }
            21 => {
                if !idle() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", out());
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
                if !fixture.marker.exists() || !out().contains("native-cancel-ready") {
                    return glib::ControlFlow::Continue;
                }
                assert!(!idle());
                if !support::try_capture(&s.window, "git-switch-live") {
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
                assert!(out().contains(&visible(&fixture.source)));
                assert!(s.preview.borrow().is_none());
                assert!(!s.approved.is_active());
                assert!(!s.start.is_sensitive());
                assert_eq!(observer_calls.get(), 3);
                if !support::try_capture(&s.window, "git-switch-cancelled") {
                    return glib::ControlFlow::Continue;
                }
                let f = fixture.clone();
                let ui = ui.clone();
                let w = s.window.clone();
                support::background(
                    move || {
                        assert_eq!(
                            git(&f.root, &["symbolic-ref", "HEAD"]),
                            b"refs/heads/main\n"
                        );
                        assert_eq!(fs::read(f.root.join("file")).unwrap(), b"main\n");
                        assert!(!f.root.join(".git/index.lock").exists());
                        Ok(())
                    },
                    move |r| {
                        r.unwrap();
                        println!("PASS branch switch GUI: native entry; complete OIDs/diff; input invalidation; consumed confirmation; normal switch; dirty editor retained; revision-bound reload refusal then explicit reload; synchronous owner and project ABA; partial HEAD.lock error actual state; live native hook output/cancel; three refreshes");
                        support::finish(w, ui, "git-switch");
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
