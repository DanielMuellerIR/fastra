use super::*;
pub(crate) fn run_project_selftest(
    ui: Rc<Ui>,
    binding: super::project_view::Binding,
    first: PathBuf,
    second: PathBuf,
    change: Rc<dyn Fn(PathBuf)>,
    old_cancel: Cancellation,
    old_work: super::project_view::WorkBinding,
) {
    let state = RefCell::new(open_inner(&ui, Some(binding.clone())));
    let phase = Cell::new(0);
    let planning_cancelled = Cell::new(false);
    let navigation_started=Cell::new(false);
    let navigation_checked=Cell::new(false);
    let started = std::time::Instant::now();
    let paused = Cell::new(None::<std::time::Instant>);
    state.borrow().search.emit_clicked();
    let arm = |state: &FolderWindow| {
        state.pane.test_approve_initial();
    };
    glib::timeout_add_local(Duration::from_millis(50), move || {
        let _held = &old_work;
        assert!(
            started.elapsed() < Duration::from_secs(45),
            "project folder phase {} {}",
            phase.get(),
            state.borrow().status.text()
        );
        let current = state.borrow().clone();
        if current.busy.get() {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                if current.pending.borrow().is_none() || !current.pane.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(current.pending.borrow().as_ref().unwrap().files().len(), 2);
                let preview = current.pending.borrow().clone().unwrap();
                assert_eq!(preview.files()[0].path(), first.join("a.txt"));
                if !navigation_checked.get() {
                    if !navigation_started.replace(true) {
                        let button=source_next(current.pane.root.upcast_ref(),ui.lang.text("Nächster Treffer","Next match")).unwrap();
                        assert!(button.is_mapped()&&button.is_sensitive());
                        git_view::test_click(&button,&[]);
                        return glib::ControlFlow::Continue;
                    }
                    let Some(doc)=ui.active().filter(|doc|doc.disk_path().as_ref()==Some(&first.join("a.txt")))else{return glib::ControlFlow::Continue;};
                    if ui.search_emphasis.borrow().is_none(){return glib::ControlFlow::Continue;}
                    assert_eq!(buffer_text(&doc.buffer),"cat\r\n");
                    assert_eq!(doc.snapshot.borrow().as_ref().unwrap().bytes(),b"\xef\xbb\xbfcat\r\n");
                    assert!(!doc.buffer.is_modified()&&!doc.buffer.can_undo());
                    if !git_view::try_capture(ui.window.upcast_ref(),"project-source-jump"){return glib::ControlFlow::Continue;}
                    navigation_checked.set(true);
                }
                ui.add_document("Unrelated", "unchanged");
                ui.active()
                    .unwrap()
                    .buffer
                    .insert(&mut ui.active().unwrap().buffer.end_iter(), " DIRTY");
                assert!(Arc::ptr_eq(
                    &preview,
                    current.pending.borrow().as_ref().unwrap()
                ));
                assert!(binding.is_current());
                arm(&current);
                paused.set(Some(std::time::Instant::now()));
                phase.set(1);
            }
            1 => {
                if !current.pane.is_ready()
                    || paused.get().unwrap().elapsed() < Duration::from_millis(350)
                {
                    return glib::ControlFlow::Continue;
                }
                project_capture(&current, "project-preview");
                change(second.clone());
                assert!(!binding.is_current());
                assert!(old_cancel.check().is_err());
                current.apply.emit_clicked();
                assert!(current.pending.borrow().is_none());
                assert!(current.transaction.borrow().is_none());
                assert_eq!(
                    std::fs::read(first.join("a.txt")).unwrap(),
                    b"\xef\xbb\xbfcat\r\n"
                );
                assert_eq!(
                    std::fs::read(second.join("a.txt")).unwrap(),
                    b"\xef\xbb\xbfcat\r\n"
                );
                phase.set(2);
            }
            2 => {
                let project = ui.project.borrow().clone().unwrap();
                let Some(next) = project.test_binding() else {
                    return glib::ControlFlow::Continue;
                };
                current.window.upgrade().unwrap().close();
                let next = open_inner(&ui, Some(next));
                next.search.emit_clicked();
                *state.borrow_mut() = next;
                phase.set(3);
            }
            3 => {
                if current.pending.borrow().is_none() || !current.pane.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                arm(&current);
                phase.set(4);
            }
            4 => {
                if !current.pane.is_ready() || !current.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                current.apply.emit_clicked();
                if !planning_cancelled.replace(true) {
                    assert!(current.project_work.borrow().is_some());
                    change(first.clone());
                    phase.set(14);
                } else {
                    phase.set(5);
                }
            }
            5 => {
                assert!(
                    current.transaction.borrow().is_some(),
                    "{}",
                    current.status.text()
                );
                assert_eq!(
                    std::fs::read(second.join("a.txt")).unwrap(),
                    "\u{feff}Hund 🐾\r\n".as_bytes()
                );
                assert_eq!(
                    std::fs::read(first.join("a.txt")).unwrap(),
                    b"\xef\xbb\xbfcat\r\n"
                );
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "unchanged DIRTY");
                current.undo.emit_clicked();
                phase.set(6);
            }
            6 => {
                assert_eq!(
                    std::fs::read(second.join("a.txt")).unwrap(),
                    b"\xef\xbb\xbfcat\r\n"
                );
                ui.replace.set_text("cat");
                current.search.emit_clicked();
                phase.set(7);
            }
            7 => {
                if current.pending.borrow().is_none() || !current.pane.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                arm(&current);
                phase.set(8);
            }
            8 => {
                if !current.pane.is_ready() || !current.apply.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                current.apply.emit_clicked();
                phase.set(9);
            }
            9 => {
                assert!(current.transaction.borrow().is_none());
                assert!(current.status.text().contains(
                    ui.lang
                        .text("Keine wirksame Ersetzung", "No effective replacement")
                ));
                assert_eq!(
                    std::fs::read(second.join("a.txt")).unwrap(),
                    b"\xef\xbb\xbfcat\r\n"
                );
                ui.replace.set_text("Hund 🐾");
                current.search.emit_clicked();
                phase.set(10);
            }
            10 => {
                if current.pending.borrow().is_none() || !current.pane.is_ready() {
                    return glib::ControlFlow::Continue;
                }
                let moved = second.with_extension("moved");
                std::fs::rename(&second, &moved).unwrap();
                std::fs::create_dir(&second).unwrap();
                std::fs::write(second.join("a.txt"), b"foreign cat").unwrap();
                current.search.emit_clicked();
                phase.set(11);
            }
            14 => {
                assert!(current.transaction.borrow().is_none());
                assert!(current.project_work.borrow().is_none());
                assert_eq!(
                    std::fs::read(second.join("a.txt")).unwrap(),
                    b"\xef\xbb\xbfcat\r\n"
                );
                change(second.clone());
                phase.set(15);
            }
            15 => {
                let project = ui.project.borrow().clone().unwrap();
                let Some(next) = project.test_binding() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(next.root.path, second);
                current.window.upgrade().unwrap().close();
                let next = open_inner(&ui, Some(next));
                next.search.emit_clicked();
                *state.borrow_mut() = next;
                phase.set(3);
            }
            _ => {
                assert!(current.pending.borrow().is_none());
                assert!(current.transaction.borrow().is_none());
                assert_eq!(std::fs::read(second.join("a.txt")).unwrap(), b"foreign cat");
                assert_eq!(
                    std::fs::read(second.with_extension("moved").join("a.txt")).unwrap(),
                    b"\xef\xbb\xbfcat\r\n"
                );
                println!("FASTRA_PROJECT_SCOPE_OK reused-tree/hidden-load/poller-restart/raw-root/tab-stability/root-switch/cancel/stale-apply/BOM-CRLF/apply-undo/no-op-status/planning-cancel/root-replaced");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
        }
        glib::ControlFlow::Continue
    });
}
fn project_capture(state: &FolderWindow, name: &str) {
    if let Some(dir) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS") {
        let dir = PathBuf::from(dir);
        std::fs::create_dir_all(&dir).unwrap();
        let window = state.window.upgrade().unwrap();
        let paintable = gtk::WidgetPaintable::new(Some(&window));
        let snap = gtk::Snapshot::new();
        paintable.snapshot(&snap, f64::from(window.width()), f64::from(window.height()));
        window
            .renderer()
            .unwrap()
            .render_texture(snap.to_node().unwrap(), None)
            .save_to_png(dir.join(format!("{name}.png")))
            .unwrap();
    }
}

fn source_next(root:&gtk::Widget,title:&str)->Option<gtk::Button>{
    if let Some(button)=root.downcast_ref::<gtk::Button>().filter(|button|button.tooltip_text().as_deref()==Some(title)){return Some(button.clone());}
    for child in chrome::children(root){if let Some(button)=source_next(&child,title){return Some(button);}}
    None
}
