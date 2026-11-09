use super::*;
fn button(ui: &Ui, de: &'static str, en: &'static str) -> gtk::Button {
    widgets::<gtk::Button>(window(ui).upcast_ref())
        .into_iter()
        .find(|b| b.is_mapped() && b.label().as_deref() == Some(ui.lang.text(de, en)))
        .unwrap()
}
fn focused_find(ui: &Ui) -> gtk::Entry {
    let entry = widgets::<gtk::Entry>(window(ui).upcast_ref())
        .into_iter()
        .find(|e| {
            e.placeholder_text().as_deref() == Some(ui.lang.text("Suchausdruck eingeben…", "Enter a search expression…"))
        })
        .unwrap();
    entry.grab_focus();
    entry
}
fn active(ui: &Ui, offset: i32) -> bool {
    ui.search_emphasis
        .borrow()
        .as_ref()
        .is_some_and(|e| e.test_range() == (offset, offset + 3))
}
pub(super) fn run(ui: Rc<Ui>) {
    let open = std::env::var("FASTRA_SINGLE_REPLACE_SELFTEST").as_deref() == Ok("footer-open");
    ui.add_document("footer.txt", "cat cat cat");
    let doc = ui.active().unwrap();
    ui.scope.set_selected(u32::from(open));
    ui.find.set_text("cat");
    ui.replace.set_text("dog");
    ui.mode.set_selected(0);
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 25,
            "footer phase {}",
            phase.get()
        );
        if pause.get().elapsed() < Duration::from_millis(250) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => chrome::show_search(&ui),
            1 => {
                if !count(&ui, 3) || !replace(&ui).is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    !widgets::<gtk::Button>(window(&ui).upcast_ref())
                        .iter()
                        .any(|b| b.is_mapped()
                            && b.label().as_deref() == Some(ui.lang.text("Suchen", "Find")))
                );
                if !open && !active(&ui, 0) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&focused_find(&ui), &["Return"]);
            }
            2 => {
                if !active(&ui, 4) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&focused_find(&ui), &["ctrl+shift+g"]);
            }
            3 => {
                if !active(&ui, 0) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&focused_find(&ui), &["ctrl+g"]);
            }
            4 => {
                if !active(&ui, 4) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&button(&ui, "Nächster", "Next"), &[]);
            }
            5 => {
                if !active(&ui, 8) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&button(&ui, "Voriger", "Previous"), &[]);
            }
            6 => {
                if !active(&ui, 4) {
                    return glib::ControlFlow::Continue;
                }
                if !git_view::try_capture(&window(&ui), "search-footer") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&button(&ui, "Aus Beispiel…", "From example…"), &[]);
            }
            7 => {
                let example = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| {
                        w.is_mapped()
                            && w.title().as_deref()
                                == Some(ui.lang.text(
                                    "Transformation per Beispiel",
                                    "Transformation by example",
                                ))
                    });
                let Some(example) = example else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(buffer_text(&doc.buffer), "cat cat cat");
                example.close();
                window(&ui).present();
            }
            8 => git_view::test_click(&button(&ui, "Alle", "All"), &[]),
            9 => git_view::test_keys(&focused_find(&ui), &["ctrl+Return"]),
            10 => {
                let review = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| {
                        w.is_mapped()
                            && w.has_css_class("fastra-owned-review")
                            && w.transient_for().as_ref() == Some(&window(&ui))
                    });
                if review.is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "cat cat cat");
                assert!(!doc.buffer.can_undo() && !doc.buffer.is_modified());
                println!(
                    "PASS native footer: File/Open hide Find, real Return/Ctrl+G/Shift+Ctrl+G and Previous/Next buttons navigate exact source hits, From example opens real dialog, Ctrl+Return opens approvals without editing source"
                );
                git_view::finish(
                    ui.window.clone().upcast(),
                    ui.clone(),
                    if open {
                        "search-footer-open"
                    } else {
                        "search-footer"
                    },
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
