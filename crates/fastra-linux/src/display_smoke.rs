use super::Ui;
use gtk::{glib, prelude::*};
use std::{
    cell::Cell,
    rc::Rc,
    time::{Duration, Instant},
};
pub(super) fn run(ui: Rc<Ui>, desktop: bool) {
    if !desktop {
        assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
        if let Some(width) = std::env::var("FASTRA_TOOL_WIDTH")
            .ok()
            .and_then(|s| s.parse::<i32>().ok())
        {
            ui.window.set_default_size(width, 850);
        }
    }
    let pane = ui.tabs.parent().unwrap().downcast::<gtk::Paned>().unwrap();
    ui.search_section.set_expanded(false);
    let phase = Cell::new(0);
    let pause = Cell::new(Instant::now());
    let start = Instant::now();
    glib::timeout_add_local(Duration::from_millis(100), move || {
        assert!(
            start.elapsed() < Duration::from_secs(12),
            "display smoke phase {}",
            phase.get()
        );
        if pause.get().elapsed() < Duration::from_millis(700) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => {
                assert!(
                    ui.tabs.height() >= pane.height() - 50 && ui.tabs.height() >= 100,
                    "early collapse hid document: document {} vs available {}",
                    ui.tabs.height(),
                    pane.height()
                );
                ui.search_section.set_expanded(true);
                phase.set(3);
                pause.set(Instant::now());
            }
            3 => {
                let display = gtk::prelude::WidgetExt::display(&ui.window);
                println!(
                    "FASTRA display smoke backend={} scale={} size={}x{}",
                    display.type_().name(),
                    ui.window.scale_factor(),
                    ui.window.width(),
                    ui.window.height()
                );
                if desktop {
                    assert!(display.type_().name().contains("Wayland"));
                }
                super::git_view::capture(ui.window.upcast_ref(), "display-expanded");
                ui.search_section.set_expanded(false);
                if !desktop {
                    ui.window
                        .set_default_size(ui.window.width(), ui.window.height() + 80);
                }
                phase.set(1);
                pause.set(Instant::now());
            }
            1 => {
                let header = ui.search_section.label_widget().unwrap();
                assert!(
                    ui.search_section.is_child_visible()
                        && header.is_mapped()
                        && header.height() > 0
                        && ui.search_section.height() >= header.height()
                        && ui.search_section.height() < 50,
                    "collapsed search header must remain visible, measured {} px",
                    ui.search_section.height()
                );
                assert!(
                    ui.tabs.height() >= pane.height() - 50,
                    "document {} vs available {}",
                    ui.tabs.height(),
                    pane.height()
                );
                super::git_view::capture(ui.window.upcast_ref(), "display-collapsed");
                if desktop {
                    ui.search_section.set_expanded(true);
                } else {
                    super::git_view::test_click(&ui.search_section.label_widget().unwrap(), &[]);
                }
                phase.set(2);
                pause.set(Instant::now());
            }
            2 => {
                if !ui.search_section.is_expanded() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    ui.search_section.height() >= 180,
                    "expanded search unavailable"
                );
                assert!(
                    ui.tabs.height() >= 100,
                    "editor unavailable after expanding search"
                );
                ui.window.set_visible(false);
                assert!(!ui.window.is_visible());
                println!("FASTRA display smoke PASS: collapse fills document, expand restores split, window hidden");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}
