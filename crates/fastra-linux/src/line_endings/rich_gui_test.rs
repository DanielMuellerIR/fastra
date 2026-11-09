use super::*;
use serde_json::Value;
use std::{
    cell::RefCell,
    path::PathBuf,
    time::{Duration, Instant},
};
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("rich-eol.md");
    let math = std::env::var_os("FASTRA_EOL_RICH_MATH_SELFTEST").is_some();
    let source = if math {
        "# Heading\n\nfirst café 🙂 $x^2$ after\n"
    } else {
        "# Heading\n\nfirst café 🙂\n"
    };
    std::fs::write(&path, source).unwrap();
    let snapshot = fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default()).unwrap();
    let decoded =
        std::sync::Arc::new(fastra_core::encoding::decode(source.as_bytes(), None).unwrap());
    crate::git_view::test_size(ui.window.upcast_ref());
    let doc = ui.add_loaded_text("rich-eol.md", decoded, snapshot);
    choose(&ui, &doc, LineEnding::CrLf);
    doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
    let old = RefCell::new(None::<Rc<crate::rich_editor::RichEditor>>);
    let answer = Rc::new(RefCell::new(None::<Value>));
    let observed = Cell::new(false);
    let stage = Cell::new(0);
    let started = Instant::now();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "Rich EOL stage {} {}",
            stage.get(),
            ui.status.text()
        );
        match stage.get() {
            0 => {
                let Some(editor) = doc
                    .rich
                    .borrow()
                    .clone()
                    .filter(|e| e.ready_for_saved_source())
                else {
                    return glib::ControlFlow::Continue;
                };
                *old.borrow_mut() = Some(editor);
                ui.save_document();
            }
            1 => {
                if !doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                let operation = old.borrow().as_ref().unwrap().close_stamp().6;
                ui.save_document();
                assert_eq!(
                    old.borrow().as_ref().unwrap().close_stamp().6,
                    operation,
                    "repeated Save must retain the running worker's Rich fence"
                );
                let reply = answer.clone();
                old.borrow().as_ref().unwrap().evaluate(r#"const root=document.getElementById('fastra-visual');const editable=root.isContentEditable;if(editable){root.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));const p=root.querySelector('p');p.append(document.createTextNode('IME-DRAFT'));p.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertCompositionText',data:'IME-DRAFT',isComposing:true}));}return JSON.stringify({editable,draft:root.textContent.includes('IME-DRAFT')});"#,move|v|*reply.borrow_mut()=v);
            }
            2 => {
                let Some(value) = answer.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                observed.set(value["editable"] == true);
                assert_eq!(value["draft"] == true, observed.get());
                assert_eq!(
                    buffer_text(&doc.buffer),
                    source,
                    "composing draft has not become a host source revision"
                );
            }
            3 => {
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                let Some(editor) = doc
                    .rich
                    .borrow()
                    .clone()
                    .filter(|e| e.ready_for_saved_source())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!observed.get() || buffer_text(&doc.buffer).contains("IME-DRAFT"),"accepted visible IME draft must survive EOL source adoption, not be destroyed with the old Rich view");
                assert!(
                    !observed.get(),
                    "normalizing save holds the old Rich view before worker start"
                );
                assert!(!Rc::ptr_eq(&editor, old.borrow().as_ref().unwrap()));
                let expected = LineEnding::CrLf.convert(source);
                assert_eq!(buffer_text(&doc.buffer), expected);
                assert_eq!(std::fs::read(&path).unwrap(), expected.as_bytes());
                let reply = answer.clone();
                editor.evaluate(
                    "return JSON.stringify({...fastraVisual.clipboardState(),math:document.querySelectorAll(\"math\").length});",
                    move |v| *reply.borrow_mut() = v,
                );
            }
            4 => {
                let Some(value) = answer.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    value["markdown"].as_str(),
                    Some(LineEnding::CrLf.convert(source).as_str())
                );
                if math {
                    assert_eq!(value["math"], 1);
                }
                println!("PASS Rich EOL save: old editable/composing frontier fenced before worker; rebased view exact CRLF source and actual file retained");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        glib::ControlFlow::Continue
    });
}
