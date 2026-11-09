use super::*;
use std::time::Instant;

pub(super) fn delay(cancel: &Cancellation) {
    if std::env::var_os("FASTRA_FOLDER_READONLY_SELFTEST").is_some() {
        let start = Instant::now();
        while start.elapsed() < Duration::from_millis(1000) && cancel.check().is_ok() {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
fn widgets<T: IsA<gtk::Widget> + glib::object::ObjectType>(root: &gtk::Widget) -> Vec<T> {
    let mut result = root
        .clone()
        .downcast::<T>()
        .ok()
        .into_iter()
        .collect::<Vec<_>>();
    for child in chrome::children(root) {
        result.extend(widgets::<T>(&child));
    }
    result
}
fn menu(state: &FolderWindow) -> gtk::MenuButton {
    widgets::<gtk::MenuButton>(state.sources.borrow().as_ref().unwrap().root.upcast_ref())
        .into_iter()
        .find(|m| m.widget_name() == "fastra-folder-file-types")
        .unwrap()
}
pub(crate) fn start(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root =
        PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join("read-only-search");
    std::fs::create_dir(&root).unwrap();
    std::fs::write(root.join("a.txt"), "cat cat dog\n").unwrap();
    std::fs::write(root.join("a.odd"), "cat\n").unwrap();
    ui.add_document("unchanged.txt", "editor remains unchanged\n");
    ui.find.set_text("cat");
    ui.replace.set_text("fox");
    ui.mode.set_selected(0);
    ui.scope.set_selected(2);
    let state = open_inner(&ui, None);
    state.set_root(root.clone());
    let phase = Cell::new(0);
    let began = Instant::now();
    let opened = Cell::new(None::<Instant>);
    let capture = RefCell::new(None);
    let reopened = RefCell::new(None::<Rc<FolderWindow>>);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed() < Duration::from_secs(25),
            "read-only search phase {}: {}",
            phase.get(),
            state.status.text()
        );
        let sources = state.sources.borrow().as_ref().unwrap().clone();
        match phase.get() {
            0 => {
                if sources.busy() {
                    return glib::ControlFlow::Continue;
                }
                state.search.emit_clicked();
            }
            1 => {
                if !state.busy.get() || !state.reading.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(sources.root.is_sensitive());
                assert!(state.excludes.is_sensitive() && state.known_text.is_sensitive());
                assert!(!state.apply.is_sensitive());
                git_view::test_click(&menu(&state), &[]);
                opened.set(Some(Instant::now()));
            }
            2 => {
                if opened.get().unwrap().elapsed() < Duration::from_millis(160) {
                    return glib::ControlFlow::Continue;
                }
                let popup = menu(&state).popover().unwrap();
                assert!(state.busy.get() && state.reading.get());
                assert!(popup.is_visible() && sources.root.is_sensitive());
                if !git_view::try_capture_x11(&popup, "folder-menu-during-scan", &capture) {
                    return glib::ControlFlow::Continue;
                }
                let all = widgets::<gtk::CheckButton>(popup.upcast_ref())
                    .into_iter()
                    .find(|c| {
                        c.label().as_deref() == Some(ui.lang.text("Alle Dateien", "All files"))
                    })
                    .unwrap();
                git_view::test_click(&all, &[]);
            }
            3 => {
                if state.busy.get()
                    || sources.busy()
                    || state
                        .pending
                        .borrow()
                        .as_ref()
                        .is_none_or(|p| p.matches() != 3)
                    || !state.pane.is_ready()
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(!state.pane.has_approvals() && !state.apply.is_sensitive());
                assert!(!state.known_text.is_active());
                let window = state.window.upgrade().unwrap();
                let find = widgets::<gtk::Entry>(window.upcast_ref())
                    .into_iter()
                    .find(|e| {
                        e.placeholder_text().as_deref()
                            == Some(
                                ui.lang
                                    .text("Suchausdruck eingeben…", "Enter a search expression…"),
                            )
                    })
                    .unwrap();
                git_view::test_click(&find, &["ctrl+a", "d", "o", "g"]);
            }
            4 => {
                if !state.busy.get() || !state.reading.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.find.text(), "dog");
                assert!(sources.root.is_sensitive());
                assert!(
                    !prevent_close(&ui),
                    "A read-only scan must not block closing the owner"
                );
                let window = state.window.upgrade().unwrap();
                window.close();
                assert!(
                    !window.is_visible(),
                    "Closing cancels a read-only scan immediately"
                );
            }
            5 => {
                if state.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(state.pending.borrow().is_none());
                *reopened.borrow_mut() = Some(open_inner(&ui, None));
            }
            6 => {
                let current = reopened.borrow().clone().unwrap();
                if current.busy.get()
                    || current.sources.borrow().as_ref().unwrap().busy()
                    || current
                        .pending
                        .borrow()
                        .as_ref()
                        .is_none_or(|p| p.matches() != 1)
                    || !current.pane.is_ready()
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(!current.pane.has_approvals() && !current.apply.is_sensitive());
                assert!(!current.known_text.is_active());
                if !git_view::try_capture_x11(
                    &current.window.upgrade().unwrap(),
                    "folder-scan-reopened",
                    &capture,
                ) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read(root.join("a.txt")).unwrap(), b"cat cat dog\n");
                assert_eq!(std::fs::read(root.join("a.odd")).unwrap(), b"cat\n");
                assert_eq!(
                    buffer_text(&ui.active().unwrap().buffer),
                    "editor remains unchanged\n"
                );
                println!("PASS read-only folder scan: native source menu remains usable while worker is held; changed type cancels old preview and yields exact fresh matches; actual Find typing; child and owner close allowed; late reply cannot publish into reopened search; no approvals or source writes");
                current.window.upgrade().unwrap().close();
                git_view::finish(ui.window.clone().upcast(), ui.clone(), "folder-readonly");
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        glib::ControlFlow::Continue
    });
}
