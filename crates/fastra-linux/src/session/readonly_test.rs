//! Echter Prozessabbruch und frischer Start; Freigabe und Wiederherstellen per nativer Eingabe.
use super::*;
use std::{
    io::Write,
    time::{Duration, Instant},
};

fn button(window: &gtk::Window, label: &str) -> gtk::Button {
    let mut widgets = Vec::new();
    super::gui_test::descendants(window.upcast_ref(), &mut widgets);
    widgets
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .find(|button| button.label().as_deref() == Some(label))
        .unwrap()
}
fn utf16(text: &str) -> Vec<u8> {
    [
        b"\xff\xfe".as_slice(),
        &text
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect::<Vec<_>>(),
    ]
    .concat()
}
pub(super) fn run(ui: Rc<Ui>, mode: &str) {
    let fixture = PathBuf::from(std::env::var_os("FASTRA_SESSION_FIXTURE").unwrap());
    let mode = mode.to_owned();
    let producer = std::env::var("FASTRA_SESSION_READONLY_PHASE").as_deref() != Ok("restore");
    let missing = mode == "readonly-missing";
    let optout = mode == "readonly-optout";
    let only = mode == "readonly-only";
    let phase = Cell::new(0);
    let started = Instant::now();
    let paused = Cell::new(Instant::now());
    let input = RefCell::new(None::<std::sync::mpsc::Receiver<()>>);
    let archives = RefCell::new(Vec::<PathBuf>::new());
    let baseline = ui.documents.borrow().len();
    support::test_size(ui.window.upcast_ref());
    gtk::glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(40),
            "readonly session {mode} phase {}",
            phase.get()
        );
        let state = ui.session.borrow().clone().unwrap();
        if !state.ready.get() || state.busy.get() {
            return gtk::glib::ControlFlow::Continue;
        }
        if input
            .borrow()
            .as_ref()
            .is_some_and(|receiver| receiver.try_recv().is_err())
        {
            return gtk::glib::ControlFlow::Continue;
        }
        input.borrow_mut().take();
        if producer {
            if phase.get() == 0 {
                std::fs::write(
                    fixture.join("reader-one.md"),
                    utf16("# Saved old reader\r\n"),
                )
                .unwrap();
                std::fs::hard_link(
                    fixture.join("reader-one.md"),
                    fixture.join("reader-one-alias.md"),
                )
                .unwrap();
                let source = fastra_document::ReadOnlyTextDocument::open(
                    &fixture.join("reader-one.md"),
                    None,
                    &fastra_core::Cancellation::default(),
                )
                .unwrap();
                super::super::readonly_source::append(&ui, "reader-one.md", Arc::new(source));
                if !only {
                    ui.add_document("Unsaved draft", "draft café 😀\r\n");
                    ui.active().unwrap().buffer.set_modified(true);
                    std::fs::write(fixture.join("reader-two.md"), "# Second reader\n").unwrap();
                    let source = fastra_document::ReadOnlyTextDocument::open(
                        &fixture.join("reader-two.md"),
                        None,
                        &fastra_core::Cancellation::default(),
                    )
                    .unwrap();
                    super::super::readonly_source::append(&ui, "reader-two.md", Arc::new(source));
                }
                state.enabled.set_active(true);
                state.flush(None);
                phase.set(1);
            } else if super::gui_test::durable(&state) {
                let saved = state
                    .lease
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .read_optional()
                    .unwrap()
                    .unwrap();
                assert_eq!(saved.version, 2);
                assert_eq!(saved.tab_count(), if only { 1 } else { 3 });
                assert_eq!(saved.active, if only { 0 } else { 2 });
                assert_eq!(saved.documents.len(), usize::from(!only));
                let json = serde_json::to_string(&saved).unwrap();
                assert!(!json.contains("Saved old reader") && !json.contains("Second reader"));
                println!(
                    "FASTRA_SESSION_READONLY_PRODUCER_OK version2/path-only/mixed-order/active"
                );
                std::io::stdout().flush().unwrap();
                unsafe {
                    libc::kill(libc::getpid(), libc::SIGKILL);
                }
                unreachable!();
            }
        } else {
            match phase.get() {
                0 => {
                    assert!(!state.enabled.is_active());
                    assert_eq!(ui.documents.borrow().len(), baseline);
                    assert_eq!(state.archives.borrow().len(), 1);
                    *archives.borrow_mut() = state
                        .archives
                        .borrow()
                        .iter()
                        .map(|archive| {
                            state_base()
                                .unwrap()
                                .join("fastra")
                                .join(&archive.lease.name)
                        })
                        .collect();
                    state.review();
                    paused.set(Instant::now());
                    phase.set(1);
                }
                1 if paused.get().elapsed() > Duration::from_millis(300) => {
                    let window = super::gui_test::modal(&ui).unwrap();
                    assert!(
                        !button(&window, ui.lang.text("Wiederherstellen", "Restore"))
                            .is_sensitive()
                    );
                    let mut widgets = Vec::new();
                    super::gui_test::descendants(window.upcast_ref(), &mut widgets);
                    let notebook = widgets
                        .iter()
                        .find_map(|widget| widget.clone().downcast::<gtk::Notebook>().ok())
                        .unwrap();
                    assert_eq!(notebook.n_pages(), if only { 1 } else { 3 });
                    super::gui_test::capture(&window, "session-readonly-review");
                    let consent = widgets
                        .into_iter()
                        .find_map(|widget| widget.downcast::<gtk::CheckButton>().ok())
                        .unwrap();
                    *input.borrow_mut() = Some(support::test_input_completed(&consent, &[], true));
                    phase.set(2);
                }
                2 => {
                    let window = super::gui_test::modal(&ui).unwrap();
                    let restore = button(&window, ui.lang.text("Wiederherstellen", "Restore"));
                    assert!(restore.is_sensitive());
                    if !optout {
                        state.enabled.set_active(true);
                    }
                    *input.borrow_mut() = Some(support::test_input_completed(&restore, &[], true));
                    phase.set(3);
                }
                3 if ui.documents.borrow().len() > baseline => {
                    let docs = ui.documents.borrow();
                    assert_eq!(
                        docs.len(),
                        baseline
                            + if only {
                                1
                            } else if missing {
                                2
                            } else {
                                3
                            }
                    );
                    let first = &docs[baseline];
                    assert_eq!(first.name, "reader-one.md");
                    assert_eq!(buffer_text(&first.buffer), "# Current disk reader\r\n");
                    assert_eq!(first.format.borrow().bom(), b"\xff\xfe");
                    assert!(
                        first.read_source.borrow().is_some() && first.snapshot.borrow().is_none()
                    );
                    let mut widgets = Vec::new();
                    super::gui_test::descendants(first.container.upcast_ref(), &mut widgets);
                    let views: Vec<_> = widgets
                        .iter()
                        .filter_map(|widget| widget.downcast_ref::<sourceview5::View>())
                        .collect();
                    assert_eq!(views.len(), 2);
                    assert!(views.iter().all(|view| !view.is_editable()));
                    assert!(first.is_read_only());
                    if !only {
                        let draft = &docs[baseline + 1];
                        assert_eq!(draft.name, "Unsaved draft");
                        assert_eq!(buffer_text(&draft.buffer), "draft café 😀\r\n");
                        assert!(draft.buffer.is_modified() && draft.snapshot.borrow().is_none());
                        assert!(!draft.is_read_only());
                        if !missing {
                            assert_eq!(docs[baseline + 2].name, "reader-two.md");
                            assert!(docs[baseline + 2].is_read_only());
                            assert!(Rc::ptr_eq(&ui.active().unwrap(), &docs[baseline + 2]));
                        }
                    }
                    if missing {
                        let window = super::gui_test::modal(&ui).unwrap();
                        assert_eq!(state.archives.borrow().len(), 1);
                        assert!(archives.borrow().iter().all(|path| path.exists()));
                        assert!(
                            !button(&window, ui.lang.text("Wiederherstellen", "Restore"))
                                .is_sensitive()
                        );
                    } else {
                        assert!(super::gui_test::modal(&ui).is_none());
                    }
                    drop(docs);
                    paused.set(Instant::now());
                    phase.set(4);
                }
                4 if paused.get().elapsed() > Duration::from_millis(350) => {
                    if missing {
                        let window = super::gui_test::modal(&ui).unwrap();
                        super::gui_test::capture(&window, "session-readonly-partial");
                        *input.borrow_mut() = Some(support::test_input_completed(
                            &button(&window, ui.lang.text("Später", "Later")),
                            &[],
                            true,
                        ));
                    }
                    paused.set(Instant::now());
                    phase.set(5);
                }
                5 if paused.get().elapsed() > Duration::from_millis(350) => {
                    if !optout && !super::gui_test::durable(&state) {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    assert_eq!(
                        std::fs::read(fixture.join("reader-one.md")).unwrap(),
                        utf16("# Current disk reader\r\n")
                    );
                    if optout {
                        assert!(!state.enabled.is_active());
                        assert!(state
                            .lease
                            .borrow()
                            .as_ref()
                            .unwrap()
                            .read_optional()
                            .unwrap()
                            .is_none());
                    } else {
                        let saved = state
                            .lease
                            .borrow()
                            .as_ref()
                            .unwrap()
                            .read_optional()
                            .unwrap()
                            .unwrap();
                        assert_eq!(
                            saved.tab_count(),
                            if only {
                                1
                            } else if missing {
                                2
                            } else {
                                3
                            }
                        );
                        assert_eq!(
                            saved.read_only_sources.len(),
                            if only || missing { 1 } else { 2 }
                        );
                    }
                    if missing || optout {
                        assert!(archives.borrow().iter().all(|path| path.exists()));
                    } else {
                        assert!(archives.borrow().iter().all(|path| !path.exists()));
                    }
                    super::gui_test::capture(ui.window.upcast_ref(), "session-readonly-restored");
                    println!("FASTRA_SESSION_READONLY_OK fresh-process/native-consent/current-disk/readonly-not-promoted/order/active/draft/source-unchanged missing={missing} only={only} optout={optout}");
                    ui.window.application().unwrap().quit();
                    return gtk::glib::ControlFlow::Break;
                }
                _ => {}
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}
