use super::*;

pub fn run(ui: Rc<Ui>, search: gtk::Button) {
    let title = format!("Fastra UI Selftest {}", std::process::id());
    ui.window.set_title(Some(&title));
    let rectangle_baseline = format!(
        "# Logical rectangle with soft wrap\n{}\nx\n\te\u{301}😀z\nlast\r\n",
        "0123456789".repeat(12)
    );
    let inspection = Rc::new(RefCell::new(None::<serde_json::Value>));
    let inspecting = Rc::new(Cell::new(false));
    let first_image = Rc::new(RefCell::new(String::new()));
    let last_stage = Cell::new(255);
    let saved_page = Cell::new(0);
    let stage = Rc::new(Cell::new(0));
    let start = std::time::Instant::now();
    let layout_stage = Cell::new(0);
    let layout_since = Cell::new(start);
    let test_dir = std::env::var_os("FASTRA_UI_TEST_ROOT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join(format!(
            "fastra-ui-selftest-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
    std::fs::create_dir(&test_dir).unwrap();
    let fixture = test_dir.join("document.txt");
    let initial = "ä🙂e\u{301}\r\nsecond\rline\n";
    let fixture_text = ui.lang.text("Katze auf dem Sofa.\nKatze im Garten.\n", "A cat on the sofa.\nA cat in the garden.\n");
    let buffer = ui.active().unwrap().buffer.clone();
    buffer.begin_irreversible_action(); buffer.set_text(fixture_text); buffer.end_irreversible_action(); buffer.set_modified(false);
    ui.find.set_text(ui.lang.text("Katze", "cat"));
    ui.replace.set_text(ui.lang.text("Hund", "dog"));
    crate::chrome::show_search(&ui);
    let original = buffer_text(&ui.active().unwrap().buffer);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(60),
            "UI selftest timed out"
        );
        if stage.get() != last_stage.get() {
            eprintln!("UI test stage {}", stage.get());
            last_stage.set(stage.get());
        }
        match stage.get() {
            0 => {
                // Ein frischer Dateistand darf sich nicht zu einem leeren Buffer zurücknehmen lassen.
                assert!(!ui.active().unwrap().buffer.can_undo());
                search.emit_clicked();
                stage.set(1);
            }
            1 => {
                if ui.pending.borrow().is_none() || !ui.approval.test_approve_initial() {
                    return glib::ControlFlow::Continue;
                }
                match layout_stage.get() {
                    0 => {
                        ui.window.set_default_size(760, 950);
                        layout_since.set(std::time::Instant::now());
                        layout_stage.set(1);
                        return glib::ControlFlow::Continue;
                    }
                    1 | 2 => {
                        if layout_since.get().elapsed() < Duration::from_millis(400) {
                            return glib::ControlFlow::Continue;
                        }
                        assert_eq!(
                            ui.window.width(),
                            if layout_stage.get() == 1 { 760 } else { 1280 }
                        );
                        assert!(
                            ui.window.height() <= 950,
                            "main window grew beyond requested screen size: {}",
                            ui.window.height()
                        );
                        git_view::capture(
                            ui.window.upcast_ref(),
                            &format!(
                                "primary-{}-{}",
                                if ui.lang.0 { "de" } else { "en" },
                                if layout_stage.get() == 1 {
                                    "min"
                                } else {
                                    "wide"
                                }
                            ),
                        );
                        if layout_stage.get() == 1 {
                            ui.window.set_default_size(1280, 950);
                            layout_since.set(std::time::Instant::now());
                            layout_stage.set(2);
                            return glib::ControlFlow::Continue;
                        }
                        layout_stage.set(3);
                    }
                    _ => {}
                }
                let pending = ui.pending.borrow();
                let pending = pending.as_ref().unwrap();
                assert!(pending.preview.matches().len() >= 2);
                assert!(ui.apply.is_sensitive());
                let expected_all = ui.approval.test_display(1);
                assert_ne!(expected_all, original);
                ui.approval.test_approve_hit(0,0,false);
                assert!(!ui.apply.is_sensitive());
                stage.set(2);
            }
            2 => {
                if !ui.approval.test_approve_initial() {
                    return glib::ControlFlow::Continue;
                }
                let expected = ui.approval.test_display(1);
                ui.apply.emit_clicked();
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), expected);
                assert!(ui.pending.borrow().is_none());
                ui.active().unwrap().buffer.undo();
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), original);
                assert!(!ui.active().unwrap().buffer.is_modified());
                search.emit_clicked();
                stage.set(3);
            }
            3 => {
                if ui.pending.borrow().is_none() || !ui.approval.test_approve_initial() {
                    return glib::ControlFlow::Continue;
                }
                ui.replace.set_text("CHANGED");
                assert!(!ui.apply.is_sensitive());
                assert!(ui.pending.borrow().is_none());
                search.emit_clicked();
                ui.add_document("other.txt", "do not change");
                stage.set(4);
            }
            4 => {
                assert!(!ui.apply.is_sensitive());
                assert!(ui.pending.borrow().is_none());
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "do not change");
                if start.elapsed() < Duration::from_millis(600) {
                    return glib::ControlFlow::Continue;
                }
                std::fs::write(&fixture, format!("\u{feff}{initial}")).unwrap();
                ui.load_path(fixture.clone());
                stage.set(5);
            }
            5 => {
                if ui.active().unwrap().snapshot.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                assert_eq!(buffer_text(&doc.buffer), initial);
                doc.buffer.insert(&mut doc.buffer.end_iter(), "saved");
                ui.save_document();
                doc.buffer.insert(&mut doc.buffer.end_iter(), "later");
                stage.set(6);
            }
            6 => {
                let doc = ui.active().unwrap();
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    std::fs::read(&fixture).unwrap(),
                    format!("\u{feff}{initial}saved").as_bytes()
                );
                assert_eq!(*doc.original.borrow(), format!("{initial}saved"));
                assert_eq!(buffer_text(&doc.buffer), format!("{initial}savedlater"));
                assert!(doc.label.text().ends_with('•'));
                std::fs::write(&fixture, "external change").unwrap();
                ui.save_document();
                stage.set(7);
            }
            7 => {
                let doc = ui.active().unwrap();
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(&fixture).unwrap(), b"external change");
                assert_eq!(*doc.original.borrow(), format!("{initial}saved"));
                assert!(doc.label.text().ends_with('•'));
                std::fs::remove_file(&fixture).unwrap();
                ui.window.set_default_size(760, 950);
                ui.search_section.set_expanded(false);
                ui.add_document("rectangle.txt", &rectangle_baseline);
                stage.set(8);
            }
            8 => {
                ui.chrome.borrow().as_ref().unwrap().search_window.close();
                ui.window.present();
                source_panes::capture(&ui.active().unwrap()).unwrap().view.grab_focus();
                layout_since.set(std::time::Instant::now());
                stage.set(80);
            }
            80 => {
                if layout_since.get().elapsed() < Duration::from_millis(400) {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                let rect = doc.rectangles.borrow()[0].clone();
                let a = rect.test_point(&ui.window, 1, 4);
                let b = rect.test_point(&ui.window, 3, 6);
                fake_input(
                    title.clone(),
                    vec![
                        "mousemove".into(),
                        a.0.to_string(),
                        a.1.to_string(),
                        "keydown".into(),
                        "Alt_L".into(),
                        "mousedown".into(),
                        "1".into(),
                        "sleep".into(),
                        "0.1".into(),
                        "mousemove".into(),
                        b.0.to_string(),
                        b.1.to_string(),
                        "sleep".into(),
                        "0.1".into(),
                        "mouseup".into(),
                        "1".into(),
                        "keyup".into(),
                        "Alt_L".into(),
                        "key".into(),
                        "q".into(),
                    ],
                );
                stage.set(9);
            }
            9 => {
                let doc = ui.active().unwrap();
                if buffer_text(&doc.buffer) == rectangle_baseline {
                    return glib::ControlFlow::Continue;
                }
                let expected = rectangle_baseline
                    .replace(
                        &"0123456789".repeat(12),
                        &format!("0123q6789{}", "0123456789".repeat(11)),
                    )
                    .replace("\nx\n", "\nxq\n")
                    .replace("\te\u{301}😀z", "\tqz");
                assert_eq!(buffer_text(&doc.buffer), expected);
                fake_input(title.clone(), vec!["key".into(), "ctrl+z".into()]);
                stage.set(10);
            }
            10 => {
                let doc = ui.active().unwrap();
                if buffer_text(&doc.buffer) != rectangle_baseline {
                    return glib::ControlFlow::Continue;
                }
                crate::rectangle_selftest::source_view(doc.container.upcast_ref())
                    .unwrap()
                    .set_insert_spaces_instead_of_tabs(true);
                let rect = doc.rectangles.borrow()[0].clone();
                rect.select((1, 4), (3, 4));
                ui.window.clipboard().set_text("P");
                rect.paste();
                stage.set(11);
            }
            11 => {
                let doc = ui.active().unwrap();
                if buffer_text(&doc.buffer) == rectangle_baseline {
                    return glib::ControlFlow::Continue;
                }
                assert!(buffer_text(&doc.buffer).contains("\nx   P\n"));
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), rectangle_baseline);
                ui.add_document("new.txt", "new document ä🙂\r\n");
                ui.save_to(ui.active().unwrap(), SaveTarget::New(fixture.clone()));
                stage.set(12);
            }
            12 => {
                let doc = ui.active().unwrap();
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    std::fs::read(&fixture).unwrap(),
                    b"new document \xc3\xa4\xf0\x9f\x99\x82\r\n"
                );
                assert!(doc.snapshot.borrow().is_some());
                assert!(!doc.buffer.is_modified());
                assert!(doc.label.text().starts_with("document.txt"));
                ui.add_document("collision.txt", "do not overwrite");
                ui.save_to(ui.active().unwrap(), SaveTarget::New(fixture.clone()));
                stage.set(13);
            }
            13 => {
                let doc = ui.active().unwrap();
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(doc.snapshot.borrow().is_none());
                assert_eq!(
                    std::fs::read(&fixture).unwrap(),
                    b"new document \xc3\xa4\xf0\x9f\x99\x82\r\n"
                );
                std::fs::remove_file(&fixture).unwrap();
                ui.add_document("whole.txt", "cat scatter cat");
                ui.find.set_text("cat");
                ui.replace.set_text("dog");
                ui.whole_word.set_active(true);
                search.emit_clicked();
                stage.set(21);
            }
            21 => {
                if !ui.approval.test_approve_initial() {
                    return glib::ControlFlow::Continue;
                }
                {
                    let pending = ui.pending.borrow();
                    let Some(pending) = pending.as_ref() else {
                        return glib::ControlFlow::Continue;
                    };
                    assert_eq!(pending.preview.matches().len(), 2);
                }
                let after = ui.approval.test_display(1);
                assert_eq!(after.as_str(), "dog scatter dog");
                ui.whole_word.set_active(false);
                assert!(!ui.apply.is_sensitive());
                ui.add_document("operations.txt", "z10\nz2\nz1\n");
                operations::test_sort(&ui);
                stage.set(14);
            }
            14 => {
                let doc = ui.active().unwrap();
                if buffer_text(&doc.buffer) == "z10\nz2\nz1\n" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "z1\nz2\nz10\n");
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), "z10\nz2\nz1\n");
                std::fs::write(
                    test_dir.join("pixel#a.png"),
                    include_bytes!("../tests/fixtures/pixel-1.png"),
                )
                .unwrap();
                std::fs::write(&fixture,"# Local preview\n\n![pixel](pixel%23a.png)\n\nInline $x^2$.\n\n```mermaid\ngraph TD; A-->B;\n```\n\n|a|b|\n|-|-|\n|1|2|\n").unwrap();
                ui.load_path(fixture.clone());
                stage.set(15);
            }
            15 => {
                let doc = ui.active().unwrap();
                if doc.snapshot.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                doc.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                stage.set(16);
            }
            16..=18 => {
                let doc = ui.active().unwrap();
                let preview = doc.markdown.borrow().as_ref().unwrap().clone();
                let value = inspection.borrow_mut().take();
                if value.is_none() && !inspecting.get() {
                    let slot = inspection.clone();
                    let busy = inspecting.clone();
                    busy.set(true);
                    preview.inspect("return JSON.stringify({ready:!!window.fastraPreviewReady,katex:!!document.querySelector('.katex math'),mermaid:!!document.querySelector('.mermaid-render svg'),image:document.querySelector('img')?.naturalWidth||0,src:document.querySelector('img')?.src||'',table:!!document.querySelector('table')})",move |value|{*slot.borrow_mut()=Some(value);busy.set(false)});
                }
                let Some(value) = value else {
                    return glib::ControlFlow::Continue;
                };
                if value["ready"] != true {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["katex"], true);
                assert_eq!(value["mermaid"], true);
                assert_eq!(value["table"], true);
                if stage.get() == 16 {
                    assert_eq!(value["image"], 1);
                    *first_image.borrow_mut() = value["src"].as_str().unwrap().into();
                    std::fs::write(
                        test_dir.join("pixel#a.png"),
                        include_bytes!("../tests/fixtures/pixel-2.png"),
                    )
                    .unwrap();
                    preview.schedule(&doc, ui.lang);
                    stage.set(17);
                } else if stage.get() == 17 {
                    if value["image"] != 2 {
                        return glib::ControlFlow::Continue;
                    };
                    assert_ne!(
                        value["src"].as_str().unwrap(),
                        first_image.borrow().as_str()
                    );
                    ui.load_path(fixture.clone());
                    stage.set(19);
                } else {
                    assert_eq!(value["image"], 2);
                    let slot = inspection.clone();
                    preview.inspect("try {await fetch('https://example.invalid/fastra-csp-test')}catch{} await new Promise(r=>setTimeout(r,80));return JSON.stringify({blocked:fastraPreviewViolations.some(v=>v.blocked.startsWith('https://')),handlers:['markdownPosition','visualMarkdown','markdownCopy','markdownCodeCopy','apply','save','writeFile','execute'].filter(name=>typeof window.webkit?.messageHandlers?.[name]?.postMessage==='function').sort(),position:typeof window.webkit?.messageHandlers?.markdownPosition?.postMessage==='function'})",move |value|{*slot.borrow_mut()=Some(value)});
                    stage.set(20);
                }
            }
            19 => {
                let doc = ui.active().unwrap();
                if doc.markdown.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                };
                doc.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                stage.set(18);
            }
            20 => {
                let Some(value) = inspection.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                if value.get("blocked").is_none() {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["blocked"], true);
                assert_eq!(
                    value["handlers"],
                    serde_json::json!(["markdownCodeCopy", "markdownPosition"])
                );
                assert_eq!(value["position"], true);
                assert!(String::from_utf8(std::fs::read(&fixture).unwrap())
                    .unwrap()
                    .contains("![pixel](pixel%23a.png)"));
                saved_page.set(ui.tabs.current_page().unwrap());
                ui.tabs.set_current_page(Some(0));
                stage.set(22);
            }
            22 => {
                assert_eq!(
                    ui.save.label().as_deref(),
                    Some(ui.lang.text("Speichern unter …", "Save as …"))
                );
                ui.tabs.set_current_page(Some(saved_page.get()));
                stage.set(23);
            }
            23 => {
                assert_eq!(
                    ui.save.label().as_deref(),
                    Some(ui.lang.text("Speichern", "Save"))
                );
                std::fs::remove_file(&fixture).unwrap();
                std::fs::remove_file(test_dir.join("pixel#a.png")).unwrap();
                std::fs::remove_dir(&test_dir).unwrap();
                println!(
                    "FASTRA_UI_SELFTEST_OK approvals/apply/one-undo/stale-input/stale-tab/save-utf8-bom-crlf/typing-during-save/external-change-refused/real-alt-drag-wrap-unicode/real-undo/column-paste-padding/new-document-save/collision-refused/whole-word-invalidation/text-sort-undo/markdown-image-katex-mermaid/image-change-reopen/csp-denial/tab-save-label"
                );
                ui.discard_confirmed.set(true);
                ui.window.close();
                return glib::ControlFlow::Break;
            }

            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

fn fake_input(title: String, args: Vec<String>) {
    // XTest-Ereignisse laufen auf dem eigenen Xvfb-Display; kein Kindprozess wartet auf dem UI-Thread.
    std::thread::spawn(move || {
        let output = std::process::Command::new("xdotool")
            .args(["search", "--onlyvisible", "--name", &format!("^{title}$")])
            .output()
            .unwrap();
        assert!(output.status.success());
        let id = String::from_utf8(output.stdout).unwrap();
        let id = id.lines().last().unwrap();
        let mut command = std::process::Command::new("xdotool");
        if std::env::var_os("FASTRA_TEST_WM").is_some() {
            command.args(["windowactivate", "--sync", id]);
        } else {
            command.args(["windowraise", id, "windowfocus", "--sync", id]);
        }
        for argument in args {
            command.arg(&argument);
            if argument == "mousemove" { command.args(["--window", id]); }
        }
        assert!(command.status().unwrap().success());
    });
}
