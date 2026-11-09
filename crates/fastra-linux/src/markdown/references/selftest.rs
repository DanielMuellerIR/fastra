use super::*;
fn find(root: &gtk::Widget, id: &str) -> Option<gtk::Widget> {
    if root.is_mapped()
        && root.width() > 0
        && root.height() > 0
        && (root.widget_name() == id
            || root.downcast_ref::<gtk::MenuButton>().is_some_and(|b| {
                b.label().as_deref() == Some(id) || b.tooltip_text().as_deref() == Some(id)
            }))
    {
        return Some(root.clone());
    }
    for child in chrome::children(root) {
        if let Some(found) = find(&child, id) {
            return Some(found);
        }
    }
    None
}
fn state() -> Option<Rc<State>> {
    LAST.with(|s| s.borrow().upgrade())
        .filter(|s| s.window.is_mapped() && s.window.width() > 0 && s.window.height() > 0)
}
fn selected_row(s: &State, index: usize) -> Option<gtk::Widget> {
    let report = s.report.borrow();
    let reference = &report.as_ref()?.findings[index].reference;
    find(
        s.window.upcast_ref(),
        &format!("referenceFinding-{}", reference.line),
    )
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let mode = std::env::var("FASTRA_REFERENCES_SELFTEST").unwrap();
    let unverified = mode == "unverified";
    let mac_reference = mode == "mac-reference";
    let identity_guard = mode == "disk-identity-guards";
    let disk_guards = mode == "disk-guards" || identity_guard;
    let hardlink = mode == "project-hardlink" || identity_guard;
    let project = mode == "project" || hardlink || disk_guards;
    let rich = mode == "rich";
    let guards = mode == "guards";
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join(if mac_reference {
        "doc.md"
    } else {
        "references.md"
    });
    let target = root.join("target.md");
    let original = if mac_reference {
        "# Gleich\r\n\r\n## Gleich\r\n\r\n[Mehrdeutig](#gleich)\r\n[Fehlt](missing.md)\r\n![Bild](bild%231.png)\r\n[Ziel][ref]\r\n[Netz](https://example.invalid)\r\n\r\n[ref]: target.md#titel\r\n"
    } else if unverified {
        "# Here\n<div id=unsupported></div>\n\n[Invalid](bad%00.md)\n[Anchor](#unsupported)\n[Present](target.md)\n[Remote](https://example.invalid/)\n"
    } else {
        "# Here\n\n[Missing](missing.md)\n[Present](target.md#target)\n[Duplicate](#repeat)\n[Remote](https://example.invalid/)\n\n# Repeat\n# Repeat\n"
    };
    let target_text = if mac_reference {
        "# Titel\n"
    } else {
        "# Target\n[Missing](other.md)\n"
    };
    if mac_reference {
        std::fs::write(root.join("bild#1.png"), [0, 255, 1]).unwrap();
    }
    std::fs::write(&path, original).unwrap();
    std::fs::write(&target, target_text).unwrap();
    if hardlink { std::fs::hard_link(&target, root.join("target.link")).unwrap(); }
    std::fs::create_dir_all(root.join("build")).unwrap();
    std::fs::write(root.join("build/ignored.md"), "[x](no.md)").unwrap();
    if project || mac_reference {
        project_view::open_path(&ui, root.clone());
    }
    ui.load_path(path.clone());
    let began = Instant::now();
    let phase = Cell::new(0);
    let pause = Cell::new(began);
    let doc = RefCell::new(None::<Rc<Document>>);
    let expected = Cell::new(0i32);
    let desired = Cell::new(0usize);
    let guarded = Cell::new(false);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            began.elapsed() < Duration::from_secs(60),
            "references phase{}: {} / {}",
            phase.get(),
            ui.status.text(),
            state()
                .map(|s| s.notice.text().to_string())
                .unwrap_or_default()
        );
        if pause.get().elapsed() < Duration::from_millis(180) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let Some(current) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                if (project || mac_reference) && project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                current.buffer.place_cursor(&current.buffer.start_iter());
                *doc.borrow_mut() = Some(current.clone());
                if rich {
                    git_view::test_click(current.rich_toggle.borrow().as_ref().unwrap(), &[]);
                }
            }
            1 => {
                if rich
                    && !doc
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .rich
                        .borrow()
                        .as_ref()
                        .is_some_and(|e| e.ready_for_saved_source())
                {
                    return glib::ControlFlow::Continue;
                }
                let Some(menu) = find(
                    ui.window.upcast_ref(),
                    ui.lang.text("Fastra-Menü", "Fastra menu"),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&menu, &[]);
            }
            2 => {
                let Some(menu) = find(ui.window.upcast_ref(), ui.lang.text("Werkzeuge", "Tools"))
                else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&menu, &[]);
            }
            3 => {
                let Some(button) = find(ui.window.upcast_ref(), "fastra-reference-check") else {
                    return glib::ControlFlow::Continue;
                };
                assert!(button.is_sensitive());
                git_view::test_click(&button, &[]);
            }
            4 => {
                let Some(s) = state() else {
                    return glib::ControlFlow::Continue;
                };
                let width = std::env::var("FASTRA_REFERENCE_WIDTH")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(900);
                s.window.set_default_size(
                    width,
                    if mac_reference {
                        720
                    } else if width == 640 {
                        600
                    } else {
                        700
                    },
                );
            }
            5 => {
                let Some(s) = state() else {
                    return glib::ControlFlow::Continue;
                };
                if !git_view::try_capture(&s.window, "references-initial") {
                    return glib::ControlFlow::Continue;
                }
                if project {
                    git_view::test_click(&s.project, &[]);
                }
                if guards {
                    WORK_DELAY.store(500, std::sync::atomic::Ordering::Relaxed);
                }
            }
            6 => {
                let s = state().unwrap();
                git_view::test_click(&s.start, &[]);
            }
            7 => {
                let s = state().unwrap();
                if guards && !guarded.get() {
                    assert!(s.busy.get());
                    git_view::test_click(&s.start, &[]);
                } else {
                    if s.busy.get() || s.report.borrow().is_none() {
                        return glib::ControlFlow::Continue;
                    }
                    let report = s.report.borrow();
                    let report = report.as_ref().unwrap();
                    assert_eq!(report.complete, !unverified, "{:?}", report.issues);
                    if unverified {
                        assert!(s.issues_scroll.is_visible());
                        assert_eq!(report.issues.len(), 1);
                    }
                    assert_eq!(report.remote_count, 1);
                    assert_eq!(
                        report.findings.len(),
                        if project || mac_reference { 4 } else { 3 }
                    );
                    assert_eq!(s.visible.borrow().len(), if project { 3 } else { 2 });
                    assert_eq!(report.sources.len(), if project { 2 } else { 1 });
                    assert!(!s.jump.is_sensitive());
                    if !git_view::try_capture(&s.window, "references-problems") {
                        return glib::ControlFlow::Continue;
                    }
                    git_view::test_click(&s.problems, &[]);
                }
            }
            8 => {
                let s = state().unwrap();
                if guards && !guarded.get() {
                    assert!(!s.busy.get());
                    assert!(s.report.borrow().is_none());
                    assert!(
                        s.notice.text().contains("unvollständig")
                            || s.notice.text().contains("incomplete")
                    );
                    if !git_view::try_capture(&s.window, "references-cancelled") {
                        return glib::ControlFlow::Continue;
                    }
                    guarded.set(true);
                    WORK_DELAY.store(0, std::sync::atomic::Ordering::Relaxed);
                    git_view::test_click(&s.start, &[]);
                    phase.set(7);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    s.visible.borrow().len(),
                    if project || mac_reference { 4 } else { 3 }
                );
                let report = s.report.borrow();
                let report = report.as_ref().unwrap();
                let index = if project {
                    report
                        .findings
                        .iter()
                        .position(|f| {
                            report
                                .sources
                                .iter()
                                .find(|v| v.id == f.source)
                                .unwrap()
                                .path
                                .as_ref()
                                == Some(&target)
                        })
                        .unwrap()
                } else {
                    0
                };
                desired.set(index);
                expected.set(report.findings[index].reference.offset);
                if project {
                    let list = find(s.window.upcast_ref(), "referenceFindings").unwrap();
                    git_view::test_click_at(&list, 20., 20., &["End"]);
                } else {
                    let Some(row) = selected_row(&s, index) else {
                        return glib::ControlFlow::Continue;
                    };
                    git_view::test_click(&row, &[]);
                }
            }
            9 => {
                let s = state().unwrap();
                if !s.jump.is_sensitive()
                    || s.visible
                        .borrow()
                        .get(s.selected.selected() as usize)
                        .copied()
                        != Some(desired.get())
                {
                    return glib::ControlFlow::Continue;
                }
                if !git_view::try_capture(&s.window, "references-all") {
                    return glib::ControlFlow::Continue;
                }
                if disk_guards {
                    if identity_guard {
                        let replacement = root.join("replacement.md");
                        std::fs::write(&replacement, target_text).unwrap();
                        std::fs::rename(replacement, &target).unwrap();
                    } else {
                        std::fs::write(&target, "# Changed\n").unwrap();
                    }
                }
                if guards {
                    let doc = doc.borrow().as_ref().unwrap().clone();
                    doc.buffer.insert(&mut doc.buffer.start_iter(), "prefix\n");
                }
                git_view::test_click(&s.jump, &[]);
            }
            10 => {
                if guards {
                    let s = state().expect("stale jump must retain report");
                    assert!(s.notice.is_visible());
                    assert!(
                        doc.borrow().as_ref().unwrap().buffer.cursor_position() != expected.get()
                    );
                    let source = s.report.borrow().as_ref().unwrap().sources[0].clone();
                    assert!(s.fresh(&source).is_none());
                    assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                    if !git_view::try_capture(&s.window, "references-stale") {
                        return glib::ControlFlow::Continue;
                    }
                    let original_doc = doc.borrow().as_ref().unwrap().clone();
                    original_doc.buffer.set_text(original);
                    assert!(
                        s.fresh(&source).is_some(),
                        "identical bytes after a new revision remain current"
                    );
                    ui.add_document("keeper.txt", "keeper");
                    tab_close::request(&ui, &original_doc);
                    ui.load_path(path.clone());
                    phase.set(19);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                if disk_guards {
                    let s = state().expect("changed disk source retains report");
                    if !s.notice.is_visible() {
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(ui.documents.borrow().len(), 1);
                    assert_eq!(ui.active().unwrap().disk_path().as_ref(), Some(&path));
                    assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                    if !git_view::try_capture(&s.window, "references-disk-stale") {
                        return glib::ControlFlow::Continue;
                    }
                    s.window.close();
                    eprintln!("REFERENCES_SELFTEST PASS changed disk snapshot blocked before opening, inline notice, original source unchanged");
                    std::process::exit(0);
                }
                if state().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let current = ui.active().unwrap();
                if current.buffer.cursor_position() != expected.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!current.is_rich_active());
                if project {
                    assert_eq!(current.disk_path().as_ref(), Some(&target));
                    if hardlink { assert!(current.is_read_only()); assert!(current.snapshot.borrow().is_none()); assert!(current.read_source.borrow().is_some()); }
                } else {
                    assert!(Rc::ptr_eq(&current, doc.borrow().as_ref().unwrap()));
                }
                let outline = current.outline.borrow().clone().unwrap();
                assert!(outline.back.is_sensitive());
                if !git_view::try_capture(ui.window.upcast_ref(), "references-source-jump") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&outline.back, &[]);
            }
            11 => {
                let current = ui.active().unwrap();
                if !Rc::ptr_eq(&current, doc.borrow().as_ref().unwrap())
                    || current.buffer.cursor_position() != 0
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&current.buffer), original);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                assert_eq!(std::fs::read_to_string(&target).unwrap(), target_text);
                eprintln!("REFERENCES_SELFTEST PASS native menu, Doc/Project scoped snapshot report, problem filter/all rows, source jump with shared Back, Rich source switch where selected, unchanged disk");
                std::process::exit(0);
            }
            19 => {
                let Some(current) = ui.active().filter(|d| {
                    d.disk_path().as_ref() == Some(&path)
                        && !Rc::ptr_eq(d, doc.borrow().as_ref().unwrap())
                }) else {
                    return glib::ControlFlow::Continue;
                };
                let s = state().unwrap();
                let source = s.report.borrow().as_ref().unwrap().sources[0].clone();
                assert!(
                    s.fresh(&source).is_none(),
                    "same path reopened is a new document"
                );
                assert_eq!(current.buffer.cursor_position(), 0);
                git_view::test_click(&s.jump, &[]);
            }
            20 => {
                let s = state().expect("closed-source jump retains report");
                assert!(s.notice.is_visible());
                assert_eq!(ui.active().unwrap().buffer.cursor_position(), 0);
                s.window.close();
                eprintln!("REFERENCES_SELFTEST PASS native Cancel/recheck generation, filter, mutation guard, identical-content republish accepted, closed/reopened source identity rejected, unchanged disk");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
