//! Echte WebKit-DOM-Änderung ohne input-Ereignis prüft die letzte Close-Fence.
use super::*;
use std::time::{Duration, Instant};
pub(super) fn run(ui: Rc<Ui>, fail: bool) {
    let root = PathBuf::from(std::env::var_os("FASTRA_SESSION_FIXTURE").unwrap());
    let path = root.join("rich.md");
    let original = b"\xef\xbb\xbf# Session\n\nbase\n".to_vec();
    std::fs::write(&path, &original).unwrap();
    let phase = Cell::new(0);
    let started = Instant::now();
    let response = Rc::new(RefCell::new(None::<serde_json::Value>));
    let waiting = Cell::new(false);
    let before = RefCell::new(None::<Vec<u8>>);
    let pause = Cell::new(None::<Instant>);
    gtk::glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(45),
            "Rich session phase {}",
            phase.get()
        );
        let state = ui.session.borrow().clone().unwrap();
        let current = || ui.active().unwrap();
        let file = || {
            state_base()
                .unwrap()
                .join("fastra")
                .join(&state.lease.borrow().as_ref().unwrap().name)
        };
        match phase.get() {
            0 => {
                if !state.ready.get() {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert!(!state.is_enabled());
                ui.load_path(path.clone());
                phase.set(1);
            }
            1 => {
                if current().name != "rich.md" {
                    return gtk::glib::ControlFlow::Continue;
                }
                current().rich_toggle.borrow().as_ref().unwrap().set_active(true);
                phase.set(2);
            }
            2 => {
                let Some(editor) = current().rich.borrow().clone() else {
                    return gtk::glib::ControlFlow::Continue;
                };
                if !waiting.replace(true) {
                    let reply = response.clone();
                    editor.evaluate("return JSON.stringify(!!window.fastraVisual && !!document.querySelector('#fastra-visual p'));",move|r|{*reply.borrow_mut()=Some(r.unwrap_or(serde_json::Value::Bool(false)));});
                }
                if let Some(value) = response.borrow_mut().take() {
                    waiting.set(false);
                    if value == true {
                        phase.set(3);
                    }
                }
            }
            3 => {
                let editor = current().rich.borrow().clone().unwrap();
                let reply = response.clone();
                editor.evaluate("document.querySelector('#fastra-visual p').textContent += ' LAST 🌈'; return JSON.stringify(fastraVisual.markdown());",move|r|{*reply.borrow_mut()=r;});
                phase.set(4);
            }
            4 => {
                if response.borrow_mut().take().is_none() {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert!(!buffer_text(&current().buffer).contains("LAST"));
                state.enabled.set_active(true);
                state.flush(None);
                phase.set(5);
            }
            5 => {
                if !gui_test::durable(&state) {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert!(buffer_text(&current().buffer).contains("LAST 🌈"));
                let bytes = std::fs::read(file()).unwrap();
                let data: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                assert!(data["documents"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|d| d["text"].as_str().unwrap().contains("LAST 🌈")
                        && d["original_hex"].as_str().unwrap().starts_with("efbbbf")));
                *before.borrow_mut() = Some(bytes);
                let editor = current().rich.borrow().clone().unwrap();
                let reply = response.clone();
                let js = if fail {
                    "document.querySelector('#fastra-visual p').textContent += ' UNFLUSHED'; fastraVisual.prepareAction=()=>{throw new Error('private test failure')}; return JSON.stringify(true);"
                } else {
                    "document.querySelector('#fastra-visual p').textContent += ' CLOSE';return JSON.stringify(true);"
                };
                editor.evaluate(js, move |r| {
                    *reply.borrow_mut() = r;
                });
                phase.set(6);
            }
            6 => {
                if response.borrow_mut().take().is_none() {
                    return gtk::glib::ControlFlow::Continue;
                }
                assert!(!buffer_text(&current().buffer).contains(if fail {
                    "UNFLUSHED"
                } else {
                    "CLOSE"
                }));
                if !fail {
                    let weak = Rc::downgrade(&state);
                    let source = path.clone();
                    let expected = original.clone();
                    ui.window.connect_close_request(move |_| {
                        if let Some(state)=weak.upgrade().filter(|state|state.allow_close.get()) {
                            let saved=state.lease.borrow().as_ref().unwrap().read_optional().unwrap().unwrap();
                            assert!(saved.documents.iter().any(|doc|doc.text.contains("CLOSE")));
                            assert_eq!(std::fs::read(&source).unwrap(),expected);
                            println!("FASTRA_SESSION_RICH_OK failure=false last-DOM/fenced-capture/source-unchanged");
                        }
                        gtk::glib::Propagation::Proceed
                    });
                }
                assert!(state.close().is_some());
                phase.set(7);
            }
            7 => {
                if fail {
                    if crate::close_protocol::active(&ui){return gtk::glib::ControlFlow::Continue;}
                    phase.set(8);return gtk::glib::ControlFlow::Continue;
                }
                let Some(window) = gui_test::modal(&ui) else {
                    return gtk::glib::ControlFlow::Continue;
                };
                assert!(gui_test::click(
                    window.upcast_ref(),
                    ui.lang
                        .text("Mit Wiederherstellung schließen", "Close with recovery")
                ));
                phase.set(8);
            }
            _ => {
                if state.busy.get() {
                    return gtk::glib::ControlFlow::Continue;
                }
                if fail {
                    if !ui.status.text().to_ascii_lowercase().contains("rich") {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    assert!(ui.window.is_visible());
                    assert!(!state.allow_close.get());
                    assert_eq!(
                        std::fs::read(file()).unwrap(),
                        *before.borrow().as_ref().unwrap()
                    );
                    assert!(!buffer_text(&current().buffer).contains("UNFLUSHED"));
                    if pause.get().is_none() {
                        pause.set(Some(Instant::now()));
                        return gtk::glib::ControlFlow::Continue;
                    }
                    if pause.get().unwrap().elapsed() < Duration::from_millis(300) {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    gui_test::capture(ui.window.upcast_ref(), "session-rich-failure");
                } else {
                    if !state.allow_close.get() {
                        return gtk::glib::ControlFlow::Continue;
                    }
                    let data = std::fs::read_to_string(file()).unwrap();
                    assert!(data.contains("CLOSE"));
                }
                assert_eq!(std::fs::read(&path).unwrap(), original);
                println!("FASTRA_SESSION_RICH_OK failure={fail} last-DOM/fenced-capture/source-unchanged");
                if let Some(app)=ui.window.application(){app.quit();}
                return gtk::glib::ControlFlow::Break;
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}
