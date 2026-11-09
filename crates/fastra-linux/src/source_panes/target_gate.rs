use super::*;
use std::time::Instant;
fn text(root: &gtk::Widget, label: &str) -> Option<gtk::Widget> {
    if root.is_mapped()
        && root
            .downcast_ref::<gtk::Label>()
            .is_some_and(|w| w.text() == label)
    {
        return Some(root.clone());
    }
    let mut child = root.first_child();
    while let Some(c) = child {
        if let Some(w) = text(&c, label) {
            return Some(w);
        }
        child = c.next_sibling();
    }
    None
}
fn find<T: IsA<gtk::Widget> + glib::object::ObjectType>(root: &gtk::Widget) -> Option<T> {
    if let Ok(w) = root.clone().dynamic_cast::<T>() {
        return Some(w);
    }
    let mut child = root.first_child();
    while let Some(c) = child {
        if let Some(w) = find(&c) {
            return Some(w);
        }
        child = c.next_sibling();
    }
    None
}
fn dialog(ui: &Ui) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .iter()
        .filter_map(|o| o.downcast_ref::<gtk::Window>().cloned())
        .find(|w| {
            w.is_visible()
                && w.title().as_deref()
                    == Some(
                        ui.lang
                            .text("Zu Zeile/Spalte springen", "Go to line/column"),
                    )
        })
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or("1100".into())
        .parse()
        .unwrap();
    ui.window.set_default_size(width, 1000);
    let original = "first\nsecond\nthird café🙂\r\n";
    ui.add_document("pane-target.txt", original);
    let doc = ui.active().unwrap();
    let mut all = Vec::new();
    super::gate::views(doc.container.upcast_ref(), &mut all);
    super::gate::named::<gtk::CheckButton>(
        doc.container.upcast_ref(),
        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
    )
    .unwrap()
    .set_active(true);
    let index = std::env::var("FASTRA_SPLIT_FROM")
        .unwrap_or("1".into())
        .parse::<usize>()
        .unwrap();
    assert!(index < 2);
    let other = 1 - index;
    let negative = std::env::var("FASTRA_SPLIT_TARGET_CASE").unwrap_or_default();
    let stage = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    let bound = RefCell::new(None::<Target>);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            start.elapsed().as_secs() < 45,
            "target stage{} status{}",
            stage.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(250) {
            return glib::ControlFlow::Continue;
        }
        super::gate::same(&doc, &all, &format!("target-{}", stage.get()));
        match stage.get() {
            0 => crate::git_view::test_click(
                &all[other],
                &[
                    "ctrl+Home",
                    "shift+Right",
                    "shift+Right",
                    "shift+Right",
                    "shift+Right",
                    "shift+Right",
                ],
            ),
            1 => crate::git_view::test_click(
                &all[index],
                &[
                    "ctrl+Home",
                    "Down",
                    "Home",
                    "shift+Right",
                    "shift+Right",
                    "shift+Right",
                    "shift+Right",
                    "shift+Right",
                    "shift+Right",
                ],
            ),
            2 => {
                assert_eq!(
                    all[other]
                        .buffer()
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((0, 5))
                );
                assert_eq!(
                    all[index]
                        .buffer()
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((6, 12))
                );
                *bound.borrow_mut() = capture(&doc);
                if !crate::git_view::try_capture(ui.window.upcast_ref(), "pane-target-selections") {
                    return glib::ControlFlow::Continue;
                }
                crate::git_view::test_click(
                    &super::gate::named::<gtk::MenuButton>(ui.window.upcast_ref(), "Text").unwrap(),
                    &[],
                );
            }
            3 => {
                let Some(label) = text(ui.window.upcast_ref(), "Unicode") else {
                    return glib::ControlFlow::Continue;
                };
                crate::git_view::test_click(&label, &[]);
            }
            4 => {
                let Some(label) = text(
                    ui.window.upcast_ref(),
                    ui.lang
                        .text("Großschreibung (ICU Root)", "Uppercase (ICU Root)"),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                crate::git_view::test_click(&label, &[]);
            }
            5 => {
                if negative == "op-aba" {
                    all[other].grab_focus();
                    all[index].grab_focus();
                    assert!(!bound.borrow().as_ref().unwrap().valid(&doc));
                } else if negative == "op-readonly" {
                    all[index].set_editable(false);
                } else if negative == "op-source" {
                    doc.buffer.insert(&mut doc.buffer.end_iter(), "!");
                } else if negative == "op-tab" {
                    let at = ui.tabs.current_page();
                    ui.add_document("other-owner.txt", "OTHER");
                    ui.tabs.set_current_page(at);
                }
                if negative.starts_with("op-") {
                    stage.set(30);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
            }
            6 => {
                if buffer_text(&doc.buffer) == original {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "first\nSECOND\nthird café🙂\r\n");
                assert_eq!(
                    all[other]
                        .buffer()
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((0, 5))
                );
                crate::git_view::test_click(
                    &super::gate::named::<gtk::MenuButton>(
                        ui.window.upcast_ref(),
                        ui.lang.text("Werkzeuge", "Tools"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            7 => {
                let Some(label) = text(
                    ui.window.upcast_ref(),
                    ui.lang
                        .text("Zu Zeile/Spalte springen …", "Go to line/column …"),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                crate::git_view::test_click(&label, &[]);
            }
            8 => {
                let Some(w) = dialog(&ui) else {
                    return glib::ControlFlow::Continue;
                };
                let entry = find::<gtk::Entry>(w.upcast_ref()).unwrap();
                crate::git_view::test_click(&entry, &["ctrl+a", "3", "colon", "2"]);
            }
            9 => {
                let w = dialog(&ui).unwrap();
                let entry = find::<gtk::Entry>(w.upcast_ref()).unwrap();
                if entry.text() != "3:2" {
                    return glib::ControlFlow::Continue;
                }
                *bound.borrow_mut() = capture(&doc);
                crate::git_view::test_click(
                    &super::gate::named::<gtk::Button>(
                        w.upcast_ref(),
                        ui.lang.text("Springen", "Go"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            10 => {
                if negative == "goto-aba" {
                    all[other].grab_focus();
                    all[index].grab_focus();
                    stage.set(31);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                if dialog(&ui).is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(all[index].buffer().cursor_position(), 14);
                assert_eq!(
                    all[other]
                        .buffer()
                        .selection_bounds()
                        .map(|(a, b)| (a.offset(), b.offset())),
                    Some((0, 5))
                );
                assert!(all[index].has_focus());
                if !crate::git_view::try_capture(ui.window.upcast_ref(), "pane-target-goto") {
                    return glib::ControlFlow::Continue;
                }
            }
            11 => {
                crate::git_view::test_click(
                    &super::gate::named::<gtk::CheckButton>(
                        doc.container.upcast_ref(),
                        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            12 => {
                assert!(!all[1].is_mapped());
                assert_eq!(capture(&doc).unwrap().view, all[0]);
                println!("SPLIT TARGET PASS native Text→Unicode→Uppercase only pane{index}, inactive selection retained; native Tools→Goto only pane{index}; Split off→Primary; width={width}");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            30 => {
                if pause.get().elapsed() < Duration::from_millis(650) {
                    return glib::ControlFlow::Continue;
                }
                let expected = if negative == "op-source" {
                    format!("{original}!")
                } else {
                    original.into()
                };
                assert_eq!(
                    buffer_text(&doc.buffer),
                    expected,
                    "late operation applied after {negative}"
                );
                println!("SPLIT TARGET {negative} PASS late native menu result discarded");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            31 => {
                if pause.get().elapsed() < Duration::from_millis(650) {
                    return glib::ControlFlow::Continue;
                }
                assert!(dialog(&ui).is_some());
                assert!(!bound.borrow().as_ref().unwrap().valid(&doc));
                println!("SPLIT TARGET goto-aba PASS native late Go discarded after PaneABA");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
