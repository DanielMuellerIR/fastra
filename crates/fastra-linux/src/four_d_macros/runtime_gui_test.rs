use super::*;
use std::time::{Duration, Instant};
fn click(widget: &impl IsA<gtk::Widget>) {
    git_view::test_click(widget, &[]);
}
fn live_tool() -> usize {
    std::fs::read_dir("/proc")
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| {
            std::fs::read(e.path().join("cmdline"))
                .is_ok_and(|v| v.starts_with(b"/runtime/tool4d\0"))
        })
        .count()
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let fixture = PathBuf::from(std::env::var_os("FASTRA_MACRO_FIXTURE").unwrap());
    let tool = PathBuf::from(std::env::var_os("FASTRA_MACRO_TEST_TOOL").unwrap());
    let project = fixture.join("document-project");
    let engine = fixture.join("engine-project");
    let other = fixture.join("other-project");
    for root in [&project, &engine, &other] {
        std::fs::create_dir_all(root.join("Project/Sources/Methods")).unwrap();
        std::fs::write(root.join("Project/Fixture.4DProject"), "{}").unwrap();
    }
    std::fs::write(
        engine.join("Project/Sources/Methods/MacroRun.4dm"),
        "// synthetic MacroRun for synthetic tool only",
    )
    .unwrap();
    std::fs::create_dir(engine.join("userPreferences.original")).unwrap();
    let watches = engine.join("userPreferences.original/debuggerWatches.json");
    std::fs::write(&watches, "original watches").unwrap();
    let original = "// NONZERO\nFutureCommand:C9999(1)\n";
    let path = project.join("Project/Sources/Methods/Synthetic.4dm");
    std::fs::write(&path, original).unwrap();
    let user = discovery::default_user().unwrap();
    std::fs::create_dir_all(&user).unwrap();
    std::fs::write(user.join("Runtime.xml"),r#"<macros><macro name="Runtime"><text><method>MAO_MethodeKomplettierenNeu(<method_name/>)</method></text></macro></macros>"#).unwrap();
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let state = RefCell::new(None::<Rc<State>>);
    let at = Cell::new(Instant::now());
    let start = Instant::now();
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            start.elapsed() < Duration::from_secs(50),
            "runtime macro phase {} {:?}",
            phase.get(),
            state.borrow().as_ref().map(|s| s.status.text())
        );
        if at.get().elapsed() < Duration::from_millis(250) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                if ui
                    .active()
                    .is_none_or(|d| d.disk_path().as_ref() != Some(&path))
                {
                    return glib::ControlFlow::Continue;
                }
                project_view::open_path(&ui, project.clone());
                phase.set(1);
            }
            1 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                let s = create(&ui).unwrap();
                git_view::test_size(&s.window);
                *state.borrow_mut() = Some(s);
                phase.set(2);
            }
            2 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.hub.busy.get() || !s.list.is_mapped() || s.list.width() <= 0 {
                    return glib::ControlFlow::Continue;
                }
                let Some(row) = s
                    .list
                    .row_at_index(0)
                    .filter(|row| row.width() > 0 && row.height() > 0)
                else {
                    return glib::ControlFlow::Continue;
                };
                click(&row);
                at.set(Instant::now());
                phase.set(3);
            }
            3 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.selected_macro().is_none() {
                    click(&s.list.row_at_index(0).unwrap());
                    at.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.prepare.is_sensitive());
                assert!(!s.apply.is_sensitive());
                if !git_view::try_capture(&s.window, "macro-runtime-unconfigured") {
                    return glib::ControlFlow::Continue;
                }
                runtime::save_setting(
                    &s,
                    discovery::Change::Set(discovery::Field::Runtime, Some(tool.clone())),
                );
                runtime::save_setting(
                    &s,
                    discovery::Change::Set(discovery::Field::Engine, Some(engine.clone())),
                );
                at.set(Instant::now());
                phase.set(30);
            }
            30 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.hub.busy.get()
                    || s.hub.config.borrow().runtime.as_ref() != Some(&tool)
                    || s.hub.config.borrow().engine.as_ref() != Some(&engine)
                {
                    return glib::ControlFlow::Continue;
                }
                if s.selected_macro().is_none() {
                    click(&s.list.row_at_index(0).unwrap());
                    at.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                assert!(s.prepare.is_sensitive());
                assert!(!s.apply.is_sensitive());
                click(&s.prepare);
                at.set(Instant::now());
                phase.set(4);
            }
            4 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.running.get() {
                    return glib::ControlFlow::Continue;
                }
                let preview_ref = s.preview.borrow();
                let preview = preview_ref
                    .as_ref()
                    .unwrap_or_else(|| panic!("{}", s.status.text()));
                assert!(preview.result.contains("FutureCommand:C9999()"));
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), original);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                assert_eq!(
                    std::fs::read_to_string(&watches).unwrap(),
                    "original watches"
                );
                assert!(s.before.width() >= 180 && s.after.width() >= 180);
                drop(preview_ref);
                if !git_view::try_capture(&s.window, "macro-runtime-preview") {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                doc.buffer
                    .select_range(&doc.buffer.start_iter(), &doc.buffer.iter_at_offset(1));
                click(&s.apply);
                at.set(Instant::now());
                phase.set(5);
            }
            5 => {
                let s = state.borrow().as_ref().unwrap().clone();
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), original);
                assert!(s.status.text().contains(ui.lang.text("veraltet", "stale")));
                git_view::test_click(&s.after, &["ctrl+Return"]);
                at.set(Instant::now());
                phase.set(6);
            }
            6 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", s.status.text());
                click(&s.apply);
                at.set(Instant::now());
                phase.set(7);
            }
            7 => {
                let s = state.borrow().as_ref().unwrap().clone();
                let doc = ui.active().unwrap();
                assert!(buffer_text(&doc.buffer).contains("FutureCommand:C9999()"));
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), original);
                assert!(!doc.buffer.can_undo());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                doc.buffer.set_text("// SETSID\nFutureCommand:C9999()\n");
                click(&s.prepare);
                at.set(Instant::now());
                phase.set(8);
            }
            8 => {
                if live_tool() == 0 {
                    return glib::ControlFlow::Continue;
                }
                project_view::open_path(&ui, other.clone());
                project_view::open_path(&ui, project.clone());
                at.set(Instant::now());
                phase.set(9);
            }
            9 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.running.get() || live_tool() > 0 {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.apply.is_sensitive());
                assert!(s.preview.borrow().is_none());
                assert_eq!(
                    std::fs::read_to_string(&watches).unwrap(),
                    "original watches"
                );
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                if s.hub.busy.get() || source(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                s.window.present();
                ui.active()
                    .unwrap()
                    .buffer
                    .set_text("// MISSING\nFutureCommand:C9999()\n");
                click(&s.prepare);
                at.set(Instant::now());
                phase.set(10);
            }
            10 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.apply.is_sensitive());
                assert!(
                    s.status
                        .text()
                        .contains(ui.lang.text("kein vollständiges", "complete, valid result")),
                    "{}",
                    s.status.text()
                );
                if !git_view::try_capture(&s.window, "macro-runtime-error") {
                    return glib::ControlFlow::Continue;
                }
                ui.active()
                    .unwrap()
                    .buffer
                    .set_text("// NUL\nFutureCommand:C9999()\n");
                click(&s.prepare);
                at.set(Instant::now());
                phase.set(11);
            }
            11 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_none());
                assert!(!s.apply.is_sensitive());
                assert!(s.status.text().contains("U+0000"), "{}", s.status.text());
                assert_eq!(
                    buffer_text(&ui.active().unwrap().buffer),
                    "// NUL\nFutureCommand:C9999()\n"
                );
                if !git_view::try_capture(&s.window, "macro-runtime-nul-rejected") {
                    return glib::ControlFlow::Continue;
                }
                ui.active()
                    .unwrap()
                    .buffer
                    .set_text("// LONGLINE\nFutureCommand:C9999()\n");
                click(&s.prepare);
                at.set(Instant::now());
                phase.set(12);
            }
            12 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_none());
                assert!(!s.apply.is_sensitive());
                assert!(s.status.text().contains("64 KiB"), "{}", s.status.text());
                assert_eq!(
                    buffer_text(&ui.active().unwrap().buffer),
                    "// LONGLINE\nFutureCommand:C9999()\n"
                );
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                if !git_view::try_capture(&s.window, "macro-runtime-longline-rejected") {
                    return glib::ControlFlow::Continue;
                }
                ui.active()
                    .unwrap()
                    .buffer
                    .set_text("// SLEEP\nFutureCommand:C9999()\n");
                click(&s.prepare);
                at.set(Instant::now());
                phase.set(13);
            }
            13 => {
                if live_tool() == 0 {
                    return glib::ControlFlow::Continue;
                }
                state.borrow().as_ref().unwrap().window.set_visible(false);
                at.set(Instant::now());
                phase.set(14);
            }
            14 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.running.get() || live_tool() > 0 {
                    return glib::ControlFlow::Continue;
                }
                assert!(!s.apply.is_sensitive());
                assert!(s.preview.borrow().is_none());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                s.window.present();
                at.set(Instant::now());
                phase.set(15);
            }
            15 => {
                let s = state.borrow().as_ref().unwrap().clone();
                let config_path = discovery::settings_path().unwrap();
                let target = fixture.join("settings-original.json");
                std::fs::write(&target, std::fs::read(&config_path).unwrap()).unwrap();
                std::fs::remove_file(&config_path).unwrap();
                std::os::unix::fs::symlink(&target, &config_path).unwrap();
                runtime::save_setting(
                    &s,
                    discovery::Change::Set(
                        discovery::Field::Engine,
                        Some(fixture.join("must-not-be-adopted")),
                    ),
                );
                at.set(Instant::now());
                phase.set(16);
            }
            16 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if !s
                    .status
                    .text()
                    .contains(ui.lang.text("nicht gespeichert", "not saved"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(s.hub.config.borrow().engine.as_ref(), Some(&engine));
                assert_eq!(s.engine_label.text().as_str(), engine.to_str().unwrap());
                assert!(!s.apply.is_sensitive());
                let config_path = discovery::settings_path().unwrap();
                assert!(std::fs::symlink_metadata(&config_path)
                    .unwrap()
                    .is_symlink());
                if !git_view::try_capture(&s.window, "macro-settings-write-rejected") {
                    return glib::ControlFlow::Continue;
                }
                std::fs::remove_file(&config_path).unwrap();
                std::fs::copy(fixture.join("settings-original.json"), &config_path).unwrap();
                git_view::finish(s.window.clone(), ui.clone(), "four-d-macro-runtime");
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
