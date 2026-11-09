use super::*;
use std::{path::PathBuf, time::Instant};
fn widgets<T: IsA<gtk::Widget> + glib::object::ObjectType>(root: &gtk::Widget) -> Vec<T> {
    let mut result = root
        .clone()
        .downcast::<T>()
        .ok()
        .into_iter()
        .collect::<Vec<_>>();
    for child in chrome::children(root) {
        result.extend(widgets::<T>(&child));
    }
    result
}
fn window(ui: &Ui) -> gtk::Window {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| {
            w.is_mapped()
                && w.title().as_deref()
                    == Some(ui.lang.text("Suchen & Ersetzen", "Search & Replace"))
        })
        .unwrap()
}
fn button(ui: &Ui, de: &'static str, en: &'static str) -> gtk::Button {
    widgets::<gtk::Button>(window(ui).upcast_ref())
        .into_iter()
        .find(|b| b.is_mapped() && b.label().as_deref() == Some(ui.lang.text(de, en)))
        .unwrap()
}
fn detail(ui: &Ui) -> gtk::TextView {
    widgets::<gtk::TextView>(window(ui).upcast_ref())
        .into_iter()
        .find(|v| v.is_mapped() && v.widget_name() == "fastra-search-detail")
        .unwrap()
}
fn find(ui: &Ui) -> gtk::Entry {
    widgets::<gtk::Entry>(window(ui).upcast_ref())
        .into_iter()
        .find(|e| {
            e.placeholder_text().as_deref() == Some(ui.lang.text("Suchausdruck eingeben…", "Enter a search expression…"))
        })
        .unwrap()
}
fn select(ui: &Ui, at: i32) {
    let v = detail(ui);
    v.grab_focus();
    let mut keys = vec!["ctrl+Home"];
    keys.extend(std::iter::repeat_n("Right", at as usize));
    keys.push("shift+Right");
    git_view::test_keys(&v, &keys);
}
fn selected(ui: &Ui, at: i32) -> bool {
    detail(ui)
        .buffer()
        .selection_bounds()
        .is_some_and(|(a, b)| a.offset() == at && b.offset() == at + 1)
}
fn ready(ui: &Ui) -> bool {
    button(ui, "Gruppe definieren", "Define group").is_sensitive()
        && buffer_text(&detail(ui).buffer()) == "abc"
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let scope = std::env::var("FASTRA_SEARCH_GROUPS_SELFTEST")
        .unwrap()
        .parse::<u32>()
        .unwrap();
    assert!(scope <= 3);
    let fixture = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).join("groups");
    std::fs::create_dir_all(&fixture).unwrap();
    let path = fixture.join("groups.txt");
    std::fs::write(&path, "abc abc\r\n").unwrap();
    ui.add_document("groups.txt", "abc abc\r\n");
    ui.mode.set_selected(2);
    ui.case.set_active(true);
    ui.find.set_text("(a)b(c)");
    ui.replace.set_text("X$2");
    if scope == 3 {
        project_view::open_path(&ui, fixture.clone());
    }
    let drag = RefCell::new(None::<Rc<Cell<bool>>>);
    let capture_pending = RefCell::new(None);
    let capture_began = Cell::new(None::<Instant>);
    let captures = std::env::var("FASTRA_CAPTURE_STRESS")
        .ok()
        .map(|v| v.parse::<usize>().unwrap())
        .unwrap_or(31);
    assert!((31..=10000).contains(&captures));
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 40,
            "groups scope{scope} phase{} find={} replace={}",
            phase.get(),
            ui.find.text(),
            ui.replace.text()
        );
        if pause.get().elapsed() < Duration::from_millis(240) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                if scope == 3 && project_view::current_binding(&ui).is_none() {
                    return glib::ControlFlow::Continue;
                }
                ui.scope.set_selected(scope);
                chrome::show_search(&ui);
                if scope == 2 {
                    folder::test_root(&ui, fixture.clone());
                }
            }
            1 => {
                if !ready(&ui) {
                    return glib::ControlFlow::Continue;
                }
                let toggle = widgets::<gtk::CheckButton>(window(&ui).upcast_ref())
                    .into_iter()
                    .find(|b| {
                        b.label().as_deref()
                            == Some(ui.lang.text("Nur in Auswahl", "Selection only"))
                    })
                    .unwrap();
                assert_eq!(toggle.is_sensitive(), scope == 0);
                assert!(widgets::<gtk::Button>(window(&ui).upcast_ref())
                    .iter()
                    .any(|b| b.is_mapped() && b.label().as_deref() == Some("$2 c")));
                select(&ui, 1);
            }
            2 => {
                if !selected(&ui, 1) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&button(&ui, "Gruppe definieren", "Define group"), &[]);
            }
            3 => {
                if ui.find.text() != "(a)(b)(c)" || ui.replace.text() != "X$3" || !ready(&ui) {
                    return glib::ControlFlow::Continue;
                }
                let view = detail(&ui);
                let table = view.buffer().tag_table();
                let Some(second) = table.lookup("capture-color-1") else {
                    return glib::ControlFlow::Continue;
                };
                let Some(third) = table.lookup("capture-color-2") else {
                    return glib::ControlFlow::Continue;
                };
                if !view.buffer().iter_at_offset(1).has_tag(&second)
                    || !view.buffer().iter_at_offset(2).has_tag(&third)
                {
                    return glib::ControlFlow::Continue;
                }
                let layout_only = std::env::var("FASTRA_GROUP_LAYOUT_ONLY").as_deref() == Ok("1");
                if layout_only {
                    if capture_began.get().is_none() {
                        capture_began.set(Some(Instant::now()));
                        return glib::ControlFlow::Continue;
                    }
                    if capture_began.get().unwrap().elapsed() < Duration::from_millis(80)
                        || !git_view::try_capture_x11(
                            &window(&ui),
                            "search-groups-defined",
                            &capture_pending,
                        )
                    {
                        return glib::ControlFlow::Continue;
                    }
                } else if !git_view::try_capture(&window(&ui), "search-groups-defined") {
                    return glib::ControlFlow::Continue;
                }
                if layout_only {
                    let owner = window(&ui);
                    let expected = std::env::var("FASTRA_SEARCH_LAYOUT_WIDTH")
                        .unwrap_or_else(|_| "520".into())
                        .parse::<i32>()
                        .unwrap();
                    assert_eq!(owner.width(), expected);
                    for label in [
                        ui.lang.text("Nur in Auswahl", "Selection only"),
                        ui.lang.text("∗ wörtlich", "Literal ∗"),
                    ] {
                        let toggle = widgets::<gtk::CheckButton>(owner.upcast_ref())
                            .into_iter()
                            .find(|b| b.label().as_deref() == Some(label))
                            .unwrap();
                        if scope > 0 && label == ui.lang.text("Nur in Auswahl", "Selection only") {
                            assert!(!toggle.is_visible());
                            continue;
                        }
                        let bounds = toggle.compute_bounds(&owner).unwrap();
                        assert!(toggle.is_mapped() && toggle.width() > 0);
                        assert!(
                            bounds.y() >= 0.
                                && (bounds.y() + bounds.height()) <= owner.height() as f32
                        );
                        let parent = toggle.parent().unwrap();
                        let in_parent = toggle.compute_bounds(&parent).unwrap();
                        assert!((in_parent.y() + in_parent.height()) <= parent.height() as f32);
                        let row = parent.parent().unwrap();
                        assert!(
                            parent.compute_bounds(&row).unwrap().bottom_left().y()
                                <= row.height() as f32
                        );
                    }
                    assert!(widgets::<gtk::Entry>(owner.upcast_ref())
                        .iter()
                        .filter(|e| e.is_mapped())
                        .all(|e| e.width() >= 120));
                    println!("PASS group layout scope{scope} {expected}: actual regex colors, three capture capsules, mapped actions and readable fields");
                    owner.close();
                    git_view::finish(
                        ui.window.clone().upcast(),
                        ui.clone(),
                        "search-groups-layout",
                    );
                    return glib::ControlFlow::Break;
                }
                let pill = widgets::<gtk::Button>(window(&ui).upcast_ref())
                    .into_iter()
                    .find(|b| b.is_mapped() && b.label().as_deref() == Some("$2 b"))
                    .unwrap();
                git_view::test_click(&pill, &[]);
            }
            4 => {
                if !ui.replace.text().contains("$2") {
                    return glib::ControlFlow::Continue;
                }
                ui.replace.set_text("X$3");
            }
            5 => {
                if !ready(&ui) {
                    return glib::ControlFlow::Continue;
                }
                select(&ui, 1);
            }
            6 => {
                if !selected(&ui, 1) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&button(&ui, "Gruppe löschen", "Delete group"), &[]);
            }
            7 => {
                if ui.find.text() != "(a)b(c)" || ui.replace.text() != "X$2" || !ready(&ui) {
                    return glib::ControlFlow::Continue;
                }
                select(&ui, 2);
            }
            8 => {
                if !selected(&ui, 2) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&button(&ui, "Gruppe löschen", "Delete group"), &[]);
            }
            9 => {
                if !widgets::<gtk::Label>(window(&ui).upcast_ref())
                    .iter()
                    .any(|l| {
                        l.is_mapped()
                            && l.text().contains(
                                ui.lang.text(
                                    "ohne Bedeutungsänderung",
                                    "without changing its meaning",
                                ),
                            )
                    })
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.find.text(), "(a)b(c)");
                assert_eq!(ui.replace.text(), "X$2");
                if !git_view::try_capture(&window(&ui), "search-groups-refused") {
                    return glib::ControlFlow::Continue;
                }
                ui.find.set_text("(z)");
            }
            10 => {
                if !button(&ui, "Gruppe löschen", "Delete group").is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!button(&ui, "Gruppe definieren", "Define group").is_sensitive());
                assert!(widgets::<gtk::Button>(window(&ui).upcast_ref())
                    .iter()
                    .any(|b| b.is_mapped() && b.label().as_deref() == Some("$1 z")));
                git_view::test_click(&button(&ui, "Gruppe löschen", "Delete group"), &[]);
            }
            11 => {
                if ui.find.text() != "z" {
                    return glib::ControlFlow::Continue;
                }
                let field = find(&ui);
                field.grab_focus();
                git_view::test_keys(&field, &["End"]);
            }
            12 => {
                let picker = widgets::<gtk::MenuButton>(window(&ui).upcast_ref())
                    .into_iter()
                    .find(|b| {
                        b.tooltip_text().as_deref()
                            == Some(
                                ui.lang
                                    .text("RegEx-Element einfügen", "Insert regex element"),
                            )
                    })
                    .unwrap();
                git_view::test_click(&picker, &[]);
            }
            13 => {
                let item = widgets::<gtk::Button>(window(&ui).upcast_ref())
                    .into_iter()
                    .find(|b| b.is_mapped() && b.widget_name() == r"regex-element-\d");
                let Some(item) = item else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&item, &[]);
            }
            14 => {
                if ui.find.text() != r"z\d" {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.mode.selected(), 2);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), "abc abc\r\n");
                assert!(ui
                    .documents
                    .borrow()
                    .iter()
                    .all(|d| !d.buffer.is_modified() && !d.buffer.can_undo()));
                let history = widgets::<gtk::MenuButton>(window(&ui).upcast_ref())
                    .into_iter()
                    .find(|b| {
                        b.tooltip_text().as_deref()
                            == Some(ui.lang.text("Suchverlauf", "Search history"))
                    })
                    .unwrap();
                if scope % 2 == 0 {
                    let field = find(&ui);
                    field.grab_focus();
                    git_view::test_keys(&field, &["alt+h"]);
                } else {
                    git_view::test_click(&history, &[]);
                }
            }
            15 => {
                let label = format!("{}: (a)b(c)", ui.lang.text("Suchen", "Find"));
                let pair = widgets::<gtk::Button>(window(&ui).upcast_ref())
                    .into_iter()
                    .find(|b| {
                        b.is_mapped()
                            && widgets::<gtk::Label>(b.upcast_ref())
                                .iter()
                                .any(|l| l.text() == label)
                    });
                let Some(pair) = pair else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&pair, &[]);
            }
            16 => {
                if ui.find.text() != "(a)b(c)" || ui.replace.text() != "X$2" {
                    return glib::ControlFlow::Continue;
                }
                let field = find(&ui);
                let focus = gtk::prelude::GtkWindowExt::focus(&window(&ui));
                if !focus.is_some_and(|f| {
                    f == field.clone().upcast::<gtk::Widget>() || f.is_ancestor(&field)
                }) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.scope.selected(), scope);
                assert_eq!(ui.mode.selected(), 2);
                ui.find.set_text(&"(a)".repeat(captures));
                ui.replace.set_text("");
            }
            17 => {
                let row = widgets::<gtk::ListView>(window(&ui).upcast_ref())
                    .into_iter()
                    .find(|v| v.has_css_class("capture-list") && v.is_mapped());
                let Some(row) = row else {
                    return glib::ControlFlow::Continue;
                };
                if row
                    .model()
                    .is_none_or(|model| model.n_items() != captures as u32)
                {
                    return glib::ControlFlow::Continue;
                }
                row.scroll_to(
                    captures as u32 - 1,
                    gtk::ListScrollFlags::FOCUS,
                    None::<gtk::ScrollInfo>,
                );
            }
            18 => {
                let pill = widgets::<gtk::Button>(window(&ui).upcast_ref())
                    .into_iter()
                    .find(|b| {
                        b.is_mapped() && b.label().as_deref() == Some(&format!("${captures} a"))
                    });
                let Some(pill) = pill else {
                    return glib::ControlFlow::Continue;
                };
                let field = widgets::<gtk::Entry>(window(&ui).upcast_ref())
                    .into_iter()
                    .find(|e| {
                        e.placeholder_text().as_deref()
                            == Some(ui.lang.text("Ersetzen durch… ($1, $2 für Gruppen)", "Replace with… ($1, $2 for groups)"))
                    })
                    .unwrap();
                *drag.borrow_mut() = Some(search_live::selftest::drag_capture(
                    pill.upcast_ref(),
                    field.upcast_ref(),
                ));
            }
            19 => {
                if ui.replace.text() != format!("${captures}")
                    || !drag.borrow().as_ref().is_some_and(|done| done.get())
                {
                    return glib::ControlFlow::Continue;
                }
                if captures > 500 {
                    let mapped = widgets::<gtk::Button>(window(&ui).upcast_ref())
                        .iter()
                        .filter(|b| b.is_mapped() && b.has_css_class("capture-pill"))
                        .count();
                    assert!(mapped<500,"virtual capture viewport instantiated {mapped} buttons for {captures} groups");
                    println!("CAPTURE_VIRTUAL count={captures} mapped-buttons={mapped}");
                }
                assert_eq!(std::fs::read_to_string(&path).unwrap(), "abc abc\r\n");
                assert!(ui
                    .documents
                    .borrow()
                    .iter()
                    .all(|d| !d.buffer.is_modified() && !d.buffer.can_undo()));
                println!(
                    "PASS native groups scope{scope}: actual detail selection + Define, reference renumbering, capture click, selected group Delete, referenced-group refusal visible, no-hit syntax capsules and fallback Delete, native element picker at caret and history pair/focus, virtual horizontal capsules and real group{captures} drag, unchanged documents/Undo/disk; selection-only control scope gate"
                );
                window(&ui).close();
                git_view::finish(ui.window.clone().upcast(), ui.clone(), "search-groups");
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        println!("groups scope{scope} phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
