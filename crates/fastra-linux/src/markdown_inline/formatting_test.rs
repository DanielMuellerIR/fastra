use super::selftest::{bar, find, reset, same, views};
use super::*;
use std::time::Instant;

pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(
        std::env::var("FASTRA_TOOL_WIDTH")
            .unwrap_or("1100".into())
            .parse()
            .unwrap(),
        650,
    );
    ui.add_document("format.md", "雪🙂\nsecond\n");
    let doc = ui.active().unwrap();
    let mut panes = Vec::new();
    views(doc.container.upcast_ref(), &mut panes);
    find::<gtk::CheckButton>(
        doc.container.upcast_ref(),
        ui.lang
            .text("Quelltextansicht teilen", "Split source editor"),
    )
    .unwrap()
    .set_active(true);
    let toolbar = bar(doc.container.upcast_ref()).unwrap();
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let which = Cell::new(0usize);
    let cases = [
        ("hardBreak", "雪🙂  \nsecond\n"),
        ("heading1", "# 雪🙂\n# second\n"),
        ("heading2", "## 雪🙂\n## second\n"),
        ("heading3", "### 雪🙂\n### second\n"),
        ("plainParagraph", "雪🙂\nsecond\n"),
        ("bulletList", "- 雪🙂\n- second\n"),
        ("orderedList", "1. 雪🙂\n2. second\n"),
        ("taskList", "- [ ] 雪🙂\n- [ ] second\n"),
        ("quote", "> 雪🙂\n> second\n"),
        ("link", "[雪🙂\nsecond\n]()"),
    ];
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 60,
            "formatting phase{} case{}: {} source={:?}",
            phase.get(),
            which.get(),
            ui.status.text(),
            buffer_text(&doc.buffer)
        );
        if pause.get().elapsed() < Duration::from_millis(240) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                git_view::test_click(&panes[1], &[]);
            }
            1 => {
                let scroll = toolbar.downcast_ref::<gtk::ScrolledWindow>().unwrap();
                let child = scroll.child().unwrap();
                let content = child
                    .downcast_ref::<gtk::Viewport>()
                    .and_then(|view| view.child())
                    .unwrap_or(child);
                let commands = chrome::children(&content)
                    .iter()
                    .filter_map(|w| {
                        w.downcast_ref::<gtk::Button>()
                            .and_then(|b| b.tooltip_text())
                            .map(|s| s.to_string())
                    })
                    .collect::<Vec<_>>();
                assert_eq!(
                    commands,
                    COMMANDS
                        .iter()
                        .map(|(_, de, en, _)| ui.lang.text(de, en).to_string())
                        .collect::<Vec<_>>()
                );
                git_view::capture(ui.window.upcast_ref(), "markdown-source-commands");
            }
            2 => {
                let (id, _) = cases[which.get()];
                reset(
                    &doc,
                    if id == "plainParagraph" {
                        "## 雪🙂\n## second\n"
                    } else {
                        "雪🙂\nsecond\n"
                    },
                );
                let target = source_panes::capture(&doc).unwrap();
                assert_eq!(target.view, panes[1]);
                if id == "hardBreak" {
                    target.buffer.place_cursor(&target.buffer.iter_at_offset(2));
                } else {
                    target
                        .buffer
                        .select_range(&target.buffer.start_iter(), &target.buffer.end_iter());
                }
                let (_, de, en, _) = COMMANDS
                    .iter()
                    .find(|(command, _, _, _)| *command == id)
                    .unwrap();
                let button = find::<gtk::Button>(&toolbar, ui.lang.text(de, en)).unwrap();
                // Auch bei Mindestbreite liegt der Befehl in der horizontalen Leiste.
                let scroll = toolbar.downcast_ref::<gtk::ScrolledWindow>().unwrap();
                let content = scroll.child().unwrap();
                let bounds = button.compute_bounds(&content).unwrap();
                scroll.hadjustment().set_value(
                    f64::from(bounds.x())
                        .min(scroll.hadjustment().upper() - scroll.hadjustment().page_size()),
                );
                let click = button.clone();
                glib::timeout_add_local_once(Duration::from_millis(50), move || {
                    git_view::test_click(&click, &[])
                });
            }
            3 => {
                if buffer_text(&doc.buffer) != cases[which.get()].1 {
                    return glib::ControlFlow::Continue;
                }
                same(&doc, cases[which.get()].1);
                let target = source_panes::capture(&doc).unwrap();
                target.buffer.undo();
            }
            4 => {
                let original = if cases[which.get()].0 == "plainParagraph" {
                    "## 雪🙂\n## second\n"
                } else {
                    "雪🙂\nsecond\n"
                };
                same(&doc, original);
                assert!(!source_panes::buffer(&doc).can_undo());
                which.set(which.get() + 1);
                if which.get() < cases.len() {
                    phase.set(2);
                } else {
                    phase.set(5);
                }
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            5 => {
                reset(&doc, "雪🙂");
                let target = source_panes::capture(&doc).unwrap();
                target.buffer.place_cursor(&target.buffer.end_iter());
                git_view::test_keys(&target.view, &["ctrl+k"]);
            }
            6 => {
                if buffer_text(&doc.buffer) != "雪🙂[]()" {
                    return glib::ControlFlow::Continue;
                }
                source_panes::buffer(&doc).undo();
                command(&ui, &doc, "insertTable");
            }
            7 | 10 => {
                let Some(window) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| {
                        w.is_mapped()
                            && w.title().as_deref()
                                == Some(ui.lang.text("Tabelle einfügen", "Insert table"))
                    })
                else {
                    return glib::ControlFlow::Continue;
                };
                if phase.get() == 7 {
                    git_view::capture(&window, "markdown-table-config");
                    git_view::test_click(
                        &find::<gtk::Button>(
                            window.upcast_ref(),
                            ui.lang.text("Abbrechen", "Cancel"),
                        )
                        .unwrap(),
                        &[],
                    );
                } else {
                    let insert = find::<gtk::Button>(
                        window.upcast_ref(),
                        ui.lang.text("Tabelle einfügen", "Insert table"),
                    )
                    .unwrap();
                    git_view::test_click(&insert, &[]);
                }
            }
            8 => {
                same(&doc, "雪🙂");
                assert!(!source_panes::buffer(&doc).can_undo());
                git_view::test_keys(&ui.window, &[]);
            }
            9 => {
                command(&ui, &doc, "insertTable");
            }
            11 => {
                let expected = format!(
                    "雪🙂\n\n| {} 1 | {} 2 | {} 3 |\n| --- | --- | --- |\n|   |   |   |",
                    ui.lang.text("Spalte", "Column"),
                    ui.lang.text("Spalte", "Column"),
                    ui.lang.text("Spalte", "Column")
                );
                if buffer_text(&doc.buffer) != expected {
                    return glib::ControlFlow::Continue;
                }
                let target = source_panes::capture(&doc).unwrap();
                let source = buffer_text(&target.buffer);
                let at = target.offsets().0 as usize;
                assert!(source
                    .chars()
                    .take(at)
                    .collect::<String>()
                    .ends_with("\n| "));
                target.buffer.undo();
                same(&doc, "雪🙂");
                assert!(!target.buffer.can_undo());
                std::env::set_var("FASTRA_SPLIT_REPLY_DELAY", "400");
                target
                    .buffer
                    .select_range(&target.buffer.start_iter(), &target.buffer.end_iter());
                command(&ui, &doc, "heading1");
                target.buffer.place_cursor(&target.buffer.end_iter());
            }
            12 => {
                if pause.get().elapsed() < Duration::from_millis(600) {
                    return glib::ControlFlow::Continue;
                }
                same(&doc, "雪🙂");
                assert!(!source_panes::buffer(&doc).can_undo());
                std::env::remove_var("FASTRA_SPLIT_REPLY_DELAY");
                reset(&doc, &"x".repeat(64 * 1024 - 1));
                let target = source_panes::capture(&doc).unwrap();
                target.buffer.place_cursor(&target.buffer.start_iter());
                command(&ui, &doc, "heading1");
            }
            13 => {
                if !ui.status.text().contains("64 KiB") {
                    return glib::ControlFlow::Continue;
                }
                same(&doc, &"x".repeat(64 * 1024 - 1));
                assert!(!source_panes::buffer(&doc).can_undo());
                fn visible_notice(widget: &gtk::Widget) -> bool {
                    widget
                        .downcast_ref::<gtk::Label>()
                        .is_some_and(|label| label.is_mapped() && label.text().contains("64 KiB"))
                        || chrome::children(widget).iter().any(visible_notice)
                }
                assert!(
                    visible_notice(ui.window.upcast_ref()),
                    "Refusal must be visible in the document window while search is closed"
                );
                git_view::capture(ui.window.upcast_ref(), "markdown-source-refusal");
                println!("PASS native Markdown source: all block/link/hardbreak commands, exact15 order, Unicode split source, single Undo, actual CtrlK, table default3/header/Cancel/caret, delayed stale selection and overlong output refusal");
                git_view::finish(
                    ui.window.clone().upcast(),
                    ui.clone(),
                    "markdown-formatting",
                );
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
