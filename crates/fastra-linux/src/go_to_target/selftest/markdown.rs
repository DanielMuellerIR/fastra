use super::*;
use std::os::unix::fs::PermissionsExt;
fn uri_handler(root: &Path) -> PathBuf {
    let data = PathBuf::from(std::env::var_os("XDG_DATA_HOME").unwrap());
    let config = PathBuf::from(std::env::var_os("XDG_CONFIG_HOME").unwrap());
    std::fs::create_dir_all(data.join("applications")).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    let output = root.join("uri.txt");
    let script = root.join("uri-handler");
    std::fs::write(
        &script,
        format!(
            "#!/usr/bin/python3\nimport sys,pathlib\npathlib.Path({}).write_text(sys.argv[1])\n",
            serde_json::to_string(output.to_str().unwrap()).unwrap()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::write(data.join("applications/fastra-target-test.desktop"),format!("[Desktop Entry]\nType=Application\nName=Fastra target test\nNoDisplay=true\nExec=\"{}\" %u\nMimeType=x-scheme-handler/https;\n",script.display())).unwrap();
    std::fs::write(
        config.join("mimeapps.list"),
        "[Default Applications]\nx-scheme-handler/https=fastra-target-test.desktop\n",
    )
    .unwrap();
    output
}
pub(super) fn start(ui: Rc<Ui>) {
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    std::fs::create_dir_all(root.join("docs")).unwrap();
    let path = root.join("start.md");
    let other = root.join("docs/space#name.md");
    let uri = uri_handler(&root);
    let source="🙂\r\n[Sprung](#zweiter-abschnitt)\r\n[Datei](docs/space%23name.md#ignored)\r\n[Web](https://example.org/a b)\r\n[Fehlt](#missing)\r\n\r\n## Zweiter Abschnitt\r\n\r\nText.\r\n";
    std::fs::write(&path, source).unwrap();
    std::fs::write(&other, "# Target\r\n\r\nUnchanged.\r\n").unwrap();
    git_view::test_size(ui.window.upcast_ref());
    ui.load_path(path.clone());
    let document = RefCell::new(None::<Rc<Document>>);
    let target_doc = RefCell::new(None::<Rc<Document>>);
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(Instant::now());
    let clicked = Cell::new(0);
    let capture = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            began.elapsed() < Duration::from_secs(35),
            "MD target phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(160) {
            return glib::ControlFlow::Continue;
        }
        let Some(doc) = document.borrow().clone().or_else(|| {
            ui.active()
                .filter(|d| d.disk_path().as_ref() == Some(&path))
        }) else {
            return glib::ControlFlow::Continue;
        };
        if document.borrow().is_none() {
            *document.borrow_mut() = Some(doc.clone());
        }
        let target = source_panes::capture(&doc);
        let at = |word: &str| source[..source.find(word).unwrap() + 1].chars().count() as i32;
        match phase.get() {
            0 => {
                if !doc.outline.borrow().as_ref().unwrap().valid() {
                    return glib::ControlFlow::Continue;
                }
                clicked.set(pointer(&target.unwrap().view, at("Sprung"), "1", true, "2"));
            }
            1 => {
                if selected(&doc) != "## Zweiter Abschnitt" {
                    return glib::ControlFlow::Continue;
                }
                assert!(!doc.buffer.can_undo());
                if !git_view::try_capture_x11(&ui.window, "target-markdown-anchor-native", &capture)
                {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&doc.outline.borrow().as_ref().unwrap().back, &[]);
            }
            2 => {
                if target.as_ref().unwrap().buffer.cursor_position() != clicked.get() {
                    return glib::ControlFlow::Continue;
                }
                clicked.set(pointer(&target.unwrap().view, at("Datei"), "1", true, "2"));
            }
            3 => {
                let Some(other_doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&other))
                else {
                    return glib::ControlFlow::Continue;
                };
                if !other_doc
                    .outline
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .back
                    .is_mapped()
                {
                    return glib::ControlFlow::Continue;
                }
                if !git_view::try_capture_x11(&ui.window, "target-markdown-file-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                *target_doc.borrow_mut() = Some(other_doc.clone());
                git_view::test_click(&other_doc.outline.borrow().as_ref().unwrap().back, &[]);
            }
            4 => {
                if !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
                    || source_panes::buffer(&doc).cursor_position() != clicked.get()
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), 2);
                pointer(
                    &source_panes::capture(&doc).unwrap().view,
                    at("Web"),
                    "1",
                    true,
                    "2",
                );
            }
            5 => {
                let Ok(address) = std::fs::read_to_string(&uri) else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(address, "https://example.org/a%20b");
                assert!(doc
                    .outline
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .forward
                    .is_sensitive());
                pointer(
                    &source_panes::capture(&doc).unwrap().view,
                    at("Fehlt"),
                    "1",
                    true,
                    "2",
                );
            }
            6 => {
                if !ui
                    .status
                    .text()
                    .contains(ui.lang.text("Keine Überschrift", "No heading"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(labels(ui.window.upcast_ref()).iter().any(|l| l.is_mapped()
                    && l.text()
                        .contains(ui.lang.text("Keine Überschrift", "No heading"))));
                assert!(doc
                    .outline
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .forward
                    .is_sensitive());
                if !git_view::try_capture_x11(
                    &ui.window,
                    "target-markdown-missing-native",
                    &capture,
                ) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&doc.outline.borrow().as_ref().unwrap().forward, &[]);
            }
            7 => {
                let other_doc = target_doc.borrow().clone().unwrap();
                if !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &other_doc)) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(source_panes::buffer(&other_doc).cursor_position(), 0);
                assert_eq!(ui.documents.borrow().len(), 2);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                println!("FASTRA_TOOL_SELFTEST_OK target-markdown actual-alt-double-click full-anchor-range Unicode-CRLF percent23-file-name shared-history missing-visible-refusal native-private-default-browser-uri no-network unchanged-files-no-undo");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        eprintln!("MD target phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
