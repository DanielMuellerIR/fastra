use super::*;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
fn click(widget: &impl IsA<gtk::Widget>, keys: &[&str]) {
    let widget = widget.as_ref();
    let native = widget.native().unwrap();
    let point = widget
        .compute_point(
            &native.clone().dynamic_cast::<gtk::Widget>().unwrap(),
            &gtk::graphene::Point::new(widget.width() as f32 / 2., widget.height() as f32 / 2.),
        )
        .unwrap();
    let (x, y) = native.surface_transform();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(native.surface().unwrap().as_ptr().cast()) }.to_string();
    let keys: Vec<String> = keys.iter().map(|s| s.to_string()).collect();
    std::thread::spawn(move || {
        let mut c = std::process::Command::new("xdotool");
        c.args([
            "windowfocus",
            "--sync",
            &id,
            "mousemove",
            "--window",
            &id,
            &(point.x() as f64 - x).round().to_string(),
            &(point.y() as f64 - y).round().to_string(),
            "click",
            "1",
        ]);
        if !keys.is_empty() {
            c.arg("key").args(keys);
        }
        assert!(c.status().unwrap().success());
    });
}

fn definition() -> Workflow {
    let mut a = fastra_workflow::Step::new("replace").unwrap();
    a.find = "cat".into();
    a.replacement = "dog".into();
    a.case_sensitive = true;
    let mut b = fastra_workflow::Step::new("replace").unwrap();
    b.find = "dog".into();
    b.replacement = "fox".into();
    b.case_sensitive = true;
    Workflow {
        id: fastra_workflow::new_id().unwrap(),
        revision: fastra_workflow::new_id().unwrap(),
        name: "Tabs · Unicode 🌈".into(),
        steps: vec![a, b],
        extra: Default::default(),
    }
}
fn checkbox(state: &State) -> gtk::CheckButton {
    state.pane.checks.first_child().unwrap().downcast().unwrap()
}
fn ready(state: &State) -> bool {
    !state.busy.get() && state.pending.borrow().is_some() && state.pane.is_ready()
}
pub(super) fn run(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_WORKFLOW_TABS_LOCALE_SELFTEST").is_some() {
        run_locale(ui);
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let fixture = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join("A.txt");
    std::fs::write(&fixture, "cat café🌈\r\n").unwrap();
    let alternate = fixture.with_file_name("A-other.txt");
    std::fs::write(&alternate, "cat café🌈\r\n").unwrap();
    let readonly_source =
        fastra_document::Document::open_hex(&fixture, &Cancellation::default()).unwrap();
    let initial = ui.documents.borrow().len();
    ui.add_document("A.txt", "cat café🌈\r\n");
    let a = ui.active().unwrap();
    let saved = fastra_io::Snapshot::read(&fixture, &Cancellation::default()).unwrap();
    *a.snapshot.borrow_mut() = Some(saved.clone());
    ui.add_document("B.txt", "cat\n");
    let b = ui.active().unwrap();
    b.buffer.set_text("cat unsaved\n");
    b.buffer.set_modified(true);
    ui.add_document("C-noop.txt", "unchanged\n");
    let c = ui.active().unwrap();
    ui.add_document("D-locked.txt", "skipped\n");
    let locked = ui.active().unwrap();
    *locked.rich.borrow_mut() = Some(rich_editor::RichEditor::new(&ui, &locked).unwrap());
    ui.tabs.set_current_page(Some(initial as u32));
    super::super::show(&ui, false);
    let holder = RefCell::new(None::<Rc<State>>);
    let phase = Cell::new(0);
    let stale_case = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(85),
            "workflow tabs timeout phase{} stale{}",
            phase.get(),
            stale_case.get()
        );
        if pause.get().elapsed() < Duration::from_millis(250) {
            return glib::ControlFlow::Continue;
        }
        if phase.get() == 0 {
            let view = super::super::TEST_VIEW
                .with(|slot| slot.borrow().as_ref().and_then(Weak::upgrade))
                .unwrap();
            if view.busy.get() || view.snapshot.borrow().is_none() {
                return glib::ControlFlow::Continue;
            }
            *view.draft.borrow_mut() = Some(super::super::Draft::Flow(definition()));
            view.dirty.set(false);
            view.refresh();
            click(&view.all_tabs, &[]);
            phase.set(1);
            pause.set(Instant::now());
            return glib::ControlFlow::Continue;
        }
        if phase.get() == 1 {
            let Some(state) =
                TEST_STATE.with(|slot| slot.borrow().as_ref().and_then(Weak::upgrade))
            else {
                return glib::ControlFlow::Continue;
            };
            git_view::test_size(&state.window);
            *holder.borrow_mut() = Some(state);
            phase.set(2);
            pause.set(Instant::now());
            return glib::ControlFlow::Continue;
        }
        let state = holder.borrow().as_ref().unwrap().clone();
        match phase.get() {
            2 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    state.pending.borrow().as_ref().unwrap().flows.len(),
                    initial + 3
                );
                assert_eq!(
                    state.captured.borrow().as_ref().unwrap().binding.len(),
                    initial + 4
                );
                let view = super::super::TEST_VIEW
                    .with(|slot| slot.borrow().as_ref().and_then(Weak::upgrade))
                    .unwrap();
                view.name.set_text("Changed elsewhere");
                assert_eq!(state.definition.name, "Tabs · Unicode 🌈");
                state.stage_docs.set_selected(initial as u32);
                state.stages.set_selected(1);
                phase.set(3);
                pause.set(Instant::now());
            }
            3 => {
                if state.stage_after.buffer().char_count() == 0 {
                    return glib::ControlFlow::Continue;
                }
                assert!(buffer(&state.stage_after).contains("fox café🌈"));
                let notebook = state
                    .pane
                    .root
                    .ancestor(gtk::Notebook::static_type())
                    .unwrap()
                    .downcast::<gtk::Notebook>()
                    .unwrap();
                notebook.set_current_page(Some(1));
                phase.set(31);
                pause.set(Instant::now());
            }
            31 => {
                git_view::capture(&state.window, "workflow-tabs-stages");
                let notebook = state
                    .pane
                    .root
                    .ancestor(gtk::Notebook::static_type())
                    .unwrap()
                    .downcast::<gtk::Notebook>()
                    .unwrap();
                notebook.set_current_page(Some(0));
                phase.set(32);
                pause.set(Instant::now());
            }
            32 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    state.apply.is_sensitive(),
                    "return from stages restores full approval readiness"
                );
                state.pane.files.set_selected((initial + 1) as u32);
                phase.set(4);
                pause.set(Instant::now());
            }
            4 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                click(&checkbox(&state), &[]);
                phase.set(5);
                pause.set(Instant::now());
            }
            5 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    state.pane.approvals().unwrap()[initial + 1],
                    Vec::<usize>::new()
                );
                state.pane.files.set_selected(initial as u32);
                phase.set(6);
                pause.set(Instant::now());
            }
            6 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                git_view::capture(&state.window, "workflow-tabs-approved");
                click(&state.apply, &[]);
                phase.set(7);
                pause.set(Instant::now());
            }
            7 => {
                if state.busy.get() || state.restoration.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&a.buffer), "fox café🌈\r\n");
                assert_eq!(buffer_text(&b.buffer), "cat unsaved\n");
                assert!(b.buffer.is_modified());
                assert_eq!(buffer_text(&c.buffer), "unchanged\n");
                assert_eq!(buffer_text(&locked.buffer), "skipped\n");
                assert!(a.buffer.can_undo());
                click(&state.undo, &[]);
                phase.set(8);
                pause.set(Instant::now());
            }
            8 => {
                if state.busy.get() || state.restoration.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&a.buffer), "cat café🌈\r\n");
                assert!(
                    !a.buffer.is_modified(),
                    "joint Undo must restore the saved clean baseline"
                );
                assert!(
                    b.buffer.is_modified(),
                    "preexisting unsaved content stays dirty after joint Undo"
                );
                state.search.emit_clicked();
                phase.set(9);
                pause.set(Instant::now());
            }
            9 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                match stale_case.get() {
                    0 => {
                        b.buffer.set_modified(!b.buffer.is_modified());
                    }
                    1 => {
                        locked.rich.borrow().as_ref().unwrap().active.set(false);
                    }
                    2 => {
                        a.saving.set(true);
                    }
                    3 => {
                        ui.add_document("new.txt", "new\n");
                    }
                    4 => {
                        let n = ui.documents.borrow().len();
                        ui.documents.borrow_mut().pop();
                        ui.tabs.remove_page(Some((n - 1) as u32));
                    }
                    5 => {
                        let mut end = c.buffer.end_iter();
                        c.buffer.insert(&mut end, "external edit\n");
                    }
                    6 => {
                        *a.section_view.borrow_mut() = Some(document_view::DocumentView::new(
                            readonly_source.clone(),
                            true,
                            ui.lang,
                            Rc::new(|| {}),
                        ));
                    }
                    7 => {
                        *a.snapshot.borrow_mut() = Some(
                            fastra_io::Snapshot::read(&alternate, &Cancellation::default())
                                .unwrap(),
                        );
                    }
                    _ => unreachable!(),
                }
                state.apply.emit_clicked();
                assert_eq!(buffer_text(&a.buffer), "cat café🌈\r\n");
                assert!(state.restoration.borrow().is_none());
                a.saving.set(false);
                a.section_view.borrow_mut().take();
                *a.snapshot.borrow_mut() = Some(saved.clone());
                b.buffer.set_modified(true);
                locked.rich.borrow().as_ref().unwrap().active.set(true);
                stale_case.set(stale_case.get() + 1);
                if stale_case.get() < 8 {
                    state.search.emit_clicked();
                    pause.set(Instant::now());
                } else {
                    state.search.emit_clicked();
                    phase.set(10);
                    pause.set(Instant::now());
                }
            }
            10 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                state.apply.emit_clicked();
                phase.set(11);
                pause.set(Instant::now());
            }
            11 => {
                if state.busy.get() || state.restoration.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let applied = buffer_text(&a.buffer);
                let mut end = c.buffer.end_iter();
                c.buffer.insert(&mut end, "break Undo\n");
                state.undo.emit_clicked();
                assert_eq!(buffer_text(&a.buffer), applied);
                assert!(state.restoration.borrow().is_some());
                state.forget.emit_clicked();
                assert!(state.restoration.borrow().is_none());
                state.search.emit_clicked();
                state.cancel_button.emit_clicked();
                assert!(state.pending.borrow().is_none());
                assert!(!state.busy.get());
                phase.set(12);
                pause.set(Instant::now());
            }
            12 => {
                git_view::capture(&state.window, "workflow-tabs-cancelled");
                assert_eq!(
                    std::fs::read(&fixture).unwrap(),
                    "cat café🌈\r\n".as_bytes()
                );
                println!("FASTRA workflow tabs PASS: native immutable workflow hook, complete stages and per-tab approvals, changed/unapproved/no-op/skipped inputs, Apply plus aggregate Undo, stale dirty/Rich/readonly/saving/new/removed/revision/saved-binding rejected, stale Undo rejected, cancellation retained contents");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
fn buffer(view: &gtk::TextView) -> String {
    let b = view.buffer();
    b.text(&b.start_iter(), &b.end_iter(), true).to_string()
}

fn run_locale(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let locale = crate::operations::titlecase_locale().unwrap();
    if let Ok(expected) = std::env::var("FASTRA_TITLECASE_EXPECT_LOCALE") {
        assert_eq!(locale.as_str(), expected);
    }
    let original_ctype =
        unsafe { std::ffi::CStr::from_ptr(libc::setlocale(libc::LC_CTYPE, std::ptr::null())) }
            .to_owned();
    let alternate = if locale.as_str() == "tr_TR" {
        c"C.UTF-8"
    } else {
        c"tr_TR.UTF-8"
    };
    let switch = move |value: &std::ffi::CStr| {
        assert!(!unsafe { libc::setlocale(libc::LC_CTYPE, value.as_ptr()) }.is_null());
    };
    let turkic = matches!(locale.as_str().split('_').next(), Some("tr" | "az"));
    let mapping = std::env::var("FASTRA_CASE_MAPPING").unwrap_or_else(|_| "titlecase".into());
    if mapping.starts_with("sort-") {
        assert_eq!(locale.as_str(), "sv_SE");
    }
    let (source_a, source_b, dirty_b, stage_a, expected_a, expected_b, kind) =
        match (mapping.as_str(), turkic) {
            ("sort-ascending", _) => (
                "ä\r\nz\r\na\r\n",
                "z\nä\na\n",
                "z\nä\na café\n",
                "a\r\nz\r\nä\r\n",
                "a!\r\nz!\r\nä!\r\n",
                "a café!\nz!\nä!\n",
                "sortAscending",
            ),
            ("sort-descending", _) => (
                "a\r\nz\r\nä\r\n",
                "a\nz\nä\n",
                "a café\nz\nä\n",
                "ä\r\nz\r\na\r\n",
                "ä!\r\nz!\r\na!\r\n",
                "ä!\nz!\na café!\n",
                "sortDescending",
            ),
            ("upper", true) => (
                "istanbul\r\n",
                "izmir\n",
                "izmir unsaved\n",
                "İSTANBUL\r\n",
                "İSTANBUL!\r\n",
                "İZMİR UNSAVED!\n",
                "uppercase",
            ),
            ("upper", false) => (
                "istanbul\r\n",
                "izmir\n",
                "izmir unsaved\n",
                "ISTANBUL\r\n",
                "ISTANBUL!\r\n",
                "IZMIR UNSAVED!\n",
                "uppercase",
            ),
            ("lower", true) => (
                "ISTANBUL\r\n",
                "IZMIR\n",
                "IZMIR UNSAVED\n",
                "ıstanbul\r\n",
                "ıstanbul!\r\n",
                "ızmır unsaved!\n",
                "lowercase",
            ),
            ("lower", false) => (
                "ISTANBUL\r\n",
                "IZMIR\n",
                "IZMIR UNSAVED\n",
                "istanbul\r\n",
                "istanbul!\r\n",
                "izmir unsaved!\n",
                "lowercase",
            ),
            (_, true) => (
                "istanbul\r\n",
                "izmir\n",
                "izmir unsaved\n",
                "İstanbul\r\n",
                "İstanbul!\r\n",
                "İzmir Unsaved!\n",
                "titlecase",
            ),
            (_, false) => (
                "istanbul\r\n",
                "izmir\n",
                "izmir unsaved\n",
                "Istanbul\r\n",
                "Istanbul!\r\n",
                "Izmir Unsaved!\n",
                "titlecase",
            ),
        };
    if mapping.starts_with("sort-") {
        assert_ne!(dirty_b, source_b);
    }
    let fixture =
        PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join("titlecase-tabs.txt");
    std::fs::write(&fixture, source_a).unwrap();
    let initial = ui.documents.borrow().len();
    ui.add_document("Titlecase-clean.txt", source_a);
    let a = ui.active().unwrap();
    *a.snapshot.borrow_mut() =
        Some(fastra_io::Snapshot::read(&fixture, &Cancellation::default()).unwrap());
    ui.add_document("Titlecase-dirty.txt", source_b);
    let b = ui.active().unwrap();
    b.buffer.set_text(dirty_b);
    b.buffer.set_modified(true);
    let mut definition = definition();
    definition.name = format!("Immutable system-locale {mapping}");
    definition.steps = vec![
        fastra_workflow::Step::new(kind).unwrap(),
        fastra_workflow::Step::new("suffixLines").unwrap(),
    ];
    definition.steps[1].argument = "!".into();
    super::super::show(&ui, false);
    let holder = RefCell::new(None::<Rc<State>>);
    let phase = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(60),
            "workflow tabs locale timeout phase{}",
            phase.get()
        );
        if pause.get().elapsed() < Duration::from_millis(250) {
            return glib::ControlFlow::Continue;
        }
        if phase.get() == 0 {
            let view = super::super::TEST_VIEW
                .with(|slot| slot.borrow().as_ref().and_then(Weak::upgrade))
                .unwrap();
            if view.busy.get() || view.snapshot.borrow().is_none() {
                return glib::ControlFlow::Continue;
            }
            *view.draft.borrow_mut() = Some(super::super::Draft::Flow(definition.clone()));
            view.dirty.set(false);
            view.refresh();
            click(&view.all_tabs, &[]);
            phase.set(1);
            pause.set(Instant::now());
            return glib::ControlFlow::Continue;
        }
        if phase.get() == 1 {
            let Some(state) =
                TEST_STATE.with(|slot| slot.borrow().as_ref().and_then(Weak::upgrade))
            else {
                return glib::ControlFlow::Continue;
            };
            git_view::test_size(&state.window);
            *holder.borrow_mut() = Some(state);
            phase.set(2);
            pause.set(Instant::now());
            return glib::ControlFlow::Continue;
        }
        let state = holder.borrow().as_ref().unwrap().clone();
        match phase.get() {
            2 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                let pending = state.pending.borrow();
                let computed = pending.as_ref().unwrap();
                assert!(computed
                    .flows
                    .iter()
                    .all(|flow| flow.locale() == Some(&locale)));
                eprintln!("CASE TABS mapping={mapping} locale={} actualA={:?} expectedA={expected_a:?} actualB={:?} expectedB={expected_b:?}",locale.as_str(),computed.flows[initial].output(),computed.flows[initial+1].output());
                assert_eq!(computed.flows[initial].output(), expected_a);
                assert_eq!(computed.flows[initial + 1].output(), expected_b);
                assert!(state.status.text().contains(locale.as_str()));
                assert_eq!(state.definition, definition);
                state.stage_docs.set_selected(initial as u32);
                state.stages.set_selected(0);
                phase.set(3);
            }
            3 => {
                if buffer(&state.stage_after).is_empty() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer(&state.stage_after), stage_a);
                assert!(state.stage_status.text().contains(locale.as_str()));
                let notebook = state
                    .pane
                    .root
                    .ancestor(gtk::Notebook::static_type())
                    .unwrap()
                    .downcast::<gtk::Notebook>()
                    .unwrap();
                notebook.set_current_page(Some(1));
                phase.set(4);
            }
            4 => {
                git_view::capture(&state.window, "workflow-tabs-locale-stages");
                let notebook = state
                    .pane
                    .root
                    .ancestor(gtk::Notebook::static_type())
                    .unwrap()
                    .downcast::<gtk::Notebook>()
                    .unwrap();
                notebook.set_current_page(Some(0));
                phase.set(5);
            }
            5 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                git_view::capture(&state.window, "workflow-tabs-locale-final");
                click(&state.apply, &[]);
                phase.set(6);
            }
            6 => {
                if state.busy.get() || state.restoration.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&a.buffer), expected_a);
                assert_eq!(buffer_text(&b.buffer), expected_b);
                assert!(a.buffer.is_modified());
                assert!(b.buffer.is_modified());
                switch(alternate);
                click(&state.undo, &[]);
                phase.set(7);
            }
            7 => {
                if state.busy.get() || state.restoration.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&a.buffer), source_a);
                assert_eq!(buffer_text(&b.buffer), dirty_b);
                assert!(!a.buffer.is_modified());
                assert!(b.buffer.is_modified());
                switch(&original_ctype);
                state.search.emit_clicked();
                phase.set(8);
            }
            8 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                switch(alternate);
                state.apply.emit_clicked();
                assert!(state.pending.borrow().is_none());
                assert!(state.restoration.borrow().is_none());
                assert_eq!(buffer_text(&a.buffer), source_a);
                assert_eq!(buffer_text(&b.buffer), dirty_b);
                switch(&original_ctype);
                state.search.emit_clicked();
                switch(alternate);
                phase.set(9);
            }
            9 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.pending.borrow().is_none());
                assert!(!state.apply.is_sensitive());
                assert_eq!(buffer_text(&a.buffer), source_a);
                assert!(b.buffer.is_modified());
                switch(&original_ctype);
                state.search.emit_clicked();
                phase.set(10);
            }
            10 => {
                if !ready(&state) {
                    return glib::ControlFlow::Continue;
                }
                state.apply.emit_clicked();
                assert!(state.busy.get());
                switch(alternate);
                phase.set(11);
            }
            11 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.pending.borrow().is_none());
                assert!(state.restoration.borrow().is_none());
                assert_eq!(buffer_text(&a.buffer), source_a);
                assert_eq!(buffer_text(&b.buffer), dirty_b);
                assert!(b.buffer.is_modified());
                switch(&original_ctype);
                assert_eq!(std::fs::read(&fixture).unwrap(), source_a.as_bytes());
                eprintln!("CASE TABS PASS mapping={mapping}");
                println!("FASTRA workflow tabs locale PASS: actual LC_CTYPE {}, immutable definition, explicit per-tab context and ID, complete stages, native Apply, dirty/clean aggregate Undo across locale change, stale Apply, late preview and late Apply plan rejected, disk unchanged",locale.as_str());
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
