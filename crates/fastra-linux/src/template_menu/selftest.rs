use super::*;
use fastra_workflow::patterns::Collection;
use std::{collections::BTreeMap, time::Instant};
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
fn empty(ui: &Ui) -> gtk::Label {
    let shell = ui.chrome.borrow();
    widgets::<gtk::Label>(shell.as_ref().unwrap().search_window.upcast_ref())
        .into_iter()
        .find(|w| w.widget_name() == "fastra-search-empty")
        .unwrap()
}
fn click_title(menu: &Menu, title: &str) {
    let button = menu.button.upgrade().unwrap();
    let popover = button.popover().unwrap();
    let label = widgets::<gtk::Label>(popover.upcast_ref())
        .into_iter()
        .find(|w| w.text() == title)
        .unwrap();
    let mut widget = label.upcast::<gtk::Widget>();
    while widget.type_().name() != "GtkModelButton" {
        widget = widget.parent().unwrap();
    }
    assert!(widget.is_mapped());
    let bounds = widget.compute_bounds(&popover).unwrap();
    assert!(
        bounds.y() >= 0. && bounds.y() + bounds.height() / 2. < popover.height() as f32,
        "menu item must be visible: {title} {bounds:?}"
    );
    git_view::test_click(&widget, &[]);
}
pub(crate) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let cancel = Cancellation::default();
    let store = Store::open(&pattern_view::config().unwrap()).unwrap();
    let snapshot = store.load(&cancel).unwrap();
    let custom = Pattern {
        id: "own-native".into(),
        name: "Eigene Vorlage mit sehr langem Namen 🐱 für die native Prüfung".into(),
        category: "Identifikatoren".into(),
        regex: "(cat)".into(),
        default_replacement: Some("$1!".into()),
        example_match: "cat".into(),
        group_labels: vec!["pet".into()],
        extra: BTreeMap::new(),
    };
    store
        .save(&snapshot, &Collection(vec![custom.clone()]), &cancel)
        .unwrap();
    ui.add_document("template-native.txt", "cat original\n");
    let doc = ui.active().unwrap();
    doc.buffer.set_text("cat original\n");
    doc.buffer.set_modified(false);
    ui.find.set_text("");
    ui.replace.set_text("keep replacement");
    ui.case.set_active(true);
    ui.whole_word.set_active(true);
    chrome::show_search(&ui);
    let start = Instant::now();
    let phase = Cell::new(0);
    let capture = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(140), move || {
        assert!(
            start.elapsed() < Duration::from_secs(35),
            "Template phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        let menu = ui.template_menus.borrow()[0].clone();
        let button = menu.button.upgrade().unwrap();
        match phase.get() {
            0 => {
                assert!(empty(&ui).is_visible());
                assert_eq!(
                    empty(&ui).text(),
                    ui.lang
                        .text("Suchausdruck eingeben…", "Enter a search expression…")
                );
                assert_eq!(
                    button.label().as_deref(),
                    Some(ui.lang.text("Vorlage", "Template"))
                );
                git_view::test_click(&button, &[]);
            }
            1 => {
                if menu.busy.get() || menu.values.borrow().is_empty() {
                    return glib::ControlFlow::Continue;
                }
                assert!(button.popover().unwrap().is_visible());
                assert_eq!(
                    menu.values
                        .borrow()
                        .iter()
                        .filter(|(_, builtin)| !builtin)
                        .count(),
                    1
                );
                if !git_view::try_capture_x11(
                    &button.popover().unwrap(),
                    "template-menu-native",
                    &capture,
                ) {
                    return glib::ControlFlow::Continue;
                }
                let email = menu
                    .values
                    .borrow()
                    .iter()
                    .find(|(p, _)| p.id == "email")
                    .unwrap()
                    .0
                    .clone();
                click_title(&menu, &pattern_view::builtin_title(&email, ui.lang));
            }
            2 => {
                if menu.busy.get()
                    || ui
                        .template_choice
                        .borrow()
                        .as_ref()
                        .is_none_or(|p| p.0 != "email")
                {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.mode.selected(), 2);
                assert_eq!(ui.replace.text(), "keep replacement");
                assert!(ui.case.is_active() && ui.whole_word.is_active());
                assert_eq!(ui.scope.selected(), 0);
                git_view::test_click(&button, &[]);
            }
            3 => {
                if menu.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(button.popover().unwrap().is_visible());
                let count = menu
                    .values
                    .borrow()
                    .iter()
                    .filter(|(_, builtin)| *builtin)
                    .count()
                    + 1;
                let mut keys = vec!["Down"; count];
                keys.push("Return");
                git_view::test_keys(&button.popover().unwrap(), &keys);
            }
            4 => {
                if menu.busy.get()
                    || ui
                        .template_choice
                        .borrow()
                        .as_ref()
                        .is_none_or(|p| p.0 != custom.id)
                {
                    return glib::ControlFlow::Continue;
                }
                if ui
                    .pending
                    .borrow()
                    .as_ref()
                    .is_none_or(|p| p.preview.matches().len() != 1)
                    || !ui.approval.is_ready()
                {
                    return glib::ControlFlow::Continue;
                }
                let owner = menu.owner.upgrade().unwrap();
                if !git_view::try_capture_x11(&owner, "template-selected-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    owner.width(),
                    std::env::var("FASTRA_SEARCH_LAYOUT_WIDTH")
                        .unwrap_or_else(|_| "520".into())
                        .parse::<i32>()
                        .unwrap()
                );
                assert_eq!(ui.find.text(), custom.regex);
                assert_eq!(ui.replace.text(), "$1!");
                assert!(button.label().unwrap().graphemes(true).count() <= 24);
                assert_eq!(button.tooltip_text().as_deref(), Some(custom.name.as_str()));
                let store = Store::open(&pattern_view::config().unwrap()).unwrap();
                let current = store.load(&Cancellation::default()).unwrap();
                let mut updated = current.collection.clone();
                updated.0[0].name = "Renamed user template".into();
                store
                    .save(&current, &updated, &Cancellation::default())
                    .unwrap();
                git_view::test_click(&button, &[]);
            }
            5 => {
                if menu.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    button.tooltip_text().as_deref(),
                    Some("Renamed user template")
                );
                assert_eq!(
                    menu.values
                        .borrow()
                        .iter()
                        .find(|(p, _)| p.id == custom.id)
                        .unwrap()
                        .0
                        .name,
                    "Renamed user template"
                );
                for scroll in widgets::<gtk::ScrolledWindow>(button.popover().unwrap().upcast_ref())
                {
                    scroll.vadjustment().set_value(scroll.vadjustment().lower());
                }
            }
            6 => {
                click_title(&menu, ui.lang.text("— Keine —", "— None —"));
            }
            7 => {
                if ui.template_choice.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.find.text(), "(cat)");
                assert_eq!(ui.replace.text(), "$1!");
                // Der native Aktionsweg startet denselben verzögerten Validator wie ein Menüklick.
                menu.action.activate(Some(&"email".to_variant()));
                ui.find.set_text("changed while validating");
            }
            8 => {
                if menu.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.find.text(), "changed while validating");
                assert!(ui.template_choice.borrow().is_none());
                ui.find.set_text("unfindable-native-1201");
                ui.search();
            }
            9 => {
                if !empty(&ui).is_visible()
                    || empty(&ui).text() != ui.lang.text("Keine Treffer.", "No matches.")
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(!ui.apply.is_sensitive());
                if !git_view::try_capture_x11(
                    &menu.owner.upgrade().unwrap(),
                    "search-empty-native",
                    &capture,
                ) {
                    return glib::ControlFlow::Continue;
                }
                let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
                window.close();
                chrome::show_search(&ui);
            }
            10 => {
                git_view::test_click(&button, &[]);
            }
            11 => {
                if menu.busy.get() || !button.popover().unwrap().is_visible() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&button.popover().unwrap(), &["Return"]);
            }
            12 => {
                let owner = menu.owner.upgrade().unwrap();
                let open = widgets::<gtk::ToggleButton>(owner.upcast_ref())
                    .into_iter()
                    .find(|b| b.label().as_deref() == Some(ui.lang.text("Geöffnet", "Open")))
                    .unwrap();
                git_view::test_click(&open, &[]);
            }
            13 => {
                if ui.scope.selected() != 1 {
                    return glib::ControlFlow::Continue;
                }
                let current = ui
                    .template_menus
                    .borrow()
                    .iter()
                    .filter_map(|m| m.owner.upgrade())
                    .find(|w| w.is_visible())
                    .unwrap();
                let open = widgets::<gtk::ToggleButton>(current.upcast_ref())
                    .into_iter()
                    .find(|b| b.label().as_deref() == Some(ui.lang.text("Geöffnet", "Open")))
                    .unwrap();
                git_view::test_click(&open, &[]);
            }
            14 => {
                let current = ui
                    .template_menus
                    .borrow()
                    .iter()
                    .filter_map(|m| m.owner.upgrade())
                    .find(|w| w.is_visible())
                    .unwrap();
                let info = widgets::<gtk::Popover>(current.upcast_ref())
                    .into_iter()
                    .find(|p| {
                        p.is_visible()
                            && widgets::<gtk::Label>(p.upcast_ref())
                                .iter()
                                .any(|l| l.text().contains("128"))
                    });
                let Some(info) = info else {
                    return glib::ControlFlow::Continue;
                };
                if !git_view::try_capture_x11(&info, "open-scope-info-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                info.popdown();
            }
            15 => {
                let current = ui
                    .template_menus
                    .borrow()
                    .iter()
                    .filter_map(|m| m.owner.upgrade())
                    .find(|w| w.is_visible())
                    .unwrap();
                let file = widgets::<gtk::ToggleButton>(current.upcast_ref())
                    .into_iter()
                    .find(|b| b.label().as_deref() == Some(ui.lang.text("Datei", "File")))
                    .unwrap();
                git_view::test_click(&file, &[]);
            }
            16 => {
                if ui.scope.selected() != 0 || !menu.owner.upgrade().unwrap().is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    doc.buffer
                        .text(&doc.buffer.start_iter(), &doc.buffer.end_iter(), true),
                    "cat original\n"
                );
                assert!(!doc.buffer.is_modified());
                println!("PASS template menu: native builtin click and custom keyboard selection; fresh user library; optional replacement; scope and flags; grapheme caption; None retains fields; stale validator refused; no-hit hint; reopen; no source writes");
                ui.discard_confirmed.set(true);
                let app = ui.window.application().unwrap();
                ui.window.close();
                app.quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        eprintln!("template phase {} complete", phase.get());
        phase.set(phase.get() + 1);
        glib::ControlFlow::Continue
    });
}
