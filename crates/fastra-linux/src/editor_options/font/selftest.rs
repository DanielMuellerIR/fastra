use super::*;
use crate::{buffer_text, git_view as support, source_panes};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
thread_local! { static RUNNING: Cell<bool> = const { Cell::new(false) }; }
const TEXT: &str = "// Font fixture café e\u{301} 😀\nlet narrow = \"iii\";\nlet wide = \"WWW\";\n";
fn widgets(root: &impl IsA<gtk::Widget>) -> Vec<gtk::Widget> {
    fn walk(root: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
        all.push(root.clone());
        let mut child = root.first_child();
        while let Some(widget) = child {
            walk(&widget, all);
            child = widget.next_sibling();
        }
    }
    let mut all = Vec::new();
    walk(root.as_ref(), &mut all);
    all
}
fn views(doc: &Document) -> Vec<sourceview5::View> {
    widgets(&doc.container)
        .into_iter()
        .filter_map(|widget| widget.downcast::<sourceview5::View>().ok())
        .collect()
}
fn split(doc: &Document) {
    widgets(&doc.container)
        .into_iter()
        .find_map(|widget| {
            widget
                .downcast::<gtk::CheckButton>()
                .ok()
                .filter(|button| button.widget_name() == "fastra-source-split")
        })
        .unwrap()
        .set_active(true);
}
fn actual(view: &sourceview5::View) -> pango::FontDescription {
    view.create_pango_layout(Some("MWi"))
        .iter()
        .run_readonly()
        .unwrap()
        .item()
        .analysis()
        .font()
        .describe()
}
fn assert_face(doc: &Document, expected: &pango::FontDescription) {
    let views = views(doc);
    assert_eq!(views.len(), 2);
    for view in views {
        let face = actual(&view);
        assert_eq!(
            face.family(),
            expected.family(),
            "actual glyph family: {face}"
        );
        assert_eq!(
            face.weight(),
            expected.weight(),
            "actual glyph weight: {face}"
        );
        assert_eq!(face.style(), expected.style(), "actual glyph style: {face}");
        for text in ["iiiiiiiiii", "WWWWWWWWWW", "0000000000"] {
            assert_eq!(
                view.create_pango_layout(Some(text)).size().0,
                view.create_pango_layout(Some("MMMMMMMMMM")).size().0
            );
        }
    }
}
pub(super) fn run(ui: Rc<Ui>) {
    if RUNNING.with(|running| running.replace(true)) {
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let restore = std::env::var("FASTRA_SOURCE_FONT_PHASE").as_deref() == Ok("restore");
    let readonly = std::env::var("FASTRA_SOURCE_FONT_SELFTEST").as_deref() == Ok("readonly");
    let missing = std::env::var("FASTRA_SOURCE_FONT_SELFTEST").as_deref() == Ok("missing");
    let busy = std::env::var("FASTRA_SOURCE_FONT_SELFTEST").as_deref() == Ok("busy");
    let held_lock = RefCell::new(None::<std::fs::File>);
    let path = root.join("source-font.rs");
    if !restore {
        std::fs::write(&path, TEXT).unwrap();
        if readonly {
            std::fs::hard_link(&path, root.join("source-font-alias.rs")).unwrap();
        }
    }
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let began = Instant::now();
    let paused = Cell::new(began);
    let input = RefCell::new(None::<std::sync::mpsc::Receiver<()>>);
    let other = RefCell::new(None::<Rc<Ui>>);
    let revision = Cell::new(0);
    let expected = RefCell::new(None::<pango::FontDescription>);
    let choice_index = Cell::new(0u32);
    let clipboard_reply = Rc::new(RefCell::new(None::<String>));
    let selection = RefCell::new(None::<(i32, i32)>);
    support::test_size(ui.window.upcast_ref());
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            began.elapsed() < Duration::from_secs(35),
            "source font phase {}: {}",
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
        let Some(doc) = ui
            .active()
            .filter(|doc| doc.disk_path().as_ref() == Some(&path))
        else {
            return glib::ControlFlow::Continue;
        };
        let state = state(&ui.window.pango_context());
        if !state.loaded.get() || state.busy.get() {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                assert_eq!(doc.is_read_only(), readonly);
                assert!(!doc.buffer.can_undo());
                if busy && !restore {
                    *held_lock.borrow_mut() = Some(
                        super::super::store::Store::open(&config_root().unwrap())
                            .unwrap()
                            .lock()
                            .unwrap(),
                    );
                }
                split(&doc);
                revision.set(doc.revision.get());
                if restore {
                    let key = std::fs::read_to_string(root.join("selected-face.txt")).unwrap();
                    assert_eq!(state.face.borrow().as_deref(), Some(key.as_str()));
                    *expected.borrow_mut() = Some(state.description().unwrap());
                } else if missing {
                    assert!(state
                        .face
                        .borrow()
                        .as_deref()
                        .unwrap()
                        .starts_with("Absent"));
                    assert!(state.description().is_none());
                } else {
                    assert!(state.face.borrow().is_none());
                    let (index, face) = state
                        .faces
                        .iter()
                        .enumerate()
                        .find(|(_, face)| {
                            face.description.weight() == pango::Weight::Bold
                                && face.description.style() != pango::Style::Normal
                        })
                        .expect(
                            "isolated font fixture must include a bold italic fixed-pitch face",
                        );
                    choice_index.set(index as u32 + 1);
                    *expected.borrow_mut() = Some(face.description.clone());
                    std::fs::write(root.join("selected-face.txt"), &face.name).unwrap();
                }
                let app = ui.window.application().unwrap();
                let window = crate::build(&app);
                window.add_document("Other source", TEXT);
                split(&window.active().unwrap());
                *other.borrow_mut() = Some(window);
                paused.set(Instant::now());
                phase.set(1);
            }
            1 if paused.get().elapsed() > Duration::from_millis(300) => {
                let source_views = views(&doc);
                assert!(source_views.iter().all(|view| view.is_mapped()));
                let view = &source_views[1];
                eprintln!(
                    "SOURCE FONT actual glyph={} 80M={:.6} 10i={:.6} 10W={:.6}",
                    actual(view),
                    f64::from(view.create_pango_layout(Some(&"M".repeat(80))).size().0)
                        / f64::from(pango::SCALE),
                    f64::from(view.create_pango_layout(Some("iiiiiiiiii")).size().0)
                        / f64::from(pango::SCALE),
                    f64::from(view.create_pango_layout(Some("WWWWWWWWWW")).size().0)
                        / f64::from(pango::SCALE)
                );
                *input.borrow_mut() = Some(support::test_input_completed(
                    view,
                    &["ctrl+End", "ctrl+shift+Home"],
                    true,
                ));
                phase.set(2);
            }
            2 => {
                let target = source_panes::capture(&doc).unwrap();
                *selection.borrow_mut() = Some(target.offsets());
                assert!(target.offsets().0 != target.offsets().1);
                doc.editor_options.borrow().as_ref().unwrap().show();
                paused.set(Instant::now());
                phase.set(3);
            }
            3 if paused.get().elapsed() > Duration::from_millis(300) => {
                let window = doc
                    .editor_options
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .window
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .upgrade()
                    .unwrap();
                support::test_size(&window);
                paused.set(Instant::now());
                phase.set(31);
            }
            31 if paused.get().elapsed() > Duration::from_millis(300) => {
                let window = doc
                    .editor_options
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .window
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .upgrade()
                    .unwrap();
                let choice = widgets(&window)
                    .into_iter()
                    .find_map(|widget| {
                        widget
                            .downcast::<gtk::DropDown>()
                            .ok()
                            .filter(|choice| choice.widget_name() == "fastra-source-font")
                    })
                    .unwrap();
                if restore {
                    assert_eq!(
                        choice.selected(),
                        state
                            .faces
                            .iter()
                            .position(|face| Some(&face.name) == state.face.borrow().as_ref())
                            .unwrap() as u32
                            + 1
                    );
                    paused.set(Instant::now());
                    phase.set(5);
                } else {
                    if missing {
                        assert_eq!(choice.selected(), state.faces.len() as u32 + 1);
                        assert!(support::try_capture(&window, "source-font-missing"));
                    }
                    *input.borrow_mut() = Some(support::test_input_completed(&choice, &[], true));
                    phase.set(4);
                }
            }
            4 => {
                let window = doc
                    .editor_options
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .window
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .upgrade()
                    .unwrap();
                let mut keys = vec!["Home"];
                keys.extend(std::iter::repeat_n("Down", choice_index.get() as usize));
                keys.push("Return");
                *input.borrow_mut() = Some(support::test_input_completed(&window, &keys, false));
                paused.set(Instant::now());
                phase.set(5);
            }
            5 if paused.get().elapsed() > Duration::from_millis(400) => {
                let locked = held_lock.borrow().is_some();
                if busy && locked {
                    assert!(state.pending.borrow().is_some() && state.error.borrow().is_some());
                    assert!(
                        !super::pending(),
                        "failed display preference must not permanently block document close"
                    );
                    assert!(store::load(&config_root().unwrap()).unwrap().face.is_none());
                    assert_face(&doc, expected.borrow().as_ref().unwrap());
                    let window = doc
                        .editor_options
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .window
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .upgrade()
                        .unwrap();
                    assert!(support::try_capture(&window, "source-font-save-error"));
                    held_lock.borrow_mut().take();
                    let retry = widgets(&window)
                        .into_iter()
                        .find_map(|widget| {
                            widget.downcast::<gtk::Button>().ok().filter(|button| {
                                button.label().as_deref()
                                    == Some(ui.lang.text("Erneut versuchen", "Retry"))
                            })
                        })
                        .unwrap();
                    *input.borrow_mut() = Some(support::test_input_completed(&retry, &[], true));
                    paused.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                assert!(state.pending.borrow().is_none());
                if missing {
                    assert!(state.face.borrow().is_none());
                    assert!(store::load(&config_root().unwrap()).unwrap().face.is_none());
                } else {
                    assert_face(&doc, expected.borrow().as_ref().unwrap());
                    assert_face(
                        &other.borrow().as_ref().unwrap().active().unwrap(),
                        expected.borrow().as_ref().unwrap(),
                    );
                    assert_eq!(
                        store::load(&config_root().unwrap()).unwrap().face,
                        *state.face.borrow()
                    );
                }
                let window = doc
                    .editor_options
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .window
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .upgrade()
                    .unwrap();
                assert!(support::try_capture(&window, "source-font-options"));
                let close = widgets(&window)
                    .into_iter()
                    .find_map(|widget| {
                        widget.downcast::<gtk::Button>().ok().filter(|button| {
                            button.label().as_deref() == Some(ui.lang.text("Schließen", "Close"))
                        })
                    })
                    .unwrap();
                *input.borrow_mut() = Some(support::test_input_completed(&close, &[], true));
                paused.set(Instant::now());
                phase.set(6);
            }
            6 if paused.get().elapsed() > Duration::from_millis(350) => {
                assert_eq!(
                    source_panes::capture(&doc).unwrap().offsets(),
                    selection.borrow().unwrap()
                );
                assert_eq!(doc.revision.get(), revision.get());
                assert!(!doc.buffer.can_undo());
                assert_eq!(buffer_text(&doc.buffer), TEXT);
                assert!(!doc.buffer.is_modified());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), TEXT);
                assert_eq!(doc.is_read_only(), readonly);
                assert!(views(&doc)
                    .iter()
                    .all(|view| view.is_editable() != readonly));
                assert!(support::try_capture(
                    ui.window.upcast_ref(),
                    "source-font-restored"
                ));
                if !readonly && !missing {
                    let target = source_panes::capture(&doc).unwrap();
                    let start = target.buffer.iter_at_offset(0);
                    let end = target.buffer.iter_at_offset(2);
                    target.buffer.select_range(&start, &end);
                    *input.borrow_mut() = Some(support::test_input_completed(
                        &target.view,
                        &["ctrl+shift+Down", "ctrl+c"],
                        false,
                    ));
                    phase.set(7);
                    return glib::ControlFlow::Continue;
                }
                println!("FASTRA_SOURCE_FONT_OK native-face-choice/two-panes/two-windows/exact-glyph-face/selection/revision/source-unchanged fresh={restore} readonly={readonly} missing={missing} busy={busy}");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            7 => {
                let clipboard = source_panes::capture(&doc).unwrap().view.clipboard();
                assert!(!clipboard.formats().contain_mime_type("text/html"));
                let reply = clipboard_reply.clone();
                glib::MainContext::default().spawn_local(async move {
                    *reply.borrow_mut() = Some(
                        clipboard
                            .read_text_future()
                            .await
                            .unwrap()
                            .unwrap()
                            .to_string(),
                    );
                });
                paused.set(Instant::now());
                phase.set(8);
            }
            8 if paused.get().elapsed() > Duration::from_millis(300) => {
                let Some(copied) = clipboard_reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(
                    copied, "//\nle\n",
                    "native rectangle copy under the selected glyph face"
                );
                assert_eq!(buffer_text(&doc.buffer), TEXT);
                assert_eq!(doc.revision.get(), revision.get());
                assert!(!doc.buffer.can_undo() && !doc.buffer.is_modified());
                assert!(support::try_capture(
                    ui.window.upcast_ref(),
                    "source-font-rectangle"
                ));
                println!("FASTRA_SOURCE_FONT_OK native-face-choice/two-panes/two-windows/exact-glyph-face/selection/revision/source-unchanged/rectangle-copy fresh={restore} readonly={readonly} missing={missing} busy={busy}");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
