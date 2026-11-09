use crate::{buffer_text, git_view as support, Ui};
use gtk::{glib, prelude::*};
use serde_json::Value;
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::Rc,
    time::{Duration, Instant},
};
const INSPECT: &str = r#"await document.fonts.ready;
const p=document.querySelector('p'),bold=document.querySelector('strong'),italic=document.querySelector('em');
return JSON.stringify({ready:!!p,family:p?getComputedStyle(p).fontFamily:null,
 background:getComputedStyle(document.body).backgroundColor,
 bold:bold?getComputedStyle(bold).fontWeight:null,italic:italic?getComputedStyle(italic).fontStyle:null,
 faces:Array.from(document.fonts).filter(f=>f.family.replaceAll(/["']/g,'')==='Fastra UI').map(f=>({style:f.style,status:f.status,weight:f.weight})),
 violations:window.fastraPreviewViolations||[]});"#;
fn assert_web(value: &Value) {
    assert_eq!(value["ready"], true, "rendered paragraph: {value}");
    assert!(value["family"].as_str().unwrap().contains("Fastra UI"));
    let dark = std::env::var("GTK_THEME").is_ok_and(|theme| theme.ends_with(":dark"));
    assert_eq!(
        value["background"],
        if dark {
            "rgb(23, 23, 23)"
        } else {
            "rgb(255, 255, 255)"
        },
        "actual WebKit theme: {value}"
    );
    assert_eq!(value["bold"], "700");
    assert_eq!(value["italic"], "italic");
    let faces = value["faces"].as_array().unwrap();
    assert_eq!(faces.len(), 2, "both bundled faces: {value}");
    for style in ["normal", "italic"] {
        assert!(
            faces
                .iter()
                .any(|face| face["style"] == style && face["status"] == "loaded"),
            "native loaded {style} face: {value}"
        );
    }
    assert!(
        value["violations"].as_array().unwrap().is_empty(),
        "strict offline CSP: {value}"
    );
}
fn face(label: &gtk::Label) -> Option<gtk::pango::FontDescription> {
    label
        .layout()
        .iter()
        .run_readonly()
        .map(|run| run.item().analysis().font().describe())
}
fn control(widget: &gtk::Widget, tooltip: &str) -> Option<gtk::Button> {
    if let Some(button) = widget.downcast_ref::<gtk::Button>().filter(|button| {
        button.is_mapped()
            && button.is_sensitive()
            && button.tooltip_text().as_deref() == Some(tooltip)
    }) {
        return Some(button.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(button) = control(&widget, tooltip) {
            return Some(button);
        }
        child = widget.next_sibling();
    }
    None
}
fn visible_label(widget: &gtk::Widget) -> Option<gtk::Label> {
    if let Some(label) = widget
        .downcast_ref::<gtk::Label>()
        .filter(|label| label.is_mapped() && label.width() > 0 && !label.text().is_empty())
    {
        return Some(label.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(label) = visible_label(&widget) {
            return Some(label);
        }
        child = widget.next_sibling();
    }
    None
}
fn semibold(widget: &gtk::Widget) -> Option<gtk::pango::FontDescription> {
    if let Some(font) = widget
        .downcast_ref::<gtk::Label>()
        .filter(|label| label.is_mapped())
        .and_then(face)
        .filter(|font| {
            font.family().as_deref() == Some("Inter Variable")
                && font.weight() == gtk::pango::Weight::Semibold
        })
    {
        return Some(font);
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(font) = semibold(&widget) {
            return Some(font);
        }
        child = widget.next_sibling();
    }
    None
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("fonts.md");
    let original="# Fonts\n\nRegular **UI Bold** *UI Italic* and ***UI Bold Italic***. café e\u{301} 界 👩🏽‍💻.\n";
    std::fs::write(&path, original).unwrap();
    ui.load_path(path.clone());
    let response = Rc::new(RefCell::new(None::<Value>));
    let requested = Cell::new(false);
    let inspected = Cell::new(false);
    let preview_prepared = Cell::new(false);
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    support::test_size(ui.window.upcast_ref());
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            began.elapsed() < Duration::from_secs(35),
            "font native phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(300) {
            return glib::ControlFlow::Continue;
        }
        let Some(doc) = ui
            .active()
            .filter(|doc| doc.disk_path().as_ref() == Some(&path))
        else {
            return glib::ControlFlow::Continue;
        };
        match phase.get() {
            0 => {
                let Some(font) = visible_label(&crate::chrome::tab_header(&ui, &doc))
                    .as_ref()
                    .and_then(face)
                else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    font.family().as_deref(),
                    Some("Inter Variable"),
                    "actual GTK tab glyph font: {font:?}"
                );
                assert_eq!(font.weight(), gtk::pango::Weight::Normal);
                let Some(toggle) = control(
                    ui.window.upcast_ref(),
                    ui.lang.text(
                        "Markdown-Vorschau ein-/ausblenden",
                        "Toggle Markdown preview",
                    ),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                eprintln!(
                    "actual GTK regular: {} {:?}",
                    font.family().unwrap(),
                    font.weight()
                );
                if doc.markdown_toggle.borrow().as_ref().unwrap().is_active()
                    && !preview_prepared.replace(true)
                {
                    support::test_click(&toggle, &[]);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&toggle, &[]);
            }
            1 => {
                let Some(preview) = doc
                    .markdown
                    .borrow()
                    .clone()
                    .filter(|preview| preview.view.is_mapped())
                else {
                    return glib::ControlFlow::Continue;
                };
                if !inspected.get() {
                    if !requested.replace(true) {
                        let response = response.clone();
                        preview.inspect(INSPECT, move |value| *response.borrow_mut() = Some(value));
                    }
                    let Some(value) = response.borrow_mut().take() else {
                        return glib::ControlFlow::Continue;
                    };
                    if value["ready"] != true {
                        requested.set(false);
                        return glib::ControlFlow::Continue;
                    }
                    assert_web(&value);
                    eprintln!("actual WebKit preview faces: {value}");
                    inspected.set(true);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(ui.window.upcast_ref(), "font-preview") {
                    requested.set(false);
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&ui.window, &["ctrl+f"]);
            }
            2 => {
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                if !window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                let Some(font) = semibold(window.upcast_ref()) else {
                    assert!(
                        pause.get().elapsed() < Duration::from_secs(3),
                        "actual GTK semibold title"
                    );
                    return glib::ControlFlow::Continue;
                };
                eprintln!(
                    "actual GTK semibold: {} {:?}",
                    font.family().unwrap(),
                    font.weight()
                );
                if !support::try_capture(&window, "font-search") {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&window, &["Escape"]);
            }
            3 => {
                let toggle = doc.rich_toggle.borrow().clone().unwrap();
                if !toggle.is_mapped() || !toggle.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                requested.set(false);
                inspected.set(false);
                support::test_click(&toggle, &[]);
            }
            4 => {
                let Some(editor) = doc
                    .rich
                    .borrow()
                    .clone()
                    .filter(|editor| editor.active.get() && editor.ready_for_saved_source())
                else {
                    return glib::ControlFlow::Continue;
                };
                if !inspected.get() {
                    if !requested.replace(true) {
                        let response = response.clone();
                        editor.evaluate(INSPECT, move |value| {
                            *response.borrow_mut() =
                                Some(value.expect("native Rich font inspection"))
                        });
                    }
                    let Some(value) = response.borrow_mut().take() else {
                        return glib::ControlFlow::Continue;
                    };
                    assert_web(&value);
                    eprintln!("actual WebKit Rich faces: {value}");
                    inspected.set(true);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(ui.window.upcast_ref(), "font-rich") {
                    requested.set(false);
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), original);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                assert!(!doc.buffer.is_modified());
                eprintln!("FONTS_SELFTEST PASS actual GTK regular/600 glyph fonts Inter Variable, native preview/Rich normal+italic WOFF2 loaded with strict offline CSP, native toggles/search, unchanged source/disk");
                crate::source_appearance::cleanup_schemes();
                super::cleanup();
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
