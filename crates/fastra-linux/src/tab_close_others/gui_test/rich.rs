use super::*;
pub(super) fn run(ui: Rc<Ui>, case: String) {
    ui.add_document("A.txt", "original");
    let a = ui.active().unwrap();
    a.buffer.set_text("dirty A");
    a.buffer.set_modified(true);
    ui.add_document("Rich.md", "# Heading\n\nAlpha\n");
    let rich = ui.active().unwrap();
    rich.rich_toggle.borrow().as_ref().unwrap().set_active(true);
    let keep = RefCell::new(None::<Rc<Document>>);
    let previous = RefCell::new(None::<Rc<Document>>);
    let docs = RefCell::new(Vec::new());
    let reply = Rc::new(RefCell::new(None::<serde_json::Value>));
    let stage = Cell::new(0);
    let logged = Cell::new(u32::MAX);
    let round = Cell::new(0);
    let after_cancel = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            began.elapsed() < Duration::from_secs(45),
            "{case} stage{}: {}",
            stage.get(),
            ui.status.text()
        );
        let discard = ui
            .lang
            .text("Ohne Speichern schließen", "Close without saving");
        let cancel = ui.lang.text("Abbrechen", "Cancel");
        if logged.replace(stage.get()) != stage.get() {
            eprintln!(
                "{case} stage={} source={:?} status={}",
                stage.get(),
                super::super::super::buffer_text(&rich.buffer),
                ui.status.text()
            );
        }
        match stage.get() {
            0 => {
                if let Some(editor) = rich.rich.borrow().clone() {
                    let reply = reply.clone();
                    editor.evaluate("if(typeof fastraVisual==='undefined')return JSON.stringify(false);const p=document.querySelector('#fastra-visual p');const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('bold');return JSON.stringify(true);",move|value|*reply.borrow_mut()=value);
                    stage.set(1);
                }
            }
            1 => {
                if let Some(value) = reply.borrow_mut().take() {
                    if value != true {
                        stage.set(0);
                        return glib::ControlFlow::Continue;
                    }
                    stage.set(2);
                }
            }
            2 if super::super::super::buffer_text(&rich.buffer).contains("**Alpha**") => {
                assert!(rich.buffer.is_modified());
                ui.add_document("Keep.txt", "keep");
                *keep.borrow_mut() = ui.active();
                ui.add_document("Previous.txt", "previous");
                *previous.borrow_mut() = ui.active();
                *docs.borrow_mut() = ui.documents.borrow().clone();
                pause.set(Instant::now());
                stage.set(3);
            }
            3 if pause.get().elapsed() > Duration::from_millis(500) => {
                menu(&ui, keep.borrow().as_ref().unwrap());
                stage.set(4);
            }
            4 => {
                if let Some(action) = others(&ui, keep.borrow().as_ref().unwrap()) {
                    click(action.upcast_ref(), "1");
                    stage.set(if case == "rich-drift" { 5 } else { 6 });
                }
            }
            5 if close_protocol::active(&ui) => {
                ui.add_document("Arrived.txt", "new tab");
                pause.set(Instant::now());
                stage.set(10);
            }
            6 => {
                if let Some(action) = dialog(discard) {
                    assert!(Rc::ptr_eq(&ui.active().unwrap(), &a));
                    same(&ui, &docs.borrow());
                    click(action.upcast_ref(), "1");
                    stage.set(7);
                }
            }
            7 => {
                if let Some(action) = dialog(if round.get() == 0 { cancel } else { discard }) {
                    if !Rc::ptr_eq(&ui.active().unwrap(), &rich) {
                        return glib::ControlFlow::Continue;
                    }
                    same(&ui, &docs.borrow());
                    click(action.upcast_ref(), "1");
                    stage.set(if round.get() == 0 { 8 } else { 12 });
                }
            }
            8 if !close_protocol::active(&ui) => {
                same(&ui, &docs.borrow());
                assert!(Rc::ptr_eq(
                    &ui.active().unwrap(),
                    previous.borrow().as_ref().unwrap()
                ));
                assert!(rich.is_rich_active());
                stage.set(9);
            }
            9 => {
                tab_close::activate(&ui, &rich);
                after_cancel.set(rich.revision.get());
                pause.set(Instant::now());
                stage.set(13);
            }
            13 if pause.get().elapsed() > Duration::from_millis(500) => {
                let editor = rich.rich.borrow().clone().unwrap();
                support::test_click(&editor.view, &["ctrl+End", "r", "e", "s", "u", "m", "e"]);
                stage.set(11);
            }
            10 if !close_protocol::active(&ui)
                && pause.get().elapsed() > Duration::from_millis(1900) =>
            {
                assert_eq!(ui.documents.borrow().len(), docs.borrow().len() + 1);
                assert!(docs.borrow().iter().all(|old| ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|doc| Rc::ptr_eq(old, doc))));
                assert!(Rc::ptr_eq(
                    &ui.active().unwrap(),
                    previous.borrow().as_ref().unwrap()
                ));
                assert!(rich.is_rich_active());
                stage.set(9);
            }
            11 if rich.revision.get() > after_cancel.get()
                && super::super::super::buffer_text(&rich.buffer).contains("resume") =>
            {
                assert!(super::super::super::buffer_text(&rich.buffer).contains("Alpha"));
                tab_close::activate(&ui, previous.borrow().as_ref().unwrap());
                if case == "rich-drift" {
                    println!("PASS close others rich-drift: late flush after membership change removes nothing, prior activation restored, owned Rich fence released and later DOM edits retained");
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
                round.set(1);
                pause.set(Instant::now());
                stage.set(3);
            }
            12 if !close_protocol::active(&ui) => {
                assert_eq!(ui.documents.borrow().len(), 1);
                assert!(Rc::ptr_eq(
                    &ui.active().unwrap(),
                    keep.borrow().as_ref().unwrap()
                ));
                assert!(!rich.is_rich_active());
                println!("PASS close others rich: genuine DOM edits synchronized before decisions, late Cancel retains all tabs and releases Rich fence, retry Discard closes complete set only");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
