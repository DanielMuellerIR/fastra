use super::*;
fn entry(widget: &gtk::Widget) -> Option<gtk::Entry> {
    if let Some(entry) = widget.downcast_ref::<gtk::Entry>() {
        return Some(entry.clone());
    }
    let mut child = widget.first_child();
    while let Some(item) = child {
        if let Some(found) = entry(&item) {
            return Some(found);
        }
        child = item.next_sibling();
    }
    None
}
fn window(ui: &Ui) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .iter()
        .filter_map(|widget| widget.clone().downcast::<gtk::Window>().ok())
        .find(|window| {
            window.is_visible()
                && window.title().as_deref()
                    == Some(ui.lang.text(
                        "Suchen & Ersetzen",
                        "Search & Replace",
                    ))
        })
}
pub(super) fn run(ui: Rc<Ui>) {
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let folder = root.join("changes");
    std::fs::create_dir_all(&folder).unwrap();
    let path = folder.join("sample.txt");
    let before = ui.lang.text("Katze Katze\n", "cat cat\n");
    let after = ui.lang.text("Hund Hund\n", "dog dog\n");
    std::fs::write(&path, before).unwrap();
    std::fs::write(root.join("pause-apply"), b"").unwrap();
    std::fs::write(root.join("pause-undo"), b"").unwrap();
    ui.add_document("Keep.txt", "keep");
    let keep = ui.active().unwrap();
    ui.add_document("Previous.txt", "previous");
    let previous = ui.active().unwrap();
    let docs = ui.documents.borrow().clone();
    super::super::super::folder::open(&ui);
    let stage = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            began.elapsed() < Duration::from_secs(45),
            "folder guard stage{}: {}",
            stage.get(),
            ui.status.text()
        );
        let search = ui.lang.text("Vorschau erstellen", "Create preview");
        let apply = ui.lang.text(
            "Freigegebene Treffer in Dateien anwenden",
            "Apply approved matches to files",
        );
        let undo = ui
            .lang
            .text("Dateiänderungen rückgängig", "Undo file changes");
        match stage.get() {
            0 => {
                if let Some(window) = window(&ui) {
                    entry(window.upcast_ref())
                        .unwrap()
                        .set_text(folder.to_str().unwrap());
                    pause.set(Instant::now());
                    stage.set(1);
                }
            }
            1 if pause.get().elapsed() > Duration::from_millis(500) => {
                let window = window(&ui).unwrap();
                click(
                    button(window.upcast_ref(), search).unwrap().upcast_ref(),
                    "1",
                );
                stage.set(2);
            }
            2 => {
                let window = window(&ui).unwrap();
                if let Some(action) =
                    button(window.upcast_ref(), apply).filter(|button| button.is_sensitive())
                {
                    click(action.upcast_ref(), "1");
                    stage.set(3);
                }
            }
            3 if root.join("ready-apply").exists() => {
                assert_eq!(std::fs::read_to_string(&path).unwrap(), after);
                request(&ui, &keep);
                assert!(!close_protocol::active(&ui));
                same(&ui, &docs);
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                assert!(ui
                    .status
                    .text()
                    .contains(ui.lang.text("Dateivorgang", "File operation")));
                std::fs::write(root.join("release-apply"), b"").unwrap();
                stage.set(4);
            }
            4 => {
                let window = window(&ui).unwrap();
                if let Some(action) =
                    button(window.upcast_ref(), undo).filter(|button| button.is_sensitive())
                {
                    click(action.upcast_ref(), "1");
                    stage.set(5);
                }
            }
            5 if root.join("ready-undo").exists() => {
                assert_eq!(std::fs::read_to_string(&path).unwrap(), before);
                request(&ui, &keep);
                assert!(!close_protocol::active(&ui));
                same(&ui, &docs);
                assert!(ui
                    .status
                    .text()
                    .contains(ui.lang.text("Dateivorgang", "File operation")));
                std::fs::write(root.join("release-undo"), b"").unwrap();
                stage.set(6);
            }
            6 => {
                let window = window(&ui).unwrap();
                if button(window.upcast_ref(), search).is_some_and(|button| button.is_sensitive()) {
                    window.close();
                    ui.window.present();
                    pause.set(Instant::now());
                    stage.set(7);
                }
            }
            7 if pause.get().elapsed() > Duration::from_millis(500) => {
                menu(&ui, &keep);
                stage.set(8);
            }
            8 => {
                if let Some(action) = others(&ui, &keep) {
                    click(action.upcast_ref(), "1");
                    stage.set(9);
                }
            }
            9 if !close_protocol::active(&ui) && ui.documents.borrow().len() == 1 => {
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &keep));
                assert_eq!(std::fs::read_to_string(&path).unwrap(), before);
                println!("PASS close others folder: actual file Apply and Undo before final Main completion block entire tab set; correct reason and journal receipt retained; idle actual context action succeeds");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
