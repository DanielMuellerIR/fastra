use super::*;
use crate::{buffer_text, git_view as support};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
use webkit6::prelude::*;
thread_local! {static RUNNING:Cell<bool>=const{Cell::new(false)};}
const TEXT: &str =
    "# Appearance\n\nAlpha café 😀.\n\n![Image](theme.png)\n\n```mermaid\ngraph LR; A-->B\n```\n";
fn widgets(root: &impl IsA<gtk::Widget>) -> Vec<gtk::Widget> {
    fn walk(widget: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
        all.push(widget.clone());
        for child in crate::chrome::children(widget) {
            walk(&child, all);
        }
    }
    let mut all = Vec::new();
    walk(root.as_ref(), &mut all);
    all
}
fn source(doc: &Document) -> sourceview5::View {
    widgets(&doc.container)
        .into_iter()
        .find_map(|widget| widget.downcast::<sourceview5::View>().ok())
        .unwrap()
}
fn settings(app: &gtk::Application) -> gtk::Window {
    app.windows()
        .into_iter()
        .find(|window| window.widget_name() == "fastra-global-settings")
        .unwrap()
}
fn mode_button(app: &gtk::Application, mode: Mode) -> gtk::ToggleButton {
    let name = match mode {
        Mode::System => "system",
        Mode::Light => "light",
        Mode::Dark => "dark",
    };
    widgets(&settings(app))
        .into_iter()
        .find_map(|widget| {
            widget
                .downcast::<gtk::ToggleButton>()
                .ok()
                .filter(|button| button.widget_name() == format!("fastra-appearance-{name}"))
        })
        .unwrap()
}
const INSPECT:&str="return JSON.stringify({applied:window.fastraAppearanceApplied,bg:getComputedStyle(document.body).backgroundColor,fg:getComputedStyle(document.body).color,selection:getSelection().toString(),undo:document.queryCommandEnabled('undo'),source:window.fastraVisual?.markdown(),diagram:document.querySelector('.mermaid-render svg .node rect')?getComputedStyle(document.querySelector('.mermaid-render svg .node rect')).fill:null});";
fn inspect(view: &webkit6::WebView, result: Rc<RefCell<Option<serde_json::Value>>>) {
    view.call_async_javascript_function(
        INSPECT,
        None,
        None,
        None,
        None::<&gio::Cancellable>,
        move |value| {
            *result.borrow_mut() = Some(
                value
                    .ok()
                    .and_then(|value| serde_json::from_str(&value.to_str()).ok())
                    .unwrap_or(serde_json::Value::Null),
            );
        },
    );
}
fn selected(buffer: &gtk::TextBuffer) -> (i32, i32) {
    (
        buffer.cursor_position(),
        buffer.iter_at_mark(&buffer.selection_bound()).offset(),
    )
}
fn assert_source(doc: &Document, revision: u64, selection: (i32, i32), dark: bool) {
    assert_eq!(buffer_text(&doc.buffer), TEXT);
    assert_eq!(doc.revision.get(), revision);
    assert!(!doc.buffer.is_modified());
    assert!(!doc.buffer.can_undo());
    assert_eq!(selected(doc.buffer.upcast_ref()), selection);
    assert_eq!(
        doc.buffer.style_scheme().unwrap().id().as_str(),
        if dark { "fastra-dark" } else { "fastra-light" }
    );
}
pub(super) fn run(ui: Rc<Ui>) {
    if RUNNING.with(|running| running.replace(true)) {
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("appearance.md");
    let restore = std::env::var("FASTRA_APPEARANCE_PHASE").as_deref() == Ok("restore");
    let mode = std::env::var("FASTRA_APPEARANCE_SELFTEST").unwrap();
    if !restore {
        std::fs::write(&path, TEXT).unwrap();
        std::fs::write(root.join("rich.md"), TEXT).unwrap();
        gtk::gdk::MemoryTexture::new(
            120,
            50,
            gtk::gdk::MemoryFormat::R8g8b8a8,
            &glib::Bytes::from_owned([0u8, 100, 200, 255].repeat(120 * 50)),
            120 * 4,
        )
        .save_to_png(root.join("theme.png"))
        .unwrap();
    }
    if mode != "home" || restore {
        ui.load_path(path.clone());
    }
    support::test_size(ui.window.upcast_ref());
    let began = Instant::now();
    let pause = Cell::new(began);
    let phase = Cell::new(0);
    let revision = Cell::new(0);
    let selection = Cell::new((0, 0));
    let input = RefCell::new(None::<std::sync::mpsc::Receiver<()>>);
    let other = RefCell::new(None::<Rc<Ui>>);
    let replies: [Rc<RefCell<Option<serde_json::Value>>>; 2] =
        std::array::from_fn(|_| Rc::default());
    let baseline = RefCell::new(Vec::<serde_json::Value>::new());
    let expected = Cell::new(false);
    let lock = RefCell::new(None);
    let rich_text = RefCell::new(String::new());
    let rich_revision = Cell::new(0);
    let rich_baseline = RefCell::new(serde_json::Value::Null);
    let capture = RefCell::new(None::<std::sync::mpsc::Receiver<bool>>);
    glib::timeout_add_local(Duration::from_millis(70), move || {
        assert!(
            began.elapsed() < Duration::from_secs(65),
            "appearance phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if input
            .borrow()
            .as_ref()
            .is_some_and(|input| input.try_recv().is_err())
        {
            return glib::ControlFlow::Continue;
        }
        input.borrow_mut().take();
        let state = state();
        let app = ui.window.application().unwrap();
        if state.busy.get() || state.queued.get() {
            return glib::ControlFlow::Continue;
        }
        if !state.loaded.get() && mode != "corrupt" {
            return glib::ControlFlow::Continue;
        }
        if mode == "home" && !restore {
            match phase.get() {
                0 => {
                    assert!(ui
                        .active()
                        .is_some_and(|doc| crate::chrome::is_pristine(&doc)));
                    let gear = widgets(&ui.window)
                        .into_iter()
                        .find_map(|widget| {
                            widget.downcast::<gtk::Button>().ok().filter(|button| {
                                button.tooltip_text().as_deref()
                                    == Some(ui.lang.text("Einstellungen", "Settings"))
                            })
                        })
                        .unwrap();
                    *input.borrow_mut() = Some(support::test_input_completed(&gear, &[], true));
                    phase.set(1);
                    pause.set(Instant::now());
                }
                1 if pause.get().elapsed() > Duration::from_millis(350) => {
                    *input.borrow_mut() = Some(support::test_input_completed(
                        &mode_button(&app, Mode::Dark),
                        &[],
                        true,
                    ));
                    phase.set(2);
                    pause.set(Instant::now());
                }
                2 if pause.get().elapsed() > Duration::from_millis(350) => {
                    assert_eq!(store::load(&config_root().unwrap()).unwrap(), Mode::Dark);
                    assert!(support::try_capture(
                        &settings(&app),
                        "appearance-home-settings"
                    ));
                    println!("FASTRA_TOOL_SELFTEST_OK appearance-home");
                    app.quit();
                    return glib::ControlFlow::Break;
                }
                _ => {}
            }
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
                if mode == "corrupt" {
                    assert!(state.error.borrow().is_some());
                    app.activate_action("settings", None);
                    phase.set(90);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                if restore {
                    assert_eq!(state.mode.get(), Mode::Dark);
                    app.activate_action("settings", None);
                    phase.set(91);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                revision.set(doc.revision.get());
                doc.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                let second = crate::build(&app);
                second.load_path(root.join("rich.md"));
                *other.borrow_mut() = Some(second);
                ui.window.present();
                pause.set(Instant::now());
                phase.set(1);
            }
            1 if pause.get().elapsed() > Duration::from_millis(400) => {
                let second = other.borrow();
                let Some(rich_doc) = second
                    .as_ref()
                    .unwrap()
                    .active()
                    .filter(|doc| doc.name == "rich.md")
                else {
                    return glib::ControlFlow::Continue;
                };
                rich_doc
                    .rich_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                *input.borrow_mut() = Some(support::test_input_completed(
                    &source(&doc),
                    &["ctrl+Home", "ctrl+shift+End"],
                    true,
                ));
                phase.set(2);
                pause.set(Instant::now());
            }
            2 if pause.get().elapsed() > Duration::from_millis(350) => {
                selection.set(selected(doc.buffer.upcast_ref()));
                assert_ne!(selection.get().0, selection.get().1);
                let gear = widgets(&ui.window)
                    .into_iter()
                    .find_map(|widget| {
                        widget.downcast::<gtk::Button>().ok().filter(|button| {
                            button.tooltip_text().as_deref()
                                == Some(ui.lang.text("Einstellungen", "Settings"))
                        })
                    })
                    .unwrap();
                *input.borrow_mut() = Some(support::test_input_completed(&gear, &[], true));
                phase.set(3);
                pause.set(Instant::now());
            }
            3 if pause.get().elapsed() > Duration::from_millis(350) => {
                let button = mode_button(&app, Mode::Light);
                *input.borrow_mut() = Some(support::test_input_completed(&button, &[], true));
                expected.set(false);
                phase.set(4);
                pause.set(Instant::now());
            }
            4 if pause.get().elapsed() > Duration::from_millis(350) => {
                assert_eq!(
                    state.mode.get(),
                    if expected.get() {
                        Mode::Dark
                    } else {
                        Mode::Light
                    }
                );
                assert_source(&doc, revision.get(), selection.get(), expected.get());
                let color = ui.window.color();
                assert_eq!(color.red() > 0.7, expected.get());
                let preview = doc.markdown.borrow().clone().unwrap();
                let second = other.borrow();
                let rich_doc = second.as_ref().unwrap().active().unwrap();
                let Some(rich) = rich_doc
                    .rich
                    .borrow()
                    .clone()
                    .filter(|rich| rich.ready_for_saved_source())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(rich.active.get());
                inspect(&preview.view, replies[0].clone());
                inspect(&rich.view, replies[1].clone());
                phase.set(5);
            }
            5 if replies.iter().all(|reply| reply.borrow().is_some()) => {
                let values: Vec<_> = replies
                    .iter()
                    .map(|reply| reply.borrow_mut().take().unwrap())
                    .collect();
                if values
                    .iter()
                    .any(|value| value["applied"].as_bool() != Some(expected.get()))
                    || values.iter().any(|value| value["diagram"].is_null())
                {
                    pause.set(Instant::now());
                    phase.set(4);
                    return glib::ControlFlow::Continue;
                }
                for value in &values {
                    assert_eq!(
                        value["bg"].as_str(),
                        Some(if expected.get() {
                            "rgb(23, 23, 23)"
                        } else {
                            "rgb(255, 255, 255)"
                        })
                    );
                }
                eprintln!("APPEARANCE dark={} DOM={values:?}", expected.get());
                if !expected.get() {
                    *baseline.borrow_mut() = values;
                    assert!(support::try_capture(&settings(&app), "appearance-light"));
                    let choice = widgets(&settings(&app))
                        .into_iter()
                        .find_map(|widget| {
                            widget
                                .downcast::<gtk::DropDown>()
                                .ok()
                                .filter(|choice| choice.widget_name() == "fastra-source-font")
                        })
                        .unwrap();
                    *input.borrow_mut() = Some(support::test_input_completed(&choice, &[], true));
                    pause.set(Instant::now());
                    phase.set(51);
                } else {
                    assert_ne!(
                        values[0]["diagram"],
                        baseline.borrow()[0]["diagram"],
                        "existing diagram must really change its palette"
                    );
                    assert_ne!(values[1]["diagram"], baseline.borrow()[1]["diagram"], "Rich diagram must change its palette in place");
                    assert_eq!(values[1]["source"], baseline.borrow()[1]["source"]);
                    assert_eq!(values[1]["undo"], baseline.borrow()[1]["undo"]);
                    assert!(support::try_capture(&settings(&app), "appearance-dark"));
                    assert!(support::try_capture(
                        ui.window.upcast_ref(),
                        "appearance-preview-dark"
                    ));
                    assert!(support::try_capture(
                        other.borrow().as_ref().unwrap().window.upcast_ref(),
                        "appearance-rich-dark"
                    ));
                    *input.borrow_mut() = Some(support::test_input_completed(
                        &mode_button(&app, Mode::System),
                        &[],
                        true,
                    ));
                    phase.set(6);
                    pause.set(Instant::now());
                }
            }
            51 if pause.get().elapsed() > Duration::from_millis(300) => {
                let popup = widgets(&settings(&app))
                    .into_iter()
                    .find_map(|widget| {
                        widget
                            .downcast::<gtk::Popover>()
                            .ok()
                            .filter(|popup| popup.is_mapped())
                    })
                    .unwrap();
                assert!(
                    popup.child().unwrap().color().red() < 0.7,
                    "light mode popup must keep dark readable text even on a dark desktop"
                );
                if !support::try_capture_x11(&popup, "appearance-light-popup", &capture) {
                    return glib::ControlFlow::Continue;
                }
                *input.borrow_mut() =
                    Some(support::test_input_completed(&popup, &["Escape"], false));
                phase.set(52);
                pause.set(Instant::now());
            }
            52 if pause.get().elapsed() > Duration::from_millis(300) => {
                *input.borrow_mut() = Some(support::test_input_completed(
                    &mode_button(&app, Mode::Dark),
                    &[],
                    true,
                ));
                expected.set(true);
                phase.set(4);
                pause.set(Instant::now());
            }
            6 if pause.get().elapsed() > Duration::from_millis(350) => {
                assert_eq!(state.mode.get(), Mode::System);
                let settings = gtk::Settings::default().unwrap();
                settings.set_gtk_theme_name(Some("Adwaita"));
                settings.set_gtk_application_prefer_dark_theme(false);
                phase.set(7);
                pause.set(Instant::now());
            }
            7 if pause.get().elapsed() > Duration::from_millis(350) => {
                if std::env::var("GTK_THEME").is_ok_and(|theme| theme.ends_with(":dark")) {
                    assert!(super::dark(&gtk::Settings::default().unwrap()));
                } else {
                    assert!(!super::dark(&gtk::Settings::default().unwrap()));
                    assert_source(&doc, revision.get(), selection.get(), false);
                }
                gtk::Settings::default()
                    .unwrap()
                    .set_gtk_application_prefer_dark_theme(true);
                phase.set(8);
                pause.set(Instant::now());
            }
            8 if pause.get().elapsed() > Duration::from_millis(350) => {
                assert_source(&doc, revision.get(), selection.get(), true);
                *input.borrow_mut() = Some(support::test_input_completed(
                    &mode_button(&app, Mode::Dark),
                    &[],
                    true,
                ));
                phase.set(9);
                pause.set(Instant::now());
            }
            9 if pause.get().elapsed() > Duration::from_millis(350) => {
                assert_eq!(store::load(&config_root().unwrap()).unwrap(), Mode::Dark);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), TEXT);
                if mode == "busy" {
                    *lock.borrow_mut() = Some(
                        super::super::store::Store::open(&config_root().unwrap())
                            .unwrap()
                            .lock()
                            .unwrap(),
                    );
                    *input.borrow_mut() = Some(support::test_input_completed(
                        &mode_button(&app, Mode::Light),
                        &[],
                        true,
                    ));
                    phase.set(10);
                } else {
                    phase.set(12);
                }
                pause.set(Instant::now());
            }
            10 if state.error.borrow().is_some() => {
                assert_eq!(store::load(&config_root().unwrap()).unwrap(), Mode::Dark);
                assert!(support::try_capture(
                    &settings(&app),
                    "appearance-save-error"
                ));
                lock.borrow_mut().take();
                let retry = widgets(&settings(&app))
                    .into_iter()
                    .find_map(|widget| {
                        widget.downcast::<gtk::Button>().ok().filter(|button| {
                            button.is_mapped()
                                && button.label().as_deref()
                                    == Some(ui.lang.text("Erneut versuchen", "Retry"))
                        })
                    })
                    .unwrap();
                *input.borrow_mut() = Some(support::test_input_completed(&retry, &[], true));
                phase.set(11);
            }
            11 => {
                assert!(state.error.borrow().is_none());
                assert_eq!(store::load(&config_root().unwrap()).unwrap(), Mode::Light);
                *input.borrow_mut() = Some(support::test_input_completed(
                    &mode_button(&app, Mode::Dark),
                    &[],
                    true,
                ));
                phase.set(12);
                pause.set(Instant::now());
            }
            12 => {
                settings(&app).close();
                let second = other.borrow();
                let second = second.as_ref().unwrap();
                second.window.present();
                let rich = second.active().unwrap().rich.borrow().clone().unwrap();
                assert!(rich.view.grab_focus());
                let reply = replies[1].clone();
                rich.view.call_async_javascript_function("const root=document.getElementById('fastra-visual');root.focus();const p=[...root.querySelectorAll('p')].find(p=>p.textContent.includes('Alpha'));const range=document.createRange();range.selectNodeContents(p);range.collapse(false);getSelection().removeAllRanges();getSelection().addRange(range);root.focus();return JSON.stringify(true);",None,None,None,None::<&gio::Cancellable>,move|value|{*reply.borrow_mut()=Some(serde_json::json!(value.is_ok()));});
                phase.set(13);
                pause.set(Instant::now());
            }
            13 if replies[1].borrow().is_some() => {
                replies[1].borrow_mut().take();
                let second = other.borrow();
                let rich = second
                    .as_ref()
                    .unwrap()
                    .active()
                    .unwrap()
                    .rich
                    .borrow()
                    .clone()
                    .unwrap();
                *input.borrow_mut() = Some(support::test_type(&rich.view, " edited"));
                phase.set(14);
                pause.set(Instant::now());
            }
            14 => {
                let second = other.borrow();
                let second = second.as_ref().unwrap();
                let rich_doc = second.active().unwrap();
                let rich = rich_doc.rich.borrow().clone().unwrap();
                if !buffer_text(&rich_doc.buffer).contains(" edited")
                    || !rich.ready_for_saved_source()
                {
                    assert!(
                        pause.get().elapsed() < Duration::from_secs(5),
                        "native Rich insertion not received; current source={:?}, ready={}",
                        buffer_text(&rich_doc.buffer),
                        rich.ready_for_saved_source()
                    );
                    return glib::ControlFlow::Continue;
                }
                *rich_text.borrow_mut() = buffer_text(&rich_doc.buffer);
                rich_revision.set(rich_doc.revision.get());
                assert!(rich_doc.buffer.is_modified());
                let reply = replies[1].clone();
                rich.view.call_async_javascript_function("const root=document.getElementById('fastra-visual'),p=[...root.querySelectorAll('p')].find(p=>p.textContent.includes('Alpha')),range=document.createRange();range.setStart(p.firstChild,0);range.setEnd(p.firstChild,5);getSelection().removeAllRanges();getSelection().addRange(range);return JSON.stringify(true);",None,None,None,None::<&gio::Cancellable>,move|value|{*reply.borrow_mut()=Some(serde_json::json!(value.is_ok()));});
                phase.set(15);
                pause.set(Instant::now());
            }
            15 if replies[1].borrow().is_some() => {
                replies[1].borrow_mut().take();
                let second = other.borrow();
                let rich = second
                    .as_ref()
                    .unwrap()
                    .active()
                    .unwrap()
                    .rich
                    .borrow()
                    .clone()
                    .unwrap();
                inspect(&rich.view, replies[1].clone());
                phase.set(16);
            }
            16 if replies[1].borrow().is_some() => {
                let value = replies[1].borrow_mut().take().unwrap();
                assert_eq!(value["selection"], "Alpha");
                assert_eq!(value["undo"], true);
                *rich_baseline.borrow_mut() = value;
                app.activate_action("settings", None);
                phase.set(17);
                pause.set(Instant::now());
            }
            17 if pause.get().elapsed() > Duration::from_millis(350) => {
                *input.borrow_mut() = Some(support::test_input_completed(
                    &mode_button(&app, Mode::Light),
                    &[],
                    true,
                ));
                expected.set(false);
                phase.set(18);
                pause.set(Instant::now());
            }
            18 if pause.get().elapsed() > Duration::from_millis(350) => {
                let second = other.borrow();
                let rich = second
                    .as_ref()
                    .unwrap()
                    .active()
                    .unwrap()
                    .rich
                    .borrow()
                    .clone()
                    .unwrap();
                inspect(&rich.view, replies[1].clone());
                phase.set(19);
            }
            19 if replies[1].borrow().is_some() => {
                let value = replies[1].borrow_mut().take().unwrap();
                if value["applied"].as_bool() != Some(expected.get()) {
                    phase.set(18);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(value["source"], rich_baseline.borrow()["source"]);
                assert_eq!(value["selection"], "Alpha");
                assert_eq!(value["undo"], true);
                let second = other.borrow();
                let rich_doc = second.as_ref().unwrap().active().unwrap();
                assert_eq!(buffer_text(&rich_doc.buffer), *rich_text.borrow());
                assert_eq!(rich_doc.revision.get(), rich_revision.get());
                assert!(rich_doc.buffer.is_modified());
                if !expected.get() {
                    *input.borrow_mut() = Some(support::test_input_completed(
                        &mode_button(&app, Mode::Dark),
                        &[],
                        true,
                    ));
                    expected.set(true);
                    phase.set(18);
                    pause.set(Instant::now());
                } else {
                    settings(&app).close();
                    let rich = rich_doc.rich.borrow().clone().unwrap();
                    let reply = replies[1].clone();
                    rich.view.call_async_javascript_function("document.getElementById('fastra-visual').focus();document.execCommand('undo');window.fastraVisual.flush();return JSON.stringify(true);",None,None,None,None::<&gio::Cancellable>,move|value|{*reply.borrow_mut()=Some(serde_json::json!(value.is_ok()));});
                    phase.set(20);
                    pause.set(Instant::now());
                }
            }
            20 => {
                let second = other.borrow();
                let rich_doc = second.as_ref().unwrap().active().unwrap();
                if buffer_text(&rich_doc.buffer) != TEXT {
                    assert!(
                        pause.get().elapsed() < Duration::from_secs(5),
                        "native Rich undo did not restore source: {:?}",
                        buffer_text(&rich_doc.buffer)
                    );
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(root.join("rich.md")).unwrap(), TEXT);
                assert_eq!(store::load(&config_root().unwrap()).unwrap(), Mode::Dark);
                println!("FASTRA_TOOL_SELFTEST_OK appearance native-rich-edit selection undo persistence");
                app.quit();
                return glib::ControlFlow::Break;
            }
            90 if pause.get().elapsed() > Duration::from_millis(350) => {
                assert!(!mode_button(&app, Mode::Dark).is_sensitive());
                assert!(support::try_capture(&settings(&app), "appearance-corrupt"));
                println!("FASTRA_TOOL_SELFTEST_OK appearance-corrupt");
                app.quit();
                return glib::ControlFlow::Break;
            }
            91 if pause.get().elapsed() > Duration::from_millis(350) => {
                assert!(mode_button(&app, Mode::Dark).is_active());
                assert!(ui.window.color().red() > 0.7);
                assert!(support::try_capture(&settings(&app), "appearance-restored"));
                println!("FASTRA_TOOL_SELFTEST_OK appearance-restored");
                app.quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
