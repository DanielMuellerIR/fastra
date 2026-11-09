use super::*;
fn ready(state: &FolderWindow) -> bool {
    !state.busy.get() && state.pending.borrow().is_some() && state.pane.is_ready()
}
pub(super) fn run(state: Rc<FolderWindow>) {
    let base = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let inputs = base.join("inputs");
    let scope = std::env::var("FASTRA_WORKFLOW_DISK_SCOPE").unwrap_or_else(|_| "folder".into());
    let titlecase = std::env::var_os("FASTRA_WORKFLOW_DISK_TITLECASE").is_some();
    let locale = crate::operations::titlecase_locale().unwrap();
    if let Ok(expected) = std::env::var("FASTRA_TITLECASE_EXPECT_LOCALE") {
        assert_eq!(locale.as_str(), expected);
    }
    let mapping = std::env::var("FASTRA_CASE_MAPPING").unwrap_or_else(|_| "titlecase".into());
    let sorting = titlecase && mapping.starts_with("sort-");
    if sorting {
        assert_eq!(locale.as_str(), "sv_SE");
    }
    let original_ctype =
        unsafe { std::ffi::CStr::from_ptr(libc::setlocale(libc::LC_CTYPE, std::ptr::null())) }
            .to_owned();
    let turkic = matches!(locale.as_str().split('_').next(), Some("tr" | "az"));
    let first_stage = if sorting {
        "ä\r\nz\r\na\r\n"
    } else if titlecase && mapping == "lower" {
        "ISTANBUL\r\n"
    } else if titlecase {
        "istanbul\r\n"
    } else {
        "dog\r\n"
    };
    let output = if !titlecase {
        "DOG\r\n"
    } else {
        match (mapping.as_str(), turkic) {
            ("sort-ascending", _) => "a\r\nz\r\nä\r\n",
            ("sort-descending", _) => "ä\r\nz\r\na\r\n",
            ("upper", true) => "İSTANBUL\r\n",
            ("upper", false) => "ISTANBUL\r\n",
            ("lower", true) => "ıstanbul\r\n",
            ("lower", false) => "istanbul\r\n",
            (_, true) => "İstanbul\r\n",
            (_, false) => "Istanbul\r\n",
        }
    };
    let original_binding =
        fastra_io::Snapshot::read(&inputs.join("a.txt"), &Cancellation::default())
            .unwrap()
            .binding_digest()
            .unwrap();
    let originals: [Vec<u8>; 3] = [
        std::fs::read(inputs.join("a.txt")).unwrap(),
        std::fs::read(inputs.join("b.txt")).unwrap(),
        std::fs::read(inputs.join("c.txt")).unwrap(),
    ];
    if state.files.is_empty() && state.project.is_none() {
        state.set_root(inputs.clone());
    }
    state.search.emit_clicked();
    let test_window = state.window.upgrade().unwrap();
    let phase = Cell::new(0);
    let stale = Cell::new(0);
    let started = std::time::Instant::now();
    let pause = Cell::new(started);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            started.elapsed() < Duration::from_secs(70),
            "disk {} phase{} stale{} {}",
            scope,
            phase.get(),
            stale.get(),
            state.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(250) {
            return glib::ControlFlow::Continue;
        }
        let win = test_window.clone();
        if std::env::var_os("FASTRA_WORKFLOW_DISK_ENCODING").is_some()
            || std::env::var_os("FASTRA_WORKFLOW_DISK_INITIAL_DIRTY").is_some()
        {
            if state.busy.get() {
                return glib::ControlFlow::Continue;
            }
            assert!(state.pending.borrow().is_none());
            assert!(!state.apply.is_sensitive());
            assert!(state.transaction.borrow().is_none());
            assert_eq!(std::fs::read(inputs.join("a.txt")).unwrap(), originals[0]);
            if std::env::var_os("FASTRA_WORKFLOW_DISK_READONLY").is_some() {
                let doc = state.host.active().unwrap();
                assert!(doc.snapshot.borrow().is_none());
                assert!(buffer_text(&doc.buffer).is_empty());
                assert!(doc.is_read_only());
            }
            git_view::capture(&win, "workflow-disk-encoding-refused");
            println!(
                "FASTRA_WORKFLOW_DISK_ENCODING_OK complete-plan-refusal/source-and-disk-unchanged"
            );
            std::process::exit(0);
        }
        match phase.get() {
            0 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                let p = state.pending.borrow();
                let p = p.as_ref().unwrap();
                assert_eq!(p.files().len(), if scope == "file" { 1 } else { 3 });
                assert!(p
                    .files()
                    .iter()
                    .all(|f| f.workflow_preview().unwrap().steps.len() == 2));
                if titlecase {
                    assert_eq!(p.workflow_locale(), Some(&locale));
                    assert!(state.status.text().contains(locale.as_str()));
                }
                let stages = state.stages.as_ref().unwrap();
                stages.files.set_selected(0);
                stages.steps.set_selected(0);
                phase.set(1);
            }
            1 => {
                let stages = state.stages.as_ref().unwrap();
                if !stages.pane.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text_view(&stages.pane.after), first_stage);
                stages.steps.set_selected(1);
                phase.set(2);
            }
            2 => {
                let stages = state.stages.as_ref().unwrap();
                if !stages.pane.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                eprintln!(
                    "CASE DISK mapping={mapping} locale={} actual={:?} expected={output:?}",
                    locale.as_str(),
                    buffer_text_view(&stages.pane.after)
                );
                assert_eq!(buffer_text_view(&stages.pane.after), output);
                let notebook = state
                    .pane
                    .root
                    .ancestor(gtk::Notebook::static_type())
                    .unwrap()
                    .downcast::<gtk::Notebook>()
                    .unwrap();
                notebook.set_current_page(Some(1));
                phase.set(3);
            }
            3 => {
                assert!(!state.stages.as_ref().unwrap().pane.checks.is_mapped());
                git_view::capture(&win, "workflow-disk-stages");
                let notebook = state
                    .pane
                    .root
                    .ancestor(gtk::Notebook::static_type())
                    .unwrap()
                    .downcast::<gtk::Notebook>()
                    .unwrap();
                notebook.set_current_page(Some(0));
                if std::env::var_os("FASTRA_WORKFLOW_DISK_INSPECTOR").is_some() {
                    expander(win.upcast_ref()).unwrap().set_expanded(true);
                    phase.set(30);
                } else {
                    phase.set(4);
                }
            }
            4 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                git_view::capture(&win, "workflow-disk-final");
                assert!(state.apply.is_sensitive());
                if std::env::var_os("FASTRA_WORKFLOW_DISK_READONLY").is_some() {
                    state.apply.emit_clicked();
                    phase.set(60);
                } else if std::env::var_os("FASTRA_FOLDER_PARENT_HIDE_DELAY").is_some() {
                    state.apply.emit_clicked();
                    assert!(state.busy.get());
                    state.host.window.set_visible(false);
                    assert!(!win.is_visible());
                    phase.set(40);
                } else {
                    git_view::test_click(&state.apply, &[]);
                    phase.set(5);
                }
            }
            5 => {
                if state.busy.get() || state.transaction.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let mut expected = vec![0xef, 0xbb, 0xbf];
                expected.extend(output.as_bytes());
                assert_eq!(std::fs::read(inputs.join("a.txt")).unwrap(), expected);
                if sorting && scope != "file" {
                    let sorted_b = if mapping == "sort-ascending" {
                        "a café\r\nz\r\nä\r\n"
                    } else {
                        "ä\r\nz\r\na café\r\n"
                    };
                    let mut expected_b = vec![0xff, 0xfe];
                    for unit in sorted_b.encode_utf16() {
                        expected_b.extend(unit.to_le_bytes());
                    }
                    assert_ne!(expected_b, originals[1]);
                    assert_eq!(std::fs::read(inputs.join("b.txt")).unwrap(), expected_b);
                    assert_eq!(std::fs::read(inputs.join("c.txt")).unwrap(), originals[2]);
                }
                let active = state.host.active().unwrap();
                assert_eq!(buffer_text(&active.buffer), output);
                assert!(!active.buffer.is_modified());
                assert!(state.undo.is_sensitive());
                if std::env::var_os("FASTRA_FOLDER_UNDO_HIDE_DELAY").is_some() {
                    state.undo.emit_clicked();
                    assert!(state.busy.get());
                    state.host.window.set_visible(false);
                    phase.set(50);
                } else {
                    git_view::test_click(&state.undo, &[]);
                    phase.set(6);
                }
            }
            6 => {
                if state.busy.get() || !state.search.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                for (i, name) in ["a.txt", "b.txt", "c.txt"].iter().enumerate() {
                    assert_eq!(std::fs::read(inputs.join(name)).unwrap(), originals[i]);
                }
                assert_eq!(buffer_text(&state.host.active().unwrap().buffer), "cat\r\n");
                state.search.emit_clicked();
                phase.set(if sorting { 70 } else { 7 });
            }
            70 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                assert!(!unsafe { libc::setlocale(libc::LC_CTYPE, c"C.UTF-8".as_ptr()) }.is_null());
                state.apply.emit_clicked();
                phase.set(71);
            }
            71 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.transaction.borrow().is_none());
                for (i, name) in ["a.txt", "b.txt", "c.txt"].iter().enumerate() {
                    assert_eq!(std::fs::read(inputs.join(name)).unwrap(), originals[i]);
                }
                assert!(
                    !unsafe { libc::setlocale(libc::LC_CTYPE, original_ctype.as_ptr()) }.is_null()
                );
                state.search.emit_clicked();
                phase.set(7);
            }
            7 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                if stale.get() == 0 {
                    let target = if scope == "file" { "a.txt" } else { "c.txt" };
                    std::fs::write(inputs.join(target), "external change").unwrap();
                    state.apply.emit_clicked();
                    phase.set(8);
                } else {
                    state.host.active().unwrap().buffer.insert(
                        &mut state.host.active().unwrap().buffer.end_iter(),
                        " dirty",
                    );
                    state.apply.emit_clicked();
                    phase.set(9);
                }
            }
            8 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.transaction.borrow().is_none());
                if scope != "file" {
                    assert_eq!(std::fs::read(inputs.join("a.txt")).unwrap(), originals[0]);
                }
                for (i, name) in ["a.txt", "b.txt", "c.txt"].iter().enumerate() {
                    std::fs::write(inputs.join(name), &originals[i]).unwrap();
                }
                stale.set(1);
                state.search.emit_clicked();
                phase.set(7);
            }
            9 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.transaction.borrow().is_none());
                assert_eq!(std::fs::read(inputs.join("a.txt")).unwrap(), originals[0]);
                assert!(buffer_text(&state.host.active().unwrap().buffer).contains("dirty"));
                git_view::capture(&win, "workflow-disk-dirty-refused");
                if scope == "project" {
                    let doc = state.host.active().unwrap();
                    doc.buffer.set_text("cat\r\n");
                    doc.update_saved_baseline_status("cat\r\n");
                    state.search.emit_clicked();
                    phase.set(10);
                    pause.set(std::time::Instant::now());
                    return glib::ControlFlow::Continue;
                }
                eprintln!(
                    "CASE DISK PASS mapping={mapping} locale={}",
                    locale.as_str()
                );
                println!("FASTRA_WORKFLOW_DISK_OK scope={} native-entry/full-two-stages/final-approvals/atomic-apply/IO-undo/BOM-CRLF-UTF16/clean-tab-refresh/stale-noop-or-file/dirty-refusal/source-kept",scope);
                std::process::exit(0);
            }
            60 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                let doc = state.host.active().unwrap();
                assert!(state.transaction.borrow().is_none());
                assert!(doc.snapshot.borrow().is_none());
                assert!(doc.is_read_only());
                assert!(buffer_text(&doc.buffer).is_empty());
                assert_eq!(std::fs::read(inputs.join("a.txt")).unwrap(), originals[0]);
                println!("FASTRA_FOLDER_READONLY_OK actual-changed-path-refused/snapshot-none/source-path-bound/dummybuffer-empty/no-transaction/disk-unchanged");
                std::process::exit(0);
            }
            50 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!win.is_visible());
                assert!(state.transaction.borrow().is_some());
                let before =
                    fastra_io::Snapshot::read(&inputs.join("a.txt"), &Cancellation::default())
                        .unwrap()
                        .binding_digest()
                        .unwrap();
                assert!(state.cancel.borrow().check().is_err());
                state.undo.emit_clicked();
                assert!(!state.busy.get());
                assert!(state.cancel.borrow().check().is_err());
                let after =
                    fastra_io::Snapshot::read(&inputs.join("a.txt"), &Cancellation::default())
                        .unwrap()
                        .binding_digest()
                        .unwrap();
                assert_eq!(before, after);
                println!("FASTRA_FOLDER_UNDO_HIDE_OK delayed-undo-cancelled/child-closed/retained-undo-callback-refused/no-new-snapshot-change/journal-kept");
                std::process::exit(0);
            }
            40 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.transaction.borrow().is_none());
                assert!(state.pending.borrow().is_none());
                assert!(!win.is_visible());
                let after =
                    fastra_io::Snapshot::read(&inputs.join("a.txt"), &Cancellation::default())
                        .unwrap()
                        .binding_digest()
                        .unwrap();
                assert_eq!(after, original_binding);
                for (i, name) in ["a.txt", "b.txt", "c.txt"].iter().enumerate() {
                    assert_eq!(std::fs::read(inputs.join(name)).unwrap(), originals[i]);
                }
                println!("FASTRA_FOLDER_PARENT_HIDE_OK changed-paths-worker-delayed/parent-hidden/child-closed/cancelled/no-transaction/exact-snapshot-binding-and-all-bytes-unchanged");
                std::process::exit(0);
            }
            30 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    win.height() <= 900,
                    "definition inspector height {}",
                    win.height()
                );
                git_view::capture(&win, "workflow-disk-definition");
                expander(win.upcast_ref()).unwrap().set_expanded(false);
                phase.set(4);
            }
            10 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                std::fs::rename(&inputs, base.join("moved-inputs")).unwrap();
                std::fs::create_dir(&inputs).unwrap();
                for (i, name) in ["a.txt", "b.txt", "c.txt"].iter().enumerate() {
                    std::fs::write(inputs.join(name), &originals[i]).unwrap();
                }
                state.apply.emit_clicked();
                phase.set(11);
            }
            11 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.transaction.borrow().is_none());
                assert_eq!(std::fs::read(inputs.join("a.txt")).unwrap(), originals[0]);
                assert_eq!(
                    std::fs::read(base.join("moved-inputs/a.txt")).unwrap(),
                    originals[0]
                );
                std::fs::remove_dir_all(&inputs).unwrap();
                std::fs::rename(base.join("moved-inputs"), &inputs).unwrap();
                eprintln!(
                    "CASE DISK PASS mapping={mapping} locale={}",
                    locale.as_str()
                );
                println!("FASTRA_WORKFLOW_DISK_OK scope=project native-entry/full-two-stages/final-approvals/atomic-apply/IO-undo/BOM-CRLF-UTF16/clean-tab-refresh/stale-noop/dirty-refusal/replaced-project-root-refused/both-roots-kept");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        pause.set(std::time::Instant::now());
        glib::ControlFlow::Continue
    });
}
fn buffer_text_view(view: &gtk::TextView) -> String {
    let b = view.buffer();
    b.text(&b.start_iter(), &b.end_iter(), true).to_string()
}

fn expander(widget: &gtk::Widget) -> Option<gtk::Expander> {
    if let Some(e) = widget.downcast_ref::<gtk::Expander>() {
        return Some(e.clone());
    }
    let mut child = widget.first_child();
    while let Some(w) = child {
        if let Some(e) = expander(&w) {
            return Some(e);
        }
        child = w.next_sibling();
    }
    None
}
