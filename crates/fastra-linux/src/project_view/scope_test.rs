use super::*;
use std::os::unix::ffi::OsStringExt;
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let fixture = PathBuf::from(std::env::var_os("FASTRA_PROJECT_FIXTURE").unwrap());
    let first = fixture.join(std::ffi::OsString::from_vec(b"project-\xff".to_vec()));
    let second = fixture.join("second-雪");
    for path in [&first, &second] {
        std::fs::create_dir_all(path.join("sub")).unwrap();
        std::fs::write(path.join("a.txt"), b"\xef\xbb\xbfcat\r\n").unwrap();
        std::fs::write(path.join("sub/keep.txt"), b"unrelated").unwrap();
    }
    support::test_size(ui.window.upcast_ref());
    let state = open(&ui);
    support::test_size(&state.window);
    state.set_root(first.clone());
    let phase = Cell::new(0);
    let started = Instant::now();
    let paused = Cell::new(None::<Instant>);
    let owner_binding = RefCell::new(None::<Binding>);
    let pending = RefCell::new(None::<(fastra_core::Cancellation, WorkBinding)>);
    let baseline = ui.documents.borrow().len();
    gtk::glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "project scope phase {} {}",
            phase.get(),
            state.status.text()
        );
        match phase.get() {
            0 => {
                if state.busy.get() || state.tree.borrow().is_none() {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert!(Rc::ptr_eq(&open(&ui), &state));
                state.filter.set_text("sub");
                state.collapsed.borrow_mut().insert(PathBuf::from("sub"));
                state.render();
                let binding = state.binding().unwrap();
                assert!(binding.is_current());
                *owner_binding.borrow_mut() = Some(binding.clone());
                let cancel = fastra_core::Cancellation::default();
                let work = binding.work(&cancel).unwrap();
                *pending.borrow_mut() = Some((cancel, work));
                let target = state
                    .tree
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .entries
                    .iter()
                    .find(|e| e.relative == Path::new("a.txt"))
                    .unwrap()
                    .clone();
                state.open_entry(&target);
                ui.window.set_visible(false);
                assert!(!ui.window.is_visible());
                assert!(
                    !binding.is_current(),
                    "hidden parent cannot own project actions"
                );
                paused.set(Some(Instant::now()));
                phase.set(1);
            }
            1 => {
                if paused.get().unwrap().elapsed() < Duration::from_millis(3300) {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert_eq!(
                    ui.documents.borrow().len(),
                    baseline,
                    "hidden project must refuse pending load"
                );
                assert!(!state.polling.get());
                ui.window.present();
                let reopened = open(&ui);
                assert!(Rc::ptr_eq(&reopened, &state));
                assert_eq!(state.filter.text(), "sub");
                assert!(state.collapsed.borrow().contains(Path::new("sub")));
                assert!(owner_binding.borrow().as_ref().unwrap().is_current());
                state.filter.set_text("");
                state.render();
                paused.set(Some(Instant::now()));
                phase.set(2);
            }
            2 => {
                if state.busy.get() || paused.get().unwrap().elapsed() < Duration::from_millis(350)
                {
                    return gtk::glib::ControlFlow::Continue;
                }
                if let Some(dir) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS") {
                    let dir = PathBuf::from(dir);
                    std::fs::create_dir_all(&dir).unwrap();
                    let paintable = gtk::WidgetPaintable::new(Some(&state.window));
                    let snap = gtk::Snapshot::new();
                    paintable.snapshot(
                        &snap,
                        f64::from(state.window.width()),
                        f64::from(state.window.height()),
                    );
                    state
                        .window
                        .renderer()
                        .unwrap()
                        .render_texture(snap.to_node().unwrap(), None)
                        .save_to_png(dir.join("project-persistent.png"))
                        .unwrap();
                }
                ui.find.set_text("cat");
                ui.replace.set_text("Hund 🐾");
                ui.mode.set_selected(0);
                ui.case.set_active(true);
                state.search_project.emit_clicked();
                assert_eq!(ui.scope.selected(), 3);
                phase.set(3);
            }
            4 => {
                if paused.get().unwrap().elapsed() < Duration::from_millis(350) {
                    return gtk::glib::ControlFlow::Continue;
                }
                if let Some(dir) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS") {
                    let paintable = gtk::WidgetPaintable::new(Some(&ui.window));
                    let snap = gtk::Snapshot::new();
                    paintable.snapshot(
                        &snap,
                        f64::from(ui.window.width()),
                        f64::from(ui.window.height()),
                    );
                    let Some(node) = snap.to_node() else {
                        return gtk::glib::ControlFlow::Continue;
                    };
                    ui.window
                        .renderer()
                        .unwrap()
                        .render_texture(node, None)
                        .save_to_png(PathBuf::from(dir).join("project-scope-main.png"))
                        .unwrap();
                }
                assert!(click_button(
                    ui.chrome
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .search_window
                        .upcast_ref(),
                    ui.lang.text("Projekt", "Project")
                ));
                phase.set(5);
            }
            _ => {
                let title = ui.lang.text("Suchen & Ersetzen", "Search & Replace");
                let Some(window) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| w.is_visible() && w.title().as_deref() == Some(title))
                else {
                    return gtk::glib::ControlFlow::Continue;
                };
                window.close();
                if phase.get() == 3 {
                    ui.window.present();
                    ui.scope.set_selected(0);
                    super::super::chrome::show_search(&ui);
                    paused.set(Some(Instant::now()));
                    phase.set(4);
                    return gtk::glib::ControlFlow::Continue;
                }
                let project = state.clone();
                let change: Rc<dyn Fn(PathBuf)> = Rc::new(move |path| project.set_root(path));
                let (cancel, work) = pending.borrow_mut().take().unwrap();
                super::super::folder::run_project_selftest(
                    ui.clone(),
                    owner_binding.borrow().clone().unwrap(),
                    first.clone(),
                    second.clone(),
                    change,
                    cancel,
                    work,
                );
                return gtk::glib::ControlFlow::Break;
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}
