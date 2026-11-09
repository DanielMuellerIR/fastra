use super::*;
use std::time::{Duration, Instant};

pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("image-watch.md");
    let image = root.join("image.png");
    let first = include_bytes!("../../tests/fixtures/pixel-1.png");
    let second = include_bytes!("../../tests/fixtures/pixel-2.png");
    let source = format!("Editable words\n\n![External image](image.png)\n\n![Initially missing](initially-missing.png)\n\n{}", "Scrollable paragraph.\n\n".repeat(80));
    std::fs::write(&path, &source).unwrap();
    std::fs::write(&image, first).unwrap();
    ui.window.set_default_size(
        std::env::var("FASTRA_RICH_WIDTH")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1180),
        850,
    );
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let started = Instant::now();
    let editor = RefCell::new(None::<Rc<RichEditor>>);
    let response = Rc::new(RefCell::new(None::<Value>));
    let in_flight = Cell::new(false);
    let baseline = RefCell::new(None::<Value>);
    let revision = Cell::new(0);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            started.elapsed() < Duration::from_secs(70),
            "image watcher phase {}",
            phase.get()
        );
        let Some(doc) = ui
            .active()
            .filter(|doc| doc.disk_path().as_ref() == Some(&path))
        else {
            return glib::ControlFlow::Continue;
        };
        if phase.get() == 0 {
            mode_toggle(&doc, ui.lang).set_active(true);
            phase.set(1);
        }
        if phase.get() == 1 {
            let Some(value) = doc.rich.borrow().clone().filter(|e| e.ready.get()) else {
                return glib::ControlFlow::Continue;
            };
            let reply = response.clone();
            value.evaluate("const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);document.getElementById('fastra-visual').focus();return JSON.stringify(true);",move|v|*reply.borrow_mut()=v);
            *editor.borrow_mut() = Some(value);
            phase.set(2);
            return glib::ControlFlow::Continue;
        }
        let editor = editor.borrow().clone().unwrap();
        if phase.get() == 2 {
            if response.borrow_mut().take() != Some(Value::Bool(true)) {
                return glib::ControlFlow::Continue;
            }
            gui_test::input(&editor.view, false, &["x"]);
            phase.set(3);
            return glib::ControlFlow::Continue;
        }
        if phase.get() == 30 {
            let Some(value) = response.borrow_mut().take() else {
                return glib::ControlFlow::Continue;
            };
            assert_eq!(value, Value::Bool(true));
            phase.set(31);
        }
        if phase.get() == 40 {
            let Some(value) = response.borrow_mut().take() else {
                return glib::ControlFlow::Continue;
            };
            assert_eq!(value,Value::Bool(true),"a newly inserted image must not inherit an older cache entry with the same Markdown path");
            gui_test::input(&editor.view, false, &["ctrl+z"]);
            phase.set(5);
            return glib::ControlFlow::Continue;
        }
        let Some(value) = response.borrow_mut().take() else {
            if !in_flight.replace(true) {
                let reply = response.clone();
                editor.evaluate("const i=document.querySelector('#fastra-visual img'),s=getSelection();return JSON.stringify({missingWidth:document.querySelectorAll('#fastra-visual img')[1]?.naturalWidth,width:i?.naturalWidth,complete:i?.complete,src:i?.getAttribute('data-md-src'),uri:i?.getAttribute('src'),markdown:fastraVisual.markdown(),anchor:s.anchorNode?.textContent,offset:s.anchorOffset,scroll:scrollY});",move|v|*reply.borrow_mut()=v);
            }
            return glib::ControlFlow::Continue;
        };
        in_flight.set(false);
        let width = value["width"].as_u64().unwrap_or(999);
        match phase.get() {
            3 if value["markdown"]
                .as_str()
                .is_some_and(|text| text.contains("wordsx"))
                && buffer_text(&doc.buffer).contains("wordsx")
                && width == 1 =>
            {
                assert!(doc.buffer.is_modified());
                let reply = response.clone();
                editor.evaluate("window.scrollTo(0,250);await new Promise(r=>requestAnimationFrame(r));return JSON.stringify(true);",move|value|*reply.borrow_mut()=value);
                phase.set(30);
            }
            31 if value["scroll"]
                .as_f64()
                .is_some_and(|offset| offset >= 200.) =>
            {
                assert!(
                    value["markdown"]
                        .as_str()
                        .unwrap()
                        .contains("![External image](image.png)"),
                    "typing must preserve the unrelated original image block bytes"
                );
                revision.set(doc.revision.get());
                *baseline.borrow_mut() = Some(value);
                std::fs::write(root.join("replacement.png"), second).unwrap();
                std::fs::rename(root.join("replacement.png"), &image).unwrap();
                phase.set(4);
            }
            4 if width == 2 => {
                let baseline = baseline.borrow();
                let before = baseline.as_ref().unwrap();
                for key in ["markdown", "anchor", "offset", "scroll", "src"] {
                    assert_eq!(value[key], before[key], "refresh changed {key}");
                }
                assert_eq!(doc.revision.get(), revision.get());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
                let reply = response.clone();
                editor.evaluate("const root=document.getElementById('fastra-visual'),image=document.createElement('img');image.dataset.mdSrc='image.png';image.src='fastra-rich://image/newly-inserted-token?v=new';root.append(image);await new Promise(r=>setTimeout(r,20));const preserved=image.getAttribute('src')==='fastra-rich://image/newly-inserted-token?v=new';image.remove();return JSON.stringify(preserved);",move|value|*reply.borrow_mut()=value);
                phase.set(40);
            }
            5 if !value["markdown"].as_str().unwrap_or("").contains("wordsx")
                && !buffer_text(&doc.buffer).contains("wordsx")
                && width == 2 =>
            {
                gui_test::input(&editor.view, false, &["ctrl+shift+z"]);
                phase.set(6);
            }
            6 if value["markdown"]
                .as_str()
                .is_some_and(|text| text.contains("wordsx"))
                && buffer_text(&doc.buffer).contains("wordsx")
                && width == 2 =>
            {
                revision.set(doc.revision.get());
                std::fs::remove_file(&image).unwrap();
                phase.set(7);
            }
            7 if width == 0 && value["complete"] == true => {
                assert_eq!(doc.revision.get(), revision.get());
                std::fs::write(root.join("target-one.png"), first).unwrap();
                std::os::unix::fs::symlink(root.join("target-one.png"), &image).unwrap();
                phase.set(8);
            }
            8 if width == 1 => {
                std::fs::write(root.join("target-two.png"), second).unwrap();
                std::os::unix::fs::symlink(root.join("target-two.png"), root.join("new-link"))
                    .unwrap();
                std::fs::rename(root.join("new-link"), &image).unwrap();
                phase.set(9);
            }
            9 if width == 2 => {
                std::fs::write(root.join("target-two.png"), b"not an image").unwrap();
                phase.set(10);
            }
            10 if width == 0 && value["complete"] == true => {
                std::fs::write(root.join("target-two.png"), first).unwrap();
                phase.set(11);
            }
            11 if width == 1 => {
                std::fs::write(root.join("initially-missing.png"), second).unwrap();
                phase.set(12);
            }
            12 if width == 1 && value["missingWidth"] == 2 => {
                assert_eq!(doc.revision.get(), revision.get());
                assert!(buffer_text(&doc.buffer).contains("wordsx"));
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
                println!("PASS native local image refresh: decoded images, initially missing file recovery, atomic replacement, missing/reappearing files, symlink target ABA, invalid image recovery, typing/caret/scroll/source unchanged and native Undo/Redo preserved");
                crate::git_view::finish(ui.window.clone().upcast(), ui.clone(), "rich-image-watch");
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
