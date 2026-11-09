use super::*;
use std::{path::PathBuf, time::Instant};
fn find(root: &gtk::Widget, id: &str) -> Option<gtk::Widget> {
    if root.is_mapped()
        && (root.widget_name() == id
            || root.tooltip_text().as_deref() == Some(id)
            || root
                .downcast_ref::<gtk::Button>()
                .is_some_and(|button| button.label().as_deref() == Some(id)))
    {
        return Some(root.clone());
    }
    chrome::children(root)
        .into_iter()
        .find_map(|child| find(&child, id))
}
fn entry(root: &gtk::Widget) -> Option<gtk::Entry> {
    root.downcast_ref::<gtk::Entry>().cloned().or_else(|| {
        chrome::children(root)
            .into_iter()
            .find_map(|child| entry(&child))
    })
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("readonly.md");
    let alias = root.join("alias.md");
    let text =
        "# Readonly\n\nfirst target 😀\n\n## Next\nsecond target café\n\n![pixel](pixel.png)\n";
    std::fs::write(
        root.join("pixel.png"),
        include_bytes!("../../tests/fixtures/pixel-1.png"),
    )
    .unwrap();
    let watch = std::env::var("FASTRA_READONLY_SOURCE_SELFTEST").as_deref() == Ok("watch");
    let preview_mode = std::env::var("FASTRA_READONLY_SOURCE_SELFTEST").as_deref() == Ok("preview");
    let print_mode = std::env::var("FASTRA_READONLY_SOURCE_SELFTEST").as_deref() == Ok("print");
    let print_phase = Cell::new(0);
    let printing = RefCell::new(None::<gtk::Window>);
    let options_mode = std::env::var("FASTRA_READONLY_SOURCE_SELFTEST").as_deref() == Ok("options");
    let options_phase = Cell::new(0);
    let options_window = RefCell::new(None::<gtk::Window>);
    let preview_phase = Cell::new(0);
    let preview_prepared = Cell::new(false);
    let point = Rc::new(RefCell::new(None::<serde_json::Value>));
    let inspecting = Rc::new(Cell::new(false));
    let mut external_bytes = vec![0xff, 0xfe];
    for c in "# Externally changed\n".encode_utf16() {
        external_bytes.extend(c.to_le_bytes());
    }
    let changed = Cell::new(false);
    let mut bytes = vec![0xff, 0xfe];
    for c in text.encode_utf16() {
        bytes.extend(c.to_le_bytes());
    }
    std::fs::write(&path, &bytes).unwrap();
    let metadata_limit =
        std::env::var("FASTRA_READONLY_SOURCE_SELFTEST").as_deref() == Ok("metadata-limit");
    let metadata_denied = metadata_limit
        || std::env::var("FASTRA_READONLY_SOURCE_SELFTEST").as_deref() == Ok("metadata");
    if metadata_denied {
        std::fs::copy(&path, &alias).unwrap();
    } else {
        std::fs::hard_link(&path, &alias).unwrap();
    }
    ui.window.set_default_size(
        std::env::var("FASTRA_TOOL_WIDTH")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(760),
        800,
    );
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let held = RefCell::new(None::<Rc<Document>>);
    let copied = Rc::new(RefCell::new(None::<String>));
    let navigating = RefCell::new(None::<gtk::Window>);
    let input = RefCell::new(None::<mpsc::Receiver<()>>);
    let popup_capture = RefCell::new(None::<mpsc::Receiver<bool>>);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed() < Duration::from_secs(60),
            "readonly source phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(200) {
            return glib::ControlFlow::Continue;
        }
        let waiting = input.borrow().as_ref().map(mpsc::Receiver::try_recv);
        match waiting {
            Some(Ok(())) => {
                input.borrow_mut().take();
            }
            Some(Err(mpsc::TryRecvError::Empty)) => return glib::ControlFlow::Continue,
            Some(Err(mpsc::TryRecvError::Disconnected)) => panic!("native input worker stopped"),
            None => {}
        }
        match phase.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                let Some(target) = source_panes::capture(&doc) else {
                    return glib::ControlFlow::Continue;
                };
                assert!(doc.is_read_only() && doc.has_source_text());
                assert!(doc.read_source.borrow().is_some() && doc.snapshot.borrow().is_none());
                assert!(!target.view.is_editable());
                assert!(target.valid_document_for_reading(&doc));
                assert!(!target.valid_document(&doc));
                assert_eq!(buffer_text(&doc.buffer), text);
                assert!(!ui.save.is_sensitive());
                assert!(!doc.rich_toggle.borrow().as_ref().unwrap().is_sensitive());
                assert!(find(ui.window.upcast_ref(), "fastra-markdown-inline").is_none());
                *held.borrow_mut() = Some(doc);
                *input.borrow_mut() = Some(git_view::test_input_completed(
                    &target.view,
                    &["ctrl+a", "ctrl+c"],
                    true,
                ));
            }
            1 => {
                let target = source_panes::capture(held.borrow().as_ref().unwrap()).unwrap();
                assert_eq!(
                    selected_offsets(held.borrow().as_ref().unwrap()),
                    Some((0, target.buffer.char_count())),
                    "actual Ctrl+A selection in readonly source"
                );
                let copied = copied.clone();
                target
                    .view
                    .clipboard()
                    .read_text_async(None::<&gio::Cancellable>, move |result| {
                        *copied.borrow_mut() = Some(result.unwrap().unwrap().to_string());
                    });
            }
            2 => {
                if copied.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(copied.borrow().as_deref(), Some(text));
                let target = source_panes::capture(held.borrow().as_ref().unwrap()).unwrap();
                *input.borrow_mut() = Some(git_view::test_input_completed(
                    &target.view,
                    &[
                        "x",
                        "BackSpace",
                        "Delete",
                        "ctrl+x",
                        "ctrl+v",
                        "ctrl+z",
                        "ctrl+y",
                    ],
                    false,
                ));
            }
            3 => {
                let doc = held.borrow().as_ref().unwrap().clone();
                assert_eq!(buffer_text(&doc.buffer), text);
                assert!(
                    !doc.buffer.is_modified() && !doc.buffer.can_undo() && !doc.buffer.can_redo()
                );
                assert_eq!(std::fs::read(&path).unwrap(), bytes);
                if !git_view::try_capture(ui.window.upcast_ref(), "readonly-source") {
                    return glib::ControlFlow::Continue;
                }
                let target = source_panes::capture(&doc).unwrap();
                *input.borrow_mut() = Some(git_view::test_input_completed(
                    &target.view,
                    &["ctrl+f"],
                    false,
                ));
            }
            4 => {
                if !ui
                    .chrome
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .search_window
                    .is_visible()
                {
                    return glib::ControlFlow::Continue;
                }
                *input.borrow_mut() = Some(git_view::test_input_completed(
                    &ui.find,
                    &["ctrl+a", "t", "a", "r", "g", "e", "t"],
                    true,
                ));
            }
            5 => {
                if ui
                    .pending
                    .borrow()
                    .as_ref()
                    .is_none_or(|pending| pending.preview.matches().len() != 2)
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(!ui.apply.is_sensitive());
                assert!(!ui.approval.replacement_button().is_sensitive());
                *input.borrow_mut() =
                    Some(git_view::test_input_completed(&ui.find, &["Return"], false));
            }
            6 => {
                let doc = held.borrow().as_ref().unwrap().clone();
                if source_panes::buffer(&doc)
                    .selection_bounds()
                    .is_none_or(|(a, b)| {
                        source_panes::buffer(&doc).text(&a, &b, true).as_str() != "target"
                    })
                {
                    return glib::ControlFlow::Continue;
                }
                ui.apply.emit_clicked();
                assert_eq!(buffer_text(&doc.buffer), text);
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                if !git_view::try_capture(&window, "readonly-source-find") {
                    return glib::ControlFlow::Continue;
                }
                *input.borrow_mut() =
                    Some(git_view::test_input_completed(&ui.find, &["Escape"], false));
            }
            7 => {
                if ui
                    .chrome
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .search_window
                    .is_visible()
                {
                    return glib::ControlFlow::Continue;
                }
                let target = source_panes::capture(held.borrow().as_ref().unwrap()).unwrap();
                *input.borrow_mut() = Some(git_view::test_input_completed(
                    &target.view,
                    &["ctrl+l"],
                    false,
                ));
            }
            8 => {
                let Some(window) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|widget| widget.downcast::<gtk::Window>().ok())
                    .find(|window| {
                        window.is_mapped()
                            && window.title().as_deref()
                                == Some(
                                    ui.lang
                                        .text("Zu Zeile/Spalte springen", "Go to line/column"),
                                )
                    })
                else {
                    return glib::ControlFlow::Continue;
                };
                let field = entry(window.upcast_ref()).unwrap();
                *input.borrow_mut() = Some(git_view::test_input_completed(
                    &field,
                    &["ctrl+a", "3", "colon", "2", "Return"],
                    true,
                ));
                *navigating.borrow_mut() = Some(window);
            }
            9 => {
                if navigating.borrow().as_ref().unwrap().is_visible() {
                    return glib::ControlFlow::Continue;
                }
                let doc = held.borrow().as_ref().unwrap().clone();
                assert_eq!(source_panes::buffer(&doc).cursor_position(), 13);
                let outline = doc.outline.borrow().clone().unwrap();
                if !outline.menu.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                *input.borrow_mut() =
                    Some(git_view::test_input_completed(&outline.menu, &[], true));
            }
            10 => {
                let doc = held.borrow().as_ref().unwrap().clone();
                let outline = doc.outline.borrow().clone().unwrap();
                if !outline.popup.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(outline.snapshot().len(), 2);
                if !git_view::try_capture_x11(
                    &outline.popup,
                    "readonly-source-outline-popup",
                    &popup_capture,
                ) {
                    return glib::ControlFlow::Continue;
                }
                if !git_view::try_capture(ui.window.upcast_ref(), "readonly-source-outline") {
                    return glib::ControlFlow::Continue;
                }
                *input.borrow_mut() = Some(git_view::test_input_completed(
                    &outline.menu,
                    &["Escape"],
                    false,
                ));
            }
            11 => {
                if options_mode {
                    let doc = held.borrow().as_ref().unwrap().clone();
                    match options_phase.get() {
                        0 => {
                            let menu = find(
                                ui.window.upcast_ref(),
                                ui.lang
                                    .text("Darstellung und Bearbeitung", "View and editing"),
                            )
                            .unwrap();
                            *input.borrow_mut() =
                                Some(git_view::test_input_completed(&menu, &[], true));
                            options_phase.set(1);
                            return glib::ControlFlow::Continue;
                        }
                        1 => {
                            let settings = doc.chrome.borrow().as_ref().unwrap().settings.clone();
                            *input.borrow_mut() =
                                Some(git_view::test_input_completed(&settings, &[], true));
                            options_phase.set(2);
                            return glib::ControlFlow::Continue;
                        }
                        2 => {
                            let Some(window) = gtk::Window::list_toplevels()
                                .into_iter()
                                .filter_map(|widget| widget.downcast::<gtk::Window>().ok())
                                .find(|window| {
                                    window.is_mapped()
                                        && window.title().as_deref()
                                            == Some(
                                                ui.lang.text("Editoroptionen", "Editor options"),
                                            )
                                })
                            else {
                                return glib::ControlFlow::Continue;
                            };
                            let menu = find(
                                ui.window.upcast_ref(),
                                ui.lang
                                    .text("Darstellung und Bearbeitung", "View and editing"),
                            )
                            .unwrap()
                            .downcast::<gtk::MenuButton>()
                            .unwrap();
                            assert!(
                                menu.popover().is_none_or(|popover| !popover.is_mapped()),
                                "source options menu releases its grab before opening the dialog"
                            );
                            let Some(close) =
                                find(window.upcast_ref(), ui.lang.text("Schließen", "Close"))
                                    .filter(|button| button.is_sensitive())
                            else {
                                return glib::ControlFlow::Continue;
                            };
                            if !git_view::try_capture(&window, "readonly-source-editor-options") {
                                return glib::ControlFlow::Continue;
                            }
                            *input.borrow_mut() =
                                Some(git_view::test_input_completed(&close, &[], true));
                            *options_window.borrow_mut() = Some(window);
                            options_phase.set(3);
                            return glib::ControlFlow::Continue;
                        }
                        _ => {
                            if options_window.borrow().as_ref().unwrap().is_visible() {
                                return glib::ControlFlow::Continue;
                            }
                            let target = source_panes::capture(&doc).unwrap();
                            if !target.view.has_focus() {
                                return glib::ControlFlow::Continue;
                            }
                            assert_eq!(target.buffer.cursor_position(), 13);
                        }
                    }
                }
                if print_mode {
                    match print_phase.get() {
                        0 => {
                            let target =
                                source_panes::capture(held.borrow().as_ref().unwrap()).unwrap();
                            *input.borrow_mut() = Some(git_view::test_input_completed(
                                &target.view,
                                &["ctrl+p"],
                                false,
                            ));
                            print_phase.set(1);
                            return glib::ControlFlow::Continue;
                        }
                        1 => {
                            let Some(window) = gtk::Window::list_toplevels()
                                .into_iter()
                                .filter_map(|widget| widget.downcast::<gtk::Window>().ok())
                                .find(|window| {
                                    window.is_mapped()
                                        && window.type_().name() == "GtkPrintUnixDialog"
                                })
                            else {
                                return glib::ControlFlow::Continue;
                            };
                            if !git_view::try_capture(&window, "readonly-source-print-dialog") {
                                return glib::ControlFlow::Continue;
                            }
                            *input.borrow_mut() =
                                Some(git_view::test_input_completed(&window, &["Escape"], false));
                            *printing.borrow_mut() = Some(window);
                            print_phase.set(2);
                            return glib::ControlFlow::Continue;
                        }
                        _ => {
                            if printing.borrow().as_ref().unwrap().is_visible()
                                || print_view::is_busy()
                            {
                                return glib::ControlFlow::Continue;
                            }
                            assert_eq!(buffer_text(&held.borrow().as_ref().unwrap().buffer), text);
                        }
                    }
                }
                if preview_mode {
                    let toggle = || {
                        find(
                            ui.window.upcast_ref(),
                            ui.lang.text(
                                "Markdown-Vorschau ein-/ausblenden",
                                "Toggle Markdown preview",
                            ),
                        )
                        .unwrap()
                    };
                    let doc = held.borrow().as_ref().unwrap().clone();
                    match preview_phase.get() {
                        0 => {
                            // Auch bei eingeschalteter App-Vorgabe den echten
                            // Vorschauknopf von Aus nach Ein prüfen.
                            if doc.markdown_toggle.borrow().as_ref().unwrap().is_active()
                                && !preview_prepared.replace(true)
                            {
                                *input.borrow_mut()=Some(git_view::test_input_completed(&toggle(), &[], true));
                                return glib::ControlFlow::Continue;
                            }
                            *input.borrow_mut() =
                                Some(git_view::test_input_completed(&toggle(), &[], true));
                            preview_phase.set(1);
                            return glib::ControlFlow::Continue;
                        }
                        1 => {
                            let Some(preview) = doc
                                .markdown
                                .borrow()
                                .clone()
                                .filter(|preview| preview.visible.get())
                            else {
                                return glib::ControlFlow::Continue;
                            };
                            let value = point.borrow_mut().take();
                            if let Some(value) = value.filter(|value| value.is_object()) {
                                let view = preview.view.clone();
                                git_view::test_click_at(
                                    &view,
                                    value["x"].as_f64().unwrap() as f32,
                                    value["y"].as_f64().unwrap() as f32,
                                    &[],
                                );
                                preview_phase.set(2);
                            } else if !inspecting.replace(true) {
                                let result = point.clone();
                                let busy = inspecting.clone();
                                preview.inspect("if(!document.documentElement.dataset.fastraPositionEpoch)return JSON.stringify(null);const h=document.querySelector('h2'),i=document.querySelector('img');if(!h||!i?.complete||i.naturalWidth!==1)return JSON.stringify(null);const r=h.getBoundingClientRect();return JSON.stringify({x:r.x+8,y:r.y+r.height/2});", move |value| { *result.borrow_mut() = Some(value); busy.set(false); });
                            }
                            return glib::ControlFlow::Continue;
                        }
                        2 => {
                            let buffer = source_panes::buffer(&doc);
                            if buffer.iter_at_offset(buffer.cursor_position()).line() != 4 {
                                return glib::ControlFlow::Continue;
                            }
                            assert_eq!(buffer_text(&doc.buffer), text);
                            if !git_view::try_capture(
                                ui.window.upcast_ref(),
                                "readonly-source-preview-position",
                            ) {
                                return glib::ControlFlow::Continue;
                            }
                            *input.borrow_mut() =
                                Some(git_view::test_input_completed(&toggle(), &[], true));
                            preview_phase.set(3);
                            return glib::ControlFlow::Continue;
                        }
                        _ => {
                            if doc.markdown_toggle.borrow().as_ref().unwrap().is_active() {
                                return glib::ControlFlow::Continue;
                            }
                        }
                    }
                }
                if watch {
                    if !changed.replace(true) {
                        std::fs::write(&alias, &external_bytes).unwrap();
                        return glib::ControlFlow::Continue;
                    }
                    if find(ui.window.upcast_ref(), "fastra-readonly-source-reopen").is_none() {
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(buffer_text(&held.borrow().as_ref().unwrap().buffer), text);
                    assert!(held
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .read_source
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .verify_identity(&Cancellation::default())
                        .is_err());
                    if !git_view::try_capture(
                        ui.window.upcast_ref(),
                        "readonly-source-external-change",
                    ) {
                        return glib::ControlFlow::Continue;
                    }
                }
                let Some(button) = find(ui.window.upcast_ref(), "fastra-readonly-edit-copy") else {
                    return glib::ControlFlow::Continue;
                };
                *input.borrow_mut() = Some(git_view::test_input_completed(&button, &[], true));
            }
            12 => {
                let original = held.borrow().as_ref().unwrap().clone();
                let Some(copy) = ui.active().filter(|doc| !Rc::ptr_eq(doc, &original)) else {
                    return glib::ControlFlow::Continue;
                };
                assert!(
                    !copy.is_read_only()
                        && copy.snapshot.borrow().is_none()
                        && copy.read_source.borrow().is_none()
                        && copy.disk_path().is_none()
                );
                assert!(copy.buffer.is_modified());
                assert_eq!(buffer_text(&copy.buffer), text);
                assert_eq!(copy.format.borrow().encode(text).unwrap(), bytes);
                *input.borrow_mut() = Some(git_view::test_input_completed(
                    &source_panes::capture(&copy).unwrap().view,
                    &["x"],
                    true,
                ));
            }
            13 => {
                let doc = held.borrow().as_ref().unwrap().clone();
                assert_eq!(buffer_text(&doc.buffer), text);
                assert!(!doc.buffer.is_modified() && !doc.buffer.can_undo());
                assert_ne!(buffer_text(&ui.active().unwrap().buffer), text);
                let expected = if watch { &external_bytes } else { &bytes };
                assert_eq!(std::fs::read(&path).unwrap(), *expected);
                assert_eq!(std::fs::read(&alias).unwrap(), *expected);
                let write_basis = fastra_io::Snapshot::read(&path, &Cancellation::default());
                if metadata_limit {
                    assert!(matches!(write_basis, Err(fastra_io::Error::Limit)));
                } else if metadata_denied {
                    assert!(
                        matches!(write_basis, Err(fastra_io::Error::Io(error)) if error.kind() == std::io::ErrorKind::PermissionDenied)
                    );
                } else {
                    assert!(matches!(
                        write_basis,
                        Err(fastra_io::Error::UnsupportedMetadata)
                    ));
                }
                if !git_view::try_capture(ui.window.upcast_ref(), "readonly-source-edit-copy") {
                    return glib::ControlFlow::Continue;
                }
                tab_close::request(&ui, &doc);
            }
            14 => {
                assert!(!ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|doc| Rc::ptr_eq(doc, held.borrow().as_ref().unwrap())));
                if super::watch::live_count() != 0 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&held.borrow().as_ref().unwrap().buffer), text);
                eprintln!("READONLY_SOURCE_SELFTEST PASS mode={} actual UTF16 file opens, full canonical panes, complete native clipboard, typing/cut/paste/undo/replace blocked, Find/GoToLine/outline work, editable unsaved copy preserves charset/BOM, source and alias retain expected bytes; closed-tab observer stops despite retained Rc", if options_mode { "editor-options" } else if print_mode { "print-dialog" } else if preview_mode { "preview-position" } else if watch { "external-change" } else if metadata_limit { "metadata-limit" } else if metadata_denied { "metadata-denied" } else { "hardlink" });
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
