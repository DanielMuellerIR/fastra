use super::*;
pub(super) fn click_with_keys(
    _window: &impl IsA<gtk::Window>,
    widget: &impl IsA<gtk::Widget>,
    keys: &[&str],
) {
    super::super::git_view::test_click(widget, keys);
}
fn open_tools(ui: &Rc<Ui>) {
    super::super::chrome::show_commands(ui);
    let weak = Rc::downgrade(ui);
    glib::timeout_add_local_once(Duration::from_millis(100), move || {
        if let Some(ui) = weak.upgrade() {
            find(ui.window.upcast_ref(), ui.lang.text("Werkzeuge", "Tools"))
                .unwrap()
                .downcast::<gtk::MenuButton>()
                .unwrap()
                .popup();
        }
    });
}
fn tool(ui: &Ui, title: &str) -> gtk::Widget {
    let menu = find(ui.window.upcast_ref(), ui.lang.text("Werkzeuge", "Tools"))
        .unwrap()
        .downcast::<gtk::MenuButton>()
        .unwrap();
    find(menu.popover().unwrap().upcast_ref(), title).unwrap()
}
pub(super) fn click(window: &impl IsA<gtk::Window>, widget: &impl IsA<gtk::Widget>) {
    click_with_keys(window, widget, &[])
}
// Der moderne FileDialog kapselt dieses öffentliche Chooser-Interface.
// Nur der Test setzt damit den Fixture-Pfad; Bestätigungen erfolgen per XTest.
#[allow(deprecated)]
pub(super) fn set_open_path(picker: &gtk::Window, path: &std::path::Path) {
    picker
        .clone()
        .dynamic_cast::<gtk::FileChooser>()
        .unwrap()
        .set_file(&gio::File::for_path(path))
        .unwrap();
}
#[allow(deprecated)]
pub(super) fn set_save_path(picker: &gtk::Window, path: &std::path::Path) {
    let chooser = picker.clone().dynamic_cast::<gtk::FileChooser>().unwrap();
    chooser
        .set_current_folder(Some(&gio::File::for_path(path.parent().unwrap())))
        .unwrap();
    chooser.set_current_name(path.file_name().unwrap().to_str().unwrap());
}
pub(super) fn find(widget: &gtk::Widget, text: &str) -> Option<gtk::Widget> {
    if widget
        .downcast_ref::<gtk::Label>()
        .is_some_and(|label| label.text() == text)
        || widget
            .downcast_ref::<gtk::Button>()
            .is_some_and(|b| b.label().as_deref() == Some(text))
        || widget
            .downcast_ref::<gtk::MenuButton>()
            .is_some_and(|b| b.label().as_deref() == Some(text))
    {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(found) = find(&widget, text) {
            return Some(found);
        }
        child = widget.next_sibling();
    }
    None
}
pub(super) fn picker() -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| w.is_visible() && w.type_().name() == "GtkFileChooserDialog")
}
pub(super) fn text(view: &gtk::TextView) -> String {
    view.buffer()
        .text(&view.buffer().start_iter(), &view.buffer().end_iter(), true)
        .into()
}
fn text_view(widget: &gtk::Widget) -> Option<gtk::TextView> {
    if let Some(text) = widget.downcast_ref::<gtk::TextView>() {
        return Some(text.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(text) = text_view(&widget) {
            return Some(text);
        }
        child = widget.next_sibling();
    }
    None
}
pub(super) fn snapshot(name: &str) -> std::sync::Arc<std::sync::atomic::AtomicBool> {
    let path =
        PathBuf::from(std::env::var_os("FASTRA_WORKFLOW_SCREENSHOT_DIR").unwrap()).join(name);
    super::super::git_view::capture_to(&view().unwrap().window, &path);
    std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true))
}

pub(super) fn view() -> Option<Rc<View>> {
    TEST_VIEW.with(|slot| slot.borrow().as_ref().and_then(std::rc::Weak::upgrade))
}
pub fn run(ui: Rc<Ui>) {
    let root = std::env::var_os("FASTRA_UI_TEST_ROOT")
        .map(PathBuf::from)
        .expect("test root on supported filesystem");
    let export = root.join(format!("workflow-export-{}.json", std::process::id()));
    assert!(!export.exists());
    let fixtures = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join(format!("fastra-workflow-fixtures-{}", std::process::id()));
    std::fs::create_dir(&fixtures).unwrap();
    let workflow_fixture = fixtures.join("swift-workflows.json");
    std::fs::write(
        &workflow_fixture,
        include_bytes!("../../../fastra-workflow/tests/fixtures/swift-workflows.json"),
    )
    .unwrap();
    let title = format!("Fastra Workflow Test {}", std::process::id());
    ui.window.set_title(Some(&title));
    ui.add_document("workflow.txt", "b\ncat\na\nb");
    let step = Cell::new(0);
    let logged = Cell::new(-1);
    let capture = RefCell::new(None::<std::sync::Arc<std::sync::atomic::AtomicBool>>);
    let screenshots = std::env::var_os("FASTRA_WORKFLOW_SCREENSHOT_DIR").is_some();
    let stamp = Cell::new(std::time::Instant::now());
    let start = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(100), move || {
        assert!(
            start.elapsed() < Duration::from_secs(90),
            "workflow stage {} timed out",
            step.get()
        );
        if stamp.get().elapsed() < Duration::from_millis(450) {
            return glib::ControlFlow::Continue;
        }
        if logged.get() != step.get() {
            eprintln!("workflow test stage {}", step.get());
            logged.set(step.get());
        }
        match step.get() {
            0 => {
                open_tools(&ui);
            }
            1 => {
                let button = tool(
                    &ui,
                    ui.lang
                        .text("Gespeicherte Textabläufe …", "Saved text workflows …"),
                );
                click(&ui.window, &button);
            }
            2 => {
                let Some(v) = view().filter(|v| v.snapshot.borrow().is_some()) else {
                    return glib::ControlFlow::Continue;
                };
                click(&v.window, &v.import);
            }
            3 => {
                let Some(picker) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                picker.set_title(Some("Fastra Workflow Picker"));
                set_open_path(&picker, &workflow_fixture);
            }
            4 => {
                if let Some(picker) = picker() {
                    let open = ["Open", "_Open", "Öffnen", "_Öffnen"]
                        .iter()
                        .find_map(|label| find(picker.upcast_ref(), label))
                        .expect("native open button");
                    click(&picker, &open);
                    return glib::ControlFlow::Continue;
                }
                let Some(dialog) = gtk::Window::list_toplevels()
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
                let button = find(
                    dialog.upcast_ref(),
                    ui.lang.text("Sammlung importieren", "Import collection"),
                )
                .unwrap();
                click(&dialog, &button);
            }
            5 => {
                let v = view().unwrap();
                if v.busy.get() || v.draft.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    v.snapshot
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .library
                        .workflows
                        .workflows
                        .len(),
                    1
                );
                let row = v.steps.row_at_index(2).unwrap();
                click(&v.window, &row);
                step.set(39);
            }
            6 => {
                let v = view().unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(v.pending.borrow().is_some(), "{}", v.status.text());
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "b\ncat\na\nb");
                assert_eq!(
                    v.after.buffer().text(
                        &v.after.buffer().start_iter(),
                        &v.after.buffer().end_iter(),
                        true
                    ),
                    "* a\n* b\n* cat"
                );
                if screenshots {
                    v.window.set_default_size(860, 760);
                    step.set(59);
                } else {
                    v.stages.set_selected(2);
                }
            }
            7 => {
                let v = view().unwrap();
                assert_eq!(
                    v.before.buffer().text(
                        &v.before.buffer().start_iter(),
                        &v.before.buffer().end_iter(),
                        true
                    ),
                    "a\nb\nb\ncat"
                );
                assert_eq!(
                    v.after.buffer().text(
                        &v.after.buffer().start_iter(),
                        &v.after.buffer().end_iter(),
                        true
                    ),
                    "a\nb\ncat"
                );
                click(&v.window, &v.apply);
            }
            8 => {
                let v = view().unwrap();
                let doc = ui.active().unwrap();
                assert_eq!(buffer_text(&doc.buffer), "* a\n* b\n* cat");
                assert!(!v.apply.is_sensitive());
                v.window.set_visible(false);
                ui.window.present();
                super::super::git_view::test_click(
                    &source_panes::capture(&doc).unwrap().view,
                    &["ctrl+z"],
                );
            }
            9 => {
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "b\ncat\na\nb");
                let v = view().unwrap();
                v.window.present();
                click(&v.window, &v.calculate);
            }
            10 => {
                let v = view().unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(v.pending.borrow().is_some());
                let doc = ui.active().unwrap();
                doc.buffer.insert(&mut doc.buffer.end_iter(), "changed");
                assert!(v.pending.borrow().is_none());
                assert!(!v.apply.is_sensitive());
                v.apply_preview();
                assert!(buffer_text(&doc.buffer).ends_with("changed"));
                doc.buffer.undo();
                click(&v.window, &v.export);
            }
            11 => {
                let Some(picker) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                picker.set_title(Some("Fastra Workflow Picker"));
                set_save_path(&picker, &export);
            }
            12 => {
                if let Some(picker) = picker() {
                    let save = ["Save", "_Save", "Speichern", "_Speichern"]
                        .iter()
                        .find_map(|label| find(picker.upcast_ref(), label))
                        .expect("native save button");
                    click(&picker, &save);
                    return glib::ControlFlow::Continue;
                }

                let v = view().unwrap();
                if v.busy.get() || !export.exists() {
                    return glib::ControlFlow::Continue;
                }
                let archive = WorkflowArchive::decode(&std::fs::read(&export).unwrap()).unwrap();
                assert_eq!(archive.workflows.len(), 1);
                assert_eq!(archive.workflows[0].name, "Liste");
                assert_eq!(archive.workflows[0].steps.len(), 3);
                std::fs::remove_file(&export).unwrap();
                let doc = ui.active().unwrap();
                doc.buffer
                    .select_range(&doc.buffer.start_iter(), &doc.buffer.iter_at_offset(1));
                v.scope.set_selected(1);
                click(&v.window, &v.exact);
                step.set(43);
            }
            13 => {
                ui.window.present();
                super::super::chrome::show_commands(&ui);
                step.set(280);
                stamp.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            280 => {
                let help = find(ui.window.upcast_ref(), ui.lang.text("Hilfe", "Help")).unwrap();
                click(&ui.window, &help);
                step.set(29);
                stamp.set(std::time::Instant::now());
                return glib::ControlFlow::Continue;
            }
            29 => {
                let Some(help) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| {
                        w.title().as_deref()
                            == Some(ui.lang.text("Fastra – Hilfe", "Fastra – Help"))
                    })
                else {
                    return glib::ControlFlow::Continue;
                };
                let text = text_view(help.upcast_ref()).unwrap();
                let content = self::text(&text);
                let heading = ui
                    .lang
                    .text("Gespeicherte Textabläufe", "Saved text workflows");
                assert!(content.contains(heading));
                assert!(content.contains(ui.lang.text("Textbausteine", "Text snippets")));
                let (mut start, _) = text
                    .buffer()
                    .start_iter()
                    .forward_search(heading, gtk::TextSearchFlags::TEXT_ONLY, None)
                    .unwrap();
                text.scroll_to_iter(&mut start, 0., true, 0., 0.);
            }
            30 => {
                if screenshots {
                    if capture.borrow().is_none() {
                        let help = gtk::Window::list_toplevels()
                            .into_iter()
                            .filter_map(|w| w.downcast::<gtk::Window>().ok())
                            .find(|w| {
                                w.is_visible()
                                    && w.title().as_deref()
                                        == Some(ui.lang.text("Fastra – Hilfe", "Fastra – Help"))
                            })
                            .unwrap();
                        let path = PathBuf::from(
                            std::env::var_os("FASTRA_WORKFLOW_SCREENSHOT_DIR").unwrap(),
                        )
                        .join(format!("workflow-help-{}.png", ui.lang.text("de", "en")));
                        super::super::git_view::capture_to(&help, &path);
                        *capture.borrow_mut() = Some(std::sync::Arc::new(
                            std::sync::atomic::AtomicBool::new(true),
                        ));
                        return glib::ControlFlow::Continue;
                    }
                    if !capture
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .load(std::sync::atomic::Ordering::Acquire)
                    {
                        return glib::ControlFlow::Continue;
                    }
                    capture.borrow_mut().take();
                }
                std::fs::remove_dir_all(&fixtures).unwrap();
                println!("FASTRA_WORKFLOW_SELFTEST_OK native-tools-menus/swift-json-import-export/step-order-and-save/three-steps/intermediate-preview/apply-one-undo/stale-text/workflow-selection/exact-display/representation-invalidation/bundled-help");
                std::process::exit(0);
            }
            40 => {
                let v = view().unwrap();
                assert_eq!(v.selected_step.get(), Some(2));
                let up = find(v.window.upcast_ref(), "↑").unwrap();
                click(&v.window, &up);
            }
            41 => {
                let v = view().unwrap();
                assert_eq!(v.selected_step.get(), Some(1));
                let down = find(v.window.upcast_ref(), "↓").unwrap();
                click(&v.window, &down);
            }
            42 => {
                let v = view().unwrap();
                assert_eq!(v.selected_step.get(), Some(2));
                v.argument.set_text("* ");
                assert!(v.dirty.get());
                click(&v.window, &v.save);
            }
            43 => {
                let v = view().unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!v.dirty.get(), "{}", v.status.text());
                click(&v.window, &v.calculate);
                step.set(5);
            }
            44 => {
                let v = view().unwrap();
                assert!(v.exact.is_active());
                assert!(!v.apply.is_sensitive());
                click(&v.window, &v.calculate);
            }
            45 => {
                let v = view().unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(text(&v.after), "* b\\n\ncat\\n\na\\n\nb");
                click(&v.window, &v.apply);
            }
            46 => {
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "* b\ncat\na\nb");
                view().unwrap().window.set_visible(false);
                ui.window.present();
                let doc = ui.active().unwrap();
                super::super::git_view::test_click(
                    &source_panes::capture(&doc).unwrap().view,
                    &["ctrl+z"],
                );
            }
            47 => {
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "b\ncat\na\nb");
                view().unwrap().window.close();
                ui.window.present();
                step.set(12);
            }
            60 | 61 => {
                let mode = "workflow";
                let size = if step.get() % 10 == 0 { "min" } else { "wide" };
                let language = ui.lang.text("de", "en");
                if capture.borrow().is_none() {
                    *capture.borrow_mut() =
                        Some(snapshot(&format!("{mode}-{language}-{size}.png")));
                    return glib::ControlFlow::Continue;
                }
                if !capture
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .load(std::sync::atomic::Ordering::Acquire)
                {
                    return glib::ControlFlow::Continue;
                }
                capture.borrow_mut().take();
                let v = view().unwrap();
                match step.get() {
                    60 => v.window.set_default_size(1280, 900),
                    61 => {
                        v.stages.set_selected(2);
                        step.set(6);
                    }
                    _ => unreachable!(),
                }
            }
            _ => unreachable!(),
        }
        step.set(step.get() + 1);
        stamp.set(std::time::Instant::now());
        glib::ControlFlow::Continue
    });
}
