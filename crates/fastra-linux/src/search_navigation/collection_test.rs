use super::*;
use std::{path::PathBuf, sync::atomic::Ordering, time::Instant};
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
fn button(window: &gtk::Window, title: &str) -> Option<gtk::Button> {
    collect::<gtk::Button>(window.upcast_ref())
        .into_iter()
        .find(|button| {
            button.is_mapped()
                && (button.label().as_deref() == Some(title)
                    || button.tooltip_text().as_deref() == Some(title))
        })
}
fn window(ui: &Ui) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| {
            w.is_mapped()
                && w.title().as_deref()
                    == Some(ui.lang.text("Suchen & Ersetzen", "Search & Replace"))
        })
}
fn notice(window: &gtk::Window, text: &str) -> bool {
    collect::<gtk::Label>(window.upcast_ref())
        .into_iter()
        .any(|label| label.is_mapped() && label.text().contains(text))
}
fn select(ui: &Ui, doc: &Rc<Document>) {
    let index = ui
        .documents
        .borrow()
        .iter()
        .position(|candidate| Rc::ptr_eq(candidate, doc))
        .unwrap();
    ui.tabs.set_current_page(Some(index as u32));
}
fn active(ui: &Ui, doc: &Rc<Document>) -> bool {
    ui.active().is_some_and(|active| Rc::ptr_eq(&active, doc))
}
fn marked(ui: &Ui, doc: &Rc<Document>, range: (i32, i32)) -> bool {
    ui.search_emphasis
        .borrow()
        .as_ref()
        .is_some_and(|emphasis| {
            emphasis
                .doc
                .upgrade()
                .is_some_and(|owner| Rc::ptr_eq(&owner, doc))
                && emphasis.range == range
        })
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(
        std::env::var("FASTRA_TOOL_WIDTH")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(1100),
        650,
    );
    let fixture =
        PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join("navigation");
    std::fs::create_dir(&fixture).unwrap();
    let a = fixture.join("a-empty.txt");
    let b = fixture.join("b-hit.txt");
    let c = fixture.join("c-hit.txt");
    std::fs::write(&a, "no match\n").unwrap();
    std::fs::write(&b, "前🙂cat\r\n").unwrap();
    std::fs::write(&c, "猫cat\n").unwrap();
    ui.add_document("duplicate.txt", "前🙂cat\r\n");
    let first = ui.active().unwrap();
    ui.add_document("duplicate.txt", "猫cat\n");
    let second = ui.active().unwrap();
    ui.add_document("dirty.txt", "unsaved");
    let dirty = ui.active().unwrap();
    dirty
        .buffer
        .insert(&mut dirty.buffer.end_iter(), " content");
    let dirty_text = buffer_text(&dirty.buffer);
    let dirty_undo = dirty.buffer.can_undo();
    let dirty_selection = source_panes::capture(&dirty).unwrap().offsets();
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let initial_count = ui.documents.borrow().len();
    let disk_b = RefCell::new(None::<Rc<Document>>);
    let disk_c = RefCell::new(None::<Rc<Document>>);
    let replies = Cell::new(0usize);
    let foreign = RefCell::new(None::<gtk::ApplicationWindow>);
    let foreign_active = Rc::new(Cell::new(false));
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            began.elapsed().as_secs() < 45,
            "collection navigation phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(250) {
            return glib::ControlFlow::Continue;
        }
        assert_eq!(buffer_text(&dirty.buffer), dirty_text);
        assert_eq!(dirty.buffer.can_undo(), dirty_undo);
        assert!(dirty.buffer.is_modified());
        assert_eq!(
            source_panes::capture(&dirty)
                .map(|t| t.offsets())
                .unwrap_or(dirty_selection),
            dirty_selection
        );
        match phase.get() {
            0 => {
                ui.find.set_text("cat");
                ui.replace.set_text("dog");
                ui.mode.set_selected(0);
                ui.scope.set_selected(1);
                tabs_search::open(&ui);
            }
            1 => {
                let Some(window) = window(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                let next = button(&window, ui.lang.text("Nächster Treffer", "Next match")).unwrap();
                if !next.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(active(&ui, &dirty));
                assert!(ui.search_emphasis.borrow().is_none());
                git_view::test_click(&next, &[]);
            }
            2 => {
                if !active(&ui, &second) || !marked(&ui, &second, (1, 4)) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&second.buffer), "猫cat\n");
                assert!(!second.buffer.can_undo() && !second.buffer.is_modified());
                let window = window(&ui).unwrap();
                assert!(
                    button(&window, ui.lang.text("Nächster Treffer", "Next match"))
                        .unwrap()
                        .is_sensitive()
                );
                git_view::test_click(
                    &button(
                        &window,
                        ui.lang.text("Vorheriger Treffer", "Previous match"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            3 => {
                if !active(&ui, &first) || !marked(&ui, &first, (2, 5)) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&first.buffer), "前🙂cat\r\n");
                assert!(!first.buffer.can_undo() && !first.buffer.is_modified());
                assert_eq!(ui.documents.borrow().len(), initial_count);
                git_view::capture(ui.window.upcast_ref(), "search-open-tab-source");
                window(&ui).unwrap().close();
            }
            4 => {
                select(&ui, &dirty);
                ui.scope.set_selected(2);
                folder::open(&ui);
            }
            5 => {
                let Some(window) = window(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                folder::test_root(&ui, fixture.clone());
                git_view::test_click(
                    &button(&window, ui.lang.text("Suchen", "Find")).unwrap(),
                    &[],
                );
            }
            6 => {
                let window = window(&ui).unwrap();
                let next = button(&window, ui.lang.text("Nächster Treffer", "Next match")).unwrap();
                if !next.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), initial_count);
                assert!(active(&ui, &dirty));
                git_view::test_click(&next, &[]);
            }
            7 => {
                let Some(doc) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&c))
                else {
                    return glib::ControlFlow::Continue;
                };
                if !marked(&ui, &doc, (1, 4)) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "猫cat\n");
                assert_eq!(ui.documents.borrow().len(), initial_count + 1);
                *disk_c.borrow_mut() = Some(doc);
                let window = window(&ui).unwrap();
                git_view::test_click(
                    &button(&window, ui.lang.text("Nächster Treffer", "Next match")).unwrap(),
                    &[],
                );
            }
            8 => {
                let Some(doc) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&b))
                else {
                    return glib::ControlFlow::Continue;
                };
                if !marked(&ui, &doc, (2, 5)) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "前🙂cat\r\n");
                assert_eq!(ui.documents.borrow().len(), initial_count + 2);
                *disk_b.borrow_mut() = Some(doc);
                let window = window(&ui).unwrap();
                git_view::test_click(
                    &button(
                        &window,
                        ui.lang.text("Vorheriger Treffer", "Previous match"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            9 => {
                if !active(&ui, disk_c.borrow().as_ref().unwrap())
                    || !marked(&ui, disk_c.borrow().as_ref().unwrap(), (1, 4))
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), initial_count + 2);
                std::fs::write(&b, "changed cat\n").unwrap();
                let window = window(&ui).unwrap();
                git_view::test_click(
                    &button(&window, ui.lang.text("Nächster Treffer", "Next match")).unwrap(),
                    &[],
                );
            }
            10 => {
                let window = window(&ui).unwrap();
                if !notice(&window, stale(ui.lang)) {
                    return glib::ControlFlow::Continue;
                }
                assert!(active(&ui, disk_c.borrow().as_ref().unwrap()));
                assert_eq!(ui.documents.borrow().len(), initial_count + 2);
                assert!(ui.search_emphasis.borrow().is_none());
                assert_eq!(
                    buffer_text(&disk_b.borrow().as_ref().unwrap().buffer),
                    "前🙂cat\r\n"
                );
                git_view::capture(&window, "search-source-stale-file");
                git_view::test_click(
                    &button(&window, ui.lang.text("Suchen", "Find")).unwrap(),
                    &[],
                );
            }
            11 => {
                let window = window(&ui).unwrap();
                let next = button(&window, ui.lang.text("Nächster Treffer", "Next match")).unwrap();
                if !next.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                std::env::set_var("FASTRA_SPLIT_REPLY_DELAY", "1");
                replies.set(DISK_REPLIES.load(Ordering::Relaxed));
                git_view::test_click(&next, &[]);
            }
            12 => {
                ui.find.set_text("changed query");
            }
            13 => {
                if DISK_REPLIES.load(Ordering::Relaxed) == replies.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), initial_count + 2);
                assert!(active(&ui, disk_c.borrow().as_ref().unwrap()));
                assert!(ui.search_emphasis.borrow().is_none());
                std::env::remove_var("FASTRA_SPLIT_REPLY_DELAY");
                for doc in [
                    disk_b.borrow().clone().unwrap(),
                    disk_c.borrow().clone().unwrap(),
                ] {
                    assert!(!doc.buffer.can_undo() && !doc.buffer.is_modified());
                }
                assert_eq!(std::fs::read_to_string(&a).unwrap(), "no match\n");
                assert_eq!(std::fs::read_to_string(&b).unwrap(), "changed cat\n");
                assert_eq!(std::fs::read_to_string(&c).unwrap(), "猫cat\n");
                let bdoc = disk_b.borrow().clone().unwrap();
                select(&ui, &bdoc);
                bdoc.buffer.insert(&mut bdoc.buffer.end_iter(), " unsaved");
                assert_eq!(buffer_text(&bdoc.buffer), "前🙂cat\r\n unsaved");
                assert!(bdoc.buffer.is_modified() && bdoc.buffer.can_undo());
                select(&ui, disk_c.borrow().as_ref().unwrap());
                ui.find.set_text("cat");
                let window = window(&ui).unwrap();
                git_view::test_click(
                    &button(&window, ui.lang.text("Suchen", "Find")).unwrap(),
                    &[],
                );
            }
            14 => {
                let window = window(&ui).unwrap();
                let next = button(&window, ui.lang.text("Nächster Treffer", "Next match")).unwrap();
                if !next.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&next, &[]);
            }
            15 => {
                if !marked(&ui, disk_c.borrow().as_ref().unwrap(), (1, 4)) {
                    return glib::ControlFlow::Continue;
                }
                let window = window(&ui).unwrap();
                git_view::test_click(
                    &button(&window, ui.lang.text("Nächster Treffer", "Next match")).unwrap(),
                    &[],
                );
            }
            16 => {
                let window = window(&ui).unwrap();
                if !notice(
                    &window,
                    ui.lang.text(
                        "Die geöffnete Datei enthält andere oder gesperrte Inhalte.",
                        "The open file has different or locked contents.",
                    ),
                ) {
                    return glib::ControlFlow::Continue;
                }
                assert!(active(&ui, disk_c.borrow().as_ref().unwrap()));
                assert!(ui.search_emphasis.borrow().is_none());
                let bdoc = disk_b.borrow().clone().unwrap();
                assert_eq!(buffer_text(&bdoc.buffer), "前🙂cat\r\n unsaved");
                assert!(bdoc.buffer.is_modified() && bdoc.buffer.can_undo());
                std::env::set_var("FASTRA_SPLIT_REPLY_DELAY", "1");
                replies.set(DISK_REPLIES.load(Ordering::Relaxed));
                git_view::test_click(
                    &button(
                        &window,
                        ui.lang.text("Vorheriger Treffer", "Previous match"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            17 => {
                let other = gtk::ApplicationWindow::builder()
                    .application(&ui.window.application().unwrap())
                    .title("Independent document")
                    .default_width(500)
                    .default_height(300)
                    .build();
                let changed = foreign_active.clone();
                let before = replies.get();
                other.connect_is_active_notify(move |window| {
                    if window.is_active() && !changed.replace(true) {
                        assert_eq!(
                            DISK_REPLIES.load(Ordering::Relaxed),
                            before,
                            "Foreign focus must precede the pending reply"
                        );
                        changed.set(true);
                    }
                });
                other.present();
                git_view::test_keys(&other, &[]);
                *foreign.borrow_mut() = Some(other);
            }
            18 => {
                if DISK_REPLIES.load(Ordering::Relaxed) == replies.get() || !foreign_active.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!source_panes::focused_is(&ui, &window(&ui).unwrap()));
                assert_eq!(ui.documents.borrow().len(), initial_count + 2);
                assert!(active(&ui, disk_c.borrow().as_ref().unwrap()));
                assert!(ui.search_emphasis.borrow().is_none());
                assert_eq!(
                    buffer_text(&disk_b.borrow().as_ref().unwrap().buffer),
                    "前🙂cat\r\n unsaved"
                );
                std::env::remove_var("FASTRA_SPLIT_REPLY_DELAY");
                foreign.borrow().as_ref().unwrap().close();
                println!("PASS native collection source navigation: duplicate tab names and zero-match input mapping, explicit jumps only, UTF16/CRLF, dirty documents/selection/Undo retained, folder raw-file opening/reuse, exact snapshot stale-file and conflicting dirty-buffer refusal, actual late replies after changed query and foreign window focus produce no tab or emphasis");
                window(&ui).unwrap().close();
                git_view::finish(
                    ui.window.clone().upcast(),
                    ui.clone(),
                    "collection-navigation",
                );
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
