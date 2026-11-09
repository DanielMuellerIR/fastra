use super::*;
use std::time::Instant;
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
fn search_window(ui: &Ui) -> gtk::Window {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| {
            w.is_mapped()
                && w.title().as_deref()
                    == Some(ui.lang.text("Suchen & Ersetzen", "Search & Replace"))
        })
        .unwrap()
}
fn chooser(ui: &Ui) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| {
            w.is_mapped()
                && w.title().as_deref()
                    == Some(ui.lang.text("Projekt-Datei-Set", "Project file set"))
        })
}
fn button(root: &gtk::Widget, title: &str) -> gtk::Button {
    widgets::<gtk::Button>(root)
        .into_iter()
        .find(|b| {
            b.is_mapped()
                && (b.label().as_deref() == Some(title)
                    || b.tooltip_text().as_deref() == Some(title))
        })
        .unwrap()
}
fn hits_ready(ui: &Ui) -> bool {
    button(search_window(ui).upcast_ref(), ui.lang.text("Alle", "All")).is_sensitive()
}
fn drop_choice(drop: &gtk::DropDown, last: bool) {
    drop.grab_focus();
    git_view::test_keys(
        drop,
        &["space", if last { "End" } else { "Home" }, "Return"],
    );
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let project = std::env::var("FASTRA_SEARCH_SOURCES_SELFTEST").as_deref() == Ok("project");
    let fixture = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join("sources");
    for path in ["src", "other", "DerivedData"] {
        std::fs::create_dir_all(fixture.join(path)).unwrap();
    }
    for path in [
        "src/a.txt",
        "src/a.odd",
        "one.txt",
        "other/b.txt",
        "DerivedData/c.txt",
    ] {
        std::fs::write(fixture.join(path), "cat\r\n").unwrap();
    }
    let folders = (0..10)
        .map(|i| fixture.with_file_name(format!("folder-{i}")))
        .collect::<Vec<_>>();
    for path in &folders {
        std::fs::create_dir(path).unwrap();
    }
    for path in &folders[..2] {
        std::fs::write(path.join("a.txt"), "cat\r\n").unwrap();
    }
    ui.find.set_text("cat");
    ui.replace.set_text("dog");
    ui.mode.set_selected(0);
    if project {
        project_view::open_path(&ui, fixture.clone());
    }
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let captures = RefCell::new(None);
    let controls = RefCell::new(None::<Rc<Controls>>);
    let focus_probe = Cell::new(None::<Instant>);
    let filter_began = Cell::new(None::<Instant>);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 45,
            "sources project={project} phase{}",
            phase.get()
        );
        if pause.get().elapsed() < Duration::from_millis(240) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                if project && project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                ui.scope.set_selected(if project { 3 } else { 2 });
                chrome::show_search(&ui);
                *controls.borrow_mut() = Some(folder::test_sources(&ui));
            }
            1 => {
                let s = controls.borrow().clone().unwrap();
                if !s.ready.get() || s.busy() {
                    return glib::ControlFlow::Continue;
                }
                if project {
                    if folder::test_matches(&ui) != Some(3) || !hits_ready(&ui) {
                        return glib::ControlFlow::Continue;
                    }
                    git_view::test_click(
                        &button(
                            search_window(&ui).upcast_ref(),
                            ui.lang
                                .text("Gespeichertes Datei-Set anlegen", "Create saved file set"),
                        ),
                        &[],
                    );
                } else {
                    s.enqueue(Some(Change::AddFolders(folders.clone())));
                }
            }
            2 => {
                let s = controls.borrow().clone().unwrap();
                if project {
                    let Some(window) = chooser(&ui) else {
                        return glib::ControlFlow::Continue;
                    };
                    let entries = widgets::<gtk::Entry>(window.upcast_ref());
                    entries[0]
                        .set_text("A deliberately long saved source set name for layout checks");
                    let paths = widgets::<gtk::TextView>(window.upcast_ref());
                    paths[0].buffer().set_text("../outside");
                    git_view::test_click(
                        &button(window.upcast_ref(), ui.lang.text("Sichern", "Save")),
                        &[],
                    );
                } else {
                    if s.busy() || folder::test_matches(&ui) != Some(2) || !hits_ready(&ui) {
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(s.request().unwrap().roots.len(), 10);
                    assert!(s.scroll.height() <= 184);
                    if !git_view::try_capture_x11(
                        &search_window(&ui),
                        "search-folder-sources",
                        &captures,
                    ) {
                        return glib::ControlFlow::Continue;
                    }
                    let checks = widgets::<gtk::CheckButton>(s.list.upcast_ref());
                    assert!(!checks.is_empty());
                    git_view::test_click(&checks[0], &[]);
                }
            }
            3 => {
                let s = controls.borrow().clone().unwrap();
                if project {
                    let window = chooser(&ui).unwrap();
                    let paths = widgets::<gtk::TextView>(window.upcast_ref())[0].buffer();
                    if buffer_text(&paths) != "src\none.txt" {
                        assert!(widgets::<gtk::Label>(window.upcast_ref())
                            .iter()
                            .any(|l| l.text().contains("..")));
                        assert_eq!(s.settings.borrow().project(&fixture).sets.len(), 1);
                        paths.set_text("src\none.txt");
                        return glib::ControlFlow::Continue;
                    }
                    if !git_view::try_capture_x11(&window, "search-file-set-editor", &captures) {
                        return glib::ControlFlow::Continue;
                    }
                    git_view::test_click(
                        &button(window.upcast_ref(), ui.lang.text("Sichern", "Save")),
                        &[],
                    );
                } else {
                    if s.busy() || folder::test_matches(&ui) != Some(1) {
                        return glib::ControlFlow::Continue;
                    }
                    assert!(!s.settings.borrow().folders[0].enabled);
                    assert_eq!(s.request().unwrap().roots.len(), 9);
                    let remove = widgets::<gtk::Button>(s.list.upcast_ref())
                        .into_iter()
                        .find(|b| b.is_mapped())
                        .unwrap();
                    git_view::test_click(&remove, &[]);
                }
            }
            4 => {
                let s = controls.borrow().clone().unwrap();
                if project {
                    if chooser(&ui).is_some()
                        || s.busy()
                        || folder::test_matches(&ui) != Some(2)
                        || !hits_ready(&ui)
                    {
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(
                        s.settings.borrow().project(&fixture).selected().paths,
                        vec!["src", "one.txt"]
                    );
                    assert_eq!(
                        search_window(&ui).width(),
                        std::env::var("FASTRA_SEARCH_LAYOUT_WIDTH")
                            .unwrap_or("520".into())
                            .parse::<i32>()
                            .unwrap()
                    );
                    if !git_view::try_capture_x11(
                        &search_window(&ui),
                        "search-project-file-set",
                        &captures,
                    ) {
                        return glib::ControlFlow::Continue;
                    }
                    drop_choice(&s.filter, true);
                } else {
                    if s.busy() || s.settings.borrow().folders.len() != 9 || !hits_ready(&ui) {
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(s.settings.borrow().folders[0].path(), folders[1]);
                    let menu = widgets::<gtk::MenuButton>(s.root.upcast_ref())
                        .into_iter()
                        .find(|m| m.widget_name() == "fastra-folder-file-types")
                        .unwrap();
                    menu.popup();
                    let popover = menu.popover().unwrap();
                    if filter_began.get().is_none() {
                        filter_began.set(Some(Instant::now()));
                        return glib::ControlFlow::Continue;
                    }
                    if filter_began.get().unwrap().elapsed() < Duration::from_millis(80) {
                        return glib::ControlFlow::Continue;
                    }
                    if !popover.is_mapped()
                        || !git_view::try_capture_x11(
                            &popover,
                            "search-folder-filter-menu",
                            &captures,
                        )
                    {
                        return glib::ControlFlow::Continue;
                    }
                    let all = widgets::<gtk::CheckButton>(menu.popover().unwrap().upcast_ref())
                        .into_iter()
                        .find(|c| {
                            c.label().as_deref() == Some(s.lang().text("Alle Dateien", "All files"))
                        })
                        .unwrap();
                    glib::timeout_add_local_once(Duration::from_millis(100), move || {
                        git_view::test_click(&all, &[]);
                    });
                }
            }
            5 => {
                let s = controls.borrow().clone().unwrap();
                if s.project.is_none() && s.filter.selected() != 1 {
                    return glib::ControlFlow::Continue;
                }
                if s.busy() {
                    return glib::ControlFlow::Continue;
                }
                if project {
                    if s.settings.borrow().project(&fixture).known_text
                        || folder::test_matches(&ui) != Some(3)
                    {
                        return glib::ControlFlow::Continue;
                    }
                    if focus_probe.get().is_none() {
                        assert!(s.sets.grab_focus());
                        git_view::test_keys(&s.sets, &["Tab"]);
                        focus_probe.set(Some(Instant::now()));
                        return glib::ControlFlow::Continue;
                    }
                    if focus_probe.get().unwrap().elapsed() < Duration::from_millis(240) {
                        return glib::ControlFlow::Continue;
                    }
                    assert!(
                        button(
                            search_window(&ui).upcast_ref(),
                            ui.lang
                                .text("Gespeichertes Datei-Set anlegen", "Create saved file set")
                        )
                        .has_focus(),
                        "native Tab crosses the custom group container"
                    );
                    drop_choice(&s.sets, false);
                } else {
                    if s.settings.borrow().known_text {
                        return glib::ControlFlow::Continue;
                    }
                    search_window(&ui).close();
                }
            }
            6 => {
                let s = controls.borrow().clone().unwrap();
                if project {
                    if s.busy()
                        || s.settings.borrow().project(&fixture).active != "all"
                        || folder::test_matches(&ui) != Some(4)
                    {
                        return glib::ControlFlow::Continue;
                    }
                    git_view::test_click(&s.remove_set, &[]);
                } else {
                    if search_window_optional(&ui).is_some() {
                        return glib::ControlFlow::Continue;
                    }
                    chrome::show_search(&ui);
                    *controls.borrow_mut() = Some(folder::test_sources(&ui));
                }
            }
            7 => {
                let s = controls.borrow().clone().unwrap();
                if !s.ready.get() || s.busy() {
                    return glib::ControlFlow::Continue;
                }
                if project {
                    if s.settings.borrow().project(&fixture).sets.len() != 1
                        || folder::test_matches(&ui) != Some(3)
                    {
                        return glib::ControlFlow::Continue;
                    }
                    assert!(!s.remove_set.is_sensitive());
                } else {
                    assert_eq!(s.request().unwrap().roots.len(), 9);
                    assert!(!s.settings.borrow().known_text);
                }
                if !hits_ready(&ui) {
                    return glib::ControlFlow::Continue;
                }
                if !git_view::try_capture_x11(
                    &search_window(&ui),
                    "search-sources-persisted",
                    &captures,
                ) {
                    return glib::ControlFlow::Continue;
                }
                if project {
                    s.excludes.set_text("other");
                    search_window(&ui).close();
                    assert!(
                        search_window_optional(&ui).is_some(),
                        "Close waits for the pending preference write"
                    );
                } else {
                    return finish(&ui, &fixture, project);
                }
            }
            8 => {
                let s = controls.borrow().clone().unwrap();
                if s.busy() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(s.settings.borrow().project(&fixture).exclusions, "other");
                assert!(s
                    .request()
                    .unwrap()
                    .exclusions
                    .iter()
                    .any(|p| p == "DerivedData"));
                search_window(&ui).close();
            }
            9 => {
                if search_window_optional(&ui).is_some() {
                    return glib::ControlFlow::Continue;
                }
                chrome::show_search(&ui);
                *controls.borrow_mut() = Some(folder::test_sources(&ui));
            }
            10 => {
                let s = controls.borrow().clone().unwrap();
                if !s.ready.get()
                    || s.busy()
                    || folder::test_matches(&ui) != Some(3)
                    || !hits_ready(&ui)
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(s.excludes.text(), "other");
                assert_eq!(s.settings.borrow().project(&fixture).sets.len(), 1);
                assert!(!s.settings.borrow().project(&fixture).known_text);
                if !git_view::try_capture_x11(
                    &search_window(&ui),
                    "search-project-reopened",
                    &captures,
                ) {
                    return glib::ControlFlow::Continue;
                }
                return finish(&ui, &fixture, project);
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
fn search_window_optional(ui: &Ui) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| {
            w.is_mapped()
                && w.title().as_deref()
                    == Some(ui.lang.text("Suchen & Ersetzen", "Search & Replace"))
        })
}

fn finish(ui: &Rc<Ui>, fixture: &std::path::Path, project: bool) -> glib::ControlFlow {
    for path in [
        "src/a.txt",
        "src/a.odd",
        "one.txt",
        "other/b.txt",
        "DerivedData/c.txt",
    ] {
        assert_eq!(std::fs::read(fixture.join(path)).unwrap(), b"cat\r\n");
    }
    println!("PASS native search sources project={project}: real checkbox/remove/type picker/file-set create/invalid path/delete controls, bounded folder list, fresh persisted choices, exact search subsets, mandatory DerivedData exclusion, close waits for preference writes, no source writes");
    search_window(ui).close();
    git_view::finish(ui.window.clone().upcast(), ui.clone(), "search-sources");
    glib::ControlFlow::Break
}
