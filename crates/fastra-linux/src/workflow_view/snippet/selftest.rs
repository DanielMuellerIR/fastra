use super::*;
use std::time::Instant;
fn button(root: &gtk::Widget, title: &str) -> Option<gtk::Button> {
    if let Some(b) = root.downcast_ref::<gtk::Button>().filter(|b| {
        b.is_mapped()
            && (b.tooltip_text().as_deref() == Some(title)
                || b.label().as_deref() == Some(title)
                || chrome::children(b.upcast_ref::<gtk::Widget>())
                    .iter()
                    .any(|c| {
                        c.downcast_ref::<gtk::Label>()
                            .is_some_and(|l| l.text() == title)
                    }))
    }) {
        return Some(b.clone());
    }
    if let Some(b) = root
        .downcast_ref::<gtk::Button>()
        .filter(|b| b.is_mapped() && super::super::selftest::find(b.upcast_ref(), title).is_some())
    {
        return Some(b.clone());
    }
    chrome::children(root).iter().find_map(|c| button(c, title))
}
fn seed(rich: bool) {
    let store = Store::open(&config_path().unwrap()).unwrap();
    let snapshot = store.load().unwrap();
    let mut library = snapshot.library.clone();
    library.snippets.snippets.push(Snippet {
        id: workflow::new_id().unwrap(),
        revision: workflow::new_id().unwrap(),
        name: "Repeated fields · Straße".into(),
        template: if rich {
            "**{{Name}}** / {{Ort}} / **{{Name}}**"
        } else {
            "{{ Name }} / {{Ort}} / {{Name}}"
        }
        .into(),
        extra: Default::default(),
    });
    store.save(&snapshot, &library).unwrap();
}
fn view() -> Option<Rc<View>> {
    TEST_VIEW
        .with(|s| s.borrow().as_ref().and_then(Weak::upgrade))
        .filter(|v| v.snippet && !v.closed.get())
}
fn open(ui: &Ui) {
    let b = button(
        ui.window.upcast_ref(),
        ui.lang.text("Textbausteine …", "Text snippets …"),
    )
    .expect("visible snippet button");
    crate::git_view::test_click(&b, &[]);
}
pub(crate) fn start(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    if std::env::var("FASTRA_SNIPPET_SELFTEST").as_deref() == Ok("rich") {
        rich::start(ui);
        return;
    }
    if std::env::var("FASTRA_SNIPPET_SELFTEST").as_deref() == Ok("big") {
        big::start(ui);
        return;
    }
    let secondary = std::env::var("FASTRA_SNIPPET_SELFTEST").as_deref() == Ok("secondary");
    seed(false);
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("snippet.txt");
    let original = "😀 b\ncat\na\nb";
    std::fs::write(&path, original).unwrap();
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let pause = Cell::new(Instant::now());
    let begin = Instant::now();
    let capture = RefCell::new(None);
    let owner = RefCell::new(None::<Rc<Document>>);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            begin.elapsed() < Duration::from_secs(65),
            "snippet phase{}: {} / {}",
            phase.get(),
            ui.status.text(),
            view()
                .map(|v| v.status.text().to_string())
                .unwrap_or_default()
        );
        if pause.get().elapsed() < Duration::from_millis(450) {
            return glib::ControlFlow::Continue;
        }
        let Some(doc) = owner.borrow().clone().or_else(|| {
            ui.active()
                .filter(|d| d.disk_path().as_ref() == Some(&path))
        }) else {
            return glib::ControlFlow::Continue;
        };
        if owner.borrow().is_none() {
            *owner.borrow_mut() = Some(doc.clone());
        }
        match phase.get() {
            0 => {
                if secondary {
                    fn split(root: &gtk::Widget) -> Option<gtk::CheckButton> {
                        if root.widget_name() == "fastra-source-split" {
                            return root.clone().downcast().ok();
                        }
                        chrome::children(root).iter().find_map(split)
                    }
                    crate::git_view::test_click(&split(doc.container.upcast_ref()).unwrap(), &[]);
                    phase.set(300);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                doc.buffer
                    .select_range(&doc.buffer.iter_at_offset(2), &doc.buffer.iter_at_offset(3));
                open(&ui);
            }
            300 => {
                fn views(root: &gtk::Widget) -> Vec<sourceview5::View> {
                    let mut out = root
                        .clone()
                        .downcast::<sourceview5::View>()
                        .ok()
                        .into_iter()
                        .collect::<Vec<_>>();
                    for child in chrome::children(root) {
                        out.extend(views(&child));
                    }
                    out
                }
                let views = views(doc.container.upcast_ref());
                assert_eq!(views.len(), 2);
                assert!(views[1].is_mapped());
                doc.buffer
                    .select_range(&doc.buffer.start_iter(), &doc.buffer.iter_at_offset(1));
                crate::git_view::test_click(&views[1], &[]);
                phase.set(301);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            301 => {
                let buffer = source_panes::buffer(&doc);
                assert_ne!(buffer, doc.buffer);
                buffer.select_range(&buffer.iter_at_offset(2), &buffer.iter_at_offset(3));
                phase.set(302);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            302 => {
                open(&ui);
                phase.set(1);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            1 => {
                let Some(v) = view().filter(|v| v.snapshot.borrow().is_some() && !v.busy.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!v.dirty.get());
                assert_eq!(v.values.borrow().len(), 2);
                let width = std::env::var("FASTRA_TOOL_WIDTH")
                    .unwrap_or("760".into())
                    .parse::<i32>()
                    .unwrap();
                v.window
                    .set_default_size(width, if width == 760 { 650 } else { 740 });
                v.values.borrow()[1].1.buffer().set_text("Köln");
                let field = v.values.borrow()[0].1.clone();
                crate::git_view::test_click(&field, &["J", "o", "Return", "X"]);
            }
            2 => {
                let v = view().unwrap();
                assert_eq!(
                    super::super::selftest::text(&v.values.borrow()[0].1),
                    "Jo\nX"
                );
                assert_eq!(
                    super::super::selftest::text(&v.after),
                    "Jo\nX / Köln / Jo\nX"
                );
                assert!(
                    v.apply.is_sensitive(),
                    "{}",
                    v.snippet_layout.as_ref().unwrap().stale.text()
                );
                assert_eq!(buffer_text(&doc.buffer), original);
                if !crate::git_view::try_capture_x11(&v.window, "snippet-source-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    v.window.width()
                        <= std::env::var("FASTRA_TOOL_WIDTH")
                            .unwrap_or("760".into())
                            .parse::<i32>()
                            .unwrap()
                            + 2,
                    "minimum width expanded {}",
                    v.window.width()
                );
                v.name.set_text("Repeated fields 2 · Straße");
                phase.set(202);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            202 => {
                let v = view().unwrap();
                crate::git_view::test_click(&v.save, &[]);
                phase.set(203);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            203 => {
                let v = view().unwrap();
                if v.busy.get() || v.dirty.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    super::super::selftest::text(&v.values.borrow()[0].1),
                    "Jo\nX"
                );
                assert_eq!(
                    super::super::selftest::text(&v.after),
                    "Jo\nX / Köln / Jo\nX"
                );
                crate::git_view::test_click(&v.apply, &[]);
                phase.set(3);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            3 => {
                assert!(view().is_none());
                assert_eq!(
                    buffer_text(&doc.buffer),
                    "😀 Jo\nX / Köln / Jo\nX\ncat\na\nb"
                );
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                if secondary {
                    assert_eq!(
                        doc.buffer
                            .selection_bounds()
                            .map(|(a, b)| (a.offset(), b.offset())),
                        Some((0, 1))
                    );
                    if !crate::git_view::try_capture_x11(
                        &ui.window,
                        "snippet-secondary-result-native",
                        &capture,
                    ) {
                        return glib::ControlFlow::Continue;
                    }
                }
                crate::git_view::test_click(
                    &source_panes::capture(&doc).unwrap().view,
                    &["ctrl+z"],
                );
            }
            4 => {
                assert_eq!(buffer_text(&doc.buffer), original, "one native Undo");
                if secondary {
                    assert_eq!(
                        doc.buffer
                            .selection_bounds()
                            .map(|(a, b)| (a.offset(), b.offset())),
                        Some((0, 1))
                    );
                }
                let buffer = source_panes::buffer(&doc);
                buffer.select_range(&buffer.iter_at_offset(2), &buffer.iter_at_offset(3));
                open(&ui);
            }
            5 => {
                let Some(v) = view().filter(|v| !v.busy.get() && v.snapshot.borrow().is_some())
                else {
                    return glib::ControlFlow::Continue;
                };
                let layout = v.snippet_layout.as_ref().unwrap();
                layout.filter.set_text("no matching name");
            }
            6 => {
                let v = view().unwrap();
                assert!(button(
                    v.snippet_layout.as_ref().unwrap().library.upcast_ref(),
                    "Repeated fields 2 · Straße"
                )
                .is_none());
                v.snippet_layout
                    .as_ref()
                    .unwrap()
                    .filter
                    .set_text("REPEATED");
            }
            7 => {
                let v = view().unwrap();
                assert!(button(
                    v.snippet_layout.as_ref().unwrap().library.upcast_ref(),
                    "Repeated fields 2 · Straße"
                )
                .is_some());
                let buffer = source_panes::buffer(&doc);
                buffer.place_cursor(&buffer.end_iter());
            }
            8 => {
                let v = view().unwrap();
                assert!(!v.apply.is_sensitive());
                insert(&v);
                assert_eq!(buffer_text(&doc.buffer), original);
                assert!(v.window.is_visible());
                v.window.close();
            }
            9 => {
                assert!(view().is_none());
                let buffer = source_panes::buffer(&doc);
                buffer.select_range(&buffer.iter_at_offset(2), &buffer.iter_at_offset(3));
                open(&ui);
            }
            10 => {
                let Some(v) = view().filter(|v| !v.busy.get() && v.snapshot.borrow().is_some())
                else {
                    return glib::ControlFlow::Continue;
                };
                doc.buffer.insert_at_cursor("x");
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), original);
                v.name.set_text("Unsaved change");
                assert!(v.dirty.get());
                phase.set(101);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            101 => {
                let v = view().unwrap();
                crate::git_view::test_click(&v.new, &[]);
                phase.set(11);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            11 => {
                let Some(w) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| {
                        w.is_visible()
                            && button(w.upcast_ref(), ui.lang.text("Zurück", "Back")).is_some()
                    })
                else {
                    return glib::ControlFlow::Continue;
                };
                crate::git_view::test_click(
                    &button(w.upcast_ref(), ui.lang.text("Zurück", "Back")).unwrap(),
                    &[],
                );
            }
            12 => {
                let v = view().unwrap();
                assert!(v.dirty.get());
                assert_eq!(v.name.text(), "Unsaved change");
                v.window.close();
            }
            13 => {
                let Some(w) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| {
                        w.is_visible()
                            && button(w.upcast_ref(), ui.lang.text("Verwerfen", "Discard"))
                                .is_some()
                    })
                else {
                    return glib::ControlFlow::Continue;
                };
                crate::git_view::test_click(
                    &button(w.upcast_ref(), ui.lang.text("Verwerfen", "Discard")).unwrap(),
                    &[],
                );
            }
            14 => {
                assert!(view().is_none());
                let buffer = source_panes::buffer(&doc);
                buffer.select_range(&buffer.iter_at_offset(2), &buffer.iter_at_offset(3));
                open(&ui);
            }
            15 => {
                let Some(v) = view().filter(|v| !v.busy.get() && v.snapshot.borrow().is_some())
                else {
                    return glib::ControlFlow::Continue;
                };
                v.name.set_text("Saved via guard");
            }
            16 => {
                let v = view().unwrap();
                crate::git_view::test_click(&v.reload, &[]);
            }
            17 => {
                let Some(w) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| {
                        w.is_visible()
                            && button(w.upcast_ref(), ui.lang.text("Verwerfen", "Discard"))
                                .is_some()
                    })
                else {
                    return glib::ControlFlow::Continue;
                };
                crate::git_view::test_click(
                    &button(w.upcast_ref(), ui.lang.text("Speichern", "Save")).unwrap(),
                    &[],
                );
            }
            18 => {
                let v = view().unwrap();
                if v.busy.get() || v.dirty.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(v.name.text(), "Saved via guard");
                assert_eq!(
                    v.snapshot
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .library
                        .snippets
                        .snippets[0]
                        .name,
                    "Saved via guard"
                );
                crate::git_view::test_click(&v.export, &[]);
            }
            19 => {
                let Some(w) = super::super::selftest::picker() else {
                    return glib::ControlFlow::Continue;
                };
                super::super::selftest::set_save_path(&w, &root.join("snippet-export.json"));
            }
            20 => {
                if let Some(w) = super::super::selftest::picker() {
                    let b = ["Save", "_Save", "Speichern", "_Speichern"]
                        .into_iter()
                        .find_map(|s| button(w.upcast_ref(), s))
                        .unwrap();
                    crate::git_view::test_click(&b, &[]);
                    return glib::ControlFlow::Continue;
                }
                let v = view().unwrap();
                if v.busy.get() || !root.join("snippet-export.json").exists() {
                    return glib::ControlFlow::Continue;
                }
                let archive = SnippetArchive::decode(
                    &std::fs::read(root.join("snippet-export.json")).unwrap(),
                )
                .unwrap();
                assert_eq!(archive.snippets.len(), 1);
                assert_eq!(archive.snippets[0].name, "Saved via guard");
                phase.set(200);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            200 => {
                let v = view().unwrap();
                crate::git_view::test_click(&v.import, &[]);
                phase.set(21);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            21 => {
                let Some(w) = super::super::selftest::picker() else {
                    return glib::ControlFlow::Continue;
                };
                super::super::selftest::set_open_path(&w, &root.join("snippet-export.json"));
            }
            22 => {
                if let Some(w) = super::super::selftest::picker() {
                    let b = ["Open", "_Open", "Öffnen", "_Öffnen"]
                        .into_iter()
                        .find_map(|s| button(w.upcast_ref(), s))
                        .unwrap();
                    crate::git_view::test_click(&b, &[]);
                    return glib::ControlFlow::Continue;
                }
                let Some(w) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| {
                        w.is_visible()
                            && button(w.upcast_ref(), ui.lang.text("Importieren", "Import"))
                                .is_some()
                    })
                else {
                    return glib::ControlFlow::Continue;
                };
                crate::git_view::test_click(
                    &button(w.upcast_ref(), ui.lang.text("Importieren", "Import")).unwrap(),
                    &[],
                );
            }
            23 => {
                let v = view().unwrap();
                if v.busy.get()
                    || v.snapshot
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .library
                        .snippets
                        .snippets
                        .len()
                        != 2
                {
                    return glib::ControlFlow::Continue;
                }
                assert_ne!(
                    v.snapshot
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .library
                        .snippets
                        .snippets[0]
                        .id,
                    v.snapshot
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .library
                        .snippets
                        .snippets[1]
                        .id
                );
                assert_ne!(
                    v.snapshot
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .library
                        .snippets
                        .snippets[0]
                        .name,
                    v.snapshot
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .library
                        .snippets
                        .snippets[1]
                        .name
                );
                if let Some(Draft::Snippet(s)) = v.draft.borrow_mut().as_mut() {
                    s.template = "nul\0value".into();
                }
                refresh(&v);
                assert!(!v.apply.is_sensitive());
                insert(&v);
                assert_eq!(buffer_text(&doc.buffer), original);
                v.window.close();
            }
            _ => {
                assert!(view().is_none());
                assert_eq!(buffer_text(&doc.buffer), original);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                println!("FASTRA_SNIPPET_SELFTEST_OK captured-source/multiline-literal-repeated/native-insert-one-undo/filter/stale-selection/stale-revision/dirty-guard-save-discard-cancel/native-json-export-import/collision-renaming/nul-refusal/source-file-unchanged");
                std::process::exit(0);
            }
        }
        eprintln!("snippet phase{}", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}

mod rich;

mod big;
