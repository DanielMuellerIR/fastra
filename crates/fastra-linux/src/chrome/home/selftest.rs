use super::*;
use std::time::Instant;

fn find(widget: &gtk::Widget, title: &str) -> Option<gtk::Button> {
    if let Some(button) = widget.downcast_ref::<gtk::Button>().filter(|b| {
        b.is_mapped()
            && (b.label().as_deref() == Some(title) || b.tooltip_text().as_deref() == Some(title))
    }) {
        return Some(button.clone());
    }
    children(widget).iter().find_map(|child| find(child, title))
}
fn decision(title: &str) -> Option<gtk::Button> {
    gtk::Window::list_toplevels()
        .iter()
        .find_map(|widget| find(widget, title))
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let first = root.join("First");
    let second = root.join("Second");
    std::fs::create_dir_all(&first).unwrap();
    std::fs::create_dir_all(&second).unwrap();
    let file = first.join("original.txt");
    std::fs::write(&file, "original\n").unwrap();
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let original = RefCell::new(None::<Rc<Document>>);
    let extra = RefCell::new(None::<Rc<Document>>);
    let old_binding = RefCell::new(None::<project_view::Binding>);
    let later_binding = RefCell::new(None::<project_view::Binding>);
    project_view::open_path(&ui, first.clone());
    ui.load_path(file.clone());
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            began.elapsed().as_secs() < 40,
            "home phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(250) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let Some(binding) = project_view::current_binding(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&file))
                else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(ui.documents.borrow().len(), 1);
                doc.buffer.insert_at_cursor("draft ");
                *original.borrow_mut() = Some(doc);
                *old_binding.borrow_mut() = Some(binding);
                ui.add_document("Second draft", "");
                let doc = ui.active().unwrap();
                doc.buffer.insert_at_cursor("unsaved");
                *extra.borrow_mut() = Some(doc);
            }
            1 | 4 => {
                let home = find(
                    ui.window.upcast_ref(),
                    ui.lang.text("Zum Willkommensbildschirm", "Show welcome"),
                )
                .unwrap();
                git_view::test_click(&home, &[]);
            }
            2 => {
                let Some(cancel) = decision(ui.lang.text("Abbrechen", "Cancel")) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&cancel, &[]);
            }
            3 => {
                if close_protocol::active(&ui) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), 2);
                assert!(old_binding.borrow().as_ref().unwrap().is_current());
                assert!(Rc::ptr_eq(
                    &ui.active().unwrap(),
                    extra.borrow().as_ref().unwrap()
                ));
                assert!(buffer_text(&original.borrow().as_ref().unwrap().buffer).contains("draft"));
            }
            5 => {
                let Some(discard) = decision(
                    ui.lang
                        .text("Ohne Speichern schließen", "Close without saving"),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                assert!(Rc::ptr_eq(
                    &ui.active().unwrap(),
                    original.borrow().as_ref().unwrap()
                ));
                git_view::test_click(&discard, &[]);
            }
            6 => {
                if !Rc::ptr_eq(&ui.active().unwrap(), extra.borrow().as_ref().unwrap()) {
                    return glib::ControlFlow::Continue;
                }
                let Some(discard) = decision(
                    ui.lang
                        .text("Ohne Speichern schließen", "Close without saving"),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&discard, &[]);
            }
            7 => {
                if close_protocol::active(&ui) || ui.project.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.documents.borrow().len(), 1);
                assert!(is_pristine(&ui.active().unwrap()));
                assert!(!old_binding.borrow().as_ref().unwrap().is_current());
                assert_eq!(std::fs::read_to_string(&file).unwrap(), "original\n");
                if !git_view::try_capture(ui.window.upcast_ref(), "home-after-reset") { return glib::ControlFlow::Continue; }
                super::reset(&ui, Some(second.clone()));
            }
            8 => {
                let Some(binding) = project_view::current_binding(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                *later_binding.borrow_mut() = Some(binding);
                ui.active().unwrap().buffer.insert_at_cursor("new draft");
                super::reset(&ui, Some(first.clone()));
            }
            9 => {
                let Some(cancel) = decision(ui.lang.text("Abbrechen", "Cancel")) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&cancel, &[]);
            }
            10 => {
                if close_protocol::active(&ui) {
                    return glib::ControlFlow::Continue;
                }
                assert!(later_binding.borrow().as_ref().unwrap().is_current());
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "new draft");
                super::reset(&ui, Some(first.clone()));
            }
            11 => {
                let Some(discard) = decision(
                    ui.lang
                        .text("Ohne Speichern schließen", "Close without saving"),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&discard, &[]);
            }
            12 => {
                if close_protocol::active(&ui) || project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!later_binding.borrow().as_ref().unwrap().is_current());
                assert!(is_pristine(&ui.active().unwrap()));
                assert_eq!(std::fs::read_to_string(&file).unwrap(), "original\n");
                if !git_view::try_capture(ui.window.upcast_ref(), "home-project-switch") { return glib::ControlFlow::Continue; }
                git_view::test_keys(&ui.window, &["x"]);
            }
            13 => {
                if buffer_text(&ui.active().unwrap().buffer) != "x" {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    !ui.active()
                        .unwrap()
                        .chrome
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .welcome
                        .is_visible()
                );
                source_appearance::cleanup_schemes();
                eprintln!(
                    "HOME_SELFTEST PASS native Home, late Cancel retains all tabs and project, common Discard, clean scratch with keyboard focus, invalidated old project bindings, project-switch Cancel and success, source disk unchanged"
                );
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
