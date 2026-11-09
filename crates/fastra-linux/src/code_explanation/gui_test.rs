use super::*;
use serde_json::json;
use sha2::{Digest, Sha256};
fn button(widget: &gtk::Widget, label: &str) -> Option<gtk::Button> {
    if let Some(b) = widget
        .downcast_ref::<gtk::Button>()
        .filter(|b| b.label().as_deref() == Some(label))
    {
        return Some(b.clone());
    }
    let mut child = widget.first_child();
    while let Some(w) = child {
        if let Some(b) = button(&w, label) {
            return Some(b);
        }
        child = w.next_sibling();
    }
    None
}
fn tools(widget: &gtk::Widget) -> Option<gtk::MenuButton> {
    if let Some(b) = widget
        .downcast_ref::<gtk::MenuButton>()
        .filter(|b| matches!(b.label().as_deref(), Some("Tools" | "Werkzeuge")))
    {
        return Some(b.clone());
    }
    let mut child = widget.first_child();
    while let Some(w) = child {
        if let Some(b) = tools(&w) {
            return Some(b);
        }
        child = w.next_sibling();
    }
    None
}
#[allow(deprecated)]
fn chooser_path(window: &gtk::Window, path: String) {
    let chooser = window
        .clone()
        .dynamic_cast::<gtk::FileChooser>()
        .expect("Native fallback chooser");
    chooser.set_file(&gio::File::for_path(path)).unwrap();
    let window = window.downgrade();
    glib::timeout_add_local_once(Duration::from_millis(700), move || {
        if let Some(window) = window.upgrade().filter(|w| w.is_visible()) {
            let open = button(window.upcast_ref(), "Open")
                .or_else(|| button(window.upcast_ref(), "Öffnen"))
                .or_else(|| button(window.upcast_ref(), "_Open"))
                .or_else(|| button(window.upcast_ref(), "_Öffnen"))
                .expect("Native chooser accept button");
            support::test_click(&open, &[]);
        }
    });
}

fn fixture(root: &std::path::Path) -> PathBuf {
    std::fs::create_dir_all(root.join("src")).unwrap();
    let first = format!(
        "// frozen source 😀\r\n{}tail\n",
        (0..150)
            .map(|n| format!("let value{n} = {n}\n"))
            .collect::<String>()
    );
    let second = "let café = \"雪\"\nlet emoji = \"👩‍💻\"\n";
    let first_bytes = [b"\xef\xbb\xbf".as_slice(), first.as_bytes()].concat();
    std::fs::write(root.join("src/first.swift"), &first_bytes).unwrap();
    std::fs::write(root.join("src/second.swift"), second).unwrap();
    let a = "22222222-2222-2222-2222-222222222222";
    let b = "33333333-3333-3333-3333-333333333333";
    let mut manifest = json!({"schemaVersion":1,"id":"11111111-1111-1111-1111-111111111111","title":"Frozen Unicode code question","question":"Explore the source, pause, and deliberately return. No working document may change.","language":"en","createdAt":"2026-11-05T09:30:00Z","projectID":"44444444-4444-4444-4444-444444444444","projectName":"Local synthetic project","sources":[{"id":a,"path":"src/first.swift","sha256":format!("{:x}",Sha256::digest(&first_bytes)),"encoding":"utf8"},{"id":b,"path":"src/second.swift","sha256":format!("{:x}",Sha256::digest(second.as_bytes())),"encoding":"utf8"}],"steps":[{"id":"55555555-5555-5555-5555-555555555555","title":"First frozen source","text":"This explanation is preserved in the package language. The source is read-only.","sourceID":a,"location":0,"length":2},{"id":"66666666-6666-6666-6666-666666666666","title":"Second source, Unicode","text":"Inspect the exact UTF-16 range in another frozen source.","sourceID":b,"location":4,"length":4},{"id":"77777777-7777-7777-7777-777777777777","title":"Return to a distant line","text":"The last step deliberately scrolls into the first source.","sourceID":a,"location":first[..first.find("tail").unwrap()].encode_utf16().count(),"length":4}],"codeFontSize":12,"explanationFontSize":12});
    if std::env::var_os("FASTRA_EXPLANATION_METADATA_SELFTEST").is_some() {
        manifest["title"] = json!("Frozen\nUnicode ".to_owned() + &"Title ".repeat(20));
        manifest["question"] = json!("Long metadata question.\n".repeat(75));
        manifest["steps"][0]["title"] = json!("First\nFrozen source");
    }
    let path = root.join("question.json");
    std::fs::write(&path, serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();
    path
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = fixture(&root);
    ui.add_document("unsaved-work.txt", "unsaved working text");
    let doc = ui.active().unwrap();
    doc.buffer.insert(&mut doc.buffer.end_iter(), " retained");
    let original = super::super::buffer_text(&doc.buffer);
    let count = ui.documents.borrow().len();
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(started);
    let held = RefCell::new(None::<Rc<Player>>);
    let old_ids = RefCell::new(Vec::<String>::new());
    let capture = RefCell::new(None::<std::sync::mpsc::Receiver<bool>>);
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or_else(|_| "400".into())
        .parse::<i32>()
        .unwrap();
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            started.elapsed() < Duration::from_secs(85),
            "explanation phase{}: {}",
            phase.get(),
            held.borrow().as_ref().map_or_else(
                || ui.status.text().to_string(),
                |p| p.status.text().to_string()
            )
        );
        assert_eq!(ui.documents.borrow().len(), count);
        assert_eq!(super::super::buffer_text(&doc.buffer), original);
        assert!(doc.buffer.is_modified());
        if pause.get().elapsed() < Duration::from_millis(350) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                let tool = tools(ui.window.upcast_ref()).unwrap();
                if !tool.is_mapped() {
                    fn menu(widget: &gtk::Widget) -> Option<gtk::MenuButton> {
                        if let Some(menu) =
                            widget.downcast_ref::<gtk::MenuButton>().filter(|button| {
                                matches!(
                                    button.tooltip_text().as_deref(),
                                    Some("Fastra menu" | "Fastra-Menü")
                                )
                            })
                        {
                            return Some(menu.clone());
                        }
                        crate::chrome::children(widget)
                            .into_iter()
                            .find_map(|widget| menu(&widget))
                    }
                    support::test_click(&menu(ui.window.upcast_ref()).unwrap(), &[]);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&tool, &[]);
            }
            1 => {
                let menu = tools(ui.window.upcast_ref()).unwrap();
                let tool = button(
                    menu.popover().unwrap().upcast_ref(),
                    ui.lang.text(
                        "Gespeicherte Codefrage öffnen …",
                        "Open saved code question …",
                    ),
                )
                .unwrap();
                support::test_click(&tool, &[]);
            }
            2 => {
                let Some(window) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| {
                        w.is_visible()
                            && w.title().as_deref()
                                == Some(ui.lang.text(
                                    "Gespeicherte Codefrage öffnen",
                                    "Open saved code question",
                                ))
                    })
                else {
                    return glib::ControlFlow::Continue;
                };
                chooser_path(&window, path.to_str().unwrap().into());
            }
            3 => {
                let Some(player) = PLAYERS
                    .with(|p| p.borrow().last().cloned())
                    .filter(|p| p.phase.get() == Phase::Ready)
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!player.source.is_editable());
                assert!(!player.explanation.is_editable());
                assert_eq!(player.index.get(), 0);
                assert_eq!(player.selected_source.get(), 0);
                assert_eq!(
                    player
                        .buffer
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((0, 2))
                );
                player.window.set_default_size(width, 850);
                *held.borrow_mut() = Some(player);
            }
            4 => {
                let player = held.borrow().as_ref().unwrap().clone();
                fn widgets(widget: &gtk::Widget, all: &mut Vec<gtk::Widget>) {
                    all.push(widget.clone());
                    for child in crate::chrome::children(widget) {
                        widgets(&child, all);
                    }
                }
                let mut all = Vec::new();
                widgets(player.window.upcast_ref(), &mut all);
                layout::check_geometry(&player.window);
                assert!(
                    player.window.titlebar().unwrap().height() <= 40,
                    "long metadata must not enlarge the title bar"
                );
                assert!(
                    player.step_title.height() <= 24,
                    "multiline step titles retain one visible heading line"
                );
                assert!(
                    player.window.width() <= width + 2,
                    "requested narrow width {width}, actual {}",
                    player.window.width()
                );
                let glyph = player
                    .source
                    .iter_location(&player.buffer.start_iter())
                    .width();
                let reference = player.source.create_pango_layout(Some("/"));
                let mut description = gtk::pango::FontDescription::from_string("monospace");
                description.set_absolute_size(13. * f64::from(gtk::pango::SCALE));
                reference.set_font_description(Some(&description));
                let base = reference.pixel_size().0;
                eprintln!("PLAYER native12 glyph={glyph}px, reference13={base}px");
                assert!((base-2..=base).contains(&glyph), "12 logical Mac points must not render larger than the 13px source role: {glyph} vs {base}");
                support::capture(&player.window, "explanation-first");
                if std::env::var_os("FASTRA_EXPLANATION_METADATA_SELFTEST").is_some() {
                    let name = all
                        .iter()
                        .find(|widget| widget.widget_name() == "explanation-source-info")
                        .unwrap();
                    support::test_click(name, &[]);
                    phase.set(44);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                let plus = all.iter().find(|widget| {
                    widget.widget_name() == "explanation-code-larger" && widget.is_mapped()
                });
                if let Some(plus) = plus {
                    support::test_click(plus, &[]);
                    phase.set(41);
                } else {
                    let menu = all
                        .iter()
                        .find(|widget| {
                            widget.widget_name() == "explanation-font-menu" && widget.is_mapped()
                        })
                        .unwrap();
                    support::test_click(menu, &[]);
                    phase.set(40);
                }
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            44 => {
                let player = held.borrow().as_ref().unwrap().clone();
                let popup = player
                    .source_select
                    .ancestor(gtk::Popover::static_type())
                    .unwrap();
                assert!(player.source_select.is_mapped());
                assert!(popup.height() < 360, "large question must remain bounded");
                let bounds = player.source_select.compute_bounds(&popup).unwrap();
                assert!(bounds.y() >= 0. && bounds.y() + bounds.height() <= popup.height() as f32);
                if !support::try_capture_x11(&popup, "explanation-long-metadata", &capture) {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&player.source_select, &["Escape"]);
                phase.set(45);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            45 => {
                let player = held.borrow().as_ref().unwrap().clone();
                if width >= 580 {
                    player.code_size.set_value(32.);
                    player.navigate(0);
                    fn plus(widget: &gtk::Widget) -> Option<gtk::Button> {
                        if let Some(button) =
                            widget.downcast_ref::<gtk::Button>().filter(|button| {
                                button.widget_name() == "explanation-code-larger"
                                    && button.is_mapped()
                            })
                        {
                            return Some(button.clone());
                        }
                        crate::chrome::children(widget)
                            .into_iter()
                            .find_map(|child| plus(&child))
                    }
                    support::test_click(&plus(player.window.upcast_ref()).unwrap(), &[]);
                    phase.set(46);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&player.return_button, &[]);
                phase.set(42);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            40 => {
                fn plus(widget: &gtk::Widget) -> Option<gtk::Button> {
                    if let Some(button) = widget.downcast_ref::<gtk::Button>().filter(|button| {
                        button.widget_name() == "explanation-code-larger" && button.is_mapped()
                    }) {
                        return Some(button.clone());
                    }
                    crate::chrome::children(widget)
                        .into_iter()
                        .find_map(|child| plus(&child))
                }
                let player = held.borrow().as_ref().unwrap().clone();
                support::test_click(&plus(player.window.upcast_ref()).unwrap(), &[]);
                phase.set(41);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            41 => {
                let player = held.borrow().as_ref().unwrap().clone();
                assert_eq!(player.code_size.value(), 13.);
                let glyph = player
                    .source
                    .iter_location(&player.buffer.start_iter())
                    .width();
                let reference = player.source.create_pango_layout(Some("/"));
                let mut description = gtk::pango::FontDescription::from_string("monospace");
                description.set_absolute_size(13. * f64::from(gtk::pango::SCALE));
                reference.set_font_description(Some(&description));
                let base = reference.pixel_size().0;
                assert!(
                    (glyph - base).abs() <= 1,
                    "13 logical Mac points match the 13px source role: {glyph} vs {base}"
                );
                assert!(player.phase.get() == Phase::Paused);
                support::test_click(&player.return_button, &[]);
                phase.set(42);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            46 => {
                let player = held.borrow().as_ref().unwrap().clone();
                assert_eq!(player.code_size.value(), 32.);
                assert!(
                    player.phase.get() == Phase::Paused,
                    "font step at the upper bound must pause rather than publish a late Ready"
                );
                player.code_size.set_value(13.);
                support::test_click(&player.return_button, &[]);
                phase.set(42);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            42 => {
                let player = held.borrow().as_ref().unwrap().clone();
                if player.phase.get() != Phase::Ready {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&player.next, &[]);
                phase.set(4);
            }
            5 => {
                let player = held.borrow().as_ref().unwrap().clone();
                if player.phase.get() != Phase::Ready || player.index.get() != 1 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(player.selected_source.get(), 1);
                assert_eq!(
                    player
                        .buffer
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((4, 8))
                );
                support::capture(&player.window, "explanation-unicode");
                support::test_click(&player.source, &["ctrl+a", "Delete", "ctrl+s"]);
            }
            6 => {
                let player = held.borrow().as_ref().unwrap().clone();
                assert!(player.phase.get() == Phase::Paused);
                assert_eq!(
                    super::super::buffer_text(&player.buffer),
                    player.package.sources[&player.package.manifest.sources[1].id]
                        .text
                        .as_ref()
                );
                support::test_click(&player.return_button, &[]);
            }
            7 => {
                let player = held.borrow().as_ref().unwrap().clone();
                if player.phase.get() != Phase::Ready {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(&player.next, &[]);
            }
            8 => {
                let player = held.borrow().as_ref().unwrap().clone();
                if player.phase.get() != Phase::Completed {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(player.index.get(), 2);
                assert_eq!(player.selected_source.get(), 0);
                assert_eq!(
                    player.buffer.text(
                        &player.buffer.selection_bounds().unwrap().0,
                        &player.buffer.selection_bounds().unwrap().1,
                        true
                    ),
                    "tail"
                );
                support::capture(&player.window, "explanation-last");
                support::test_click(&player.source, &["Home"]);
            }
            9 => {
                let player = held.borrow().as_ref().unwrap().clone();
                assert!(player.phase.get() == Phase::Paused);
                player.navigate(0);
                player.text_size.set_value(14.);
            }
            10 => {
                let player = held.borrow().as_ref().unwrap().clone();
                assert!(
                    player.phase.get() == Phase::Paused,
                    "A superseded layout callback cannot report Ready"
                );
                support::test_click(&player.wrap, &[]);
            }
            11 => {
                let player = held.borrow().as_ref().unwrap().clone();
                assert!(!player.wrap.is_active());
                player.code_size.set_value(16.);
                player.text_size.set_value(18.);
                std::fs::write(
                    root.join("src/first.swift"),
                    b"source changed after package load",
                )
                .unwrap();
                support::test_click(&player.return_button, &[]);
            }
            12 => {
                let player = held.borrow().as_ref().unwrap().clone();
                if player.phase.get() != Phase::Ready {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    super::super::buffer_text(&player.buffer).starts_with("// frozen source 😀")
                );
                support::capture(&player.window, "explanation-return-frozen");
                *old_ids.borrow_mut() = player.document_ids.clone();
                support::test_click(&player.source, &["ctrl+w"]);
            }
            13 => {
                let player = held.borrow().as_ref().unwrap().clone();
                if player.window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert!(PLAYERS.with(|p| p.borrow().is_empty()));
                assert!(player.phase.get() == Phase::Closed);
                let _ = fixture(&root);
                let package = Package::load(&path, &fastra_core::Cancellation::default()).unwrap();
                let reopened =
                    open_package(&ui.window.application().unwrap(), package, ui.lang).unwrap();
                reopened.window.set_default_size(width, 850);
                *held.borrow_mut() = Some(reopened);
            }
            14 => {
                let player = held.borrow().as_ref().unwrap().clone();
                if player.phase.get() != Phase::Ready {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(player.index.get(), 0);
                assert!(player
                    .document_ids
                    .iter()
                    .all(|id| !old_ids.borrow().contains(id)));
                player.navigate(1);
                player.buffer.set_text("unexpected view contents");
            }
            15 => {
                let player = held.borrow().as_ref().unwrap().clone();
                assert!(player.phase.get() == Phase::Paused);
                player.navigate(1);
            }
            16 => {
                let player = held.borrow().as_ref().unwrap().clone();
                if player.phase.get() == Phase::Loading {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    player.phase.get() == Phase::Failed,
                    "Actual view contents must match the sealed snapshot"
                );
                player.window.close();
                assert!(PLAYERS.with(|p| p.borrow().is_empty()));
                assert_eq!(ui.documents.borrow().len(), count);
                assert_eq!(super::super::buffer_text(&doc.buffer), original);
                println!("FASTRA_EXPLANATION_SELFTEST=PASS actual-tools-filechooser frozen-hashes utf16-ready source-switch native-navigation own-exploration stale-layout readonly wrap-fonts isolated-dirty ctrl-w fresh-ids");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        eprintln!("explanation native phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
