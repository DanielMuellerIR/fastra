use super::*;
use std::{
    fs,
    os::unix::ffi::OsStringExt,
    path::Path,
    process::Command,
    time::{Duration, Instant},
};
fn git(root: &Path, args: &[&str]) {
    let out = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(out.status.success(), "{:?}", out);
}
fn collect(w: &gtk::Widget, out: &mut Vec<gtk::Widget>) {
    out.push(w.clone());
    let mut child = w.first_child();
    while let Some(w) = child {
        child = w.next_sibling();
        collect(&w, out);
    }
}
fn click_read(s: &State) {
    let mut widgets = Vec::new();
    collect(s.window.upcast_ref(), &mut widgets);
    let button = widgets
        .iter()
        .filter_map(|w| w.downcast_ref::<gtk::Button>())
        .find(|b| {
            b.label().as_deref()
                == Some(
                    s.lang()
                        .text("Gewähltes Dateipaar lesen", "Read selected file pair"),
                )
        })
        .unwrap();
    support::test_click(button, &[]);
}
pub(super) fn start(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("XDG_STATE_HOME").unwrap())
        .join(format!("git-history-{}", glib::uuid_string_random()));
    let fixture = root.clone();
    let lang = ui.lang;
    support::background(
        move || {
            fs::create_dir_all(&fixture).unwrap();
            for a in [
                vec!["init", "-q", "-b", "main"],
                vec!["config", "user.name", "Synthetic"],
                vec!["config", "user.email", "synthetic@example.invalid"],
                vec!["config", "commit.gpgsign", "false"],
            ] {
                git(&fixture, &a);
            }
            fs::write(fixture.join("source.txt"), "old Grüße 🚀\r\nline\r\n").unwrap();
            fs::write(
                fixture.join(std::ffi::OsString::from_vec(b"raw-\xff\n.bin".to_vec())),
                [0, 255, 1],
            )
            .unwrap();
            git(&fixture, &["add", "-A"]);
            git(&fixture, &["commit", "-qm", "root"]);
            git(&fixture, &["checkout", "-qb", "side"]);
            fs::write(fixture.join("side.txt"), "side").unwrap();
            git(&fixture, &["add", "-A"]);
            git(&fixture, &["commit", "-qm", "side"]);
            git(&fixture, &["checkout", "-q", "main"]);
            fs::write(fixture.join("source.txt"), "new Grüße 🚀\r\nline\r\n").unwrap();
            git(&fixture, &["add", "-A"]);
            git(&fixture, &["commit", "-qm", "main"]);
            git(&fixture, &["merge", "--no-ff", "-qm", "merge", "side"]);
            Ok(fixture)
        },
        move |result| {
            let root = result.unwrap();
            ui.add_document("untouched editor", "editor remains unchanged");
            support::open(&ui, "/usr/bin/git".into());
            let window = gtk::Window::list_toplevels()
                .into_iter()
                .filter_map(|w| w.downcast::<gtk::Window>().ok())
                .find(|w| w.title().as_deref() == Some(lang.text("Git · Lesen", "Git · Read")))
                .unwrap();
            let mut widgets = Vec::new();
            collect(window.upcast_ref(), &mut widgets);
            widgets
                .iter()
                .find_map(|w| w.downcast_ref::<gtk::Entry>())
                .unwrap()
                .set_text(root.to_str().unwrap());
            let explore = widgets
                .iter()
                .filter_map(|w| w.downcast_ref::<gtk::Button>())
                .find(|b| {
                    b.label().as_deref()
                        == Some(lang.text("Historie erkunden …", "Explore history …"))
                })
                .unwrap()
                .clone();
            glib::timeout_add_local_once(Duration::from_millis(250), move || {
                support::test_click(&explore, &[])
            });
        },
    );
}
pub(super) fn run(s: Rc<State>) {
    support::test_size(&s.window);
    let stage = Cell::new(0);
    let started = Instant::now();
    let paint = Cell::new(Instant::now());
    let original = fs::read(s.root.join("source.txt")).unwrap();
    let index = fs::read(s.root.join(".git/index")).unwrap();
    let head = fs::read(s.root.join(".git/HEAD")).unwrap();
    let doc = s.ui.upgrade().unwrap().active().unwrap();
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            started.elapsed() < Duration::from_secs(50),
            "history stage{} {}",
            stage.get(),
            s.status.text()
        );
        if s.busy.get() {
            return glib::ControlFlow::Continue;
        }
        match stage.get() {
            0 => {
                assert_eq!(
                    s.history.borrow().as_ref().unwrap().commits[0]
                        .parents
                        .len(),
                    2
                );
                s.parents.set_selected(1);
                stage.set(1);
            }
            1 => {
                let changes = s.changes.borrow().clone().unwrap();
                let index = changes
                    .changes()
                    .iter()
                    .position(|c| c.new_path.bytes() == b"source.txt")
                    .unwrap();
                s.files.set_selected(index as u32);
                click_read(&s);
                stage.set(2);
            }
            2 => {
                let pair = s.pair.borrow().clone().unwrap();
                assert_eq!(pair.before.text(), Some("old Grüße 🚀\r\nline\r\n"));
                assert_eq!(pair.after.text(), Some("new Grüße 🚀\r\nline\r\n"));
                assert_eq!(
                    super::super::buffer_text(&s.before.buffer()),
                    pair.before.text().unwrap()
                );
                assert_eq!(
                    super::super::buffer_text(&s.after.buffer()),
                    pair.after.text().unwrap()
                );
                assert!(s
                    .report
                    .buffer()
                    .text(
                        &s.report.buffer().start_iter(),
                        &s.report.buffer().end_iter(),
                        true
                    )
                    .contains("Logical difference blocks: 1"));
                paint.set(Instant::now());
                stage.set(3);
            }
            3 => {
                if paint.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                support::capture(&s.window, "git-history-pair");
                s.pages.set_current_page(Some(0));
                paint.set(Instant::now());
                stage.set(4);
            }
            4 => {
                if paint.get().elapsed() < Duration::from_millis(300) {
                    return glib::ControlFlow::Continue;
                }
                support::capture(&s.window, "git-history-graph");
                let count = s.history.borrow().as_ref().unwrap().commits.len();
                s.commits.set_selected((count - 1) as u32);
                stage.set(5);
            }
            5 => {
                let changes = s.changes.borrow().clone().unwrap();
                assert!(changes.parent.is_none());
                let index = changes
                    .changes()
                    .iter()
                    .position(|c| c.new_path.bytes().starts_with(b"raw-"))
                    .unwrap();
                s.files.set_selected(index as u32);
                click_read(&s);
                stage.set(6);
            }
            6 => {
                assert!(s.pair.borrow().as_ref().unwrap().after.text().is_none());
                assert!(s
                    .before
                    .buffer()
                    .text(
                        &s.before.buffer().start_iter(),
                        &s.before.buffer().end_iter(),
                        true
                    )
                    .is_empty());
                s.pages.set_current_page(Some(2));
                paint.set(Instant::now());
                stage.set(7);
            }
            7 => {
                if paint.get().elapsed() < Duration::from_millis(200) {
                    return glib::ControlFlow::Continue;
                }
                support::capture(&s.window, "git-history-binary");
                s.file();
                s.stop();
                stage.set(8);
            }
            8 => {
                s.file();
                s.ui.upgrade().unwrap().window.set_visible(false);
                stage.set(9);
            }
            _ => {
                assert!(!s.window.is_visible());
                assert_eq!(fs::read(s.root.join("source.txt")).unwrap(), original);
                assert_eq!(fs::read(s.root.join(".git/index")).unwrap(), index);
                assert_eq!(fs::read(s.root.join(".git/HEAD")).unwrap(), head);
                assert_eq!(
                    super::super::buffer_text(&doc.buffer),
                    "editor remains unchanged"
                );
                assert!(!doc.buffer.can_undo());
                fs::remove_dir_all(&s.root).unwrap();
                println!("FASTRA_GIT_HISTORY_OK actual-button/merge-parent/immutable-CRLF-Unicode-pair/raw-binary-path/graph/diff-blocks/cancel/parent-hide/no-index-or-source-or-editor-change");
                std::process::exit(0);
            }
        }
        glib::ControlFlow::Continue
    });
}
