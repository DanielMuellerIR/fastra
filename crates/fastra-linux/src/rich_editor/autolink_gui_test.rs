use super::*;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root =
        PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").expect("isolated test root"));
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("autolinks.md");
    let eol = match std::env::var("FASTRA_AUTOLINK_EOL").as_deref() {
        Ok("crlf") => "\r\n",
        Ok("cr") => "\r",
        _ => "\n",
    };
    let original="# Autolink gate\n\nhttp://a/$x$\n\nwww.example.com/==x==\n\na&#64;example.com a\\@example.com\n\n$z$ next to https://example.com/\n\nhttp://a/`foo bar` www.c.com ` www.d.com\n\nref[^n] twice[^n]\n\n[^n]: http://footnote.invalid/\n\nTail\n".replace('\n',eol);
    std::fs::write(&path, original.as_bytes()).unwrap();
    let expected = original.replace("Tail", "Tail edited");
    let state = Cell::new(0);
    let reply = Rc::new(RefCell::new(None::<Value>));
    let held = RefCell::new(None::<Rc<RichEditor>>);
    let captures = RefCell::new(None);
    let start = Instant::now();
    ui.window.set_default_size(1100, 850);
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            start.elapsed() < Duration::from_secs(80),
            "autolink stage {}: {}",
            state.get(),
            ui.status.text()
        );
        let current = || ui.active().unwrap();
        match state.get() {
            0 => {
                ui.load_path(path.clone());
                state.set(1);
            }
            1 => {
                if current().name != "autolinks.md" {
                    return glib::ControlFlow::Continue;
                }
                let before = Instant::now();
                mode_toggle(&current(), ui.lang).set_active(true);
                println!("AUTOLINK toggle_sync_us={}", before.elapsed().as_micros());
                state.set(2);
            }
            2 => {
                let Some(editor) = current().rich.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!editor.failed.get(), "{}", editor.status.text());
                if !editor.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                *held.borrow_mut() = Some(editor.clone());
                let reply = reply.clone();
                editor.evaluate("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));const root=document.getElementById('fastra-visual');return JSON.stringify({source:fastraVisual.markdown(),hrefs:[...root.querySelectorAll('a')].map(a=>a.getAttribute('href')),nested:root.querySelectorAll('a a').length,math:root.querySelectorAll('[data-tex]').length,url:document.URL,html:root.innerHTML});",move|v|*reply.borrow_mut()=v);
                state.set(3);
            }
            3 => {
                let Some(value) = reply.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["source"], original);
                assert_eq!(value["nested"], 0);
                assert_eq!(value["math"], 1);
                assert_eq!(value["url"], BASE);
                let hrefs = value["hrefs"].as_array().unwrap();
                assert!(hrefs.iter().any(|v| v == "http://a/$x$"));
                assert!(hrefs.iter().any(|v| v == "mailto:a@example.com"));
                assert!(hrefs.iter().any(|v| v == "http://www.example.com/==x=="));
                assert!(!hrefs.iter().any(|v| v == "http://www.c.com"));
                for href in hrefs {
                    let href = href.as_str().unwrap();
                    assert!(!href.contains("FASTRA") && !href.contains('<'));
                }
                std::fs::write(
                    root.join("dom.json"),
                    serde_json::to_vec_pretty(&value).unwrap(),
                )
                .unwrap();
                if !gui_test::capture(&ui.window, "autolink-initial", &captures) {
                    return glib::ControlFlow::Continue;
                }
                reply.borrow_mut().take();
                let out = reply.clone();
                held.borrow().as_ref().unwrap().evaluate("const p=[...document.querySelectorAll('#fastra-visual p')].find(p=>p.textContent==='Tail');const r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertText',false,' edited');return JSON.stringify(true);",move|v|*out.borrow_mut()=v);
                state.set(4);
            }
            4 => {
                if reply.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                if buffer_text(&current().buffer) != expected {
                    return glib::ControlFlow::Continue;
                }
                reply.borrow_mut().take();
                held.borrow().as_ref().unwrap().command("undo");
                state.set(5);
            }
            5 => {
                if buffer_text(&current().buffer) != original {
                    return glib::ControlFlow::Continue;
                }
                held.borrow().as_ref().unwrap().command("redo");
                state.set(6);
            }
            6 => {
                if buffer_text(&current().buffer) != expected {
                    return glib::ControlFlow::Continue;
                }
                ui.save_document();
                state.set(7);
            }
            7 => {
                if current().saving.get() || std::fs::read(&path).unwrap() != expected.as_bytes() {
                    return glib::ControlFlow::Continue;
                }
                mode_toggle(&current(), ui.lang).set_active(false);
                state.set(8);
            }
            8 => {
                if current().rich.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&current().buffer), expected);
                assert_eq!(std::fs::read(&path).unwrap(), expected.as_bytes());
                println!("PASS autolink native WebKit: literal Math URI, decoded Mail, mark-safe URL, no nested links, exact source/undo/redo/save/mode roundtrip with {:?}",eol);
                ui.window.close();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
