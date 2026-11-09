use super::*;
use std::time::{Duration, Instant};
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let fixture = PathBuf::from(std::env::var_os("FASTRA_MACRO_FIXTURE").unwrap());
    let tool = PathBuf::from(std::env::var_os("FASTRA_MACRO_TEST_TOOL").unwrap());
    let engine = PathBuf::from(std::env::var_os("FASTRA_MACRO_TEST_ENGINE").unwrap());
    let project = fixture.join("document-project");
    let path = project.join("Project/Sources/Methods/SyntheticShellProbe.4dm");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(project.join("Project/Fixture.4DProject"), "{}").unwrap();
    let original = "// before shell-isolation probe\n";
    let expected = format!(
        "// shell-isolated\n// caller: {}",
        glib::user_name().into_string().expect("UTF-8 caller")
    );
    std::fs::write(&path, original).unwrap();
    let user = discovery::default_user().unwrap();
    std::fs::create_dir_all(&user).unwrap();
    std::fs::write(user.join("Runtime.xml"), r#"<macros><macro name="Runtime"><text><method>MAO_MethodeKomplettierenNeu(<method_name/>)</method></text></macro></macros>"#).unwrap();
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let state = RefCell::new(None::<Rc<State>>);
    let start = Instant::now();
    let at = Cell::new(Instant::now());
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            start.elapsed() < Duration::from_secs(35),
            "shell probe phase {} {:?}",
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
                if s.hub.busy.get() || !s.list.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                let Some(row) = s
                    .list
                    .row_at_index(0)
                    .filter(|r| r.width() > 0 && r.height() > 0)
                else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&row, &[]);
                at.set(Instant::now());
                phase.set(3);
            }
            3 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.selected_macro().is_none() {
                    git_view::test_click(&s.list.row_at_index(0).unwrap(), &[]);
                    at.set(Instant::now());
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
                phase.set(4);
            }
            4 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.hub.busy.get() || s.hub.config.borrow().engine.as_ref() != Some(&engine) {
                    return glib::ControlFlow::Continue;
                }
                if !s.prepare.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&s.prepare, &[]);
                at.set(Instant::now());
                phase.set(5);
            }
            5 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    s.preview.borrow().as_ref().map(|p| p.result.as_str()),
                    Some(expected.as_str()),
                    "{}",
                    s.status.text()
                );
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), original);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                if !git_view::try_capture(&s.window, "macro-shell-isolated-preview") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&s.apply, &[]);
                at.set(Instant::now());
                phase.set(6);
            }
            _ => {
                let s = state.borrow().as_ref().unwrap().clone();
                let doc = ui.active().unwrap();
                assert_eq!(buffer_text(&doc.buffer), expected);
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), original);
                assert!(!doc.buffer.can_undo());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                git_view::finish(s.window.clone(), ui.clone(), "four-d-macro-shell");
                return glib::ControlFlow::Break;
            }
        }
        glib::ControlFlow::Continue
    });
}
