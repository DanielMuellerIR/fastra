use super::*;
use std::{
    path::Path,
    time::{Duration, Instant},
};
fn tick(delay: &Cell<Instant>) -> bool {
    delay.get().elapsed() < Duration::from_millis(250)
}
fn click(button: &gtk::Button, delay: &Cell<Instant>) {
    support::test_click(button, &[]);
    delay.set(Instant::now());
}
fn window(title: &str) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| w.is_visible() && w.title().as_deref() == Some(title))
}
fn button(widget: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(b) = widget
        .downcast_ref::<gtk::Button>()
        .filter(|b| b.label().as_deref() == Some(label))
    {
        return Some(b.clone());
    }
    let mut child = widget.first_child();
    while let Some(item) = child {
        if let Some(b) = button(&item, label) {
            return Some(b);
        }
        child = item.next_sibling();
    }
    None
}
fn active(ui: &Ui) -> Option<PathBuf> {
    ui.active().and_then(|doc| doc.disk_path())
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    match std::env::var("FASTRA_IMPORT_TEST_CASE").as_deref() {
        Ok("routing") => routing(ui),
        Ok("project") => project(ui),
        Ok("hostloss") => hostloss(ui),
        _ => flow(ui),
    }
}
fn setup(ui: &Rc<Ui>) -> (Rc<State>, PathBuf) {
    let fixture = PathBuf::from(std::env::var_os("FASTRA_TOOL_FIXTURE").unwrap());
    let state = open(ui);
    support::test_size(&state.window);
    for (entry, path) in [
        (&state.program, fixture.join("poormans-text")),
        (&state.source, fixture.join("source.mbox")),
        (&state.destination, fixture.join("destination")),
    ] {
        set_path(entry, &path, &state.status, ui.lang);
    }
    state.stem.set_text("result");
    (state, fixture)
}
fn flow(ui: Rc<Ui>) {
    let (state, fixture) = setup(&ui);
    let phase = Cell::new(0);
    let delay = Cell::new(Instant::now());
    let started = Instant::now();
    let progress_seen = Cell::new(false);
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "flow phase {}: {}",
            phase.get(),
            state.status.text()
        );
        if state.busy.get()
            && state
                .status
                .text()
                .contains(ui.lang.text("Nachrichten:", "Messages:"))
        {
            progress_seen.set(true);
        }
        if tick(&delay) || state.busy.get() {
            return gtk::glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                use std::os::unix::ffi::OsStrExt;
                let raw = Path::new(std::ffi::OsStr::from_bytes(b"/source-\xff.mbox"));
                set_path(&state.source, raw, &state.status, ui.lang);
                assert!(state.source.text().is_empty());
                assert!(state.status.text().contains("UTF-8"));
                set_path(
                    &state.source,
                    &fixture.join("source.mbox"),
                    &state.status,
                    ui.lang,
                );
                click(&state.catalog_button, &delay);
                phase.set(1);
            }
            1 => {
                assert!(super::super::buffer_text(&state.catalog.buffer()).contains("mbox"));
                std::fs::write(fixture.join("source.mbox"), "toolerror").unwrap();
                click(&state.prepare, &delay);
                phase.set(10);
            }
            10 => {
                assert!(state.prepared.borrow().is_none());
                assert!(!fixture.join("destination/result").exists());
                assert!(super::super::buffer_text(&state.preview.buffer())
                    .contains("missing required tool: fixture"));
                std::fs::write(fixture.join("source.mbox"), "valid").unwrap();
                click(&state.prepare, &delay);
                phase.set(2);
            }
            2 => {
                assert!(progress_seen.get(), "live progress was never visible");
                assert!(state.prepared.borrow().is_some(), "{}", state.status.text());
                assert!(!fixture.join("destination/result").exists());
                let visible = super::super::buffer_text(&state.preview.buffer());
                assert!(visible.contains(ui.lang.text("Inhaltsverlust", "Content loss")));
                for content in state
                    .prepared
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .preview()
                    .markdown_text
                    .values()
                {
                    assert!(visible.contains(content));
                }
                if !support::try_capture(&state.window, "import-preview") {
                    return gtk::glib::ControlFlow::Continue;
                }
                ui.active()
                    .unwrap()
                    .revision
                    .set(ui.active().unwrap().revision.get() + 1);
                click(&state.adopt, &delay);
                phase.set(3);
            }
            3 => {
                assert!(!fixture.join("destination/result").exists());
                assert!(state
                    .status
                    .text()
                    .contains(ui.lang.text("veraltet", "stale")));
                click(&state.prepare, &delay);
                phase.set(4);
            }
            4 => {
                assert!(state.prepared.borrow().is_some(), "{}", state.status.text());
                click(&state.adopt, &delay);
                phase.set(5);
            }
            _ => {
                if active(&ui) != Some(fixture.join("destination/result/index.md")) {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert!(fixture.join("destination/result/docs/two.md").is_file());
                assert_eq!(
                    std::fs::read_to_string(fixture.join("source.mbox")).unwrap(),
                    "valid"
                );
                support::finish(state.window.clone(), ui.clone(), "import-flow");
                return gtk::glib::ControlFlow::Break;
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}
fn project(ui: Rc<Ui>) {
    let (state, fixture) = setup(&ui);
    let a = fixture.join("project-a");
    let b = fixture.join("project-b");
    for p in [&a, &b] {
        std::fs::create_dir_all(p).unwrap();
    }
    super::super::project_view::open_path(&ui, a.clone());
    state.window.present();
    let phase = Cell::new(0);
    let delay = Cell::new(Instant::now());
    let started = Instant::now();
    let initial = RefCell::new(None);
    let original = ui.active().unwrap();
    let baseline = ui.documents.borrow().len();
    std::fs::write(fixture.join("probe.txt"), "unchanged probe").unwrap();
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "project phase {}: {}",
            phase.get(),
            state.status.text()
        );
        if tick(&delay) || (state.busy.get() && !matches!(phase.get(), 4 | 6)) {
            return gtk::glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let Some(binding) = super::super::project_view::current_binding(&ui) else {
                    return gtk::glib::ControlFlow::Continue;
                };
                assert!(binding.is_current());
                *initial.borrow_mut() = owner(&ui);
                click(&state.prepare, &delay);
                phase.set(1);
            }
            1 => {
                assert!(state.prepared.borrow().is_some(), "{}", state.status.text());
                let expected = owner(&ui);
                let weak = Rc::downgrade(&ui);
                ui.load_path_owned(
                    fixture.join("probe.txt"),
                    Rc::new(move || weak.upgrade().and_then(|ui| owner(&ui)) == expected),
                );
                super::super::project_view::open_path(&ui, b.clone());
                super::super::project_view::open_path(&ui, a.clone());
                state.window.present();
                delay.set(Instant::now());
                phase.set(2);
            }
            2 => {
                let Some(current) = owner(&ui) else {
                    return gtk::glib::ControlFlow::Continue;
                };
                assert!(Rc::ptr_eq(&original, &ui.active().unwrap()));
                assert_eq!(
                    ui.documents.borrow().len(),
                    baseline,
                    "ABA must refuse pending open"
                );
                assert_ne!(current, *initial.borrow().as_ref().unwrap());
                click(&state.adopt, &delay);
                phase.set(3);
            }
            3 => {
                assert!(!fixture.join("destination/result").exists());
                assert!(state
                    .status
                    .text()
                    .contains(ui.lang.text("veraltet", "stale")));
                std::fs::write(fixture.join("source.mbox"), "cancel").unwrap();
                click(&state.prepare, &delay);
                phase.set(4);
            }
            4 => {
                if !fixture.join("source.pids").exists() {
                    return gtk::glib::ControlFlow::Continue;
                }
                super::super::project_view::open_path(&ui, b.clone());
                super::super::project_view::open_path(&ui, a.clone());
                state.window.present();
                delay.set(Instant::now());
                phase.set(5);
            }
            5 => {
                assert!(
                    state.prepared.borrow().is_none(),
                    "stale preparation must be refused"
                );
                if owner(&ui).is_none() {
                    return gtk::glib::ControlFlow::Continue;
                }
                std::fs::remove_file(fixture.join("source.pids")).unwrap();
                click(&state.prepare, &delay);
                phase.set(6);
            }
            6 => {
                if !fixture.join("source.pids").exists() {
                    return gtk::glib::ControlFlow::Continue;
                }
                click(
                    &button(
                        state.window.upcast_ref(),
                        ui.lang.text("Abbrechen", "Cancel"),
                    )
                    .unwrap(),
                    &delay,
                );
                phase.set(7);
            }
            _ => {
                assert!(state.prepared.borrow().is_none());
                assert!(!fixture.join("destination/result").exists());
                for pid in std::fs::read_to_string(fixture.join("source.pids"))
                    .unwrap()
                    .split_whitespace()
                {
                    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat"));
                    assert!(stat.map_or(true, |s| s
                        .rsplit_once(')')
                        .is_some_and(|(_, s)| s.starts_with(" Z") || s.starts_with(" X"))));
                }
                support::finish(
                    state.window.clone(),
                    ui.clone(),
                    "import-project-aba-cancel",
                );
                return gtk::glib::ControlFlow::Break;
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}
fn routing(ui: Rc<Ui>) {
    let fixture = PathBuf::from(std::env::var_os("FASTRA_TOOL_FIXTURE").unwrap());
    let phase = Cell::new(0);
    let delay = Cell::new(Instant::now());
    let started = Instant::now();
    let baseline = ui.documents.borrow().len();
    let sized = Cell::new(u32::MAX);
    ui.load_path_validated(
        fixture.join("source.mbox"),
        None,
        Rc::new(|| true),
        Some(Box::new(|_| false)),
    );
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "routing phase {}",
            phase.get()
        );
        if tick(&delay) {
            return gtk::glib::ControlFlow::Continue;
        }
        let title = ui.lang.text("Dokument öffnen", "Open document");
        match phase.get() {
            0 => {
                let Some(w) = window(title) else {
                    return gtk::glib::ControlFlow::Continue;
                };
                if sized.get() != phase.get() {
                    w.set_default_size(
                        std::env::var("FASTRA_TOOL_WIDTH").unwrap().parse().unwrap(),
                        320,
                    );
                    sized.set(phase.get());
                    delay.set(Instant::now());
                    return gtk::glib::ControlFlow::Continue;
                }
                if !support::try_capture(&w, "import-route-file") {
                    return gtk::glib::ControlFlow::Continue;
                }
                click(
                    &button(
                        w.upcast_ref(),
                        ui.lang.text("Quelltext öffnen", "Open source"),
                    )
                    .unwrap(),
                    &delay,
                );
                phase.set(1);
            }
            1 => {
                assert_eq!(
                    ui.documents.borrow().len(),
                    baseline,
                    "source choice must preserve original LoadValidator"
                );
                super::super::desktop_open::open_files(
                    &ui,
                    &[gio::File::for_path(fixture.join("package.mbox"))],
                );
                delay.set(Instant::now());
                phase.set(2);
            }
            2 => {
                let Some(w) = window(title) else {
                    return gtk::glib::ControlFlow::Continue;
                };
                if sized.get() != phase.get() {
                    w.set_default_size(
                        std::env::var("FASTRA_TOOL_WIDTH").unwrap().parse().unwrap(),
                        320,
                    );
                    sized.set(phase.get());
                    delay.set(Instant::now());
                    return gtk::glib::ControlFlow::Continue;
                }
                if !support::try_capture(&w, "import-route-package") {
                    return gtk::glib::ControlFlow::Continue;
                }
                click(
                    &button(
                        w.upcast_ref(),
                        ui.lang.text("Als Ordner öffnen", "Open as folder"),
                    )
                    .unwrap(),
                    &delay,
                );
                phase.set(3);
            }
            3 => {
                let Some(p) = super::super::project_view::current_binding(&ui) else {
                    return gtk::glib::ControlFlow::Continue;
                };
                assert_eq!(p.root.path, fixture.join("package.mbox"));
                super::super::desktop_open::open_files(
                    &ui,
                    &[gio::File::for_path(fixture.join("normal-folder"))],
                );
                delay.set(Instant::now());
                phase.set(4);
            }
            4 => {
                let Some(p) = super::super::project_view::current_binding(&ui) else {
                    return gtk::glib::ControlFlow::Continue;
                };
                if p.root.path != fixture.join("normal-folder") {
                    return gtk::glib::ControlFlow::Continue;
                }
                ui.load_path(fixture.join("unavailable.docx"));
                delay.set(Instant::now());
                phase.set(5);
            }
            5 => {
                let Some(w) = window(title) else {
                    return gtk::glib::ControlFlow::Continue;
                };
                let import = button(
                    w.upcast_ref(),
                    ui.lang
                        .text("Als Markdown importieren …", "Import as Markdown …"),
                )
                .unwrap();
                assert!(!import.is_sensitive());
                if !support::try_capture(&w, "import-route-unavailable") {
                    return gtk::glib::ControlFlow::Continue;
                }
                click(
                    &button(w.upcast_ref(), ui.lang.text("Abbrechen", "Cancel")).unwrap(),
                    &delay,
                );
                phase.set(6);
            }
            6 => {
                ui.load_path(fixture.join("source.mbox"));
                delay.set(Instant::now());
                phase.set(7);
            }
            7 => {
                let Some(w) = window(title) else {
                    return gtk::glib::ControlFlow::Continue;
                };
                click(
                    &button(
                        w.upcast_ref(),
                        ui.lang
                            .text("Als Markdown importieren …", "Import as Markdown …"),
                    )
                    .unwrap(),
                    &delay,
                );
                phase.set(8);
            }
            _ => {
                let Some(w) = window(ui.lang.text("Dokument importieren", "Import document"))
                else {
                    return gtk::glib::ControlFlow::Continue;
                };
                if !support::try_capture(&w, "import-route-import") {
                    return gtk::glib::ControlFlow::Continue;
                }
                support::finish(w, ui.clone(), "import-routing");
                return gtk::glib::ControlFlow::Break;
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}
fn hostloss(ui: Rc<Ui>) {
    let (state, _) = setup(&ui);
    if let Some(path) = std::env::var_os("FASTRA_IMPORT_HOSTLOSS_SOURCE") {
        set_path(&state.source, &PathBuf::from(path), &state.status, ui.lang);
    }
    let delay = Cell::new(Instant::now());
    gtk::glib::timeout_add_local(Duration::from_millis(30), move || {
        if tick(&delay) {
            return gtk::glib::ControlFlow::Continue;
        }
        support::test_click(&state.prepare, &[]);
        gtk::glib::ControlFlow::Break
    });
}
