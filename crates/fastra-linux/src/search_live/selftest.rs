use super::*;
use std::{path::PathBuf, time::Instant};
fn collect<T: IsA<gtk::Widget> + glib::object::ObjectType>(root: &gtk::Widget) -> Vec<T> {
    let mut found = root
        .clone()
        .downcast::<T>()
        .ok()
        .into_iter()
        .collect::<Vec<_>>();
    for child in chrome::children(root) {
        found.extend(collect::<T>(&child));
    }
    found
}
fn collection(ui: &Ui) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|window| {
            window.is_mapped()
                && window.title().as_deref()
                    == Some(ui.lang.text("Suchen & Ersetzen", "Search & Replace"))
        })
}
fn entry(window: &gtk::Window, title: &str) -> gtk::Entry {
    collect::<gtk::Entry>(window.upcast_ref())
        .into_iter()
        .find(|entry| entry.placeholder_text().as_deref() == Some(title))
        .unwrap()
}
fn next(window: &gtk::Window, lang: Language) -> gtk::Button {
    collect::<gtk::Button>(window.upcast_ref())
        .into_iter()
        .find(|button| {
            button.tooltip_text().as_deref() == Some(lang.text("Nächster Treffer", "Next match"))
        })
        .unwrap()
}
fn count(window: &gtk::Window, lang: Language, n: usize) -> bool {
    let expected = format!("{} ({n})", lang.text("Treffer", "Matches"));
    collect::<gtk::Label>(window.upcast_ref())
        .iter()
        .any(|label| label.is_mapped() && label.text() == expected)
}
fn geometry(window: &gtk::Window, name: &str) -> bool {
    let root = window.child().unwrap();
    println!(
        "GEOMETRY {name} actual={}x{} default={:?} root={:?}",
        window.width(),
        window.height(),
        window.default_size(),
        root.measure(gtk::Orientation::Vertical, root.width())
    );
    let expected = std::env::var("FASTRA_SEARCH_LAYOUT_WIDTH")
        .ok()
        .and_then(|s| s.parse::<i32>().ok())
        .unwrap_or(520);
    assert_eq!(window.width(), expected);
    if name.starts_with("search-live-file") {
        assert!(
            window.height() <= 520,
            "file search must retain compact Mac dimensions"
        );
    }
    git_view::try_capture(window, name)
}
fn type_query(entry: &gtk::Entry, keys: &[&str]) {
    entry.grab_focus();
    git_view::test_keys(entry, keys);
}
pub(crate) fn drag_capture(source: &gtk::Widget, target: &gtk::Widget) -> Rc<Cell<bool>> {
    let finished = Rc::new(Cell::new(false));
    let controllers = source.observe_controllers();
    let controller = (0..controllers.n_items())
        .filter_map(|i| controllers.item(i))
        .find_map(|item| item.downcast::<gtk::DragSource>().ok())
        .unwrap();
    let done = finished.clone();
    controller.connect_drag_end(move |_, _, _| done.set(true));
    let native = source.native().unwrap();
    let widget = native.clone().dynamic_cast::<gtk::Widget>().unwrap();
    let point = |w: &gtk::Widget| {
        w.compute_point(
            &widget,
            &gtk::graphene::Point::new(w.width() as f32 / 2., w.height() as f32 / 2.),
        )
        .unwrap()
    };
    let start = point(source);
    let end = point(target);
    let (x, y) = native.surface_transform();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let get: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { get(native.surface().unwrap().as_ptr().cast()) }.to_string();
    let sx = (f64::from(start.x()) - x).round().to_string();
    let sy = (f64::from(start.y()) - y).round().to_string();
    let step = (f64::from(start.x()) - x - 16.).round().to_string();
    let tx = (f64::from(end.x()) - x).round().to_string();
    let ty = (f64::from(end.y()) - y).round().to_string();
    std::thread::spawn(move || {
        assert!(std::process::Command::new("xdotool")
            .args([
                "windowraise",
                &id,
                "windowfocus",
                "--sync",
                &id,
                "mousemove",
                "--window",
                &id,
                &sx,
                &sy,
                "mousedown",
                "1",
                "sleep",
                "0.15",
                "mousemove",
                "--window",
                &id,
                &step,
                &sy,
                "sleep",
                "0.15",
                "mousemove",
                "--window",
                &id,
                &tx,
                &ty,
                "sleep",
                "0.35",
                "mousemove",
                "--window",
                &id,
                &tx,
                &ty,
                "sleep",
                "0.35",
                "mouseup",
                "1"
            ])
            .status()
            .unwrap()
            .success());
    });
    finished
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(1000, 650);
    let fixture = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join("live");
    std::fs::create_dir(&fixture).unwrap();
    std::fs::write(fixture.join("a.txt"), "cat ca\n").unwrap();
    std::fs::write(fixture.join("skip.txt"), "cat\n").unwrap();
    ui.add_document("live.txt", "cat Cat dog\n");
    let doc = ui.active().unwrap();
    ui.find.set_text("");
    ui.replace.set_text("fox");
    ui.mode.set_selected(0);
    ui.case.set_active(false);
    let drag_finished = RefCell::new(None::<Rc<Cell<bool>>>);
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let observed = Rc::new(Cell::new(false));
    let armed = Rc::new(Cell::new(false));
    let window_id = RefCell::new(None::<gtk::Window>);
    let weak = Rc::downgrade(&ui);
    let did = observed.clone();
    let arm = armed.clone();
    ui.find.connect_changed(move |_| {
        if arm.get() {
            if let Some(ui) = weak.upgrade() {
                assert!(ui.pending.borrow().is_none());
                assert!(ui.search_emphasis.borrow().is_none());
                did.set(true);
            }
        }
    });
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 45,
            "live phase{}: {} replacement={}",
            phase.get(),
            ui.status.text(),
            ui.replace.text()
        );
        if pause.get().elapsed() < Duration::from_millis(200) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                chrome::show_search(&ui);
                type_query(&ui.find, &["c", "a", "t"]);
            }
            1 => {
                if !ui
                    .pending
                    .borrow()
                    .as_ref()
                    .is_some_and(|pending| pending.preview.matches().len() == 2)
                {
                    return glib::ControlFlow::Continue;
                }
                if !next(&ui.chrome.borrow().as_ref().unwrap().search_window, ui.lang)
                    .is_sensitive()
                {
                    return glib::ControlFlow::Continue;
                }
                if !geometry(
                    &ui.chrome.borrow().as_ref().unwrap().search_window,
                    "search-live-file",
                ) {
                    return glib::ControlFlow::Continue;
                }
                armed.set(true);
                type_query(&ui.find, &["ctrl+a", "d", "o", "g"]);
            }
            2 => {
                if !ui.pending.borrow().as_ref().is_some_and(|pending| {
                    pending.preview.matches().len() == 1 && ui.find.text() == "dog"
                }) {
                    return glib::ControlFlow::Continue;
                }
                assert!(observed.get());
                armed.set(false);
                type_query(&ui.find, &["ctrl+a", "c", "a", "t"]);
            }
            3 => {
                if !ui
                    .pending
                    .borrow()
                    .as_ref()
                    .is_some_and(|pending| pending.preview.matches().len() == 2)
                {
                    return glib::ControlFlow::Continue;
                }
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                let ignore = collect::<gtk::CheckButton>(window.upcast_ref())
                    .into_iter()
                    .find(|button| {
                        button.label().as_deref()
                            == Some(ui.lang.text("Groß = klein", "Ignore case"))
                    })
                    .unwrap();
                git_view::test_click(&ignore, &[]);
            }
            4 => {
                if !ui
                    .pending
                    .borrow()
                    .as_ref()
                    .is_some_and(|pending| pending.preview.matches().len() == 1)
                {
                    return glib::ControlFlow::Continue;
                }
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                let swap =
                    collect::<gtk::Button>(window.upcast_ref())
                        .into_iter()
                        .find(|button| {
                            button.tooltip_text().as_deref()
                                == Some(ui.lang.text(
                                    "Suchen und Ersetzen vertauschen",
                                    "Swap Find and Replace",
                                ))
                        })
                        .unwrap();
                git_view::test_click(&swap, &[]);
                phase.set(40);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            40 => {
                assert_eq!(ui.find.text(), "fox");
                assert_eq!(ui.replace.text(), "cat");
                assert_eq!(buffer_text(&doc.buffer), "cat Cat dog\n");
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                let swap =
                    collect::<gtk::Button>(window.upcast_ref())
                        .into_iter()
                        .find(|button| {
                            button.tooltip_text().as_deref()
                                == Some(ui.lang.text(
                                    "Suchen und Ersetzen vertauschen",
                                    "Swap Find and Replace",
                                ))
                        })
                        .unwrap();
                git_view::test_click(&swap, &[]);
                phase.set(41);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            41 => {
                assert_eq!(ui.find.text(), "cat");
                assert_eq!(ui.replace.text(), "fox");
                git_view::test_keys(
                    &ui.chrome.borrow().as_ref().unwrap().search_window,
                    &["Escape"],
                );
                phase.set(5);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            5 => {
                if ui
                    .chrome
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .search_window
                    .is_visible()
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.pending.borrow().is_none());
                assert_eq!(buffer_text(&doc.buffer), "cat Cat dog\n");
                assert!(!doc.buffer.can_undo() && !doc.buffer.is_modified());
                ui.add_document("extra.txt", "cat\n");
                ui.scope.set_selected(1);
                chrome::show_search(&ui);
            }
            6 => {
                let Some(window) = collection(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                if !next(&window, ui.lang).is_sensitive() || !count(&window, ui.lang, 2) {
                    return glib::ControlFlow::Continue;
                }
                if !geometry(&window, "search-live-open") {
                    return glib::ControlFlow::Continue;
                }
                *window_id.borrow_mut() = Some(window.clone());
                chrome::show_search(&ui);
                assert_eq!(ui.scope.selected(), 1);
                assert_eq!(collection(&ui).as_ref(), Some(&window));
                let find = entry(&window, ui.lang.text("Suchausdruck eingeben…", "Enter a search expression…"));
                git_view::test_keys(&find, &["d", "o", "g"]);
            }
            7 => {
                let window = collection(&ui).unwrap();
                if !next(&window, ui.lang).is_sensitive() || !count(&window, ui.lang, 1) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(window_id.borrow().as_ref(), Some(&window));
                assert_eq!(ui.find.text(), "dog");
                window.close();
            }
            8 => {
                ui.scope.set_selected(2);
                ui.find.set_text("ca");
                chrome::show_search(&ui);
            }
            9 => {
                let Some(window) = collection(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                folder::test_root(&ui, fixture.clone());
                let excludes = collect::<gtk::Entry>(window.upcast_ref())
                    .into_iter()
                    .find(|entry| {
                        entry.placeholder_text().is_some_and(|s| {
                            s.starts_with(ui.lang.text("Ausschlüsse", "Separate exclusions"))
                        })
                    })
                    .unwrap();
                excludes.set_text("skip.txt");
            }
            10 => {
                if pause.get().elapsed() < Duration::from_millis(650) {
                    return glib::ControlFlow::Continue;
                }
                let window = collection(&ui).unwrap();
                assert!(!next(&window, ui.lang).is_sensitive());
                assert!(count(&window, ui.lang, 0));
                type_query(
                    &entry(&window, ui.lang.text("Suchausdruck eingeben…", "Enter a search expression…")),
                    &["Return"],
                );
            }
            11 => {
                let window = collection(&ui).unwrap();
                if !next(&window, ui.lang).is_sensitive() || !count(&window, ui.lang, 2) {
                    return glib::ControlFlow::Continue;
                }
                type_query(
                    &entry(&window, ui.lang.text("Suchausdruck eingeben…", "Enter a search expression…")),
                    &["ctrl+a", "c", "a", "t"],
                );
            }
            12 => {
                let window = collection(&ui).unwrap();
                if !next(&window, ui.lang).is_sensitive() || !count(&window, ui.lang, 1) {
                    return glib::ControlFlow::Continue;
                }
                if !geometry(&window, "search-live-folder") {
                    return glib::ControlFlow::Continue;
                }
                window.close();
            }
            13 => {
                chrome::show_search(&ui);
                assert_eq!(ui.scope.selected(), 2);
            }
            14 => {
                let window = collection(&ui).unwrap();
                if !next(&window, ui.lang).is_sensitive() || !count(&window, ui.lang, 1) {
                    return glib::ControlFlow::Continue;
                }
                assert!(collect::<gtk::Label>(window.upcast_ref())
                    .iter()
                    .any(|label| label.text() == fixture.to_str().unwrap()));
                assert!(collect::<gtk::Entry>(window.upcast_ref())
                    .iter()
                    .any(|entry| entry.text() == "skip.txt"));
                assert_eq!(ui.documents.borrow().len(), 3);
                assert_eq!(
                    std::fs::read_to_string(fixture.join("a.txt")).unwrap(),
                    "cat ca\n"
                );
                assert_eq!(
                    std::fs::read_to_string(fixture.join("skip.txt")).unwrap(),
                    "cat\n"
                );
                assert_eq!(buffer_text(&doc.buffer), "cat Cat dog\n");
                assert!(!doc.buffer.can_undo() && !doc.buffer.is_modified());
                println!(
                    "PASS native live search: real typed file/open/folder queries, immediate stale invalidation, case toggle and native Swap, close cancellation, active-scope reuse,3-grapheme threshold, short-pattern real Return, remembered folder root/filter, no implicit source opening or file/Undo changes"
                );
                window.close();
            }
            15 => {
                ui.add_document(ui.lang.text("Filmliste.txt", "MovieList.txt"), "ring, The — 2002\nhobbit, The — 2012\nempire, The — 1980\nphantom menace, The — 1999\nmatrix, The — 1999\n");
                ui.scope.set_selected(0);
                ui.case.set_active(false);
                ui.mode.set_selected(1);
                ui.find.set_text("*, the");
                ui.replace.set_text("The *");
                chrome::show_search(&ui);
            }
            16 => {
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                if !next(&window, ui.lang).is_sensitive() || !count(&window, ui.lang, 5) {
                    return glib::ControlFlow::Continue;
                }
                if !geometry(&window, "search-live-file-wildcards") {
                    return glib::ControlFlow::Continue;
                }
                assert!(ui.capture_scroll.is_mapped());
                let detail = collect::<gtk::TextView>(window.upcast_ref())
                    .into_iter()
                    .find(|view| view.widget_name() == "fastra-search-detail")
                    .unwrap();
                assert_eq!(buffer_text(&detail.buffer()), "ring, The");
                let scroll = detail.ancestor(gtk::ScrolledWindow::static_type()).unwrap();
                assert_eq!(scroll.height(), 28, "detail retains one Mac-height line");
                let pill = collect::<gtk::Button>(window.upcast_ref())
                    .into_iter()
                    .find(|button| button.label().as_deref() == Some("$1 *"))
                    .unwrap();
                git_view::test_click(&pill, &[]);
            }
            17 => {
                assert!(ui.replace.text().contains("$1"));
                assert!(
                    !ui.active().unwrap().buffer.can_undo()
                        && !ui.active().unwrap().buffer.is_modified()
                );
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                if !next(&window, ui.lang).is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.replace.text().matches("$1").count(), 1);
                let pill = collect::<gtk::Button>(window.upcast_ref())
                    .into_iter()
                    .find(|button| button.label().as_deref() == Some("$1 *"))
                    .unwrap();
                *drag_finished.borrow_mut() =
                    Some(drag_capture(pill.upcast_ref(), ui.replace.upcast_ref()));
            }
            18 => {
                assert!(
                    pause.get().elapsed() < Duration::from_secs(5),
                    "capture drag did not finish: {}",
                    ui.replace.text()
                );
                if ui.replace.text().matches("$1").count() != 2
                    || !drag_finished
                        .borrow()
                        .as_ref()
                        .is_some_and(|done| done.get())
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    !ui.active().unwrap().buffer.can_undo()
                        && !ui.active().unwrap().buffer.is_modified()
                );
                println!(
                    "PASS native compact search layouts: file/open/folder geometry, same5-film Mac wildcard fixture, inline capture pill, real click and real drag into replacement without source edit"
                );
                super::detail_test::after_live(ui.clone());
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
