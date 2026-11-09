use super::*;
pub(super) fn run(ui: Rc<Ui>, case: String) {
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("bound-save.txt");
    std::fs::write(&path, "original\n").unwrap();
    ui.add_document("A.txt", "original\n");
    let a = ui.active().unwrap();
    *a.snapshot.borrow_mut() =
        Some(fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default()).unwrap());
    a.buffer.set_text("approved save\n");
    a.buffer.set_modified(true);
    ui.add_document("B.txt", "original B\n");
    let b = ui.active().unwrap();
    b.buffer.set_text("dirty B\n");
    b.buffer.set_modified(true);
    ui.add_document("Keep.txt", "keep");
    let keep = ui.active().unwrap();
    ui.add_document("Previous.txt", "previous");
    let previous = ui.active().unwrap();
    let docs = ui.documents.borrow().clone();
    if case == "readonly" {
        let source =
            fastra_document::Document::open_hex(&path, &fastra_core::Cancellation::default())
                .unwrap();
        *a.section_view.borrow_mut() = Some(super::super::super::document_view::DocumentView::new(
            source,
            true,
            ui.lang,
            Rc::new(|| {}),
        ));
    }
    if case == "io-failure" {
        std::fs::write(&path, "external content\n").unwrap();
    }
    let stage = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let pending = RefCell::new(None::<super::super::super::asset_io::Pending>);
    let extra = RefCell::new(None::<Rc<Document>>);
    let original_count = docs.len();
    ui.window.set_default_size(1100, 900);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            started.elapsed() < Duration::from_secs(40),
            "safety {case} stage{}: {}",
            stage.get(),
            ui.status.text()
        );
        let discard = ui
            .lang
            .text("Ohne Speichern schließen", "Close without saving");
        let save = ui.lang.text("Speichern und schließen", "Save and close");
        match stage.get() {
            0 if pause.get().elapsed() > Duration::from_millis(500) => {
                if case == "guards" {
                    a.saving.set(true);
                    request(&ui, &keep);
                    assert!(!close_protocol::active(&ui));
                    same(&ui, &docs);
                    a.saving.set(false);
                    b.close_pending.set(true);
                    request(&ui, &keep);
                    assert!(!close_protocol::active(&ui));
                    same(&ui, &docs);
                    b.close_pending.set(false);
                    let io = super::super::super::asset_io::begin();
                    request(&ui, &keep);
                    assert!(!close_protocol::active(&ui));
                    same(&ui, &docs);
                    drop(io);
                    assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                    println!("PASS close others guards: saving, closePending and pending asset IO retain complete membership and previous activation");
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
                menu(&ui, &keep);
                stage.set(1);
            }
            1 => {
                if let Some(action) = others(&ui, &keep) {
                    assert!(Rc::ptr_eq(&ui.active().unwrap(), &previous));
                    click(action.upcast_ref(), "1");
                    stage.set(2);
                }
            }
            2 => {
                if let Some(action) = dialog(
                    if ["late-save", "save-source", "readonly", "io-failure"]
                        .contains(&case.as_str())
                    {
                        save
                    } else {
                        discard
                    },
                ) {
                    assert!(Rc::ptr_eq(&ui.active().unwrap(), &a));
                    same(&ui, &docs);
                    match case.as_str() {
                        "keep-aba" => {
                            tab_close::activate(&ui, &keep);
                            tab_close::activate(&ui, &a);
                            stage.set(5);
                        }
                        "members-aba" => {
                            ui.add_document("Transient.txt", "transient");
                            let at = ui.documents.borrow().len() - 1;
                            ui.documents.borrow_mut().pop();
                            ui.tabs.remove_page(Some(at as u32));
                            tab_close::activate(&ui, &a);
                            same(&ui, &docs);
                            stage.set(5);
                        }
                        "keep-replaced" => {
                            let at = ui
                                .documents
                                .borrow()
                                .iter()
                                .position(|doc| Rc::ptr_eq(doc, &keep))
                                .unwrap();
                            ui.documents.borrow_mut().remove(at);
                            ui.tabs.remove_page(Some(at as u32));
                            ui.add_document("Keep.txt", "replacement");
                            *extra.borrow_mut() = ui.active();
                            stage.set(5);
                        }
                        _ => {
                            click(action.upcast_ref(), "1");
                            stage.set(if ["late-save", "save-source"].contains(&case.as_str()) {
                                3
                            } else if ["readonly", "io-failure"].contains(&case.as_str()) {
                                5
                            } else {
                                4
                            });
                        }
                    }
                }
            }
            3 if a.saving.get() => {
                if case == "late-save" {
                    ui.add_document("Arrived.txt", "new tab must survive");
                    *extra.borrow_mut() = ui.active();
                } else {
                    a.buffer.set_text("later input must survive\n");
                }
                stage.set(5);
            }
            4 => {
                if let Some(action) = dialog(discard) {
                    if !Rc::ptr_eq(&ui.active().unwrap(), &b) {
                        return glib::ControlFlow::Continue;
                    }
                    same(&ui, &docs);
                    match case.as_str() {
                        "revision" => a.buffer.set_text("later input\n"),
                        "revision-aba" => {
                            a.buffer.set_text("different\n");
                            a.buffer.set_text("approved save\n");
                        }
                        "keep-revision" => keep.buffer.set_text("later keep input\n"),
                        "asset-late" => {
                            *pending.borrow_mut() = Some(super::super::super::asset_io::begin())
                        }
                        _ => panic!("unknown safety case {case}"),
                    }
                    click(action.upcast_ref(), "1");
                    stage.set(5);
                }
            }
            5 if !close_protocol::active(&ui) && !a.saving.get() => {
                if case == "late-save" {
                    let now = ui.documents.borrow();
                    assert_eq!(now.len(), original_count + 1);
                    assert!(docs
                        .iter()
                        .all(|prior| now.iter().any(|current| Rc::ptr_eq(current, prior))));
                    assert!(now
                        .iter()
                        .any(|doc| Rc::ptr_eq(doc, extra.borrow().as_ref().unwrap())));
                    assert_eq!(std::fs::read_to_string(&path).unwrap(), "approved save\n");
                } else if case == "keep-replaced" {
                    let now = ui.documents.borrow();
                    assert_eq!(now.len(), original_count);
                    assert!(!now.iter().any(|doc| Rc::ptr_eq(doc, &keep)));
                    assert!(docs
                        .iter()
                        .filter(|doc| !Rc::ptr_eq(doc, &keep))
                        .all(|prior| now.iter().any(|current| Rc::ptr_eq(current, prior))));
                    assert!(now
                        .iter()
                        .any(|doc| Rc::ptr_eq(doc, extra.borrow().as_ref().unwrap())));
                } else {
                    same(&ui, &docs);
                }
                assert!(
                    Rc::ptr_eq(&ui.active().unwrap(), &previous),
                    "restore previous on {case}"
                );
                assert!(ui.window.is_visible() && ui.window.is_sensitive());
                if case == "save-source" {
                    assert_eq!(
                        super::super::super::buffer_text(&a.buffer),
                        "later input must survive\n"
                    );
                    assert!(a.buffer.is_modified());
                    assert_eq!(std::fs::read_to_string(&path).unwrap(), "approved save\n");
                } else if case == "io-failure" {
                    assert_eq!(
                        std::fs::read_to_string(&path).unwrap(),
                        "external content\n"
                    );
                    assert!(a.buffer.is_modified());
                } else if case != "late-save" {
                    assert_eq!(std::fs::read_to_string(&path).unwrap(), "original\n");
                }
                pending.borrow_mut().take();
                println!("PASS close others safety {case}: no bound candidate removed, previous activation restored, no late completion closes tabs");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
