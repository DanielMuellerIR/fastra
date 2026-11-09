use super::*;
use std::time::{Duration, Instant};
fn click(button: &impl IsA<gtk::Widget>, at: &Cell<Instant>) {
    git_view::test_click(button, &[]);
    at.set(Instant::now());
}
fn choose(s: &State, name: &str, at: &Cell<Instant>) {
    let id = s
        .hub
        .catalog
        .borrow()
        .as_ref()
        .unwrap()
        .macros
        .iter()
        .find(|m| m.display_name == name)
        .unwrap()
        .id
        .clone();
    let index = s
        .selection_rows
        .borrow()
        .iter()
        .position(|v| v == &id)
        .unwrap();
    click(&s.list.row_at_index(index as i32).unwrap(), at);
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
pub(super) fn run(ui: Rc<Ui>, menu: gtk::MenuButton, entry: gtk::Button) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let fixture = PathBuf::from(std::env::var_os("FASTRA_MACRO_FIXTURE").unwrap());
    let project = fixture.join("project-a");
    let other = fixture.join("project-b");
    let path = project.join("Project/Sources/Methods/U\u{308}bersicht.4dm");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::create_dir_all(&other).unwrap();
    std::fs::write(project.join("Project/Test.4DProject"), "{}").unwrap();
    std::fs::write(&path, "abc😀def\n").unwrap();
    let user = discovery::default_user().unwrap();
    std::fs::create_dir_all(&user).unwrap();
    std::fs::write(user.join("Macros.xml"),r##"<macros><macro name="Header /#"><text>[<method_name/>:<selection/><caret/>]</text></macro><macro name="Reserved /o"><text>BAD</text></macro><macro name="Runtime"><text><method>MAO_MethodeKomplettierenNeu(<method_name/>)</method></text></macro><macro name="Unknown"><text>A<future/>B</text></macro></macros>"##).unwrap();
    let component = project.join("Components/Example.4dbase/Contents/Macros v2");
    std::fs::create_dir_all(&component).unwrap();
    std::fs::write(
        component.join("Macros.xml"),
        "<macros><macro name='Component'><text>component</text></macro></macros>",
    )
    .unwrap();
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let delay = Cell::new(Instant::now());
    let started = Instant::now();
    let state = RefCell::new(None::<Rc<State>>);
    let original_doc = RefCell::new(None::<Rc<Document>>);
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            started.elapsed() < Duration::from_secs(55),
            "macro phase {} status {:?}",
            phase.get(),
            state.borrow().as_ref().map(|s| s.status.text())
        );
        if delay.get().elapsed() < Duration::from_millis(300) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                *original_doc.borrow_mut() = Some(doc);
                project_view::open_path(&ui, project.clone());
                phase.set(1);
            }
            1 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                let doc = original_doc.borrow().as_ref().unwrap().clone();
                doc.buffer
                    .select_range(&doc.buffer.iter_at_offset(3), &doc.buffer.iter_at_offset(4));
                click(&menu, &delay);
                phase.set(31);
            }
            31 => {
                click(&entry, &delay);
                phase.set(32);
            }
            32 => {
                let Some(s) = hub(&ui).dialog.borrow().upgrade() else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_size(&s.window);
                *state.borrow_mut() = Some(s);
                phase.set(2);
                delay.set(Instant::now());
            }
            2 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.hub.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(s.hub.catalog.borrow().as_ref().unwrap().macros.len(), 5);
                git_view::test_click(&s.sources, &["End", "Return"]);
                delay.set(Instant::now());
                phase.set(20);
            }
            20 => {
                let s = state.borrow().as_ref().unwrap().clone();
                assert!(
                    s.sources.selected() > 0,
                    "native source choice must change source"
                );
                assert_eq!(s.selection_rows.borrow().len(), 4);
                let refresh = button(
                    s.window.child().unwrap().upcast_ref(),
                    ui.lang.text("Neu laden", "Refresh"),
                )
                .unwrap();
                click(&refresh, &delay);
                phase.set(21);
            }
            21 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.hub.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(s.selection_rows.borrow().len(), 4);
                choose(&s, "Runtime", &delay);
                phase.set(3);
            }
            3 => {
                let s = state.borrow().as_ref().unwrap().clone();
                assert!(!s.prepare.is_sensitive());
                assert!(buffer_text(&s.details.buffer()).contains("MacroRun"));
                if !git_view::try_capture(&s.window, "macro-catalog") {
                    return glib::ControlFlow::Continue;
                }
                choose(&s, "Unknown", &delay);
                phase.set(4);
            }
            4 => {
                let s = state.borrow().as_ref().unwrap().clone();
                assert!(!s.prepare.is_sensitive());
                assert!(buffer_text(&s.details.buffer()).contains("future"));
                choose(&s, "Header", &delay);
                phase.set(5);
            }
            5 => {
                let s = state.borrow().as_ref().unwrap().clone();
                click(&s.prepare, &delay);
                phase.set(6);
            }
            6 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some(), "{}", s.status.text());
                assert_eq!(
                    buffer_text(&original_doc.borrow().as_ref().unwrap().buffer),
                    "abc😀def\n"
                );
                assert!(buffer_text(&s.after.buffer()).contains("Übersicht:😀"));
                assert!(
                    s.before.width() >= 180 && s.after.width() >= 180,
                    "both complete diff panes must be visible"
                );
                if !git_view::try_capture(&s.window, "macro-preview") {
                    return glib::ControlFlow::Continue;
                }
                let doc = original_doc.borrow().as_ref().unwrap().clone();
                doc.buffer
                    .select_range(&doc.buffer.start_iter(), &doc.buffer.start_iter());
                click(&s.apply, &delay);
                phase.set(7);
            }
            7 => {
                let s = state.borrow().as_ref().unwrap().clone();
                assert!(s.status.text().contains(ui.lang.text("veraltet", "stale")));
                let doc = original_doc.borrow().as_ref().unwrap().clone();
                assert_eq!(buffer_text(&doc.buffer), "abc😀def\n");
                doc.buffer
                    .select_range(&doc.buffer.iter_at_offset(3), &doc.buffer.iter_at_offset(4));
                click(&s.prepare, &delay);
                phase.set(8);
            }
            8 => {
                let s = state.borrow().as_ref().unwrap().clone();
                if s.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(s.preview.borrow().is_some());
                click(&s.apply, &delay);
                phase.set(9);
            }
            9 => {
                let s = state.borrow().as_ref().unwrap().clone();
                let doc = original_doc.borrow().as_ref().unwrap().clone();
                assert_eq!(buffer_text(&doc.buffer), "abc[Übersicht:😀]def\n");
                assert_eq!(
                    doc.buffer.iter_at_mark(&doc.buffer.get_insert()).offset(),
                    "abc[Übersicht:😀".chars().count() as i32
                );
                assert!(doc.buffer.can_undo());
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), "abc😀def\n");
                assert!(
                    !doc.buffer.can_undo(),
                    "macro must be exactly one undo step"
                );
                assert_eq!(std::fs::read_to_string(&path).unwrap(), "abc😀def\n");
                let close =
                    button(s.window.upcast_ref(), ui.lang.text("Schließen", "Close")).unwrap();
                click(&close, &delay);
                phase.set(10);
            }
            10 => {
                let doc = original_doc.borrow().as_ref().unwrap().clone();
                doc.buffer
                    .select_range(&doc.buffer.iter_at_offset(3), &doc.buffer.iter_at_offset(4));
                state.borrow_mut().take();
                ui.window.present();
                git_view::test_click(&doc.container, &["ctrl+numbersign"]);
                delay.set(Instant::now());
                phase.set(11);
            }
            11 => {
                let Some(s) = hub(&ui).dialog.borrow().upgrade() else {
                    return glib::ControlFlow::Continue;
                };
                if s.running.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    s.preview.borrow().is_some(),
                    "keyboard macro must prepare a preview: {}",
                    s.status.text()
                );
                git_view::test_size(&s.window);
                *state.borrow_mut() = Some(s);
                project_view::open_path(&ui, other.clone());
                project_view::open_path(&ui, project.clone());
                delay.set(Instant::now());
                phase.set(12);
            }
            12 => {
                if project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                let s = state.borrow().as_ref().unwrap().clone();
                s.window.present();
                click(&s.apply, &delay);
                phase.set(13);
            }
            _ => {
                let s = state.borrow().as_ref().unwrap().clone();
                assert_eq!(
                    buffer_text(&original_doc.borrow().as_ref().unwrap().buffer),
                    "abc😀def\n"
                );
                assert!(s.status.text().contains(ui.lang.text("veraltet", "stale")));
                assert_eq!(std::fs::read_to_string(&path).unwrap(), "abc😀def\n");
                assert!(!fixture.join("tool4d-launched").exists());
                git_view::finish(s.window.clone(), ui.clone(), "four-d-macros");
                return glib::ControlFlow::Break;
            }
        }
        glib::ControlFlow::Continue
    });
}
