use super::selftest::{
    click, click_with_keys, find, picker, set_open_path, set_save_path, snapshot, text, view,
};
use super::*;
#[derive(serde::Deserialize)]
struct Case {
    source: String,
    selection: Option<[usize; 2]>,
    stages: Vec<String>,
    expected: String,
}
fn native_source(widget: &gtk::Widget) -> Option<sourceview5::View> {
    if let Some(view) = widget.downcast_ref::<sourceview5::View>() {
        return Some(view.clone());
    }
    let mut child = widget.first_child();
    while let Some(item) = child {
        if let Some(v) = native_source(&item) {
            return Some(v);
        }
        child = item.next_sibling();
    }
    None
}
fn prompt(ui: &Ui) -> Option<(gtk::Window, gtk::Entry)> {
    fn entry(widget: &gtk::Widget) -> Option<gtk::Entry> {
        if let Some(e) = widget.downcast_ref::<gtk::Entry>() {
            return Some(e.clone());
        }
        let mut child = widget.first_child();
        while let Some(item) = child {
            if let Some(e) = entry(&item) {
                return Some(e);
            }
            child = item.next_sibling();
        }
        None
    }
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| {
            w.title().as_deref() == Some("Fastra Hard Wrap Test")
                || w.title().as_deref()
                    == Some(ui.lang.text("Harter Zeilenumbruch …", "Hard wrap …"))
        })
        .and_then(|w| entry(w.upcast_ref()).map(|e| (w, e)))
}
fn select_case(doc: &Document, case: &Case) {
    let range = case.selection.unwrap();
    let bytes = Utf16Range {
        location: range[0],
        length: range[1],
    }
    .byte_range(&case.source)
    .unwrap();
    doc.buffer.select_range(
        &doc.buffer
            .iter_at_offset(case.source[..bytes.start].chars().count() as i32),
        &doc.buffer
            .iter_at_offset(case.source[..bytes.end].chars().count() as i32),
    );
}
fn menu(ui: &Ui, text: &str) {
    click(&ui.window, &find(ui.window.upcast_ref(), text).unwrap());
}
pub(super) fn run(ui: Rc<Ui>) {
    let fixture =
        PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap()).join("extended-workflows.json");
    std::fs::write(
        &fixture,
        include_bytes!("../../../fastra-workflow/tests/fixtures/swift-extended-workflows.json"),
    )
    .unwrap();
    let export = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap())
        .join(format!("extended-workflows-{}.json", std::process::id()));
    let cases: Vec<Case> = serde_json::from_slice(include_bytes!(
        "../../../fastra-workflow/tests/fixtures/swift-extended-workflow-results.json"
    ))
    .unwrap();
    ui.window.set_title(Some(&format!(
        "Fastra Extended Text Test {}",
        std::process::id()
    )));
    ui.add_document("extended.txt", "a\tb\n\tc");
    let doc = ui.active().unwrap();
    let source = native_source(doc.container.upcast_ref()).unwrap();
    source.set_tab_width(3);
    source.set_indent_width(2);
    source.set_insert_spaces_instead_of_tabs(true);
    assert_eq!(crate::editor_options::indentation(&doc), (false, 2, 3));
    let stage = Cell::new(0);
    let undo_before_nul = Cell::new(false);
    let stamp = Cell::new(std::time::Instant::now());
    let start = std::time::Instant::now();
    let capture = RefCell::new(None::<std::sync::Arc<std::sync::atomic::AtomicBool>>);
    glib::timeout_add_local(Duration::from_millis(100), move || {
        assert!(
            start.elapsed() < Duration::from_secs(90),
            "extended stage{} timed out",
            stage.get()
        );
        if stamp.get().elapsed() < Duration::from_millis(400) {
            return glib::ControlFlow::Continue;
        }
        eprintln!("extended text stage{}", stage.get());
        let v = view();
        match stage.get() {
            0 => menu(&ui, "Text"),
            1 => menu(&ui, ui.lang.text("Einrückung / Tabs", "Indentation / tabs")),
            2 => menu(&ui, ui.lang.text("Tabs in Leerzeichen", "Tabs to spaces")),
            3 => {
                if buffer_text(&doc.buffer) == "a\tb\n\tc" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "a  b\n   c");
                menu(&ui, ui.lang.text("Rückgängig", "Undo"));
            }
            4 => {
                assert_eq!(buffer_text(&doc.buffer), "a\tb\n\tc");
                doc.buffer.place_cursor(&doc.buffer.iter_at_offset(2));
                menu(&ui, "Text");
            }
            5 => menu(&ui, ui.lang.text("Vertauschen", "Transpose")),
            6 => menu(
                &ui,
                ui.lang.text("Zeichen vertauschen", "Transpose characters"),
            ),
            7 => {
                if buffer_text(&doc.buffer) == "a\tb\n\tc" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "ab\t\n\tc");
                menu(&ui, ui.lang.text("Rückgängig", "Undo"));
            }
            8 => {
                assert_eq!(buffer_text(&doc.buffer), "a\tb\n\tc");
                doc.buffer.set_text(r"\x00");
                undo_before_nul.set(doc.buffer.can_undo());
                menu(&ui, "Text");
                stage.set(99);
            }
            100 => menu(
                &ui,
                ui.lang
                    .text("Anführungszeichen / Escapes", "Quotes / escapes"),
            ),
            101 => menu(
                &ui,
                ui.lang
                    .text("Escape-Sequenzen umwandeln", "Convert escape sequences"),
            ),
            102 => {
                if !ui.status.text().contains("U+0000") {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), r"\x00");
                assert_eq!(doc.buffer.can_undo(), undo_before_nul.get());
                doc.buffer.set_text("one two three");
                menu(&ui, "Text");
                stage.set(109);
            }
            110 => menu(&ui, ui.lang.text("Harter Zeilenumbruch …", "Hard wrap …")),
            111 => {
                let Some((window, field)) = prompt(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                window.set_title(Some("Fastra Hard Wrap Test"));
                click_with_keys(&window, &field, &["ctrl+a", "4", "Return"]);
            }
            112 => {
                let (window, field) = prompt(&ui).unwrap();
                assert_eq!(field.text(), "4");
                click(
                    &window,
                    &find(window.upcast_ref(), ui.lang.text("Anwenden", "Apply")).unwrap(),
                );
            }
            113 => {
                if buffer_text(&doc.buffer) == "one two three" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "one\ntwo\nthree");
                menu(&ui, ui.lang.text("Rückgängig", "Undo"));
            }
            114 => {
                assert_eq!(buffer_text(&doc.buffer), "one two three");
                stage.set(8);
                doc.buffer.set_text(&cases[0].source);
                let range = cases[0].selection.unwrap();
                let bytes = Utf16Range {
                    location: range[0],
                    length: range[1],
                }
                .byte_range(&cases[0].source)
                .unwrap();
                doc.buffer.select_range(
                    &doc.buffer
                        .iter_at_offset(cases[0].source[..bytes.start].chars().count() as i32),
                    &doc.buffer
                        .iter_at_offset(cases[0].source[..bytes.end].chars().count() as i32),
                );
                menu(&ui, ui.lang.text("Werkzeuge", "Tools"));
            }
            9 => menu(
                &ui,
                ui.lang
                    .text("Gespeicherte Textabläufe …", "Saved text workflows …"),
            ),
            10 => {
                let Some(v) = v.filter(|v| v.snapshot.borrow().is_some()) else {
                    return glib::ControlFlow::Continue;
                };
                click(&v.window, &v.import);
            }
            11 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                p.set_title(Some("Fastra Extended Import"));
                set_open_path(&p, &fixture);
            }
            12 => {
                if let Some(p) = picker() {
                    let b = ["Open", "_Open", "Öffnen", "_Öffnen"]
                        .iter()
                        .find_map(|s| find(p.upcast_ref(), s))
                        .unwrap();
                    click(&p, &b);
                    return glib::ControlFlow::Continue;
                }
                let Some(p) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| {
                        w.title().as_deref()
                            == Some(ui.lang.text(
                                "Sammlung vor Import prüfen",
                                "Review collection before importing",
                            ))
                    })
                else {
                    return glib::ControlFlow::Continue;
                };
                click(
                    &p,
                    &find(
                        p.upcast_ref(),
                        ui.lang.text("Sammlung importieren", "Import collection"),
                    )
                    .unwrap(),
                );
            }
            13 => {
                let Some(v) = v.filter(|v| !v.busy.get() && v.draft.borrow().is_some()) else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    v.snapshot
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .library
                        .workflows
                        .workflows
                        .len(),
                    5
                );
                v.scope.set_selected(1);
                assert_eq!(v.tab_width.value_as_int(), 3);
                assert_eq!(v.indent_width.value_as_int(), 2);
                assert!(!v.uses_tabs.is_active());
                assert!(v.profile.is_visible());
                click(&v.window, &v.calculate);
            }
            14 => {
                let v = v.unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(v.pending.borrow().is_some(), "{}", v.status.text());
                assert_eq!(text(&v.after), cases[0].expected);
                v.stages.set_selected(1);
            }
            15 => {
                let v = v.unwrap();
                assert_eq!(text(&v.after), cases[0].stages[0]);
                v.window.set_default_size(860, 760);
            }
            16 => {
                let v = v.unwrap();
                assert!(v.window.height() <= 1000);
                if std::env::var_os("FASTRA_WORKFLOW_SCREENSHOT_DIR").is_some() {
                    *capture.borrow_mut() = Some(snapshot(&format!(
                        "extended-workflow-{}.min.png",
                        if ui.lang.0 { "de" } else { "en" }
                    )));
                }
            }
            17 => {
                if capture
                    .borrow()
                    .as_ref()
                    .is_some_and(|c| !c.load(std::sync::atomic::Ordering::Acquire))
                {
                    return glib::ControlFlow::Continue;
                }
                let v = v.unwrap();
                v.window.set_default_size(1280, 850);
                v.steps.select_row(v.steps.row_at_index(2).as_ref());
            }
            18 => {
                let v = v.unwrap();
                assert!(v.uses_tabs.is_sensitive());
                assert!(v.indent_width.is_sensitive());
                if std::env::var_os("FASTRA_WORKFLOW_SCREENSHOT_DIR").is_some() {
                    *capture.borrow_mut() = Some(snapshot(&format!(
                        "extended-workflow-{}.wide.png",
                        if ui.lang.0 { "de" } else { "en" }
                    )));
                }
            }
            19 => {
                if capture
                    .borrow()
                    .as_ref()
                    .is_some_and(|c| !c.load(std::sync::atomic::Ordering::Acquire))
                {
                    return glib::ControlFlow::Continue;
                }
                let v = v.unwrap();
                click(&v.window, &v.apply);
            }
            20 => {
                assert_eq!(buffer_text(&doc.buffer), cases[0].expected);
                assert!(!v.unwrap().apply.is_sensitive());
                ui.window.present();
                menu(&ui, ui.lang.text("Rückgängig", "Undo"));
            }
            21 => {
                assert_eq!(buffer_text(&doc.buffer), cases[0].source);
                select_case(&doc, &cases[0]);
                let v = v.unwrap();
                v.window.present();
                click(&v.window, &v.calculate);
            }
            22 => {
                let v = v.unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(v.pending.borrow().is_some());
                click_with_keys(&v.window, &v.tab_width, &["ctrl+a", "4", "Return"]);
            }
            23 => {
                let v = v.unwrap();
                assert_eq!(v.tab_width.value_as_int(), 4);
                assert!(v.pending.borrow().is_none());
                assert!(!v.apply.is_sensitive());
                assert_eq!(buffer_text(&doc.buffer), cases[0].source);
                click_with_keys(&v.window, &v.tab_width, &["ctrl+a", "3", "Return"]);
            }
            24 => {
                let v = v.unwrap();
                assert_eq!(v.tab_width.value_as_int(), 3);
                click(&v.window, &v.save);
            }
            25 => {
                let v = v.unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!v.dirty.get());
                click(&v.window, &v.export);
            }
            26 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                p.set_title(Some("Fastra Extended Export"));
                set_save_path(&p, &export);
            }
            27 => {
                if let Some(p) = picker() {
                    let b = ["Save", "_Save", "Speichern", "_Speichern"]
                        .iter()
                        .find_map(|s| find(p.upcast_ref(), s))
                        .unwrap();
                    click(&p, &b);
                    return glib::ControlFlow::Continue;
                }
                let v = v.unwrap();
                if v.busy.get() || !export.exists() {
                    return glib::ControlFlow::Continue;
                }
                let loaded = WorkflowArchive::decode(&std::fs::read(&export).unwrap()).unwrap();
                assert_eq!(loaded.workflows.len(), 5);
                assert_eq!(loaded.workflows[0].steps[2].tab_width, 3);
                assert_eq!(loaded.workflows[0].steps[2].indent_width, 2);
                std::fs::remove_file(&export).unwrap();
                std::fs::remove_file(&fixture).unwrap();
                println!("FASTRA_EXTENDED_TEXT_SELFTEST_OK native-text-submenus/profile-detab/actual-caret-transpose/one-undo/generated-nul-blocked/native-hard-wrap-prompt/swift-archive-import-export/4-step-selection/intermediate-full-preview/profile-edit-stale/min-wide");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        stamp.set(std::time::Instant::now());
        glib::ControlFlow::Continue
    });
}
