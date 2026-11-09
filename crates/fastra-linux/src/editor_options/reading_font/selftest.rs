use super::*;
use crate::{buffer_text, git_view as support};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
thread_local! {static RUNNING:Cell<bool>=const{Cell::new(false)};}
fn widgets(root: &impl IsA<gtk::Widget>) -> Vec<gtk::Widget> {
    fn walk(root: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
        all.push(root.clone());
        for child in crate::chrome::children(root) {
            walk(&child, all);
        }
    }
    let mut all = Vec::new();
    walk(root.as_ref(), &mut all);
    all
}
fn settings(app: &gtk::Application) -> gtk::Window {
    app.windows()
        .into_iter()
        .find(|window| window.widget_name() == "fastra-global-settings")
        .unwrap()
}
fn choice(app: &gtk::Application) -> gtk::DropDown {
    widgets(&settings(app))
        .into_iter()
        .find_map(|widget| {
            widget
                .downcast::<gtk::DropDown>()
                .ok()
                .filter(|choice| choice.widget_name() == "fastra-reading-font")
        })
        .unwrap()
}
fn reveal(widget: &impl IsA<gtk::Widget>) {
    let widget = widget.as_ref();
    let mut parent = widget.parent();
    while let Some(current) = parent {
        if let Some(scroll) = current.downcast_ref::<gtk::ScrolledWindow>() {
            let bounds = widget.compute_bounds(&scroll.child().unwrap()).unwrap();
            scroll.vadjustment().set_value(f64::from(bounds.y()) - 80.);
            break;
        }
        parent = current.parent();
    }
}
fn inspect(view: &webkit6::WebView, reply: Rc<RefCell<Option<serde_json::Value>>>) {
    view.call_async_javascript_function(r#"await document.fonts.ready;const s=getComputedStyle(document.body),c=document.createElement('canvas').getContext('2d');const width=family=>{c.font=`${s.fontStyle} ${s.fontWeight} ${s.fontSize} ${family}`;return c.measureText('iiiiMMMMWWW readable café').width;};return JSON.stringify({applied:window.fastraReadingFontApplied,font:s.fontFamily,size:s.fontSize,weight:s.fontWeight,style:s.fontStyle,width:width(s.fontFamily),fallback:width('"Fastra UI",sans-serif'),fonts:[...document.fonts].filter(f=>f.status==='loaded').map(f=>f.family),image:document.querySelector('img')?.getBoundingClientRect().width,token:document.documentElement.dataset.fastraRender,scroll:scrollY,selection:getSelection().toString(),undo:document.queryCommandEnabled('undo'),source:window.fastraVisual?.markdown()});"#,None,None,None,None::<&gio::Cancellable>,move|value|{*reply.borrow_mut()=Some(value.ok().and_then(|value|serde_json::from_str(&value.to_str()).ok()).unwrap_or_default());});
}
pub(super) fn run(ui: Rc<Ui>) {
    if RUNNING.with(|running| running.replace(true)) {
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("reading.md");
    let text = format!(
        "# Reading font\n\nAlpha café 😀.\n\n![Image](font.png)\n\n{}",
        "Paragraph wide WWW narrow iii.\n\n".repeat(50)
    );
    let restore = std::env::var("FASTRA_READING_FONT_PHASE").as_deref() == Ok("restore");
    let mode = std::env::var("FASTRA_READING_FONT_SELFTEST").unwrap();
    if !restore {
        std::fs::write(&path, &text).unwrap();
        std::fs::write(root.join("rich.md"), &text).unwrap();
        gtk::gdk::MemoryTexture::new(
            120,
            50,
            gtk::gdk::MemoryFormat::R8g8b8a8,
            &glib::Bytes::from_owned([60u8, 100, 210, 255].repeat(120 * 50)),
            120 * 4,
        )
        .save_to_png(root.join("font.png"))
        .unwrap();
    }
    ui.load_path(path.clone());
    support::test_size(ui.window.upcast_ref());
    let began = Instant::now();
    let pause = Cell::new(began);
    let phase = Cell::new(0);
    let step = Cell::new(0usize);
    let last_phase = Cell::new(u32::MAX);
    let input = RefCell::new(None::<std::sync::mpsc::Receiver<()>>);
    let other = RefCell::new(None::<Rc<Ui>>);
    let replies: [Rc<RefCell<Option<serde_json::Value>>>; 2] =
        std::array::from_fn(|_| Rc::default());
    let base = RefCell::new(Vec::<serde_json::Value>::new());
    let rich_text = RefCell::new(String::new());
    let rich_revision = Cell::new(0);
    let revision = Cell::new(0);
    let selection = Cell::new((0, 0));
    let lock = RefCell::new(None);
    let choices = RefCell::new(Vec::<usize>::new());
    glib::timeout_add_local(Duration::from_millis(70), move || {
        if last_phase.replace(phase.get()) != phase.get() {
            eprintln!("READING phase {} step {}", phase.get(), step.get());
        }
        assert!(
            began.elapsed() < Duration::from_secs(70),
            "reading font phase{} step{}: {}",
            phase.get(),
            step.get(),
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
        let state = state(&ui.window.pango_context());
        let app = ui.window.application().unwrap();
        if state.busy.get() || state.queued.get() {
            return glib::ControlFlow::Continue;
        }
        if !state.loaded.get() && mode != "corrupt" {
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
                app.activate_action("settings", None);
                if mode == "corrupt" || mode == "missing" {
                    phase.set(90);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                if restore {
                    assert_eq!(
                        state.face.borrow().as_ref(),
                        Some(&std::fs::read_to_string(root.join("reading-face.txt")).unwrap())
                    );
                    phase.set(91);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                for (family, weight, style) in [
                    ("DejaVu Sans", pango::Weight::Normal, pango::Style::Normal),
                    (
                        "Inter Variable",
                        pango::Weight::Normal,
                        pango::Style::Normal,
                    ),
                    ("Sora", pango::Weight::Semibold, pango::Style::Normal),
                    ("DejaVu Sans", pango::Weight::Bold, pango::Style::Italic),
                ] {
                    let index = state
                        .faces
                        .iter()
                        .position(|face| {
                            face.description.family().as_deref() == Some(family)
                                && face.description.weight() == weight
                                && face.description.style() == style
                        })
                        .unwrap_or_else(|| {
                            panic!(
                                "missing fixture {family} {weight:?} {style:?}; faces={:?}",
                                state.faces.iter().map(|f| &f.name).collect::<Vec<_>>()
                            )
                        });
                    choices.borrow_mut().push(index + 1);
                }
                doc.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                revision.set(doc.revision.get());
                let a = doc.buffer.iter_at_offset(3);
                let b = doc.buffer.iter_at_offset(12);
                doc.buffer.select_range(&a, &b);
                selection.set((
                    doc.buffer.cursor_position(),
                    doc.buffer
                        .iter_at_mark(&doc.buffer.selection_bound())
                        .offset(),
                ));
                let second = crate::build(&app);
                second.load_path(root.join("rich.md"));
                *other.borrow_mut() = Some(second);
                pause.set(Instant::now());
                phase.set(1);
            }
            1 if pause.get().elapsed() > Duration::from_millis(350) => {
                let other = other.borrow();
                let second = other.as_ref().unwrap();
                let Some(doc) = second.active().filter(|doc| doc.name == "rich.md") else {
                    return glib::ControlFlow::Continue;
                };
                doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
                pause.set(Instant::now());
                phase.set(2);
            }
            2 => {
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
                let reply = replies[1].clone();
                rich.view.call_async_javascript_function("const root=document.getElementById('fastra-visual'),p=[...root.querySelectorAll('p')].find(p=>p.textContent.includes('Alpha')),r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);root.focus();return JSON.stringify(true);",None,None,None,None::<&gio::Cancellable>,move|value|{*reply.borrow_mut()=Some(serde_json::json!(value.is_ok()));});
                phase.set(3);
            }
            3 if replies[1].borrow().is_some() => {
                replies[1].borrow_mut().take();
                settings(&app).close();
                pause.set(Instant::now());
                phase.set(31);
            }
            31 if pause.get().elapsed() > Duration::from_millis(300) => {
                let second = other.borrow();
                second.as_ref().unwrap().window.present();
                let rich = second
                    .as_ref()
                    .unwrap()
                    .active()
                    .unwrap()
                    .rich
                    .borrow()
                    .clone()
                    .unwrap();
                assert!(rich.view.grab_focus());
                *input.borrow_mut() = Some(support::test_type(&rich.view, " edited"));
                pause.set(Instant::now());
                phase.set(4);
            }
            4 => {
                let second = other.borrow();
                let rich_doc = second.as_ref().unwrap().active().unwrap();
                if !buffer_text(&rich_doc.buffer).contains(" edited")
                    || !rich_doc
                        .rich
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .ready_for_saved_source()
                {
                    assert!(
                        pause.get().elapsed() < Duration::from_secs(5),
                        "native Rich typing missing: {}",
                        buffer_text(&rich_doc.buffer)
                    );
                    return glib::ControlFlow::Continue;
                }
                *rich_text.borrow_mut() = buffer_text(&rich_doc.buffer);
                rich_revision.set(rich_doc.revision.get());
                let rich = rich_doc.rich.borrow().clone().unwrap();
                let reply = replies[1].clone();
                rich.view.call_async_javascript_function("const p=[...document.querySelectorAll('#fastra-visual p')].find(p=>p.textContent.includes('Alpha')),r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,5);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",None,None,None,None::<&gio::Cancellable>,move|value|{*reply.borrow_mut()=Some(serde_json::json!(value.is_ok()));});
                phase.set(5);
            }
            5 if replies[1].borrow().is_some() => {
                replies[1].borrow_mut().take();
                let preview = doc.markdown.borrow().clone().unwrap();
                preview.view.evaluate_javascript(
                    "window.scrollTo(0,200)",
                    None,
                    None,
                    None::<&gio::Cancellable>,
                    |_| {},
                );
                let rich = other
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .active()
                    .unwrap()
                    .rich
                    .borrow()
                    .clone()
                    .unwrap();
                inspect(&preview.view, replies[0].clone());
                inspect(&rich.view, replies[1].clone());
                phase.set(6);
            }
            6 if replies.iter().all(|r| r.borrow().is_some()) => {
                let values: Vec<_> = replies
                    .iter()
                    .map(|r| r.borrow_mut().take().unwrap())
                    .collect();
                if values
                    .iter()
                    .any(|v| v["applied"].is_null() || v["image"] != 120.)
                {
                    phase.set(5);
                    *replies[1].borrow_mut() = Some(serde_json::json!(true));
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    values[0]["scroll"].as_f64().unwrap() > 0.,
                    "fixture must really scroll before changing fonts"
                );
                assert_eq!(values[1]["selection"], "Alpha");
                assert_eq!(values[1]["undo"], true);
                assert!(values.iter().all(|v| v["size"] == "14px"));
                *base.borrow_mut() = values;
                app.activate_action("settings", None);
                pause.set(Instant::now());
                phase.set(7);
            }
            7 if pause.get().elapsed() > Duration::from_millis(300) => {
                let choice = choice(&app);
                reveal(&choice);
                pause.set(Instant::now());
                phase.set(71);
            }
            71 if pause.get().elapsed() > Duration::from_millis(250) => {
                let choice = choice(&app);
                *input.borrow_mut() = Some(support::test_input_completed(&choice, &[], true));
                phase.set(8);
            }
            8 => {
                let index = choices.borrow()[step.get()];
                let mut keys = vec!["Home"];
                keys.extend(std::iter::repeat_n("Down", index));
                keys.push("Return");
                if mode == "busy" && step.get() == 0 {
                    *lock.borrow_mut() = Some(
                        super::super::store::Store::open(&config_root().unwrap())
                            .unwrap()
                            .wait_lock()
                            .unwrap(),
                    );
                }
                *input.borrow_mut() =
                    Some(support::test_input_completed(&settings(&app), &keys, false));
                pause.set(Instant::now());
                phase.set(9);
            }
            9 if pause.get().elapsed() > Duration::from_millis(250) => {
                if mode == "busy" && lock.borrow().is_some() {
                    assert!(state.error.borrow().is_some());
                    assert!(!super::pending());
                    assert!(state.hold.borrow().is_none());
                    assert!(font::store::load_named(&config_root().unwrap(), FILE)
                        .unwrap()
                        .face
                        .is_none());
                    if !support::try_capture(&settings(&app), "reading-font-save-error") {
                        return glib::ControlFlow::Continue;
                    }
                    lock.borrow_mut().take();
                    let retry = widgets(&settings(&app))
                        .into_iter()
                        .find_map(|w| {
                            w.downcast::<gtk::Button>()
                                .ok()
                                .filter(|b| b.widget_name() == "fastra-reading-font-retry")
                        })
                        .unwrap();
                    reveal(&retry);
                    pause.set(Instant::now());
                    phase.set(95);
                    return glib::ControlFlow::Continue;
                }
                let expected = &state.faces[choices.borrow()[step.get()] - 1];
                assert_eq!(state.face.borrow().as_ref(), Some(&expected.name));
                assert_eq!(
                    font::store::load_named(&config_root().unwrap(), FILE)
                        .unwrap()
                        .face,
                    *state.face.borrow()
                );
                assert!(state.error.borrow().is_none());
                assert!(state.hold.borrow().is_none());
                inspect(
                    &doc.markdown.borrow().as_ref().unwrap().view,
                    replies[0].clone(),
                );
                inspect(
                    &other
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .active()
                        .unwrap()
                        .rich
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .view,
                    replies[1].clone(),
                );
                phase.set(10);
            }
            10 if replies.iter().all(|r| r.borrow().is_some()) => {
                if !support::try_capture(
                    &settings(&app),
                    &format!("reading-font-settings-{}", step.get()),
                ) {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(
                    ui.window.upcast_ref(),
                    &format!("reading-font-preview-{}", step.get()),
                ) {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(
                    other.borrow().as_ref().unwrap().window.upcast_ref(),
                    &format!("reading-font-rich-{}", step.get()),
                ) {
                    return glib::ControlFlow::Continue;
                }
                let values: Vec<_> = replies
                    .iter()
                    .map(|r| r.borrow_mut().take().unwrap())
                    .collect();
                let expected = &state.faces[choices.borrow()[step.get()] - 1];
                let family = expected.description.family().unwrap();
                let css = font::face_css(
                    "body",
                    Some(&expected.description),
                    "'Fastra UI',system-ui,sans-serif",
                );
                if values
                    .iter()
                    .any(|v| v["applied"].as_str() != Some(css.as_str()))
                {
                    phase.set(9);
                    return glib::ControlFlow::Continue;
                }
                eprintln!("READING FACE {} metrics={:?}", expected.name, values.iter().map(|v|serde_json::json!({"font":v["font"],"weight":v["weight"],"style":v["style"],"size":v["size"],"width":v["width"],"fallback":v["fallback"],"image":v["image"],"scroll":v["scroll"],"fonts":v["fonts"]})).collect::<Vec<_>>());
                for (i, value) in values.iter().enumerate() {
                    assert!(value["font"].as_str().unwrap().contains(family.as_str()));
                    assert_eq!(value["size"], "14px");
                    assert_eq!(value["image"], 120.);
                    assert_eq!(value["token"], base.borrow()[i]["token"]);
                    assert_eq!(value["scroll"], base.borrow()[i]["scroll"]);
                    assert_eq!(value["selection"], base.borrow()[i]["selection"]);
                    assert_eq!(value["undo"], base.borrow()[i]["undo"]);
                    if family == "Inter Variable" || family == "Sora" {
                        assert!(
                            value["fonts"]
                                .as_array()
                                .unwrap()
                                .iter()
                                .any(|f| f.as_str() == Some(family.as_str())),
                            "bundled app font must load in child WebKit"
                        );
                    } else {
                        assert!(
                            (value["width"].as_f64().unwrap()
                                - value["fallback"].as_f64().unwrap())
                            .abs()
                                > 0.1,
                            "installed face must really affect glyph metrics"
                        );
                    }
                }
                if step.get() == 3 {
                    assert_eq!(values[0]["weight"], "700");
                    assert_eq!(values[0]["style"], "italic");
                }
                assert_eq!(buffer_text(&doc.buffer), text);
                assert_eq!(doc.revision.get(), revision.get());
                assert!(!doc.buffer.is_modified() && !doc.buffer.can_undo());
                assert_eq!(
                    (
                        doc.buffer.cursor_position(),
                        doc.buffer
                            .iter_at_mark(&doc.buffer.selection_bound())
                            .offset()
                    ),
                    selection.get()
                );
                let second = other.borrow();
                let rich_doc = second.as_ref().unwrap().active().unwrap();
                assert_eq!(buffer_text(&rich_doc.buffer), *rich_text.borrow());
                assert_eq!(rich_doc.revision.get(), rich_revision.get());
                assert_eq!(values[1]["source"], base.borrow()[1]["source"]);
                if step.get() < 3 {
                    step.set(step.get() + 1);
                    pause.set(Instant::now());
                    phase.set(7);
                } else {
                    std::fs::write(root.join("reading-face.txt"), &expected.name).unwrap();
                    settings(&app).close();
                    let rich = rich_doc.rich.borrow().clone().unwrap();
                    let reply = replies[1].clone();
                    rich.view.call_async_javascript_function("document.getElementById('fastra-visual').focus();document.execCommand('undo');window.fastraVisual.flush();return JSON.stringify(true);",None,None,None,None::<&gio::Cancellable>,move|v|{*reply.borrow_mut()=Some(serde_json::json!(v.is_ok()));});
                    phase.set(11);
                    pause.set(Instant::now());
                }
            }
            11 => {
                let second = other.borrow();
                let rich_doc = second.as_ref().unwrap().active().unwrap();
                if buffer_text(&rich_doc.buffer) != text {
                    assert!(
                        pause.get().elapsed() < Duration::from_secs(4),
                        "undo failed"
                    );
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
                println!("FASTRA_TOOL_SELFTEST_OK reading-font native-font-choice proportional/bold-italic/bundled-child-fonts/image120/source-selection/revision/dirty/DOM-selection/undo/token/scroll/persistence");
                app.quit();
                return glib::ControlFlow::Break;
            }
            95 if pause.get().elapsed() > Duration::from_millis(250) => {
                let retry = widgets(&settings(&app))
                    .into_iter()
                    .find_map(|w| {
                        w.downcast::<gtk::Button>()
                            .ok()
                            .filter(|b| b.widget_name() == "fastra-reading-font-retry")
                    })
                    .unwrap();
                *input.borrow_mut() = Some(support::test_input_completed(&retry, &[], true));
                pause.set(Instant::now());
                phase.set(9);
            }
            90 if pause.get().elapsed() > Duration::from_millis(350) => {
                let choice = choice(&app);
                reveal(&choice);
                assert_eq!(choice.is_sensitive(), mode != "corrupt");
                assert!(
                    state.error.borrow().is_some()
                        || state.face.borrow().as_ref().unwrap().starts_with("Absent")
                );
                if mode == "missing" {
                    assert!(state.description().is_none());
                    assert_eq!(choice.selected(), state.faces.len() as u32 + 1);
                    assert!(font::store::load_named(&config_root().unwrap(), FILE)
                        .unwrap()
                        .face
                        .unwrap()
                        .starts_with("Absent"));
                }
                pause.set(Instant::now());
                phase.set(92);
            }
            92 if pause.get().elapsed() > Duration::from_millis(250) => {
                assert!(support::try_capture(
                    &settings(&app),
                    &format!("reading-font-{mode}")
                ));
                println!("FASTRA_TOOL_SELFTEST_OK reading-font {mode} retained visible");
                app.quit();
                return glib::ControlFlow::Break;
            }
            91 if pause.get().elapsed() > Duration::from_millis(350) => {
                let index = state
                    .faces
                    .iter()
                    .position(|f| Some(&f.name) == state.face.borrow().as_ref())
                    .unwrap()
                    + 1;
                assert_eq!(choice(&app).selected(), index as u32);
                doc.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                pause.set(Instant::now());
                phase.set(93);
            }
            93 if pause.get().elapsed() > Duration::from_millis(350) => {
                if let Some(preview) = doc.markdown.borrow().as_ref() {
                    inspect(&preview.view, replies[0].clone());
                    phase.set(94);
                }
            }
            94 if replies[0].borrow().is_some() => {
                let value = replies[0].borrow_mut().take().unwrap();
                if value["applied"].is_null() {
                    pause.set(Instant::now());
                    phase.set(93);
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(value["weight"], "700");
                assert_eq!(value["style"], "italic");
                assert_eq!(value["size"], "14px");
                assert_eq!(value["image"], 120.);
                println!("FASTRA_TOOL_SELFTEST_OK reading-font fresh-process actual-preview-face");
                app.quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
