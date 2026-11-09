use super::*;
use crate::git_view as support;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
const SOURCE: &str = "# Code\r\n\r\n~~~rust\r\nlet value = 1;\r\n// <script>window.codeBad=true</script>\r\n~~~\r\n\r\n````mermaid\r\ngraph LR; A-->B\r\n````\r\n\r\n- Nested\r\n\r\n  ```mermaid\r\n  graph LR; C-->D\r\n  ```\r\n\r\n```mermaid\r\nthis is not a diagram\r\n```\r\n\r\n<script>window.codeBad=true</script>\r\n\r\nTail café 😀.\r\n";
const INSPECT: &str = "return JSON.stringify({source:fastraVisual.markdown(),svg:document.querySelectorAll('.mermaid-render svg').length,error:[...document.querySelectorAll('pre.mermaid-error')].map(n=>n.dataset.error),editable:document.querySelector('code.language-rust').isContentEditable,protected:[...document.querySelectorAll('.mermaid-render')].every(n=>!n.isContentEditable),highlight:document.querySelectorAll('code.language-rust .hljs-keyword').length,bad:typeof window.codeBad,dark:window.fastraAppearanceApplied,fills:[...document.querySelectorAll('.mermaid-render')].map(n=>getComputedStyle(n.querySelector('.node rect')).fill),undo:document.queryCommandEnabled('undo')});";
fn named(root: &impl IsA<gtk::Widget>, name: &str) -> Option<gtk::Widget> {
    if root.as_ref().widget_name() == name {
        return Some(root.as_ref().clone());
    }
    for child in crate::chrome::children(root.as_ref()) {
        if let Some(found) = named(&child, name) {
            return Some(found);
        }
    }
    None
}
fn settings(ui: &Ui) -> gtk::Window {
    ui.window
        .application()
        .unwrap()
        .windows()
        .into_iter()
        .find(|window| window.widget_name() == "fastra-global-settings")
        .unwrap()
}
fn query(editor: &RichEditor, script: &str, reply: &Rc<RefCell<Option<Value>>>) {
    let reply = reply.clone();
    editor.evaluate(script, move |value| *reply.borrow_mut() = value);
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    let path = root.join("rich-code.md");
    let restore = std::env::var("FASTRA_RICH_CODE_PHASE").as_deref() == Ok("restore");
    let source = if std::env::var_os("FASTRA_RICH_CODE_MATH").is_some() {
        format!("$x$\r\n\r\n{SOURCE}")
    } else {
        SOURCE.into()
    };
    let expected = if restore {
        std::fs::read_to_string(root.join("saved-code.txt")).unwrap()
    } else {
        std::fs::write(&path, &source).unwrap();
        source.clone()
    };
    ui.window
        .set_default_size(if ui.lang.0 { 760 } else { 1100 }, 980);
    ui.search_section.set_expanded(false);
    ui.load_path(path.clone());
    let stage = Cell::new(0);
    let previous = Cell::new(u32::MAX);
    let began = Instant::now();
    let doc = RefCell::new(None::<Rc<Document>>);
    let editor = RefCell::new(None::<Rc<RichEditor>>);
    let reply = Rc::new(RefCell::new(None));
    let input = RefCell::new(None::<std::sync::mpsc::Receiver<()>>);
    let saved = RefCell::new(String::new());
    let themed = RefCell::new(Value::Null);
    let history_began = Cell::new(Instant::now());
    let target_dark = !std::env::var("GTK_THEME").is_ok_and(|theme| theme.ends_with(":dark"));
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            began.elapsed() < Duration::from_secs(65),
            "Rich code timeout at {}",
            stage.get()
        );
        if previous.replace(stage.get()) != stage.get() {
            eprintln!("RICH_CODE_PHASE {}", stage.get());
        }
        match stage.get() {
            0 => {
                let Some(active) = ui.active().filter(|d| {
                    d.disk_path().as_ref() == Some(&path) && buffer_text(&d.buffer) == expected
                }) else {
                    return glib::ControlFlow::Continue;
                };
                let toggle = mode_toggle(&active, ui.lang);
                if !toggle.is_mapped()
                    || toggle.width() == 0
                    || toggle.height() == 0
                    || began.elapsed() < Duration::from_millis(500)
                {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&toggle, &[]);
                *doc.borrow_mut() = Some(active);
                stage.set(1);
            }
            1 => {
                let Some(rich) = doc
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .rich
                    .borrow()
                    .clone()
                    .filter(|e| e.ready_for_saved_source())
                else {
                    return glib::ControlFlow::Continue;
                };
                query(&rich, INSPECT, &reply);
                *editor.borrow_mut() = Some(rich);
                stage.set(2);
            }
            2 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["source"], expected);
                assert_eq!(value["svg"], 2);
                assert_eq!(
                    value["error"],
                    json!([ui.lang.text(
                        "Diagramm konnte nicht gerendert werden.",
                        "Diagram could not be rendered."
                    )])
                );
                assert_eq!(value["editable"], true);
                assert_eq!(value["protected"], true);
                assert!(value["highlight"].as_u64().unwrap() > 0);
                assert_eq!(value["bad"], "undefined");
                assert_eq!(value["undo"], false);
                assert!(!doc.borrow().as_ref().unwrap().buffer.is_modified());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), expected);
                if !support::try_capture(
                    ui.window.upcast_ref(),
                    if restore {
                        "rich-code-restored"
                    } else {
                        "rich-code"
                    },
                ) {
                    query(editor.borrow().as_ref().unwrap(), INSPECT, &reply);
                    return glib::ControlFlow::Continue;
                }
                if restore {
                    println!("PASS Rich code fresh restore: saved code, both diagrams, localized invalid diagram and original protected sources");
                    support::finish(ui.window.clone().upcast(), ui.clone(), "rich-code-restored");
                    return glib::ControlFlow::Break;
                }
                let rich = editor.borrow();
                let rich = rich.as_ref().unwrap();
                rich.view.grab_focus();
                query(rich, "const c=document.querySelector('code.language-rust');c.scrollIntoView({block:'center'});document.getElementById('fastra-visual').focus();const walker=document.createTreeWalker(c,NodeFilter.SHOW_TEXT);let node,offset=c.textContent.indexOf(';')+1;while(node=walker.nextNode()){if(offset<=node.length){const r=document.createRange();r.setStart(node,offset);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);break;}offset-=node.length;}return JSON.stringify(!!node);", &reply);
                stage.set(3);
            }
            3 if reply.borrow().is_some() => {
                assert_eq!(reply.borrow_mut().take().unwrap(), true);
                *input.borrow_mut() = Some(support::test_type(
                    &editor.borrow().as_ref().unwrap().view,
                    " // edited",
                ));
                stage.set(4);
            }
            4 => {
                let waiting = input
                    .borrow()
                    .as_ref()
                    .is_some_and(|receiver| receiver.try_recv().is_err());
                if waiting {
                    return glib::ControlFlow::Continue;
                }
                input.borrow_mut().take();
                if !buffer_text(&doc.borrow().as_ref().unwrap().buffer)
                    .contains("let value = 1; // edited")
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(doc.borrow().as_ref().unwrap().buffer.is_modified());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
                editor.borrow().as_ref().unwrap().command("undo");
                stage.set(5);
            }
            5 => {
                if buffer_text(&doc.borrow().as_ref().unwrap().buffer) != source
                    || !editor.borrow().as_ref().unwrap().ready_for_saved_source()
                {
                    return glib::ControlFlow::Continue;
                }
                editor.borrow().as_ref().unwrap().command("redo");
                stage.set(6);
            }
            6 => {
                let text = buffer_text(&doc.borrow().as_ref().unwrap().buffer);
                if !text.contains("let value = 1; // edited")
                    || !editor.borrow().as_ref().unwrap().ready_for_saved_source()
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(text.contains("````mermaid\r\ngraph LR; A-->B\r\n````\r\n"));
                assert!(text.contains("  graph LR; C-->D\r\n"));
                assert!(text.ends_with("Tail café 😀.\r\n"));
                *saved.borrow_mut() = text;
                support::test_keys(&editor.borrow().as_ref().unwrap().view, &["ctrl+s"]);
                stage.set(7);
            }
            7 => {
                if doc.borrow().as_ref().unwrap().buffer.is_modified()
                    || std::fs::read_to_string(&path).unwrap() != *saved.borrow()
                {
                    return glib::ControlFlow::Continue;
                }
                std::fs::write(root.join("saved-code.txt"), &*saved.borrow()).unwrap();
                query(editor.borrow().as_ref().unwrap(), INSPECT, &reply);
                stage.set(8);
            }
            8 if reply.borrow().is_some() => {
                let value = reply.borrow_mut().take().unwrap();
                assert_eq!(value["source"], *saved.borrow());
                assert_eq!(value["svg"], 2);
                assert_eq!(value["bad"], "undefined");
                assert!(!editor.borrow().as_ref().unwrap().failed.get());
                if !support::try_capture(ui.window.upcast_ref(), "rich-code-edited") {
                    query(editor.borrow().as_ref().unwrap(), INSPECT, &reply);
                    return glib::ControlFlow::Continue;
                }
                println!("PASS Rich code: actual native typing, editable highlighted code, protected top-level/nested diagrams, localized invalid syntax, source-safe HTML, byte-exact Undo, Redo and actual Ctrl+S; unrelated CRLF/Unicode blocks unchanged");
                let rich = editor.borrow();
                let rich = rich.as_ref().unwrap();
                rich.view.grab_focus();
                query(rich, "const n=document.querySelector('.mermaid-render').closest('[data-md-opaque]');document.getElementById('fastra-visual').focus();const r=document.createRange();r.selectNode(n);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);", &reply);
                stage.set(9);
            }
            9 if reply.borrow().is_some() => {
                reply.borrow_mut().take();
                support::test_keys(&editor.borrow().as_ref().unwrap().view, &["BackSpace"]);
                stage.set(10);
            }
            10 => {
                if buffer_text(&doc.borrow().as_ref().unwrap().buffer).contains("graph LR; A-->B") {
                    return glib::ControlFlow::Continue;
                }
                ui.window
                    .application()
                    .unwrap()
                    .activate_action("settings", None);
                stage.set(11);
            }
            11 => {
                let window = settings(&ui);
                let button = named(
                    &window,
                    if target_dark {
                        "fastra-appearance-dark"
                    } else {
                        "fastra-appearance-light"
                    },
                )
                .unwrap();
                if !button.is_mapped() || button.width() == 0 {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&button, &[]);
                stage.set(12);
            }
            12 => {
                if named(
                    &settings(&ui),
                    if target_dark {
                        "fastra-appearance-dark"
                    } else {
                        "fastra-appearance-light"
                    },
                )
                .unwrap()
                .downcast::<gtk::ToggleButton>()
                .unwrap()
                .is_active()
                {
                    settings(&ui).close();
                    query(editor.borrow().as_ref().unwrap(), INSPECT, &reply);
                    stage.set(13);
                }
            }
            13 if reply.borrow().is_some() => {
                let value = reply.borrow_mut().take().unwrap();
                if value["dark"] != target_dark {
                    query(editor.borrow().as_ref().unwrap(), INSPECT, &reply);
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(value["svg"], 1);
                *themed.borrow_mut() = value["fills"][0].clone();
                editor.borrow().as_ref().unwrap().command("undo");
                history_began.set(Instant::now());
                stage.set(14);
            }
            14 => {
                if buffer_text(&doc.borrow().as_ref().unwrap().buffer) != *saved.borrow()
                    || !editor.borrow().as_ref().unwrap().ready_for_saved_source()
                {
                    return glib::ControlFlow::Continue;
                }
                query(editor.borrow().as_ref().unwrap(), INSPECT, &reply);
                stage.set(15);
            }
            15 if reply.borrow().is_some() => {
                let value = reply.borrow_mut().take().unwrap();
                assert_eq!(value["svg"], 2);
                if value["fills"] != json!([*themed.borrow(), *themed.borrow()])
                    && history_began.get().elapsed() < Duration::from_secs(2)
                {
                    query(editor.borrow().as_ref().unwrap(), INSPECT, &reply);
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    value["fills"],
                    json!([*themed.borrow(), *themed.borrow()]),
                    "Undo must restore the current diagram palette"
                );
                assert_eq!(value["source"], *saved.borrow());
                support::test_keys(&editor.borrow().as_ref().unwrap().view, &["ctrl+s"]);
                stage.set(16);
            }
            16 => {
                if doc.borrow().as_ref().unwrap().buffer.is_modified() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&path).unwrap(), *saved.borrow());
                if !support::try_capture(ui.window.upcast_ref(), "rich-code-theme-history") {
                    return glib::ControlFlow::Continue;
                }
                println!("PASS Rich diagram history: actual deletion, native appearance choice, Undo restores exact source and current SVG colors without losing ordinary code edit");
                support::finish(ui.window.clone().upcast(), ui.clone(), "rich-code");
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
