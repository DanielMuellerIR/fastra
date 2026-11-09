use super::*;
use std::time::{Duration, Instant};

#[derive(Default)]
struct Probe {
    pending: Cell<bool>,
    reply: RefCell<Option<bool>>,
}
fn rendered(doc: &crate::Document, variant: &str, probe: &Rc<Probe>) -> bool {
    if !matches!(variant, "math" | "image") {
        return true;
    }
    if let Some(ready) = probe.reply.borrow_mut().take() {
        probe.pending.set(false);
        assert!(
            ready,
            "the retained Rich view actually renders its math/images"
        );
        return true;
    }
    if !probe.pending.replace(true) {
        let target = probe.clone();
        let code = if variant == "math" {
            "return JSON.stringify(document.querySelectorAll('[data-tex][data-rendered] math').length>0);"
        } else {
            "return JSON.stringify(Array.from(document.querySelectorAll('img')).some(image=>image.naturalWidth>0 && image.dataset.mdSrc==='picture.png'));"
        };
        doc.rich
            .borrow()
            .as_ref()
            .unwrap()
            .evaluate(code, move |value| {
                *target.reply.borrow_mut() = Some(value == Some(serde_json::json!(true)));
            });
    }
    false
}

pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let left = root.join("rich-left.md");
    let right = root.join("rich-right.md");
    let variant = std::env::var("FASTRA_DIFF_RICH_VARIANT").unwrap_or_else(|_| "basic".into());
    let original = match variant.as_str() {
        "empty" => "remove me\r\n", "definitions" => "[ref]: https://example.org\r\n",
        "math" => "# Math\r\n\r\n$x^2 + 1$\r\n", "image" => "# Image\r\n\r\n![alt](picture.png)\r\n\r\nold\r\n",
        "basic" => "# Übersicht 👩‍💻\r\n\r\nold **bold** café [Link][ref]\r\n\r\n<script>protected()</script>\r\n\r\n[ref]: https://example.org\r\n",
        _ => panic!("unknown Rich comparison variant"),
    };
    let output = match variant.as_str() {
        "empty" | "definitions" => String::new(),
        "math" => original.replace("x^2", "x^3"),
        _ => original.replace("old", "new"),
    };
    if variant == "image" {
        std::fs::write(
            root.join("picture.png"),
            include_bytes!("../../tests/fixtures/pixel-1.png"),
        )
        .unwrap();
    }
    let probe = Rc::new(Probe::default());
    std::fs::write(&left, original).unwrap();
    std::fs::write(&right, &output).unwrap();
    ui.load_path(left.clone());
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let source = RefCell::new(None::<Rc<crate::Document>>);
    let state = RefCell::new(None::<Rc<State>>);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(50),
            "Rich comparison phase{}: {}; preview={:?}",
            phase.get(),
            ui.status.text(),
            transfer::test_preview()
                .map(|p| (p.apply.is_sensitive(), p.view.status.text().to_string()))
        );
        if pause.get().elapsed() < Duration::from_millis(300) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&left))
                else {
                    return glib::ControlFlow::Continue;
                };
                support::test_click(doc.rich_toggle.borrow().as_ref().unwrap(), &[]);
                *source.borrow_mut() = Some(doc);
            }
            1 => {
                let doc = source.borrow().clone().unwrap();
                if !doc
                    .rich
                    .borrow()
                    .as_ref()
                    .is_some_and(|editor| editor.can_replace_source())
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), original);
                let picker = open(&ui);
                picker.choose(1, sources::Choice::File(right.clone()));
                *state.borrow_mut() = Some(picker);
            }
            2 => {
                let state = state.borrow().clone().unwrap();
                if !state.picker.compare.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.picker.compare, &[]);
            }
            3 => {
                let state = state.borrow().clone().unwrap();
                if state.busy.get() || !state.view.transfer[0].is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(source.borrow().as_ref().unwrap().is_rich_active());
                support::test_click(&state.view.transfer[0], &[]);
            }
            4 => {
                let Some(preview) = transfer::test_preview().filter(|p| p.apply.is_sensitive())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(preview.plan.output(), output);
                assert_eq!(
                    buffer_text(&source.borrow().as_ref().unwrap().buffer),
                    original
                );
                if !support::try_capture(&preview.window, "compare-rich-transfer-preview") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&preview.apply, &[]);
            }
            5 => {
                let doc = source.borrow().clone().unwrap();
                let state = state.borrow().clone().unwrap();
                if state.busy.get()
                    || transfer::test_preview().is_some()
                    || buffer_text(&doc.buffer) != output
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(doc.is_rich_active(), "transfer retains the same Rich mode");
                if variant == "image" {
                    assert_eq!(doc.rich.borrow().as_ref().unwrap().image_cache_metrics().0, 1,
                        "unchanged image reuses its verified token instead of growing the Undo cache");
                }
                assert_eq!(std::fs::read_to_string(&left).unwrap(), original);
                support::test_click(&chrome::tab_header(&ui, &doc), &[]);
            }
            6 => {
                let doc = source.borrow().clone().unwrap();
                if !ui.active().is_some_and(|active| Rc::ptr_eq(&active, &doc)) {
                    return glib::ControlFlow::Continue;
                }
                if !rendered(&doc, &variant, &probe) {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(ui.window.upcast_ref(), "compare-rich-applied") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click_at(
                    &doc.rich.borrow().as_ref().unwrap().view,
                    60.,
                    110.,
                    &["ctrl+z"],
                );
            }
            7 => {
                let doc = source.borrow().clone().unwrap();
                if buffer_text(&doc.buffer) != original {
                    return glib::ControlFlow::Continue;
                }
                assert!(doc.is_rich_active());
                support::test_keys(&ui.window, &["ctrl+shift+z"]);
            }
            8 => {
                let doc = source.borrow().clone().unwrap();
                if buffer_text(&doc.buffer) != output {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&ui.window, &["ctrl+z"]);
            }
            _ => {
                let doc = source.borrow().clone().unwrap();
                if buffer_text(&doc.buffer) != original {
                    return glib::ControlFlow::Continue;
                }
                assert!(doc.is_rich_active());
                assert_eq!(std::fs::read_to_string(&left).unwrap(), original);
                assert_eq!(std::fs::read_to_string(&right).unwrap(), output);
                if !rendered(&doc, &variant, &probe) {
                    return glib::ControlFlow::Continue;
                }
                if variant == "image" {
                    assert_eq!(doc.rich.borrow().as_ref().unwrap().image_cache_metrics().0, 1);
                    assert_eq!(
                        std::fs::read(root.join("picture.png")).unwrap(),
                        include_bytes!("../../tests/fixtures/pixel-1.png")
                    );
                }
                if !support::try_capture(ui.window.upcast_ref(), "compare-rich-undone") {
                    return glib::ControlFlow::Continue;
                }
                eprintln!("DIFF_PICKER_SELFTEST PASS Rich {variant} native picker/preview/Apply, mode and WebView retained, complete exact CRLF/Unicode/hidden-reference/protected source, actual math/image rendering where present, one native Undo/Redo/Undo, no disk writes");
                crate::source_appearance::cleanup_schemes();
                std::process::exit(0);
            }
        }
        eprintln!("Rich comparison phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
