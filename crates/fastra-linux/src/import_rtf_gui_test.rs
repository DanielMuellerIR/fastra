//! Echter RTF-Clipboardweg über den sichtbaren Importdialog und die lokale PMT-CLI.
use super::*;
use gtk::glib;
use std::time::{Duration, Instant};
thread_local! { static MATERIALIZED: RefCell<Weak<State>> = const { RefCell::new(Weak::new()) }; }
pub(super) fn opened(state: &Rc<State>) {
    MATERIALIZED.with(|slot| *slot.borrow_mut() = Rc::downgrade(state));
}
pub(super) fn start(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    let path = root.join("rtf-origin.md");
    std::fs::write(&path, "Original **document** stays unchanged.\n").unwrap();
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let reply = Rc::new(Cell::new(false));
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(30),
            "RTF clipboard setup {}",
            phase.get()
        );
        if pause.get().elapsed() < Duration::from_millis(250) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                let toggle = doc.rich_toggle.borrow().clone().unwrap();
                if !toggle.is_mapped() || toggle.width() <= 0 {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&toggle, &[]);
            }
            1 => {
                let Some(editor) = ui
                    .active()
                    .and_then(|doc| doc.rich.borrow().clone())
                    .filter(|e| e.ready_for_saved_source())
                else {
                    return glib::ControlFlow::Continue;
                };
                let rtf = br"{\rtf1\ansi\uc1{\colortbl;\red255\green255\blue0;} Plain {\b Bold} \highlight1 Marked\highlight0  \u196?}";
                editor
                    .view
                    .clipboard()
                    .set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
                        "text/rtf",
                        &glib::Bytes::from_static(rtf),
                    )))
                    .unwrap();
                editor.view.grab_focus();
                let ready = reply.clone();
                editor.evaluate(
                    "document.getElementById('fastra-visual').focus();return JSON.stringify(true);",
                    move |value| ready.set(value == Some(serde_json::json!(true))),
                );
            }
            2 => {
                if !reply.get() {
                    return glib::ControlFlow::Continue;
                }
                let editor = ui.active().unwrap().rich.borrow().clone().unwrap();
                support::test_keys(&editor.view, &["ctrl+v"]);
            }
            _ => {
                let Some(state) = MATERIALIZED
                    .with(|slot| slot.borrow().upgrade())
                    .filter(|s| s.window.is_mapped())
                else {
                    return glib::ControlFlow::Continue;
                };
                fn loss_label(widget: &gtk::Widget, needle: &str) -> bool {
                    widget
                        .downcast_ref::<gtk::Label>()
                        .is_some_and(|l| l.is_mapped() && l.text().contains(needle))
                        || crate::chrome::children(widget)
                            .iter()
                            .any(|child| loss_label(child, needle))
                }
                assert!(loss_label(
                    state.window.upcast_ref(),
                    ui.lang.text(
                        "Formatierung und Textmarker können",
                        "conversion can lose formatting"
                    )
                ));
                if !support::try_capture(&state.window, "rtf-loss-boundary") {
                    return glib::ControlFlow::Continue;
                }
                begin(ui.clone());
                return glib::ControlFlow::Break;
            }
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
pub(super) fn begin(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let state = MATERIALIZED
        .with(|slot| slot.borrow().upgrade())
        .expect("actual RTF clipboard dialog");
    let fixture = PathBuf::from(std::env::var_os("FASTRA_RICH_TEST_ROOT").unwrap());
    let destination = fixture.join("rtf-destination");
    std::fs::create_dir(&destination).unwrap();
    let source = PathBuf::from(state.source.text().as_str());
    let source_bytes = std::fs::read(&source).unwrap();
    assert!(source_bytes.starts_with(br"{\rtf1"));
    let original = ui.active().unwrap();
    let original_text = super::super::buffer_text(&original.buffer);
    let original_path = original.disk_path().unwrap();
    let original_disk = std::fs::read(&original_path).unwrap();
    set_path(
        &state.program,
        &PathBuf::from(std::env::var_os("FASTRA_POORMANS_TEXT").unwrap()),
        &state.status,
        ui.lang,
    );
    set_path(&state.destination, &destination, &state.status, ui.lang);
    state.stem.set_text("rtf-result");
    state.window.set_default_size(
        std::env::var("FASTRA_TOOL_WIDTH")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(1100),
        850,
    );
    let phase = Cell::new(0);
    let delay = Cell::new(Instant::now());
    let started = Instant::now();
    let output = RefCell::new(None::<PathBuf>);
    let reply = Rc::new(RefCell::new(None::<serde_json::Value>));
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            started.elapsed() < Duration::from_secs(100),
            "real RTF phase {}: {}",
            phase.get(),
            state.status.text()
        );
        if delay.get().elapsed() < Duration::from_millis(250) || state.busy.get() {
            return glib::ControlFlow::Continue;
        }
        let next = |n| {
            eprintln!("Real RTF phase {n}");
            phase.set(n);
            delay.set(Instant::now());
        };
        match phase.get() {
            0 => {
                if !support::try_capture(&state.window, "rtf-clipboard-loss-boundary") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.catalog_button, &[]);
                next(1);
            }
            1 => {
                assert!(
                    super::super::buffer_text(&state.catalog.buffer()).contains("rtf"),
                    "{}",
                    state.status.text()
                );
                support::test_click(&state.prepare, &[]);
                next(2);
            }
            2 => {
                if state.prepared.borrow().is_none() {
                    let failure = format!(
                        "{}\n{}\n{}",
                        state.status.text(),
                        super::super::buffer_text(&state.preview.buffer()),
                        super::super::buffer_text(&state.raw.buffer())
                    );
                    std::fs::write(fixture.join("rtf-import-error.txt"), &failure).unwrap();
                    panic!("{failure}");
                }
                let prepared = state.prepared.borrow();
                let preview = prepared.as_ref().unwrap().preview();
                assert!(preview
                    .markdown_text
                    .values()
                    .any(|s| s.trim() == "Plain **Bold** ==Marked== Ä"));
                let visible = super::super::buffer_text(&state.preview.buffer());
                for content in preview.markdown_text.values() {
                    assert!(visible.contains(content));
                }
                assert!(visible.contains("richText.highlightColorApproximation"));
                assert!(visible.contains(ui.lang.text(
                    "Textmarkierungen bleiben erhalten",
                    "Highlights are retained"
                )));
                assert!(!destination.join("rtf-result").exists());
                assert_eq!(std::fs::read(&source).unwrap(), source_bytes);
                *output.borrow_mut() = Some(destination.join("rtf-result").join(&preview.entry));
                drop(prepared);
                if !support::try_capture(&state.window, "rtf-complete-preview") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.adopt, &[]);
                next(3);
            }
            3 => {
                let path = output.borrow().clone().unwrap();
                if ui.active().and_then(|d| d.disk_path()) != Some(path.clone()) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    std::fs::read_to_string(&path).unwrap().trim(),
                    "Plain **Bold** ==Marked== Ä"
                );
                assert_eq!(std::fs::read(&source).unwrap(), source_bytes);
                assert_eq!(super::super::buffer_text(&original.buffer), original_text);
                assert_eq!(std::fs::read(&original_path).unwrap(), original_disk);
                state.window.close();
                next(4);
            }
            4 => {
                if state.window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                let doc = ui.active().unwrap();
                if doc.rich.borrow().is_none() {
                    let Some(button) = doc.rich_toggle.borrow().clone() else {
                        return glib::ControlFlow::Continue;
                    };
                    if !button.is_mapped() || button.width() <= 0 {
                        return glib::ControlFlow::Continue;
                    }
                    support::test_click(&button, &[]);
                }
                next(5);
            }
            5 => {
                let Some(editor) = ui.active().and_then(|d| d.rich.borrow().clone()) else {
                    return glib::ControlFlow::Continue;
                };
                let response = reply.clone();
                editor.evaluate("if(typeof fastraVisual==='undefined')return null; return JSON.stringify({mark:document.querySelector('#fastra-visual mark')?.textContent,bold:document.querySelector('#fastra-visual strong')?.textContent,text:document.getElementById('fastra-visual').textContent});",move|v|*response.borrow_mut()=v);
                next(6);
            }
            _ => {
                let Some(value) = reply.borrow_mut().take() else {
                    phase.set(5);
                    return glib::ControlFlow::Continue;
                };
                if value.is_null() {
                    phase.set(5);
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(value["mark"], "Marked");
                assert_eq!(value["bold"], "Bold");
                assert!(value["text"].as_str().unwrap().contains('Ä'));
                if !support::try_capture(ui.window.upcast_ref(), "rtf-imported-rich-markup") {
                    return glib::ControlFlow::Continue;
                }
                std::fs::write(fixture.join("rtf-consumer.json"),serde_json::to_vec_pretty(&serde_json::json!({"rtfClipboard":true,"visibleLossBoundary":true,"completePreview":true,"explicitNativeAdoption":true,"markdown":"Plain **Bold** ==Marked== Ä","actualRichMark":"Marked","actualRichBold":"Bold","originalBufferUnchanged":true,"originalDiskUnchanged":true,"sourceRtfUnchanged":true})).unwrap()).unwrap();
                eprintln!("PASS real RTF clipboard -> visible loss boundary -> actual PMT -> complete preview -> native adoption -> real Rich highlight/bold/Unicode; original document unchanged");
                support::finish(ui.window.clone().upcast(), ui.clone(), "rtf-real-consumer");
                return glib::ControlFlow::Break;
            }
        }
        glib::ControlFlow::Continue
    });
}
