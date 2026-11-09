use super::selftest::{click, find, picker, set_open_path, snapshot, text, view};
use super::*;
fn menu(ui: &Ui, de: &'static str, en: &'static str) {
    click(
        &ui.window,
        &find(ui.window.upcast_ref(), ui.lang.text(de, en)).unwrap(),
    );
}
fn select(doc: &Document) {
    let buffer = if std::env::var_os("FASTRA_CASE_SOURCE_SECONDARY").is_some() {
        doc.source_panes.borrow().as_ref().unwrap().buffers[1].clone()
    } else {
        doc.buffer.clone()
    };
    let sorting = std::env::var("FASTRA_CASE_MAPPING")
        .unwrap_or_default()
        .starts_with("sort-");
    let (start, end) = if sorting { (7, 12) } else { (2, 16) };
    buffer.select_range(&buffer.iter_at_offset(start), &buffer.iter_at_offset(end));
}
fn source_views(widget: &gtk::Widget, views: &mut Vec<sourceview5::View>) {
    if let Some(view) = widget.downcast_ref::<sourceview5::View>() {
        views.push(view.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        source_views(&widget, views);
        child = widget.next_sibling();
    }
}

pub(super) fn run(ui: Rc<Ui>) {
    let locale = crate::operations::titlecase_locale().unwrap();
    if let Ok(expected) = std::env::var("FASTRA_TITLECASE_EXPECT_LOCALE") {
        assert_eq!(locale.as_str(), expected);
    }
    let fixture =
        PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap()).join("titlecase-workflow.json");
    let mapping = std::env::var("FASTRA_CASE_MAPPING").unwrap_or_else(|_| "titlecase".into());
    let kind = match mapping.as_str() {
        "upper" => "uppercase",
        "lower" => "lowercase",
        "titlecase" => "titlecase",
        "sort-ascending" => "sortAscending",
        "sort-descending" => "sortDescending",
        _ => panic!("unsupported mapping"),
    };
    let sorting = mapping.starts_with("sort-");
    if sorting {
        assert_eq!(locale.as_str(), "sv_SE");
    }
    let original_ctype =
        unsafe { std::ffi::CStr::from_ptr(libc::setlocale(libc::LC_CTYPE, std::ptr::null())) }
            .to_owned();
    let mut definition: serde_json::Value = serde_json::from_slice(include_bytes!(
        "../../../fastra-workflow/tests/fixtures/titlecase-workflow-swift.json"
    ))
    .unwrap();
    definition["workflows"][0]["steps"][0]["kind"] = kind.into();
    std::fs::write(&fixture, serde_json::to_vec_pretty(&definition).unwrap()).unwrap();
    ui.window.set_title(Some(&format!(
        "Fastra Titlecase Test {}",
        std::process::id()
    )));
    let turkic = matches!(locale.as_str().split('_').next(), Some("tr" | "az"));
    let (source, first, selected, final_text) = match (mapping.as_str(), turkic) {
        ("sort-ascending", _) => (
            "😀 head\nä\nz\na\ntail",
            "😀 head\na\nz\nä\ntail",
            "a\nz\nä",
            "😀 head\na!\nz!\nä!\ntail",
        ),
        ("sort-descending", _) => (
            "😀 head\na\nz\nä\ntail",
            "😀 head\nä\nz\na\ntail",
            "ä\nz\na",
            "😀 head\nä!\nz!\na!\ntail",
        ),
        ("upper", true) => (
            "😀 istanbul izmir tail",
            "😀 İSTANBUL İZMİR tail",
            "İSTANBUL İZMİR",
            "😀 İSTANBUL İZMİR! tail",
        ),
        ("upper", false) => (
            "😀 istanbul izmir tail",
            "😀 ISTANBUL IZMIR tail",
            "ISTANBUL IZMIR",
            "😀 ISTANBUL IZMIR! tail",
        ),
        ("lower", true) => (
            "😀 ISTANBUL IZMIR tail",
            "😀 ıstanbul ızmır tail",
            "ıstanbul ızmır",
            "😀 ıstanbul ızmır! tail",
        ),
        ("lower", false) => (
            "😀 ISTANBUL IZMIR tail",
            "😀 istanbul izmir tail",
            "istanbul izmir",
            "😀 istanbul izmir! tail",
        ),
        (_, true) => (
            "😀 istanbul izmir tail",
            "😀 İstanbul İzmir tail",
            "İstanbul İzmir",
            "😀 İstanbul İzmir! tail",
        ),
        (_, false) => (
            "😀 istanbul izmir tail",
            "😀 Istanbul Izmir tail",
            "Istanbul Izmir",
            "😀 Istanbul Izmir! tail",
        ),
    };
    ui.add_document("titlecase.txt", source);
    let doc = ui.active().unwrap();
    let saved_fixture = if sorting {
        PathBuf::from(
            std::env::var_os("FASTRA_UI_TEST_ROOT")
                .expect("FASTRA_UI_TEST_ROOT is required for the sort save fixture"),
        )
        .join("sort-menu-saved.txt")
    } else {
        fixture.with_file_name("sort-menu-saved.txt")
    };
    if sorting {
        std::fs::write(&saved_fixture, source).unwrap();
        *doc.snapshot.borrow_mut() =
            Some(fastra_io::Snapshot::read(&saved_fixture, &Cancellation::default()).unwrap());
    }
    let secondary = std::env::var_os("FASTRA_CASE_SOURCE_SECONDARY").is_some();
    if secondary {
        let label = find(
            doc.container.upcast_ref(),
            ui.lang.text("Quelltextansicht teilen", "Split source editor"),
        )
        .unwrap();
        label
            .ancestor(gtk::CheckButton::static_type())
            .unwrap()
            .downcast::<gtk::CheckButton>()
            .unwrap()
            .set_active(true);
    }
    select(&doc);
    let stale_menu = sorting && std::env::var_os("FASTRA_SORT_MENU_STALE").is_some();
    if stale_menu {
        assert!(std::env::var_os("FASTRA_SPLIT_REPLY_DELAY").is_some());
    }
    let menu_generation = Cell::new(ui.generation.get());
    let initial_revision = doc.revision.get();
    let initial_undo = doc.buffer.can_undo();
    let stage = Cell::new(0);
    let stamp = Cell::new(std::time::Instant::now());
    let start = std::time::Instant::now();
    let capture = RefCell::new(None::<std::sync::Arc<std::sync::atomic::AtomicBool>>);
    glib::timeout_add_local(Duration::from_millis(100), move || {
        assert!(
            start.elapsed() < Duration::from_secs(80),
            "Titlecase stage{} timed out: {}",
            stage.get(),
            ui.status.text()
        );
        let wait = if stale_menu && stage.get() == 3 {
            100
        } else {
            400
        };
        if stamp.get().elapsed() < Duration::from_millis(wait) {
            return glib::ControlFlow::Continue;
        }
        eprintln!("Titlecase stage{}", stage.get());
        let v = view();
        match stage.get() {
            0 => {
                if secondary {
                    let mut views = Vec::new();
                    source_views(doc.container.upcast_ref(), &mut views);
                    assert_eq!(views.len(), 2);
                    assert!(views[1].grab_focus());
                    assert_eq!(source_panes::capture(&doc).unwrap().view, views[1]);
                    select(&doc);
                }
                menu(&ui, "Text", "Text");
            }
            1 => {
                if sorting {
                    menu(&ui, "Zeilen", "Lines")
                } else {
                    menu(&ui, "Unicode", "Unicode")
                }
            }
            2 => {
                let name = format!(
                    "{} ({})",
                    match mapping.as_str() {
                        "sort-ascending" => ui.lang.text(
                            "Zeilen sortieren ↑ · Textlocale",
                            "Sort lines ↑ · text locale"
                        ),
                        "sort-descending" => ui.lang.text(
                            "Zeilen sortieren ↓ · Textlocale",
                            "Sort lines ↓ · text locale"
                        ),
                        "upper" => ui
                            .lang
                            .text("Großschreibung · Systemlocale", "Uppercase · system locale"),
                        "lower" => ui.lang.text(
                            "Kleinschreibung · Systemlocale",
                            "Lowercase · system locale"
                        ),
                        _ => ui.lang.text(
                            "Wortanfänge groß · Systemlocale",
                            "Titlecase · system locale"
                        ),
                    },
                    locale.as_str()
                );
                menu_generation.set(ui.generation.get());
                click(&ui.window, &find(ui.window.upcast_ref(), &name).unwrap());
            }
            3 if stale_menu => {
                if ui.generation.get() == menu_generation.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), source);
                ui.status.set_text("sort-stale-awaiting-completion");
                assert!(!unsafe { libc::setlocale(libc::LC_CTYPE, c"C.UTF-8".as_ptr()) }.is_null());
                stage.set(31);
                stamp.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            31 => {
                if !ui
                    .status
                    .text()
                    .contains(ui.lang.text("nicht übernommen", "not applied"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), source);
                assert_eq!(doc.revision.get(), initial_revision);
                assert_eq!(doc.buffer.can_undo(), initial_undo);
                assert_eq!(std::fs::read_to_string(&saved_fixture).unwrap(), source);
                assert!(
                    !unsafe { libc::setlocale(libc::LC_CTYPE, original_ctype.as_ptr()) }.is_null()
                );
                std::fs::remove_file(&saved_fixture).unwrap();
                std::fs::remove_file(&fixture).unwrap();
                println!("FASTRA_SORT_MENU_STALE_OK captured-before-locale-change/real-menu/sourceB/late-completion-rejected/no-edit/no-new-undo/disk-kept");
                std::process::exit(0);
            }
            3 => {
                if buffer_text(&doc.buffer) == source {
                    return glib::ControlFlow::Continue;
                }
                eprintln!(
                    "CASE MENU mapping={mapping} LC_CTYPE={} actual={:?} expected={first:?}",
                    locale.as_str(),
                    buffer_text(&doc.buffer)
                );
                assert_eq!(buffer_text(&doc.buffer), first);
                if sorting {
                    ui.status.set_text("sort-save-awaiting-button");
                    click(&ui.window, &ui.save);
                    stage.set(30);
                    stamp.set(std::time::Instant::now());
                    return glib::ControlFlow::Continue;
                }
                menu(&ui, "Rückgängig", "Undo");
            }
            30 => {
                let status = ui.status.text();
                if doc.saving.get()
                    || status == "sort-save-awaiting-button"
                    || status
                        == ui
                            .lang
                            .text("Datei wird sicher gespeichert …", "Saving file safely …")
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    status,
                    ui.lang.text(
                        "Datei sicher gespeichert. Spätere Editoränderungen bleiben ungesichert.",
                        "File saved safely. Later editor edits remain unsaved."
                    ),
                    "Save did not complete successfully: {status}"
                );
                assert_eq!(std::fs::read_to_string(&saved_fixture).unwrap(), first);
                assert!(!doc.buffer.is_modified());
                menu(&ui, "Rückgängig", "Undo");
                stage.set(4);
                stamp.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            4 => {
                assert_eq!(buffer_text(&doc.buffer), source);
                select(&doc);
                menu(&ui, "Werkzeuge", "Tools");
            }
            5 => menu(&ui, "Gespeicherte Textabläufe …", "Saved text workflows …"),
            6 => {
                let Some(v) = v.filter(|v| v.snapshot.borrow().is_some()) else {
                    return glib::ControlFlow::Continue;
                };
                click(&v.window, &v.import);
            }
            7 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                set_open_path(&p, &fixture);
            }
            8 => {
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
            9 => {
                let Some(v) = v.filter(|v| !v.busy.get() && v.draft.borrow().is_some()) else {
                    return glib::ControlFlow::Continue;
                };
                v.scope.set_selected(1);
                select(&doc);
                click(&v.window, &v.calculate);
            }
            10 => {
                let v = v.unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(v.pending.borrow().is_some(), "{}", v.status.text());
                eprintln!("CASE WORKFLOW mapping={mapping} LC_CTYPE={} actual={:?} expected={final_text:?} summary={}",locale.as_str(),text(&v.after),v.summary.text());
                assert_eq!(text(&v.after), final_text);
                assert!(v.summary.text().contains(locale.as_str()));
                v.stages.set_selected(1);
                assert_eq!(text(&v.after), selected);
                assert!(v.summary.text().contains(locale.as_str()));
                v.window.set_default_size(860, 760);
            }
            11 => {
                if std::env::var_os("FASTRA_WORKFLOW_SCREENSHOT_DIR").is_some() {
                    *capture.borrow_mut() = Some(snapshot(&format!(
                        "titlecase-{}.min.png",
                        if ui.lang.0 { "de" } else { "en" }
                    )));
                }
            }
            12 => {
                if capture
                    .borrow()
                    .as_ref()
                    .is_some_and(|c| !c.load(std::sync::atomic::Ordering::Acquire))
                {
                    return glib::ControlFlow::Continue;
                }
                v.unwrap().window.set_default_size(1280, 850);
            }
            13 => {
                if std::env::var_os("FASTRA_WORKFLOW_SCREENSHOT_DIR").is_some() {
                    *capture.borrow_mut() = Some(snapshot(&format!(
                        "titlecase-{}.wide.png",
                        if ui.lang.0 { "de" } else { "en" }
                    )));
                }
            }
            14 => {
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
            15 => {
                assert_eq!(buffer_text(&doc.buffer), final_text);
                ui.window.present();
                menu(&ui, "Rückgängig", "Undo");
            }
            16 => {
                assert_eq!(buffer_text(&doc.buffer), source);
                select(&doc);
                let v = v.unwrap();
                v.window.present();
                click(&v.window, &v.calculate);
            }
            17 => {
                let v = v.unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(v.pending.borrow().is_some());
                doc.buffer.insert(&mut doc.buffer.end_iter(), "changed");
                assert!(!v.apply.is_sensitive());
                assert!(v.pending.borrow().is_none());
            }
            18 if sorting => {
                doc.buffer.set_text(source);
                select(&doc);
                let v = v.unwrap();
                click(&v.window, &v.calculate);
            }
            19 => {
                let v = v.unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(v.pending.borrow().is_some());
                assert!(!unsafe { libc::setlocale(libc::LC_CTYPE, c"C.UTF-8".as_ptr()) }.is_null());
                click(&v.window, &v.apply);
            }
            20 => {
                let v = v.unwrap();
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(v.pending.borrow().is_none());
                assert!(
                    !unsafe { libc::setlocale(libc::LC_CTYPE, original_ctype.as_ptr()) }.is_null()
                );
                std::fs::remove_file(&saved_fixture).unwrap();
                std::fs::remove_file(&fixture).unwrap();
                println!("FASTRA_SORT_SINGLE_OK mapping={mapping} locale={} native-menu/sourceB/selection/save-bytes/Undo/single-workflow/stage-and-final-locale/stale-apply",locale.as_str());
                std::process::exit(0);
            }
            18 => {
                std::fs::remove_file(&fixture).unwrap();
                eprintln!(
                    "CASE SINGLE PASS mapping={mapping} locale={}",
                    locale.as_str()
                );
                println!("FASTRA_TITLECASE_SELFTEST_OK real-gtk-ctype/ui-language-independent/native-text-menu/selection-one-undo/swift-json-import/explicit-locale-in-step-and-final-preview/two-stages/apply-one-undo/stale-input/min-wide");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        stamp.set(std::time::Instant::now());
        glib::ControlFlow::Continue
    });
}
