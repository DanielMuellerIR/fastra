use super::*;
use std::{
    os::unix::ffi::OsStringExt,
    time::{Duration, Instant},
};
pub(super) fn run(ui: Rc<Ui>, mode: &str) {
    let mode = mode.to_owned();
    let root = PathBuf::from(std::env::var_os("FASTRA_SESSION_FIXTURE").unwrap());
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(None::<Instant>);
    support::test_size(ui.window.upcast_ref());
    gtk::glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "Journal phase {}",
            phase.get()
        );
        let state = ui.session.borrow().clone().unwrap();
        if !state.ready.get() {
            return gtk::glib::ControlFlow::Continue;
        }
        assert!(!state.enabled.is_active());
        match phase.get() {
            0 => {
                if mode == "journal-empty" {
                    assert!(state.journals.borrow().is_empty());
                    println!("FASTRA_SESSION_JOURNAL_EMPTY_OK fresh-after-cleanup");
                    ui.window.application().unwrap().quit();
                    return gtk::glib::ControlFlow::Break;
                }
                if mode == "journal-missing" {
                    let missing = root.join(std::ffi::OsString::from_vec(b"missing-\xff".to_vec()));
                    assert!(!missing.exists());
                    remember_journal(&ui, missing).unwrap();
                } else if mode == "journal-produce" {
                    let directory =
                        root.join(std::ffi::OsString::from_vec(b"project-\xff".to_vec()));
                    std::fs::create_dir_all(&directory).unwrap();
                    let source = directory.join("source.txt");
                    std::fs::write(&source, b"old").unwrap();
                    let c = fastra_core::Cancellation::default();
                    let snapshot = fastra_io::Snapshot::read(&source, &c).unwrap();
                    let request = fastra_core::SearchRequest {
                        pattern: "old".into(),
                        replacement: "new".into(),
                        mode: fastra_core::SearchMode::Literal,
                        case_sensitive: true,
                        range: None,
                    };
                    let preview = fastra_core::preview(
                        "old",
                        1,
                        1,
                        &request,
                        fastra_core::Limits::default(),
                        &c,
                    )
                    .unwrap();
                    let change =
                        fastra_io::Change::from_preview(snapshot, &preview, 1, 1, &[0], &c)
                            .unwrap();
                    let transaction = fastra_io::Transaction::apply(vec![change], &c)
                        .unwrap()
                        .unwrap();
                    let journal = transaction.path().to_owned();
                    use std::os::unix::ffi::OsStrExt;
                    std::fs::write(root.join("journal.path"), journal.as_os_str().as_bytes())
                        .unwrap();
                    ui.add_document("Private", "NEVER_INDEX_PRIVATE_TEXT");
                    ui.active().unwrap().buffer.set_modified(true);
                    remember_journal(&ui, journal).unwrap();
                } else {
                    let expected =
                        store::source_path(&std::fs::read(root.join("journal.path")).unwrap());
                    assert_eq!(&*state.journals.borrow(), &vec![expected]);
                }
                phase.set(1);
            }
            1 => {
                if state.busy.get() || state.has_pending_index() {
                    return gtk::glib::ControlFlow::Continue;
                }
                if mode == "journal-produce" {
                    let record = state
                        .lease
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .read_optional()
                        .unwrap()
                        .unwrap();
                    assert!(record.documents.is_empty());
                    assert_eq!(record.recovery_journals.len(), 1);
                    println!("FASTRA_SESSION_JOURNAL_PRODUCE_OK metadata-only/raw-path");
                    ui.window.application().unwrap().quit();
                    return gtk::glib::ControlFlow::Break;
                }
                state.journal_button.emit_clicked();
                phase.set(2);
            }
            2 => {
                let title = ui
                    .lang
                    .text("Bekannte Dateitransaktionen", "Known file transactions");
                let Some(window) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| w.is_visible() && w.title().as_deref() == Some(title))
                else {
                    return gtk::glib::ControlFlow::Continue;
                };
                if pause.get().is_none() {
                    pause.set(Some(Instant::now()));
                    return gtk::glib::ControlFlow::Continue;
                }
                if pause.get().unwrap().elapsed() < Duration::from_millis(300) {
                    return gtk::glib::ControlFlow::Continue;
                }
                gui_test::capture(&window, "session-journal-index");
                pause.set(None);
                let mut widgets = Vec::new();
                gui_test::descendants(window.upcast_ref(), &mut widgets);
                if mode == "journal-missing" {
                    assert!(gui_test::click(
                        window.upcast_ref(),
                        ui.lang.text("Eintrag vergessen …", "Forget entry …")
                    ));
                    phase.set(3);
                    return gtk::glib::ControlFlow::Continue;
                }
                let button = widgets
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Button>().ok())
                    .find(|b| b.label().is_none())
                    .unwrap();
                button.emit_clicked();
                phase.set(3);
            }
            3 => {
                if mode == "journal-missing" {
                    let clicked = gtk::Window::list_toplevels()
                        .into_iter()
                        .filter_map(|w| w.downcast::<gtk::Window>().ok())
                        .filter(|w| w.is_visible())
                        .any(|w| {
                            gui_test::click(
                                w.upcast_ref(),
                                ui.lang
                                    .text("Nur Indexeintrag vergessen", "Forget index entry only"),
                            )
                        });
                    if clicked {
                        phase.set(4);
                    }
                    return gtk::glib::ControlFlow::Continue;
                }
                let title = ui
                    .lang
                    .text("Dateisicherungen wiederaufnehmen", "Resume file recovery");
                let Some(window) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| w.is_visible() && w.title().as_deref() == Some(title))
                else {
                    return gtk::glib::ControlFlow::Continue;
                };
                let mut widgets = Vec::new();
                gui_test::descendants(window.upcast_ref(), &mut widgets);
                if !widgets
                    .iter()
                    .filter_map(|w| w.downcast_ref::<gtk::Label>())
                    .any(|l| {
                        l.text()
                            .contains(ui.lang.text("Journalzustand", "Journal state"))
                    })
                {
                    return gtk::glib::ControlFlow::Continue;
                }
                let path = store::source_path(&std::fs::read(root.join("journal.path")).unwrap());
                assert!(path.exists());
                assert_eq!(
                    std::fs::read(path.parent().unwrap().join("source.txt")).unwrap(),
                    b"new"
                );
                if pause.get().is_none() {
                    pause.set(Some(Instant::now()));
                    return gtk::glib::ControlFlow::Continue;
                }
                if pause.get().unwrap().elapsed() < Duration::from_millis(300) {
                    return gtk::glib::ControlFlow::Continue;
                }
                gui_test::capture(&window, "session-journal-raw-recovery");
                window.close();
                let c = fastra_core::Cancellation::default();
                let mut transaction = fastra_io::Transaction::reopen(&path).unwrap();
                transaction.undo(&c).unwrap();
                transaction.discard(&c).unwrap();
                assert!(!path.exists());
                forget_journal(&ui, &path);
                phase.set(4);
            }
            _ => {
                if state.busy.get() || state.has_pending_index() {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert!(state.journals.borrow().is_empty());
                for archive in state.archives.borrow().iter() {
                    assert!(archive.session.recovery_journals.is_empty());
                }
                if mode == "journal-missing" {
                    assert!(state
                        .lease
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .read_optional()
                        .unwrap()
                        .unwrap()
                        .documents
                        .is_empty());
                    println!("FASTRA_SESSION_JOURNAL_MISSING_OK confirmed-index-only-removal");
                } else {
                    println!("FASTRA_SESSION_JOURNAL_REOPEN_OK raw-callback/full-inspection/no-auto-write/verified-cleanup");
                }
                ui.window.application().unwrap().quit();
                return gtk::glib::ControlFlow::Break;
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}
