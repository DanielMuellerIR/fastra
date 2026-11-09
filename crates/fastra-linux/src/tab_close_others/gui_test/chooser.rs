#[allow(deprecated)]
fn configure(window: gtk::Window, root: &std::path::Path, path: &std::path::Path) {
    // GtkFileDialog nutzt unter dem isolierten GTK-Backend diesen nativen Dialog.
    let chooser = window.dynamic_cast::<gtk::FileChooser>().unwrap();
    chooser
        .set_current_folder(Some(&gtk::gio::File::for_path(root)))
        .unwrap();
    chooser.set_current_name(path.file_name().unwrap().to_str().unwrap());
}
use super::*;
pub(super) fn run(ui: Rc<Ui>, case: String) {
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("saved Unicode.txt");
    let text = "Unicode café🌈 Ελληνικά\n";
    ui.add_document("Untitled.txt", "original");
    let a = ui.active().unwrap();
    a.buffer.set_text(text);
    a.buffer.set_modified(true);
    ui.add_document("B.txt", "clean");
    let b = ui.active().unwrap();
    b.buffer.set_text("dirty B");
    b.buffer.set_modified(true);
    ui.add_document("Keep.txt", "keep");
    let keep = ui.active().unwrap();
    ui.add_document("Previous.txt", "previous");
    let previous = ui.active().unwrap();
    let docs = ui.documents.borrow().clone();
    let original_count = docs.len();
    let stage = Cell::new(0);
    let round = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let reply = Rc::new(Cell::new(false));
    let extra = RefCell::new(None::<Rc<Document>>);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            began.elapsed() < Duration::from_secs(40),
            "{case} stage{}: {}",
            stage.get(),
            ui.status.text()
        );
        let cancel = ui.lang.text("Abbrechen", "Cancel");
        let save = ui.lang.text("Speichern und schließen", "Save and close");
        let discard = ui
            .lang
            .text("Ohne Speichern schließen", "Close without saving");
        match stage.get() {
            0 if pause.get().elapsed() > Duration::from_millis(500) => {
                menu(&ui, &keep);
                stage.set(1);
            }
            1 => {
                if let Some(action) = others(&ui, &keep) {
                    click(action.upcast_ref(), "1");
                    stage.set(2);
                }
            }
            2 => {
                if let Some(action) = dialog(if round.get() == 0 { save } else { discard }) {
                    assert!(Rc::ptr_eq(
                        &ui.active().unwrap(),
                        if round.get() == 0 { &a } else { &b }
                    ));
                    click(action.upcast_ref(), "1");
                    stage.set(if round.get() == 0 { 3 } else { 7 });
                }
            }
            3 => {
                let chooser = gtk::Window::list_toplevels()
                    .iter()
                    .filter_map(|widget| widget.clone().downcast::<gtk::Window>().ok())
                    .find(|window| {
                        window.is_visible() && window.type_().name() == "GtkFileChooserDialog"
                    });
                if let Some(window) = chooser {
                    same(&ui, &docs);
                    assert!(a.saving.get());
                    if case == "chooser-drift" {
                        ui.add_document("Arrived.txt", "must survive");
                        *extra.borrow_mut() = ui.active();
                        pause.set(Instant::now());
                        stage.set(8);
                    } else {
                        configure(window, &root, &path);
                        let done = reply.clone();
                        done.set(true);
                        pause.set(Instant::now());
                        stage.set(4);
                    }
                }
            }
            4 if reply.get() && pause.get().elapsed() > Duration::from_millis(500) => {
                let action = dialog("Save")
                    .or_else(|| dialog("Speichern"))
                    .expect("native chooser Save");
                assert!(action.is_sensitive());
                click(action.upcast_ref(), "1");
                stage.set(5);
            }
            5 => {
                if let Some(action) = dialog(cancel) {
                    if !Rc::ptr_eq(&ui.active().unwrap(), &b) {
                        return glib::ControlFlow::Continue;
                    }
                    same(&ui, &docs);
                    assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
                    assert!(!a.buffer.is_modified());
                    click(action.upcast_ref(), "1");
                    stage.set(6);
                }
            }
            6 if !close_protocol::active(&ui) => {
                same(&ui, &docs);
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                assert_eq!(a.snapshot.borrow().as_ref().unwrap().path(), path);
                round.set(1);
                pause.set(Instant::now());
                stage.set(0);
            }
            7 if !close_protocol::active(&ui) => {
                assert_eq!(ui.documents.borrow().len(), 1);
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &keep));
                assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
                println!("PASS close others SaveAs: actual chooser Save writes exact Unicode, later Cancel retains all tabs and saved path; retry closes only fully approved set");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            8 if !close_protocol::active(&ui)
                && !a.saving.get()
                && pause.get().elapsed() > Duration::from_millis(500) =>
            {
                let now = ui.documents.borrow();
                assert_eq!(now.len(), original_count + 1);
                assert!(docs
                    .iter()
                    .all(|prior| now.iter().any(|doc| Rc::ptr_eq(doc, prior))));
                assert!(now
                    .iter()
                    .any(|doc| Rc::ptr_eq(doc, extra.borrow().as_ref().unwrap())));
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                assert!(a.buffer.is_modified() && a.snapshot.borrow().is_none());
                assert!(!path.exists());
                assert!(!gtk::Window::list_toplevels()
                    .iter()
                    .any(|widget| widget.is_visible()
                        && widget.type_().name() == "GtkFileChooserDialog"));
                println!("PASS close others chooser-drift: membership change cancels exactly owned chooser; no write, no candidate removal, new tab retained and previous activation restored");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
