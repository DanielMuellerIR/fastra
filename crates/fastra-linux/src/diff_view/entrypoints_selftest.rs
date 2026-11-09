use super::*;
use std::time::{Duration, Instant};

fn find(widget: &gtk::Widget, predicate: &impl Fn(&gtk::Widget) -> bool) -> Option<gtk::Widget> {
    if widget.is_mapped() && widget.width() > 0 && predicate(widget) {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(found) = find(&widget, predicate) {
            return Some(found);
        }
        child = widget.next_sibling();
    }
    None
}
fn button(ui: &Ui, labels: &[&str]) -> Option<gtk::Button> {
    find(ui.window.upcast_ref(), &|widget| {
        widget.downcast_ref::<gtk::Button>().is_some_and(|b| {
            b.is_sensitive()
                && b.label()
                    .is_some_and(|text| labels.contains(&text.as_str()))
        })
    })
    .and_downcast()
}
fn menu(ui: &Ui, labels: &[&str]) -> gtk::MenuButton {
    find(ui.window.upcast_ref(), &|widget| {
        widget.downcast_ref::<gtk::MenuButton>().is_some_and(|b| {
            b.label()
                .is_some_and(|text| labels.contains(&text.as_str()))
                || b.tooltip_text()
                    .is_some_and(|text| labels.contains(&text.as_str()))
        })
    })
    .unwrap()
    .downcast()
    .unwrap()
}
fn tab(ui: &Ui, doc: &crate::Document) -> gtk::Widget {
    find(&chrome::tab_header(ui, doc), &|widget| {
        widget.has_css_class("tab-select")
    })
    .unwrap()
}
fn editor(doc: &crate::Document) -> gtk::Widget {
    if let Some(editor) = doc.rich.borrow().as_ref().filter(|e| e.active.get()) {
        return editor.view.clone().upcast();
    }
    find(doc.container.upcast_ref(), &|widget| {
        widget.is::<sourceview5::View>()
    })
    .unwrap()
}
fn edit_input(doc: &crate::Document, keys: &[&str]) {
    if let Some(editor) = doc
        .rich
        .borrow()
        .clone()
        .filter(|editor| editor.active.get())
    {
        let view = editor.view.clone();
        let keys = keys.iter().map(|key| key.to_string()).collect::<Vec<_>>();
        editor.evaluate("const p=Array.from(document.querySelectorAll('#fastra-visual p')).find(p=>p.getBoundingClientRect().height>0); const r=p.getBoundingClientRect(); return JSON.stringify({x:r.left+8,y:r.top+r.height/2,editable:p.isContentEditable});", move |value| {
            let value = value.expect("native editable paragraph geometry");
            assert_eq!(value["editable"],true);
            support::test_click_at(&view, value["x"].as_f64().unwrap() as f32, value["y"].as_f64().unwrap() as f32, &keys.iter().map(String::as_str).collect::<Vec<_>>());
        });
    } else {
        support::test_click_at(&editor(doc), 80., 20., keys);
    }
}

fn is_active(ui: &Ui, doc: &Rc<crate::Document>) -> bool {
    ui.active().is_some_and(|active| Rc::ptr_eq(&active, doc))
}
fn member(ui: &Ui, doc: &Rc<crate::Document>) -> bool {
    ui.documents
        .borrow()
        .iter()
        .any(|item| Rc::ptr_eq(item, doc))
}
fn picker() -> Option<Rc<State>> {
    result::test_last()
        .filter(|state| state.picker.window.is_visible() && state.picker.test_loaded())
}
fn pair(ui: &Ui, expected: [&Rc<crate::Document>; 2]) {
    let actual = crate::tab_comparison::ordered(ui).expect("valid pair");
    assert!(
        actual.iter().zip(expected).all(|(a, b)| Rc::ptr_eq(a, b)),
        "pair follows visible tab order"
    );
}
fn chosen(state: &State, side: usize, ui: &Ui, doc: &Rc<crate::Document>) {
    assert!(state.choices.borrow()[side]
        .as_ref()
        .and_then(|choice| choice.document(ui))
        .is_some_and(|actual| Rc::ptr_eq(&actual, doc)));
}
fn settings() -> fastra_workflow::comparison_preferences::Settings {
    let root = PathBuf::from(std::env::var_os("XDG_CONFIG_HOME").unwrap());
    fastra_workflow::comparison_preferences::Store::open(&root)
        .unwrap()
        .load()
        .unwrap()
}
pub(super) fn run(ui: Rc<Ui>, mode: &str) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    if mode.starts_with("tabs") {
        tabs(ui, mode == "tabs-rich");
    } else {
        saved(ui, mode == "saved-rich");
    }
}
fn tabs(ui: Rc<Ui>, rich: bool) {
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let left = root.join("pair-left.txt");
    let right = root.join(if rich {
        "pair-right.md"
    } else {
        "pair-right.txt"
    });
    std::fs::write(&left, "left source\n").unwrap();
    std::fs::write(&right, "right source\n").unwrap();
    ui.load_path(left.clone());
    let documents = RefCell::new(Vec::<Rc<crate::Document>>::new());
    let old_context = RefCell::new(None::<Rc<State>>);
    let replaced = Cell::new(false);
    let rich_requested = Cell::new(false);
    let webview = RefCell::new(None::<webkit6::WebView>);
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            started.elapsed() < Duration::from_secs(40),
            "comparison tab entry phase{}: {}",
            phase.get(),
            ui.status.text()
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
                documents.borrow_mut().push(doc);
                ui.load_path(right.clone());
            }
            1 => {
                if documents.borrow().len() == 1 {
                    let Some(doc) = ui
                        .active()
                        .filter(|doc| doc.disk_path().as_ref() == Some(&right))
                    else {
                        return glib::ControlFlow::Continue;
                    };
                    documents.borrow_mut().push(doc);
                    ui.add_document("third", "third source\n");
                    documents.borrow_mut().push(ui.active().unwrap());
                    return glib::ControlFlow::Continue;
                }
                let header = chrome::tab_header(&ui, &documents.borrow()[1]);
                let Some(select) = find(&header, &|widget| widget.has_css_class("tab-select"))
                else {
                    return glib::ControlFlow::Continue;
                };
                support::test_click(&select, &[]);
            }
            2 => {
                let docs = documents.borrow();
                if !is_active(&ui, &docs[1]) {
                    return glib::ControlFlow::Continue;
                }
                if rich {
                    if !rich_requested.get() {
                        let toggle = docs[1].rich_toggle.borrow().clone().unwrap();
                        if !toggle.is_mapped()
                            || toggle.width() <= 0
                            || toggle.height() <= 0
                            || !toggle.is_sensitive()
                        {
                            return glib::ControlFlow::Continue;
                        }
                        support::test_click(&toggle, &[]);
                        rich_requested.set(true);
                        return glib::ControlFlow::Continue;
                    }
                    let Some(editor) =
                        docs[1].rich.borrow().clone().filter(|editor| {
                            editor.active.get() && editor.ready_for_saved_source()
                        })
                    else {
                        return glib::ControlFlow::Continue;
                    };
                    *webview.borrow_mut() = Some(editor.view.clone());
                }
                support::test_shift_click(&tab(&ui, &docs[0]));
            }
            3 => {
                let docs = documents.borrow();
                assert!(is_active(&ui, &docs[1]));
                pair(&ui, [&docs[0], &docs[1]]);
                assert!(chrome::tab_header(&ui, &docs[0]).has_css_class("comparison"));
                assert!(chrome::tab_header(&ui, &docs[1]).has_css_class("active"));
                if !support::try_capture(ui.window.upcast_ref(), "compare-tab-pair") {
                    return glib::ControlFlow::Continue;
                }
                support::test_shift_click(&tab(&ui, &docs[1]));
            }
            4 => {
                assert!(crate::tab_comparison::ordered(&ui).is_none());
                support::test_shift_click(&tab(&ui, &documents.borrow()[0]));
            }
            5 => {
                let docs = documents.borrow();
                pair(&ui, [&docs[0], &docs[1]]);
                support::test_shift_click(&tab(&ui, &docs[0]));
            }
            6 => {
                assert!(crate::tab_comparison::ordered(&ui).is_none());
                support::test_shift_click(&tab(&ui, &documents.borrow()[2]));
            }
            7 => {
                let docs = documents.borrow();
                if !replaced.replace(true) {
                    pair(&ui, [&docs[1], &docs[2]]);
                    support::test_shift_click(&tab(&ui, &docs[0]));
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                pair(&ui, [&docs[0], &docs[1]]);
                support::test_click(&tab(&ui, &docs[1]), &[]);
            }
            8 => {
                let docs = documents.borrow();
                assert!(crate::tab_comparison::ordered(&ui).is_none());
                assert!(is_active(&ui, &docs[1]));
                support::test_shift_click(&tab(&ui, &docs[0]));
            }
            9 => {
                let docs = documents.borrow();
                pair(&ui, [&docs[0], &docs[1]]);
                support::test_context_click(&tab(&ui, &docs[2]));
            }
            10 => {
                assert!(button(&ui, &["Dateien vergleichen…", "Compare Files…"]).is_none());
                assert!(button(&ui, &["Diesen Tab schließen", "Close this tab"]).is_some());
                assert!(is_active(&ui, &documents.borrow()[1]));
                support::test_keys(&ui.window, &["Escape"]);
            }
            11 => {
                support::test_context_click(&tab(&ui, &documents.borrow()[0]));
            }
            12 => {
                let Some(compare) = button(&ui, &["Dateien vergleichen…", "Compare Files…"])
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(is_active(&ui, &documents.borrow()[1]));
                if !support::try_capture(ui.window.upcast_ref(), "compare-tab-context") {
                    return glib::ControlFlow::Continue;
                }
                if std::env::var_os("FASTRA_NATIVE_POPUP_SCREENSHOT").is_some() {
                    let output =
                        PathBuf::from(std::env::var_os("FASTRA_TOOL_SCREENSHOTS").unwrap())
                            .join("compare-tab-context-native.png");
                    support::background(
                        move || {
                            let status = std::process::Command::new("import")
                                .args(["-window", "root"])
                                .arg(output)
                                .status()
                                .map_err(|error| error.to_string())?;
                            if status.success() {
                                Ok(())
                            } else {
                                Err("native popup capture failed".into())
                            }
                        },
                        move |result| {
                            result.expect("isolated native popup screenshot");
                            support::test_click(&compare, &[]);
                        },
                    );
                } else {
                    support::test_click(&compare, &[]);
                }
            }
            13 => {
                let Some(state) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                let docs = documents.borrow();
                chosen(&state, 0, &ui, &docs[0]);
                chosen(&state, 1, &ui, &docs[1]);
                if !support::try_capture(&state.picker.window, "compare-tab-prefill") {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&state.picker.window, &["Escape"]);
                *old_context.borrow_mut() = Some(state);
            }
            14 => {
                if picker().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let doc = &documents.borrow()[1];
                edit_input(doc, &["Caps_Lock", "ctrl+alt+shift+d"]);
            }
            15 => {
                let Some(state) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                chosen(&state, 0, &ui, &documents.borrow()[1]);
                assert!(
                    state.choices.borrow()[1].is_none(),
                    "global command keeps active-left default despite pair"
                );
                support::test_keys(&state.picker.window, &["Escape", "Caps_Lock"]);
            }
            16 => {
                if picker().is_some() {
                    return glib::ControlFlow::Continue;
                }
                if rich {
                    phase.set(20);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                edit_input(&documents.borrow()[1], &["ctrl+f"]);
            }
            17 => {
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                if !window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&ui.find, &["ctrl+alt+shift+d"]);
            }
            18 => {
                let Some(state) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                chosen(&state, 0, &ui, &documents.borrow()[1]);
                assert!(state.choices.borrow()[1].is_none());
                support::test_keys(&state.picker.window, &["Escape"]);
            }
            19 => {
                if picker().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                support::test_keys(&window, &["Escape"]);
            }
            20 => {
                let header = chrome::tab_header(&ui, &documents.borrow()[0]);
                let close = header
                    .last_child()
                    .unwrap()
                    .downcast::<gtk::Button>()
                    .unwrap();
                support::test_click(&close, &[]);
            }
            21 => {
                if member(&ui, &documents.borrow()[0]) {
                    return glib::ControlFlow::Continue;
                }
                assert!(crate::tab_comparison::ordered(&ui).is_none());
                ui.load_path(left.clone());
            }
            _ => {
                let old = &documents.borrow()[0];
                let Some(new) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&left))
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!Rc::ptr_eq(old, &new));
                assert!(
                    old_context.borrow().as_ref().unwrap().choices.borrow()[0]
                        .as_ref()
                        .unwrap()
                        .document(&ui)
                        .is_none(),
                    "same path does not rebind closed source"
                );
                assert!(crate::tab_comparison::ordered(&ui).is_none());
                assert_eq!(std::fs::read_to_string(&left).unwrap(), "left source\n");
                assert_eq!(std::fs::read_to_string(&right).unwrap(), "right source\n");
                if rich {
                    let docs = documents.borrow();
                    assert!(docs[1].is_rich_active());
                    assert_eq!(
                        docs[1].rich.borrow().as_ref().unwrap().view,
                        *webview.borrow().as_ref().unwrap()
                    );
                }
                eprintln!("DIFF_ENTRYPOINTS_SELFTEST PASS rich={rich} native Shift partner/toggle/replace without activation, normal same-active clears, unrelated context excludes action, actual pair context fills visible order, uppercase+CapsLock global shortcut bound to the editor owner, closed/reopened path never rebinds, no disk writes");
                crate::source_appearance::cleanup_schemes();
                std::process::exit(0);
            }
        }
        eprintln!("comparison tabs phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
fn saved(ui: Rc<Ui>, rich: bool) {
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("saved.md");
    let original = "saved line  \n";
    std::fs::write(&path, original).unwrap();
    ui.load_path(path.clone());
    let doc = RefCell::new(None::<Rc<crate::Document>>);
    let draft = RefCell::new(String::new());
    let basis = RefCell::new(String::new());
    let comparison = RefCell::new(None::<Rc<State>>);
    let typed = RefCell::new(None::<std::sync::mpsc::Receiver<()>>);
    let webview = RefCell::new(None::<webkit6::WebView>);
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            started.elapsed() < Duration::from_secs(45),
            "saved comparison rich={rich} phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(300) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let Some(source) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!crate::tab_comparison::can_saved(&ui));
                *doc.borrow_mut() = Some(source.clone());
                if rich {
                    let toggle = source.rich_toggle.borrow().clone().unwrap();
                    if !toggle.is_mapped()
                        || toggle.width() <= 0
                        || toggle.height() <= 0
                        || !toggle.is_sensitive()
                    {
                        return glib::ControlFlow::Continue;
                    }
                    support::test_click(&toggle, &[]);
                }
            }
            1 => {
                let source = doc.borrow().clone().unwrap();
                if rich {
                    let Some(editor) =
                        source.rich.borrow().clone().filter(|editor| {
                            editor.active.get() && editor.ready_for_saved_source()
                        })
                    else {
                        return glib::ControlFlow::Continue;
                    };
                    *webview.borrow_mut() = Some(editor.view.clone());
                }
                edit_input(&source, &["ctrl+alt+shift+d"]);
            }
            2 => {
                let Some(state) = picker() else {
                    return glib::ControlFlow::Continue;
                };
                chosen(&state, 0, &ui, doc.borrow().as_ref().unwrap());
                assert!(state.choices.borrow()[1].is_none());
                support::test_click(&state.picker.options[0], &[]);
            }
            3 => {
                let state = picker().unwrap();
                support::test_click(&state.picker.options[3], &[]);
            }
            4 => {
                let options = settings().options;
                if !options[0] || !options[3] {
                    return glib::ControlFlow::Continue;
                }
                let state = picker().unwrap();
                support::test_keys(&state.picker.window, &["Escape"]);
            }
            5 => {
                if picker().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let source = doc.borrow().clone().unwrap();
                assert_eq!(
                    buffer_text(&source.buffer),
                    original,
                    "shortcut did not invoke an editor command"
                );
                edit_input(&source, &["ctrl+a"]);
            }
            6 => {
                *typed.borrow_mut() = Some(support::test_type(
                    &editor(doc.borrow().as_ref().unwrap()),
                    "SAVED line\n",
                ));
            }
            7 => {
                if typed.borrow().as_ref().unwrap().try_recv().is_err() {
                    return glib::ControlFlow::Continue;
                }
                typed.borrow_mut().take();
            }
            8 => {
                if !crate::tab_comparison::can_saved(&ui) {
                    let source = doc.borrow().clone().unwrap();
                    assert!(
                        pause.get().elapsed() < Duration::from_secs(4),
                        "saved action did not become ready: modified={}, text={:?}, rich={:?}",
                        source.buffer.is_modified(),
                        buffer_text(&source.buffer),
                        source.rich.borrow().as_ref().map(|editor| (
                            editor.active.get(),
                            editor.ready_for_saved_source(),
                            editor.pending()
                        ))
                    );
                    return glib::ControlFlow::Continue;
                }
                let source = doc.borrow().clone().unwrap();
                *draft.borrow_mut() = buffer_text(&source.buffer);
                assert_ne!(*draft.borrow(), original);
                support::test_click(&menu(&ui, &["Fastra-Menü", "Fastra menu"]), &[]);
            }
            9 => {
                support::test_click(&menu(&ui, &["Werkzeuge", "Tools"]), &[]);
            }
            10 => {
                assert!(ui.saved_diff_tool.is_mapped() && ui.saved_diff_tool.is_sensitive());
                support::test_click(&ui.saved_diff_tool, &[]);
            }
            11 => {
                let Some(state) = ui.active().and_then(|doc| doc.comparison.borrow().clone())
                else {
                    return glib::ControlFlow::Continue;
                };
                if state.busy.get()
                    || !state.view.ready.get()
                    || state.view.alignment.test_pending()
                {
                    return glib::ControlFlow::Continue;
                }
                let model = state.model.borrow().clone().unwrap();
                *basis.borrow_mut() = model.inputs[1].snapshot.text.clone();
                assert!(
                    basis.borrow().contains("SAVED line"),
                    "complete native Rich input reaches comparison"
                );
                assert!(model.inputs[0].file.is_some() && model.inputs[1].file.is_none());
                let options = model.comparison.options();
                assert_eq!(
                    [
                        options.ignore_trailing_whitespace,
                        options.ignore_all_whitespace,
                        options.ignore_blank_lines,
                        options.ignore_case
                    ],
                    [false; 4]
                );
                assert_eq!(
                    model.comparison.blocks().len(),
                    1,
                    "saved comparison ignores remembered ignore options"
                );
                assert_eq!(model.paths, [Some(path.clone()), Some(path.clone())]);
                chosen(&state, 1, &ui, doc.borrow().as_ref().unwrap());
                assert!(state.view.names[0]
                    .text()
                    .contains(ui.lang.text("gespeichert", "saved")));
                assert!(state.view.names[1]
                    .text()
                    .contains(ui.lang.text("ungespeichert", "unsaved")));
                assert!(
                    !state.view.transfer[0].is_sensitive() && state.view.transfer[1].is_sensitive()
                );
                assert!(picker().is_none(), "saved opens result directly");
                if !support::try_capture(ui.window.upcast_ref(), "compare-saved") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&state.view.transfer[1], &[]);
                *comparison.borrow_mut() = Some(state);
            }
            12 => {
                let Some(preview) = transfer::test_preview().filter(|p| p.apply.is_sensitive())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(preview.plan.output(), original);
                if !support::try_capture(&preview.window, "compare-saved-transfer") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&preview.apply, &[]);
            }
            13 => {
                let source = doc.borrow().clone().unwrap();
                if comparison.borrow().as_ref().unwrap().busy.get()
                    || transfer::test_preview().is_some()
                    || buffer_text(&source.buffer) != original
                {
                    return glib::ControlFlow::Continue;
                }
                support::test_shift_click(&tab(&ui, &source));
            }
            14 => {
                let source = doc.borrow().clone().unwrap();
                if !is_active(&ui, &source) {
                    return glib::ControlFlow::Continue;
                }
                assert!(crate::tab_comparison::ordered(&ui).is_none());
                if rich {
                    assert!(source.is_rich_active());
                    assert_eq!(
                        source.rich.borrow().as_ref().unwrap().view,
                        *webview.borrow().as_ref().unwrap()
                    );
                }
                edit_input(&source, &["ctrl+z"]);
            }
            _ => {
                let source = doc.borrow().clone().unwrap();
                if buffer_text(&source.buffer) != *basis.borrow() {
                    assert!(pause.get().elapsed() < Duration::from_secs(5), "saved native Undo mismatch: captured={:?}, comparison_basis={:?}, actual={:?}", *draft.borrow(), basis, buffer_text(&source.buffer));
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                assert_eq!(settings().options, [true, false, false, true]);
                assert!(source.buffer.is_modified());
                if rich {
                    assert!(source.is_rich_active());
                    assert_eq!(
                        source.rich.borrow().as_ref().unwrap().view,
                        *webview.borrow().as_ref().unwrap()
                    );
                }
                eprintln!("DIFF_ENTRYPOINTS_SELFTEST PASS native saved entry rich={rich}, clean-disabled, actual global shortcut/remembered options, dirty memory vs disk directly/default options, full native transfer approval, same editor and one Undo, source bytes and remembered options unchanged");
                crate::source_appearance::cleanup_schemes();
                std::process::exit(0);
            }
        }
        eprintln!("comparison saved rich={rich} phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
