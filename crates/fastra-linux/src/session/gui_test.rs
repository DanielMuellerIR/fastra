//! Mehrprozess-Selbsttest: echter eigener Prozessabbruch, frischer Start und sichtbare Restore-/Close-Aktionen.
use super::*;
use std::{
    io::Write,
    time::{Duration, Instant},
};
pub(super) fn descendants(widget: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
    all.push(widget.clone());
    let mut child = widget.first_child();
    while let Some(item) = child {
        descendants(&item, all);
        child = item.next_sibling();
    }
}
fn windows() -> Vec<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .filter(|w| w.is_visible())
        .collect()
}
pub(super) fn modal(ui: &Ui) -> Option<gtk::Window> {
    windows()
        .into_iter()
        .find(|w| w.transient_for().as_ref() == Some(ui.window.upcast_ref()))
}

pub(super) fn click(widget: &gtk::Widget, label: &str) -> bool {
    let mut all = Vec::new();
    descendants(widget, &mut all);
    if let Some(button) = all
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Button>().ok())
        .find(|b| b.label().as_deref() == Some(label))
    {
        button.emit_clicked();
        true
    } else {
        false
    }
}
fn consent(window: &gtk::Window) {
    let mut all = Vec::new();
    descendants(window.upcast_ref(), &mut all);
    all.into_iter()
        .find_map(|w| w.downcast::<gtk::CheckButton>().ok())
        .unwrap()
        .set_active(true);
}
pub(super) fn capture(window: &gtk::Window, name: &str) {
    let Some(directory) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS").map(PathBuf::from) else {
        return;
    };
    std::fs::create_dir_all(&directory).unwrap();
    let paintable = gtk::WidgetPaintable::new(Some(window));
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(
        &snapshot,
        f64::from(window.width()),
        f64::from(window.height()),
    );
    let node = snapshot.to_node().unwrap();
    window
        .renderer()
        .unwrap()
        .render_texture(&node, None)
        .save_to_png(directory.join(format!("{name}.png")))
        .unwrap();
}
pub(super) fn durable(state: &State) -> bool {
    state.ready.get() && !state.busy.get() && *state.stamp.borrow() == state.current_stamp()
}
fn run_aux(ui: Rc<Ui>, mode: &str) {
    let mode = mode.to_owned();
    let phase = Cell::new(0);
    let started = Instant::now();
    let paused = Cell::new(None);
    let names = RefCell::new(Vec::<String>::new());
    let baseline = ui.documents.borrow().len();
    support::test_size(ui.window.upcast_ref());
    gtk::glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(20),
            "aux {mode} phase{}",
            phase.get()
        );
        let state = ui.session.borrow().clone().unwrap();
        if mode == "epoch" && state.ready.get() && !state.enabled.is_active() {
            state.enabled.set_active(true);
        }
        if ["delete", "preview"].contains(&mode.as_str())
            && phase.get() == 0
            && state.ready.get()
            && modal(&ui).is_none()
        {
            state.manage.emit_clicked();
        }
        match mode.as_str() {
            "preview" => {
                if phase.get() == 0 && state.ready.get() {
                    if let Some(window) = modal(&ui) {
                        support::test_size(&window);
                        let mut all = Vec::new();
                        descendants(window.upcast_ref(), &mut all);
                        all.into_iter()
                            .find_map(|w| w.downcast::<gtk::Notebook>().ok())
                            .unwrap()
                            .set_current_page(Some(1));
                        paused.set(Some(Instant::now()));
                        phase.set(1);
                    }
                } else if phase.get() == 1
                    && paused.get().unwrap().elapsed() > Duration::from_millis(300)
                {
                    capture(&modal(&ui).unwrap(), "session-labels");
                    println!("FASTRA_SESSION_LABELS_OK");
                    ui.window.application().unwrap().quit();
                    return gtk::glib::ControlFlow::Break;
                }
            }
            "epoch" => {
                if phase.get() == 0 && durable(&state) {
                    let before = state.epoch.get();
                    changed(&ui);
                    assert_eq!(state.epoch.get(), before + 1);
                    state.flush(None);
                    assert!(state.busy.get());
                    changed(&ui);
                    assert_eq!(state.epoch.get(), before + 2);
                    phase.set(1);
                } else if phase.get() == 1 && durable(&state) {
                    println!("FASTRA_SESSION_EPOCH_OK ack-without-text/inflight-update");
                    ui.window.application().unwrap().quit();
                    return gtk::glib::ControlFlow::Break;
                }
            }
            "layout" | "optout" => {
                assert!(!state.enabled.is_active());
                if phase.get() == 0 && state.ready.get() && !state.busy.get() {
                    if mode == "optout" {
                        ui.add_document("Private", "NEVER_PERSIST_PRIVATE_TEXT");
                        ui.active().unwrap().buffer.set_modified(true);
                    }
                    paused.set(Some(Instant::now()));
                    phase.set(1);
                }
                if phase.get() == 1
                    && paused.get().unwrap().elapsed() > Duration::from_millis(1500)
                    && state.ready.get()
                    && !state.busy.get()
                {
                    assert!(!state_base()
                        .unwrap()
                        .join("fastra")
                        .join(&state.lease.borrow().as_ref().unwrap().name)
                        .exists());
                    capture(ui.window.upcast_ref(), "session-main");
                    println!("FASTRA_SESSION_OPTOUT_OK no-text-file/default-off");
                    ui.window.application().unwrap().quit();
                    return gtk::glib::ControlFlow::Break;
                }
            }
            "error" => match phase.get() {
                0 => {
                    if state.busy.get() {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    assert!(!state.ready.get());
                    remember_journal(&ui, PathBuf::from("/test/missing-private-journal")).unwrap();
                    assert_eq!(state.close(), Some(gtk::glib::Propagation::Stop));
                    assert!(
                        ui.window.is_sensitive(),
                        "failed initialization must keep Retry usable"
                    );
                    assert!(
                        state
                            .status
                            .text()
                            .contains(ui.lang.text("unvollständig", "incomplete"))
                            || state
                                .status
                                .text()
                                .contains(ui.lang.text("nicht vollständig", "incomplete"))
                    );
                    paused.set(Some(Instant::now()));
                    phase.set(1);
                }
                1 => {
                    if paused.get().unwrap().elapsed() < Duration::from_millis(250) {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    capture(ui.window.upcast_ref(), "session-error");
                    use std::os::unix::fs::PermissionsExt;
                    std::fs::set_permissions(
                        state_base().unwrap().join("fastra"),
                        std::fs::Permissions::from_mode(0o700),
                    )
                    .unwrap();
                    assert!(click(
                        ui.window.upcast_ref(),
                        ui.lang.text("Erneut prüfen", "Retry")
                    ));
                    phase.set(2);
                }
                _ => {
                    if state.ready.get() && !state.busy.get() {
                        println!("FASTRA_SESSION_ERROR_RETRY_OK private-permissions/visible-error/real-retry");
                        ui.window.application().unwrap().quit();
                        return gtk::glib::ControlFlow::Break;
                    }
                }
            },
            "delete" => match phase.get() {
                0 => {
                    if !state.ready.get() {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    let Some(window) = modal(&ui) else {
                        return gtk::glib::ControlFlow::Continue;
                    };
                    *names.borrow_mut() = state
                        .archives
                        .borrow()
                        .iter()
                        .map(|a| a.lease.name.clone())
                        .collect();
                    assert!(!names.borrow().is_empty());
                    assert!(click(
                        window.upcast_ref(),
                        ui.lang
                            .text("Diese Sicherungen löschen …", "Delete these backups …")
                    ));
                    paused.set(Some(Instant::now()));
                    phase.set(1);
                }
                1 => {
                    if paused.get().unwrap().elapsed() < Duration::from_millis(300) {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    let window = windows()
                        .into_iter()
                        .find(|w| {
                            let mut all = Vec::new();
                            descendants(w.upcast_ref(), &mut all);
                            all.iter()
                                .filter_map(|w| w.clone().downcast::<gtk::Button>().ok())
                                .any(|b| {
                                    b.label().as_deref()
                                        == Some(
                                            ui.lang.text("Sicherungen löschen", "Delete backups"),
                                        )
                                })
                        })
                        .unwrap();
                    capture(&window, "session-delete");
                    assert!(click(
                        window.upcast_ref(),
                        ui.lang.text("Sicherungen löschen", "Delete backups")
                    ));
                    phase.set(2);
                }
                _ => {
                    if modal(&ui).is_none()
                        && state.archives.borrow().is_empty()
                        && !state.busy.get()
                    {
                        assert_eq!(ui.documents.borrow().len(), baseline);
                        for name in names.borrow().iter() {
                            assert!(!state_base().unwrap().join("fastra").join(name).exists());
                        }
                        let path =
                            PathBuf::from(std::env::var_os("FASTRA_SESSION_FIXTURE").unwrap())
                                .join("source.txt");
                        let original = [
                            b"\xff\xfe".as_slice(),
                            &"base café\r\n"
                                .encode_utf16()
                                .flat_map(u16::to_le_bytes)
                                .collect::<Vec<_>>(),
                        ]
                        .concat();
                        assert_eq!(std::fs::read(path).unwrap(), original);
                        println!("FASTRA_SESSION_DELETE_OK confirmed-inactive-only/source-retained/current-tabs-retained");
                        ui.window.application().unwrap().quit();
                        return gtk::glib::ControlFlow::Break;
                    }
                }
            },
            _ => unreachable!(),
        }
        gtk::glib::ControlFlow::Continue
    });
}

pub(super) fn run(ui: Rc<Ui>, mode: &str) {
    if ["layout", "optout", "error", "delete", "epoch", "preview"].contains(&mode) {
        run_aux(ui, mode);
        return;
    }
    let fixture = PathBuf::from(std::env::var_os("FASTRA_SESSION_FIXTURE").unwrap());
    let mode = mode.to_owned();
    let phase = Cell::new(0);
    let deadline = Instant::now();
    let opted = Cell::new(false);
    let baseline = ui.documents.borrow().len();
    let paused_at = Cell::new(None);
    let expected_binding = RefCell::new(None::<String>);
    gtk::glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            deadline.elapsed() < Duration::from_secs(45),
            "session timeout mode {mode} phase{}",
            phase.get()
        );
        let state = ui.session.borrow().clone().unwrap();
        if !state.ready.get() {
            return gtk::glib::ControlFlow::Continue;
        }
        if !opted.replace(true) {
            assert!(!state.enabled.is_active());
            state.enabled.set_active(true);
            if mode != "produce" {
                state.manage.emit_clicked();
            }
        }
        if mode == "produce" {
            match phase.get() {
                0 => {
                    assert!(state.archives.borrow().is_empty());
                    ui.add_document("Scratch", "scratch café\r\n");
                    let doc = ui.active().unwrap();
                    doc.buffer.insert(&mut doc.buffer.end_iter(), "unsaved");
                    ui.load_path(fixture.join("source.txt"));
                    phase.set(1);
                }
                1 => {
                    let doc = ui.active().unwrap();
                    if doc.snapshot.borrow().is_none() {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    assert_eq!(buffer_text(&doc.buffer), "base café\r\n");
                    assert_eq!(doc.format.borrow().bom(), b"\xff\xfe");
                    doc.buffer.insert(&mut doc.buffer.end_iter(), "dirty");
                    if std::env::var_os("FASTRA_SESSION_EOL_SELFTEST").is_some() {
                        crate::line_endings::select_for_test(
                            &doc,
                            fastra_core::encoding::LineEnding::Lf,
                        );
                        assert!(doc.buffer.is_modified());
                    }
                    state.flush(None);
                    phase.set(2);
                }
                _ => {
                    if !durable(&state) {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    println!("FASTRA_SESSION_PRODUCER_DURABLE");
                    std::io::stdout().flush().unwrap();
                    unsafe { libc::kill(libc::getpid(), libc::SIGKILL) };
                    unreachable!();
                }
            }
        } else {
            match phase.get() {
                0 => {
                    let Some(window) = modal(&ui) else {
                        return gtk::glib::ControlFlow::Continue;
                    };
                    support::test_size(&window);
                    assert_eq!(ui.documents.borrow().len(), baseline);
                    *expected_binding.borrow_mut() = state
                        .archives
                        .borrow()
                        .iter()
                        .flat_map(|a| a.session.documents.iter())
                        .find(|r| r.path.is_some())
                        .unwrap()
                        .binding
                        .clone();
                    assert_eq!(
                        state
                            .archives
                            .borrow()
                            .iter()
                            .map(|a| a.session.documents.len())
                            .sum::<usize>(),
                        2
                    );
                    let mut widgets = Vec::new();
                    descendants(window.upcast_ref(), &mut widgets);
                    let restore = widgets
                        .iter()
                        .filter_map(|w| w.clone().downcast::<gtk::Button>().ok())
                        .find(|b| {
                            b.label().as_deref()
                                == Some(ui.lang.text("Wiederherstellen", "Restore"))
                        })
                        .unwrap();
                    assert!(!restore.is_sensitive());
                    paused_at.set(Some(Instant::now()));
                    phase.set(1);
                }
                1 => {
                    if paused_at.get().unwrap().elapsed() < Duration::from_millis(300) {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    let window = modal(&ui).unwrap();
                    capture(&window, "session");
                    let mut widgets = Vec::new();
                    descendants(window.upcast_ref(), &mut widgets);
                    widgets
                        .into_iter()
                        .find_map(|w| w.downcast::<gtk::Notebook>().ok())
                        .unwrap()
                        .set_current_page(Some(1));
                    paused_at.set(Some(Instant::now()));
                    phase.set(10);
                }
                10 => {
                    if paused_at.get().unwrap().elapsed() < Duration::from_millis(250) {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    let window = modal(&ui).unwrap();
                    capture(&window, "session-source");
                    consent(&window);
                    ui.generation.set(ui.generation.get() + 1);
                    assert!(click(
                        window.upcast_ref(),
                        ui.lang.text("Wiederherstellen", "Restore")
                    ));
                    assert_eq!(ui.documents.borrow().len(), baseline);
                    assert!(click(window.upcast_ref(), ui.lang.text("Später", "Later")));
                    state.review();
                    phase.set(2);
                }
                2 => {
                    let window = modal(&ui).unwrap();
                    consent(&window);
                    click(
                        window.upcast_ref(),
                        ui.lang.text("Wiederherstellen", "Restore"),
                    );
                    window.close();
                    paused_at.set(Some(Instant::now()));
                    phase.set(3);
                }
                3 => {
                    if paused_at.get().unwrap().elapsed() < Duration::from_millis(350) {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    assert_eq!(
                        ui.documents.borrow().len(),
                        baseline,
                        "closed consent must not add tabs"
                    );
                    state.review();
                    let window = modal(&ui).unwrap();
                    consent(&window);
                    click(
                        window.upcast_ref(),
                        ui.lang.text("Wiederherstellen", "Restore"),
                    );
                    phase.set(4);
                }
                4 => {
                    if ui.documents.borrow().len() != baseline + 2 || !durable(&state) {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    let docs = ui.documents.borrow();
                    let scratch = &docs[baseline];
                    let source = &docs[baseline + 1];
                    assert!(buffer_text(&scratch.buffer).starts_with("scratch café\r\nunsaved"));
                    assert_eq!(*scratch.original.borrow(), "scratch café\r\n");
                    assert!(scratch.buffer.is_modified());
                    assert!(scratch.snapshot.borrow().is_none());
                    assert_eq!(buffer_text(&source.buffer), "base café\r\ndirty");
                    assert_eq!(*source.original.borrow(), "base café\r\n");
                    assert!(source.buffer.is_modified());
                    assert_eq!(source.format.borrow().bom(), b"\xff\xfe");
                    if std::env::var_os("FASTRA_SESSION_EOL_SELFTEST").is_some() {
                        assert_eq!(
                            source.line_endings.saved(),
                            fastra_core::encoding::LineEnding::CrLf
                        );
                        assert_eq!(
                            source.line_endings.pending(),
                            Some(fastra_core::encoding::LineEnding::Lf)
                        );
                        assert_eq!(
                            source.line_endings.current(),
                            fastra_core::encoding::LineEnding::Lf
                        );
                    }
                    let unchanged = mode.starts_with("unchanged");
                    assert_eq!(
                        ui.save.label().as_deref(),
                        Some(if unchanged {
                            ui.lang.text("Speichern", "Save")
                        } else {
                            ui.lang.text("Speichern unter …", "Save as …")
                        })
                    );
                    assert_eq!(
                        source.snapshot.borrow().is_some(),
                        unchanged,
                        "source binding must match the complete original snapshot"
                    );
                    let original_bytes = [
                        b"\xff\xfe".as_slice(),
                        &"base café\r\n"
                            .encode_utf16()
                            .flat_map(u16::to_le_bytes)
                            .collect::<Vec<_>>(),
                    ]
                    .concat();
                    assert_eq!(
                        std::fs::read(fixture.join("source.txt")).unwrap(),
                        if unchanged {
                            original_bytes
                        } else {
                            b"foreign replacement\n".to_vec()
                        }
                    );
                    drop(docs);
                    let capture = state.capture(None).unwrap().session().unwrap();
                    let source = &capture.documents[1];
                    if std::env::var_os("FASTRA_SESSION_EOL_SELFTEST").is_some() {
                        assert_eq!(source.saved_ending, Some(1));
                        assert_eq!(source.pending_ending, Some(0));
                    }
                    assert_eq!(
                        store::unhex(&source.original_hex).unwrap(),
                        [
                            b"\xff\xfe".as_slice(),
                            &"base café\r\n"
                                .encode_utf16()
                                .flat_map(u16::to_le_bytes)
                                .collect::<Vec<_>>()
                        ]
                        .concat()
                    );
                    assert!(source.path.is_some());
                    assert_eq!(source.binding, *expected_binding.borrow());
                    assert_ne!(source.text, "foreign replacement\n");
                    let scratch = ui.documents.borrow()[baseline].clone();
                    scratch
                        .buffer
                        .insert(&mut scratch.buffer.end_iter(), "close-only");
                    let expected_scratch = buffer_text(&scratch.buffer);
                    let discard = mode.ends_with("discard");
                    let unchanged = mode.starts_with("unchanged");
                    let weak = Rc::downgrade(&state);
                    ui.window.connect_close_request(move |_|{
                        if let Some(state)=weak.upgrade(){if state.allow_close.get(){
                            assert!(durable(&state));
                            let saved=state.lease.borrow().as_ref().unwrap().read_optional().unwrap().unwrap();
                            if discard{if unchanged{assert_eq!(saved.documents.len(),1);assert_eq!(saved.documents[0].text,"base café\r\n");assert!(!saved.documents[0].dirty);}else{assert!(saved.documents.is_empty());}}else{assert_eq!(saved.documents.len(),2);assert_eq!(saved.documents[0].text,expected_scratch);}
                            println!("FASTRA_SESSION_SELFTEST_OK crash/fresh-reopen/restore-consent/stale-owner/closed-consent/dirty-text/original-snapshot/BOM/close-flush discard={discard}");
                        }}gtk::glib::Propagation::Proceed
                    });
                    assert_eq!(state.close(), Some(gtk::glib::Propagation::Stop));
                    paused_at.set(Some(Instant::now()));
                    phase.set(5);
                }
                _ => {
                    if paused_at.get().unwrap().elapsed() < Duration::from_millis(300) {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    let label = ui.lang.text(
                        if mode.ends_with("discard") {
                            "Verwerfen und schließen"
                        } else {
                            "Mit Wiederherstellung schließen"
                        },
                        if mode.ends_with("discard") {
                            "Discard and close"
                        } else {
                            "Close with recovery"
                        },
                    );
                    if let Some(window) = modal(&ui) {
                        capture(&window, "session-close");
                        click(window.upcast_ref(), label);
                    } else {
                        let mut clicked = false;
                        for window in windows() {
                            clicked |= click(window.upcast_ref(), label);
                        }
                        if !clicked && durable(&state) && state.allow_close.get() {
                            return gtk::glib::ControlFlow::Break;
                        }
                    }
                }
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}
