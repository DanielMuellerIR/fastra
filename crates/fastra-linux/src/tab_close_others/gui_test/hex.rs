use super::*;
fn row(widget: &gtk::Widget) -> Option<gtk::Entry> {
    if let Some(entry) = widget
        .downcast_ref::<gtk::Entry>()
        .filter(|entry| entry.placeholder_text().is_none())
    {
        return Some(entry.clone());
    }
    let mut child = widget.first_child();
    while let Some(item) = child {
        if let Some(found) = row(&item) {
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
                && window
                    .title()
                    .is_some_and(|title| title.contains(ui.lang.text("Hex bearbeiten", "Edit hex")))
        })
}
pub(super) fn run(ui: Rc<Ui>, case: String) {
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("binary.bin");
    let original = (0u8..=255).collect::<Vec<_>>();
    std::fs::write(&path, &original).unwrap();
    ui.add_document("binary.bin", "read-only section");
    let binary = ui.active().unwrap();
    let source =
        fastra_document::Document::open_hex(&path, &fastra_core::Cancellation::default()).unwrap();
    *binary.section_view.borrow_mut() =
        Some(super::super::super::document_view::DocumentView::new(
            source.clone(),
            true,
            ui.lang,
            Rc::new(|| {}),
        ));
    let editor = super::super::super::hex_editor::open(&ui, &binary, source);
    ui.add_document("Keep.txt", "keep");
    let keep = if case == "hex-keep" {
        binary.clone()
    } else {
        ui.active().unwrap()
    };
    ui.add_document("Previous.txt", "previous");
    let previous = ui.active().unwrap();
    let docs = ui.documents.borrow().clone();
    let stage = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            began.elapsed() < Duration::from_secs(40),
            "{case} stage{}: {}",
            stage.get(),
            ui.status.text()
        );
        match stage.get() {
            0 => {
                if let Some(window) = window(&ui) {
                    if let Some(row) = row(window.upcast_ref())
                        .filter(|row| row.is_sensitive() && !row.text().is_empty())
                    {
                        support::test_click(&row, &["ctrl+a", "A", "A"]);
                        stage.set(1);
                    }
                }
            }
            1 if editor.dirty() => {
                assert_eq!(std::fs::read(&path).unwrap(), original);
                ui.window.present();
                pause.set(Instant::now());
                stage.set(2);
            }
            2 if pause.get().elapsed() > Duration::from_millis(500) => {
                menu(&ui, &keep);
                stage.set(3);
            }
            3 => {
                if let Some(action) = others(&ui, &keep) {
                    assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                    click(action.upcast_ref(), "1");
                    pause.set(Instant::now());
                    stage.set(if case == "hex-keep" || !editor.dirty() {
                        6
                    } else {
                        4
                    });
                }
            }
            4 if pause.get().elapsed() > Duration::from_millis(500) => {
                assert!(!close_protocol::active(&ui));
                same(&ui, &docs);
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                assert!(editor.dirty());
                let window = window(&ui).unwrap();
                if !support::try_capture(&window, "others-hex-review") {
                    return glib::ControlFlow::Continue;
                }
                let reset = button(
                    window.upcast_ref(),
                    ui.lang
                        .text("Feldeingabe zurücksetzen", "Reset field input"),
                )
                .unwrap();
                click(reset.upcast_ref(), "1");
                stage.set(5);
            }
            5 if !editor.dirty() => {
                ui.window.present();
                pause.set(Instant::now());
                stage.set(2);
            }
            6 if !close_protocol::active(&ui)
                && pause.get().elapsed() > Duration::from_millis(500) =>
            {
                assert_eq!(ui.documents.borrow().len(), 1);
                assert!(Rc::ptr_eq(&ui.active().unwrap(), &keep));
                assert_eq!(std::fs::read(&path).unwrap(), original);
                if case == "hex-keep" {
                    assert!(editor.dirty());
                    assert!(window(&ui).is_some());
                } else {
                    assert!(!editor.dirty());
                    assert!(window(&ui).is_none());
                }
                println!(
                    "PASS close others {case}: {} Raw file bytes unchanged.",
                    if case == "hex-keep" {
                        "Keep Hex draft is excluded from candidates and remains dirty/visible."
                    } else {
                        "Candidate Hex draft blocks without loss and retains review; explicit reset permits retry and closes its clean view."
                    }
                );
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        // After explicit Hex reset, the second request must take the success branch.
        if stage.get() == 4 && !editor.dirty() {
            stage.set(6);
        }
        glib::ControlFlow::Continue
    });
}
