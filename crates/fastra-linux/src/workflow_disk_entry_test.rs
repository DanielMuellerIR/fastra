use super::selftest::{find, view};
use super::*;
fn first_entry(widget: &gtk::Widget) -> Option<gtk::Entry> {
    if let Some(e) = widget.downcast_ref::<gtk::Entry>() {
        return Some(e.clone());
    }
    let mut child = widget.first_child();
    while let Some(w) = child {
        if let Some(e) = first_entry(&w) {
            return Some(e);
        }
        child = w.next_sibling();
    }
    None
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let base = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let inputs = base.join("inputs");
    std::fs::create_dir_all(&inputs).unwrap();
    let scope = std::env::var("FASTRA_WORKFLOW_DISK_SCOPE").unwrap_or_else(|_| "folder".into());
    std::fs::write(inputs.join("a.txt"), b"\xef\xbb\xbfcat\r\n").unwrap();
    let mut utf16 = vec![0xff, 0xfe];
    for u in "cat café\r\n".encode_utf16() {
        utf16.extend(u.to_le_bytes());
    }
    std::fs::write(inputs.join("b.txt"), utf16).unwrap();
    std::fs::write(inputs.join("c.txt"), "NONE\n").unwrap();
    if std::env::var_os("FASTRA_WORKFLOW_DISK_ENCODING").is_some() {
        std::fs::write(inputs.join("bad.txt"), b"cat\x80").unwrap();
    }
    ui.add_document("Workflow-file.txt", "cat\r\n");
    let doc = ui.active().unwrap();
    *doc.snapshot.borrow_mut() =
        Some(fastra_io::Snapshot::read(&inputs.join("a.txt"), &Cancellation::default()).unwrap());
    if std::env::var_os("FASTRA_WORKFLOW_DISK_INITIAL_DIRTY").is_some() {
        doc.buffer.insert(&mut doc.buffer.end_iter(), " dirty");
    }
    if scope == "project" {
        crate::project_view::open(&ui);
        let window = gtk::Window::list_toplevels()
            .into_iter()
            .filter_map(|w| w.downcast::<gtk::Window>().ok())
            .find(|w| w.title().as_deref() == Some(ui.lang.text("Projektdateien", "Project files")))
            .unwrap();
        first_entry(window.upcast_ref())
            .unwrap()
            .set_text(inputs.to_str().unwrap());
    }
    let phase = Cell::new(0);
    let pause = Cell::new(std::time::Instant::now());
    let started = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            started.elapsed() < Duration::from_secs(25),
            "disk entry phase{}",
            phase.get()
        );
        if pause.get().elapsed() < Duration::from_millis(300) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                if scope == "project" && crate::project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                show(&ui, false);
            }
            1 => {
                let Some(v) = view().filter(|v| v.snapshot.borrow().is_some() && !v.busy.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                let mut first = Step::new("replace").unwrap();
                first.find = "cat".into();
                let titlecase = std::env::var_os("FASTRA_WORKFLOW_DISK_TITLECASE").is_some();
                let mapping =
                    std::env::var("FASTRA_CASE_MAPPING").unwrap_or_else(|_| "titlecase".into());
                first.replacement = if titlecase {
                    if mapping.starts_with("sort-") {
                        "ä\r\nz\r\na".into()
                    } else if mapping == "lower" {
                        "ISTANBUL".into()
                    } else {
                        "istanbul".into()
                    }
                } else if std::env::var_os("FASTRA_WORKFLOW_DISK_ENCODING").is_some() {
                    "雪".into()
                } else {
                    "dog".into()
                };
                *v.draft.borrow_mut() = Some(Draft::Flow(Workflow {
                    id: workflow::new_id().unwrap(),
                    revision: workflow::new_id().unwrap(),
                    name: "Immutable disk workflow".into(),
                    steps: vec![
                        first,
                        Step::new(if titlecase {
                            match mapping.as_str() {
                                "sort-ascending" => "sortAscending",
                                "sort-descending" => "sortDescending",
                                "upper" => "uppercase",
                                "lower" => "lowercase",
                                _ => "titlecase",
                            }
                        } else {
                            "uppercase"
                        })
                        .unwrap(),
                    ],
                    extra: Default::default(),
                }));
                v.dirty.set(false);
                v.refresh();
                if std::env::var_os("FASTRA_WORKFLOW_DISK_READONLY").is_some() {
                    let source = fastra_document::Document::open_hex(
                        &inputs.join("a.txt"),
                        &Cancellation::default(),
                    )
                    .unwrap();
                    *doc.section_view.borrow_mut() = Some(document_view::DocumentView::new(
                        source,
                        true,
                        ui.lang,
                        Rc::new(|| {}),
                    ));
                    doc.snapshot.borrow_mut().take();
                    doc.buffer.set_text("");
                    doc.buffer.set_modified(false);
                }

                git_view::test_click(&v.disk, &[]);
            }
            2 => {
                let v = view().unwrap();
                let label = match scope.as_str() {
                    "file" => ui
                        .lang
                        .text("Gespeicherte aktive Datei …", "Saved active file …"),
                    "project" => ui
                        .lang
                        .text("Dateien aus dem Projekt …", "Files from the project …"),
                    _ => ui
                        .lang
                        .text("Dateien aus einem Ordner …", "Files from a folder …"),
                };
                git_view::test_click(&find(v.window.upcast_ref(), label).unwrap(), &[]);
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(std::time::Instant::now());
        glib::ControlFlow::Continue
    });
}
