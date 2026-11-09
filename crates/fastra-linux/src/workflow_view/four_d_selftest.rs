use super::selftest::{click, find, picker, set_open_path, snapshot, text, view};
use super::*;
#[derive(serde::Deserialize)]
struct Expected {
    source: String,
    selection: [usize; 2],
    stages: Vec<String>,
    expected: String,
}
fn select(doc: &Document, data: &Expected) {
    let source = buffer_text(&doc.buffer);
    let prefix_end = data.selection[0];
    let mut units = 0;
    let mut a = 0;
    for c in source.chars() {
        if units >= prefix_end {
            break;
        }
        units += c.len_utf16();
        a += 1;
    }
    let suffix = data.source[Utf16Range {
        location: data.selection[0],
        length: data.selection[1],
    }
    .byte_range(&data.source)
    .unwrap()
    .end..]
        .chars()
        .count() as i32;
    let b = doc.buffer.char_count() - suffix;
    doc.buffer
        .select_range(&doc.buffer.iter_at_offset(a), &doc.buffer.iter_at_offset(b));
}
fn menu(ui: &Ui, de: &'static str, en: &'static str) {
    click(
        &ui.window,
        &find(ui.window.upcast_ref(), ui.lang.text(de, en)).unwrap(),
    );
}
pub(super) fn run(ui: Rc<Ui>) {
    let expected: Expected = serde_json::from_slice(include_bytes!(
        "../../../fastra-workflow/tests/fixtures/four-d-workflow-results.json"
    ))
    .unwrap();
    let fixture =
        PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap()).join("four-d-workflow.json");
    std::fs::write(
        &fixture,
        include_bytes!("../../../fastra-workflow/tests/fixtures/four-d-workflow-swift.json"),
    )
    .unwrap();
    ui.window.set_title(Some(&format!(
        "Fastra 4D Transform Test {}",
        std::process::id()
    )));
    ui.add_document("four-d-transform.4dm", &expected.source);
    let doc = ui.active().unwrap();
    select(&doc, &expected);
    let r = Utf16Range {
        location: expected.selection[0],
        length: expected.selection[1],
    }
    .byte_range(&expected.source)
    .unwrap();
    let first = format!(
        "{}{}{}",
        &expected.source[..r.start],
        expected.stages[0],
        &expected.source[r.end..]
    );
    let stage = Cell::new(0);
    let stamp = Cell::new(std::time::Instant::now());
    let start = std::time::Instant::now();
    let capture = RefCell::new(None::<std::sync::Arc<std::sync::atomic::AtomicBool>>);
    glib::timeout_add_local(Duration::from_millis(100), move || {
        assert!(
            start.elapsed() < Duration::from_secs(90),
            "4D transform stage{} timed out",
            stage.get()
        );
        if stamp.get().elapsed() < Duration::from_millis(400) {
            return glib::ControlFlow::Continue;
        }
        eprintln!("4D transform stage{}", stage.get());
        let v = view();
        match stage.get() {
            0 => menu(&ui, "Text", "Text"),
            1 => menu(&ui, "4D", "4D"),
            2 => menu(
                &ui,
                "4D-Token-Suffixe entfernen",
                "Remove 4D token suffixes",
            ),
            3 => {
                if buffer_text(&doc.buffer) == expected.source {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), first);
                menu(&ui, "Rückgängig", "Undo");
            }
            4 => {
                assert_eq!(buffer_text(&doc.buffer), expected.source);
                doc.buffer.set_text(&first);
                select(&doc, &expected);
                menu(&ui, "Text", "Text");
            }
            5 => menu(&ui, "4D", "4D"),
            6 => menu(
                &ui,
                "4D-Befehls-Token ergänzen (keine Konstanten)",
                "Add 4D command tokens (no constants)",
            ),
            7 => {
                if buffer_text(&doc.buffer) == first {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), expected.expected);
                menu(&ui, "Rückgängig", "Undo");
            }
            8 => {
                assert_eq!(buffer_text(&doc.buffer), first);
                doc.buffer.set_text(&expected.source);
                select(&doc, &expected);
                menu(&ui, "Werkzeuge", "Tools");
            }
            9 => menu(&ui, "Gespeicherte Textabläufe …", "Saved text workflows …"),
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
                p.set_title(Some("Fastra 4D Import"));
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
                assert_eq!(v.steps.row_at_index(2), None);
                v.scope.set_selected(1);
                select(&doc, &expected);
                click(&v.window, &v.calculate);
            }
            14 => {
                let v = v.unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(v.pending.borrow().is_some(), "{}", v.status.text());
                assert_eq!(text(&v.after), expected.expected);
                v.stages.set_selected(1);
                v.window.set_default_size(860, 760);
            }
            15 => {
                let v = v.unwrap();
                assert_eq!(text(&v.after), expected.stages[0]);
                v.steps.select_row(v.steps.row_at_index(1).as_ref());
            }
            16 => {
                let v = v.unwrap();
                assert!(
                    v.window.width() <= 900,
                    "minimum workflow width={}",
                    v.window.width()
                );
                if std::env::var_os("FASTRA_WORKFLOW_SCREENSHOT_DIR").is_some() {
                    *capture.borrow_mut() = Some(snapshot(&format!(
                        "four-d-transform-{}.min.png",
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
                v.unwrap().window.set_default_size(1280, 850);
            }
            18 => {
                if std::env::var_os("FASTRA_WORKFLOW_SCREENSHOT_DIR").is_some() {
                    *capture.borrow_mut() = Some(snapshot(&format!(
                        "four-d-transform-{}.wide.png",
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
                assert_eq!(buffer_text(&doc.buffer), expected.expected);
                assert!(!v.unwrap().apply.is_sensitive());
                ui.window.present();
                menu(&ui, "Rückgängig", "Undo");
            }
            21 => {
                assert_eq!(buffer_text(&doc.buffer), expected.source);
                select(&doc, &expected);
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
                doc.buffer.insert(&mut doc.buffer.end_iter(), "changed");
                assert!(!v.apply.is_sensitive());
                assert!(v.pending.borrow().is_none());
                v.window.close();
                ui.window.present();
                doc.buffer.begin_irreversible_action();
                doc.buffer.set_text("ALERT:C41\u{307}");
                doc.buffer.end_irreversible_action();
                doc.buffer.begin_user_action();
                doc.buffer.insert(&mut doc.buffer.end_iter(), " ");
                doc.buffer.end_user_action();
                menu(&ui, "Text", "Text");
            }
            23 => menu(&ui, "4D", "4D"),
            24 => menu(
                &ui,
                "4D-Token-Suffixe entfernen",
                "Remove 4D token suffixes",
            ),
            25 => {
                if !ui.status.text().contains("Unicode") {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "ALERT:C41\u{307} ");
                assert!(doc.buffer.can_undo());
                if let Some(directory) = std::env::var_os("FASTRA_WORKFLOW_SCREENSHOT_DIR") {
                    super::super::git_view::capture_to(
                        ui.window.upcast_ref::<gtk::Window>(),
                        &PathBuf::from(directory).join(format!(
                            "four-d-error-{}.png",
                            if ui.lang.0 { "de" } else { "en" }
                        )),
                    );
                }
                menu(&ui, "Rückgängig", "Undo");
            }
            26 => {
                assert_eq!(buffer_text(&doc.buffer), "ALERT:C41\u{307}");
                assert!(!doc.buffer.can_undo());
                std::fs::remove_file(&fixture).unwrap();
                println!("FASTRA_4D_TRANSFORM_SELFTEST_OK native-text-menu/both-4d-transforms/selection/one-undo/protected-strings-comments-and-types/swift-workflow-import/complete-step-preview/apply-undo/stale-input/split-grapheme-refused-source-and-undo-kept/min-wide");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        stamp.set(std::time::Instant::now());
        glib::ControlFlow::Continue
    });
}
