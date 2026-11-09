use super::*;
fn send(title: String, args: Vec<String>) {
    std::thread::spawn(move || {
        let output = std::process::Command::new("xdotool")
            .args(["search", "--name", &format!("^{title}$")])
            .output()
            .unwrap();
        let ids = String::from_utf8(output.stdout).unwrap();
        let id = ids.lines().next().expect("test window");
        assert!(std::process::Command::new("xdotool")
            .args(["windowfocus", "--sync", id])
            .status()
            .unwrap()
            .success());
        let args: Vec<_> = args
            .into_iter()
            .map(|s| if s == "WINDOW" { id.into() } else { s })
            .collect();
        assert!(std::process::Command::new("xdotool")
            .args(args)
            .status()
            .unwrap()
            .success());
    });
}
fn click_with_keys(window: &impl IsA<gtk::Window>, widget: &impl IsA<gtk::Widget>, keys: &[&str]) {
    let window = window.as_ref();
    let widget = widget.as_ref();
    if let Some(popover) = widget.ancestor(gtk::Popover::static_type()).and_downcast::<gtk::Popover>() {
        if !popover.is_mapped() {
            if let Some(menu) = popover.parent().and_downcast::<gtk::MenuButton>() {
                menu.popup();
                let window = window.clone(); let widget = widget.clone(); let keys: Vec<_> = keys.iter().map(|key| key.to_string()).collect();
                glib::timeout_add_local_once(Duration::from_millis(150), move || { let refs: Vec<_> = keys.iter().map(String::as_str).collect(); click_with_keys(&window, &widget, &refs); });
                return;
            }
        }
    }
    if !widget.is_mapped() || widget.width() <= 0 || widget.height() <= 0 {
        let window = window.clone(); let widget = widget.clone(); let keys: Vec<_> = keys.iter().map(|key| key.to_string()).collect();
        glib::timeout_add_local_once(Duration::from_millis(50), move || { let refs: Vec<_> = keys.iter().map(String::as_str).collect(); click_with_keys(&window, &widget, &refs); });
        return;
    }
    let native = widget.native().expect("native test surface");
    let native_widget = native.clone().dynamic_cast::<gtk::Widget>().unwrap();
    let point = widget
        .compute_point(
            &native_widget,
            &gtk::graphene::Point::new(widget.width() as f32 / 2., widget.height() as f32 / 2.),
        )
        .unwrap();
    let (x, y) = native.surface_transform();
    let surface = native.surface().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null(), "X11 backend required for XTest");
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(surface.as_ptr().cast()) };
    let mut args = vec![
        "mousemove".into(),
        "--window".into(),
        id.to_string(),
        (point.x() as f64 - x).round().to_string(),
        (point.y() as f64 - y).round().to_string(),
        "click".into(),
        "1".into(),
    ];
    if !keys.is_empty() {
        args.push("key".into());
        args.extend(keys.iter().map(|key| key.to_string()));
    }
    send(window.title().unwrap().into(), args);
}
fn click(window: &impl IsA<gtk::Window>, widget: &impl IsA<gtk::Widget>) {
    click_with_keys(window, widget, &[])
}
// Der moderne FileDialog kapselt dieses öffentliche Chooser-Interface.
// Nur der Test setzt damit den Fixture-Pfad; Bestätigungen erfolgen per XTest.
#[allow(deprecated)]
fn set_open_path(picker: &gtk::Window, path: &std::path::Path) {
    picker
        .clone()
        .dynamic_cast::<gtk::FileChooser>()
        .unwrap()
        .set_file(&gio::File::for_path(path))
        .unwrap();
}
#[allow(deprecated)]
fn set_save_path(picker: &gtk::Window, path: &std::path::Path) {
    let chooser = picker.clone().dynamic_cast::<gtk::FileChooser>().unwrap();
    chooser
        .set_current_folder(Some(&gio::File::for_path(path.parent().unwrap())))
        .unwrap();
    chooser.set_current_name(path.file_name().unwrap().to_str().unwrap());
}
fn find(widget: &gtk::Widget, text: &str) -> Option<gtk::Widget> {
    if widget
        .downcast_ref::<gtk::Label>()
        .is_some_and(|label| label.text() == text)
        || widget
            .downcast_ref::<gtk::Button>()
            .is_some_and(|b| b.label().as_deref() == Some(text) || b.tooltip_text().as_deref() == Some(text))
        || widget
            .downcast_ref::<gtk::MenuButton>()
            .is_some_and(|b| b.label().as_deref() == Some(text) || b.tooltip_text().as_deref() == Some(text))
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
fn picker() -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| w.is_visible() && w.type_().name() == "GtkFileChooserDialog")
}
fn text(view: &gtk::TextView) -> String {
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

fn template_view() -> Option<Rc<View>> {
    VIEWS.with(|all| all.borrow().iter().find_map(std::rc::Weak::upgrade))
}
fn named(title: &str) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|v| v.downcast::<gtk::Window>().ok())
        .find(|v| v.is_visible() && v.title().as_deref() == Some(title))
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let runtime = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
    let fixture = runtime.join("swift-patterns.json");
    std::fs::write(
        &fixture,
        include_bytes!("../../../fastra-workflow/tests/fixtures/swift-patterns.json"),
    )
    .unwrap();
    let mut future = Collection::decode(
        include_bytes!("../../../fastra-workflow/tests/fixtures/swift-patterns.json"),
        &Cancellation::default(),
    )
    .unwrap();
    future.0.truncate(1);
    future.0[0].extra.insert(
        "futureFlags".into(),
        serde_json::from_str("{\"big\":123456789012345678901234567890,\"enabled\":true}").unwrap(),
    );
    let future_fixture = runtime.join("future-patterns.json");
    std::fs::write(
        &future_fixture,
        future.encode(&Cancellation::default()).unwrap(),
    )
    .unwrap();
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let export = root.join(format!("patterns-{}.json", std::process::id()));
    let future_export = root.join(format!("patterns-future-{}.json", std::process::id()));
    assert!(!export.exists() && !future_export.exists());
    let stage = Cell::new(0);
    let previous = Cell::new(255);
    let start = std::time::Instant::now();
    let generation = Cell::new(0);
    let painted = Cell::new(std::time::Instant::now());
    let baseline = "cat🙂 cat";
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed() < Duration::from_secs(90),
            "pattern selftest timed out stage {}",
            stage.get()
        );
        if previous.replace(stage.get()) != stage.get() {
            eprintln!("Pattern test stage {}", stage.get());
        }
        match stage.get() {
            0 => {
                if !ui.window.is_mapped() || ui.active().is_none() {
                    return glib::ControlFlow::Continue;
                }
                ui.active().unwrap().buffer.set_text(baseline);
                ui.find.set_text("cat");
                ui.replace.set_text("dog");
                ui.mode.set_selected(0);
                ui.case.set_active(true);
                ui.whole_word.set_active(true);
                chrome::show_search(&ui);
                ui.search();
                stage.set(1);
            }
            1 => {
                if !ui.approval.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                generation.set(ui.generation.get());
                let button = find(
                    ui.chrome.borrow().as_ref().unwrap().search_window.upcast_ref(),
                    ui.lang.text("Vorlagen verwalten…", "Manage templates…"),
                )
                .unwrap();
                click(&ui.chrome.borrow().as_ref().unwrap().search_window, &button);
                stage.set(2);
            }
            2 => {
                let Some(v) = template_view() else {
                    return glib::ControlFlow::Continue;
                };
                if v.busy.get() || v.snapshot.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let entry = gtk::Entry::new();
                entry.set_text("row\nname");
                assert_eq!(
                    entry.text(),
                    "row\nname",
                    "native name field must preserve imported text"
                );
                assert_eq!(v.builtins.len(), 38);
                assert!(v
                    .snapshot
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .collection
                    .0
                    .is_empty());
                assert!(!v.form.is_sensitive());
                assert!(!v.save.is_sensitive());
                click(&v.window, &v.apply);
                stage.set(3);
            }
            3 => {
                let v = template_view().unwrap();
                if v.busy.get() || ui.mode.selected() != 2 {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.find.text().contains('@'));
                assert_eq!(ui.replace.text(), "dog");
                assert!(ui.case.is_active() && ui.whole_word.is_active());
                assert_eq!(ui.scope.selected(), 0);
                assert!(ui.generation.get() > generation.get());
                assert!(!ui.approval.has_approvals() && !ui.apply.is_sensitive());
                assert!(!ui.apply.is_sensitive());
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), baseline);
                click(&v.window, &v.import);
                stage.set(4);
            }
            4 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                p.set_title(Some("Fastra Pattern Picker"));
                set_open_path(&p, &fixture);
                stage.set(5);
            }
            5 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                let Some(b) = ["Open", "Öffnen"]
                    .into_iter()
                    .find_map(|s| find(p.upcast_ref(), s))
                else {
                    return glib::ControlFlow::Continue;
                };
                click(&p, &b);
                stage.set(6);
            }
            6 => {
                let v = template_view().unwrap();
                let Some(dialog) = named(v.lang.text(
                    "Suchvorlagen vor Import prüfen",
                    "Review search templates before import",
                )) else {
                    return glib::ControlFlow::Continue;
                };
                let rendered = text(&text_view(dialog.upcast_ref()).unwrap());
                assert!(rendered.contains("user-6793398e") && rendered.contains("groupLabels"));
                let accept = find(
                    dialog.upcast_ref(),
                    v.lang.text("Sammlung importieren", "Import collection"),
                )
                .unwrap();
                click(&dialog, &accept);
                stage.set(7);
            }
            7 => {
                let v = template_view().unwrap();
                if v.busy.get() || v.snapshot.borrow().as_ref().unwrap().collection.0.len() != 2 {
                    return glib::ControlFlow::Continue;
                }
                v.picker.set_selected(38);
                let armed = Rc::new(Cell::new(true));
                let copy = armed.clone();
                let owner = Rc::downgrade(&ui);
                v.apply.connect_clicked(move |_| {
                    if copy.replace(false) {
                        owner.upgrade().unwrap().find.set_text("newer input");
                    }
                });
                click(&v.window, &v.apply);
                stage.set(8);
            }
            8 => {
                let v = template_view().unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.find.text(), "newer input");
                assert_eq!(ui.replace.text(), "dog");
                assert!(!ui.approval.has_approvals() && !ui.apply.is_sensitive());
                click(&v.window, &v.apply);
                stage.set(9);
            }
            9 => {
                let v = template_view().unwrap();
                if v.busy.get() || ui.find.text() != "(cat)(🙂?)" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.replace.text(), "$2$1");
                assert!(!ui.approval.has_approvals() && !ui.apply.is_sensitive());
                assert!(!ui.apply.is_sensitive());
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), baseline);
                click(&v.window, &v.duplicate);
                stage.set(10);
            }
            10 => {
                let v = template_view().unwrap();
                if !v.dirty.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(v.snapshot.borrow().as_ref().unwrap().collection.0.len(), 2);
                assert!(!v.import.is_sensitive() && !v.export.is_sensitive());
                assert!(prevent_close(&ui));
                click_with_keys(
                    &v.window,
                    &v.name,
                    &[
                        "ctrl+a", "M", "y", "space", "s", "a", "v", "e", "d", "space", "p", "a",
                        "t", "t", "e", "r", "n",
                    ],
                );
                stage.set(11);
            }
            11 => {
                let v = template_view().unwrap();
                if v.name.text() != "My saved pattern" {
                    return glib::ControlFlow::Continue;
                }
                click(&v.window, &v.save);
                stage.set(12);
            }
            12 => {
                let v = template_view().unwrap();
                if v.busy.get() || v.dirty.get() {
                    return glib::ControlFlow::Continue;
                }
                let s = v.snapshot.borrow();
                assert_eq!(s.as_ref().unwrap().collection.0.len(), 3);
                let p = s
                    .as_ref()
                    .unwrap()
                    .collection
                    .0
                    .iter()
                    .find(|p| p.name == "My saved pattern")
                    .unwrap();
                assert_eq!(p.group_labels, ["Tier", "Emoji"]);
                assert_ne!(p.id, "user-6793398e-0389-4ade-97b2-24f44b932101");
                drop(s);
                click(&v.window, &v.export);
                stage.set(13);
            }
            13 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                p.set_title(Some("Fastra Pattern Picker"));
                set_save_path(&p, &export);
                stage.set(14);
            }
            14 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                let Some(b) = ["Save", "Speichern"]
                    .into_iter()
                    .find_map(|s| find(p.upcast_ref(), s))
                else {
                    return glib::ControlFlow::Continue;
                };
                click(&p, &b);
                stage.set(15);
            }
            15 => {
                let v = template_view().unwrap();
                if v.busy.get() || !export.exists() {
                    return glib::ControlFlow::Continue;
                }
                let bytes = std::fs::read(&export).unwrap();
                let data: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                assert_eq!(data.as_array().unwrap().len(), 3);
                let imported = Collection::decode(&bytes, &Cancellation::default()).unwrap();
                assert!(imported.0.iter().any(|p| p.name == "My saved pattern"));
                click(&v.window, &v.import);
                stage.set(16);
            }
            16 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                p.set_title(Some("Fastra Pattern Picker"));
                set_open_path(&p, &future_fixture);
                stage.set(17);
            }
            17 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                let Some(b) = ["Open", "Öffnen"]
                    .into_iter()
                    .find_map(|s| find(p.upcast_ref(), s))
                else {
                    return glib::ControlFlow::Continue;
                };
                click(&p, &b);
                stage.set(18);
            }
            18 => {
                let v = template_view().unwrap();
                let Some(dialog) = named(v.lang.text(
                    "Suchvorlagen vor Import prüfen",
                    "Review search templates before import",
                )) else {
                    return glib::ControlFlow::Continue;
                };
                assert!(text(&text_view(dialog.upcast_ref()).unwrap()).contains("futureFlags"));
                let accept = find(
                    dialog.upcast_ref(),
                    v.lang.text("Sammlung importieren", "Import collection"),
                )
                .unwrap();
                click(&dialog, &accept);
                stage.set(19);
            }
            19 => {
                let v = template_view().unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(v.snapshot.borrow().as_ref().unwrap().collection.0.len(), 3);
                assert!(!v.apply.is_sensitive());
                assert!(matches!(
                    v.read_draft().unwrap().usable(&Cancellation::default()),
                    Err(Error::Unsupported(_))
                ));
                click(&v.window, &v.export);
                stage.set(20);
            }
            20 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                p.set_title(Some("Fastra Pattern Picker"));
                set_save_path(&p, &future_export);
                stage.set(21);
            }
            21 => {
                let Some(p) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                let Some(b) = ["Save", "Speichern"]
                    .into_iter()
                    .find_map(|s| find(p.upcast_ref(), s))
                else {
                    return glib::ControlFlow::Continue;
                };
                click(&p, &b);
                stage.set(22);
            }
            22 => {
                let v = template_view().unwrap();
                if v.busy.get() || !future_export.exists() {
                    return glib::ControlFlow::Continue;
                }
                let imported = Collection::decode(
                    &std::fs::read(&future_export).unwrap(),
                    &Cancellation::default(),
                )
                .unwrap();
                let p = imported.0.iter().find(|p| !p.extra.is_empty()).unwrap();
                assert_eq!(p.extra["futureFlags"], future.0[0].extra["futureFlags"]);
                click(&v.window, &v.new);
                stage.set(23);
            }
            23 => {
                let v = template_view().unwrap();
                if !v.dirty.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(v.read_draft().unwrap().regex, ui.find.text());
                assert_eq!(v.snapshot.borrow().as_ref().unwrap().collection.0.len(), 3);
                click(&v.window, &v.discard);
                stage.set(24);
            }
            24 => {
                let v = template_view().unwrap();
                if v.dirty.get() {
                    return glib::ControlFlow::Continue;
                }
                click(&v.window, &v.reload);
                stage.set(25);
            }
            25 => {
                let v = template_view().unwrap();
                if v.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(v.snapshot.borrow().as_ref().unwrap().collection.0.len(), 3);
                let index = v
                    .snapshot
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .collection
                    .0
                    .iter()
                    .position(|p| p.name == "My saved pattern")
                    .unwrap();
                v.picker.set_selected(38 + index as u32);
                v.window.set_default_size(640, 430);
                painted.set(std::time::Instant::now());
                stage.set(26);
            }
            26 | 27 => {
                if painted.get().elapsed() < Duration::from_millis(400) {
                    return glib::ControlFlow::Continue;
                }
                let v = template_view().unwrap();
                assert!(v.window.height() <= 900);
                git_view::capture(
                    &v.window,
                    &format!(
                        "patterns-{}-{}",
                        if ui.lang.0 { "de" } else { "en" },
                        if stage.get() == 26 { "min" } else { "wide" }
                    ),
                );
                if stage.get() == 26 {
                    v.window.set_default_size(1180, 650);
                    painted.set(std::time::Instant::now());
                    stage.set(27);
                } else {
                    assert_eq!(buffer_text(&ui.active().unwrap().buffer), baseline);
                    assert!(!ui.apply.is_sensitive() && !ui.approval.has_approvals());
                    assert!(ui.case.is_active() && ui.whole_word.is_active());
                    assert_eq!(ui.scope.selected(), 0);
                    v.window.close();
                    ui.window.present();
                    let help = find(ui.window.upcast_ref(), ui.lang.text("Hilfe", "Help")).unwrap();
                    click(&ui.window, &help);
                    stage.set(28);
                }
            }
            28 => {
                let Some(help) = named(ui.lang.text("Fastra – Hilfe", "Fastra – Help")) else {
                    return glib::ControlFlow::Continue;
                };
                let view = text_view(help.upcast_ref()).unwrap();
                let heading = ui.lang.text("Suchvorlagen", "Search templates");
                let content = text(&view);
                assert!(content.contains(heading));
                assert!(
                    content.contains(ui.lang.text("Gleiche IDs ersetzen", "Matching IDs replace"))
                );
                let (mut position, _) = view
                    .buffer()
                    .start_iter()
                    .forward_search(heading, gtk::TextSearchFlags::TEXT_ONLY, None)
                    .unwrap();
                view.scroll_to_iter(&mut position, 0., true, 0., 0.);
                painted.set(std::time::Instant::now());
                stage.set(29);
            }
            29 => {
                if painted.get().elapsed() < Duration::from_millis(400) {
                    return glib::ControlFlow::Continue;
                }
                let help = named(ui.lang.text("Fastra – Hilfe", "Fastra – Help")).unwrap();
                git_view::capture(
                    &help,
                    &format!("patterns-help-{}", if ui.lang.0 { "de" } else { "en" }),
                );
                std::fs::remove_file(&export).unwrap();
                std::fs::remove_file(&future_export).unwrap();
                std::fs::remove_file(&fixture).unwrap();
                std::fs::remove_file(&future_fixture).unwrap();
                eprintln!(
                    "FASTRA_PATTERN_SELFTEST_OK real-search-form-button/builtins-immutable/swift-json-import-review-export/optional-replacement-preserved/regex-mode/generation-invalidated/no-automatic-approval-or-document-write/stale-form-completion/duplicate-and-real-name-typing/private-save/new-draft-discard/reload/no-phantom-definitions/unknown-fields-and-precise-numbers-preserved/unknown-apply-disabled/dirty-main-close-guard/min-wide-layout/bundled-help"
                );
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
