use super::*;
use std::time::{Duration, Instant};
fn click(widget: &gtk::Widget, label: &str) -> bool {
    let mut all = Vec::new();
    widgets(widget, &mut all);
    if let Some(button) = all
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Button>().ok())
        .find(|b| b.label().as_deref() == Some(label))
    {
        button.emit_clicked();
        true
    } else {
        false
    }
}
fn capture(window: &gtk::Window, name: &str) {
    if let Some(path) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS") {
        let root = std::path::PathBuf::from(path);
        std::fs::create_dir_all(&root).unwrap();
        let p = gtk::WidgetPaintable::new(Some(window));
        let s = gtk::Snapshot::new();
        p.snapshot(&s, f64::from(window.width()), f64::from(window.height()));
        let Some(node) = s.to_node() else {
            return;
        };
        window
            .renderer()
            .unwrap()
            .render_texture(node, None)
            .save_to_png(root.join(format!("{name}.png")))
            .unwrap();
    }
}
fn row(state: &State) -> gtk::Button {
    state
        .list
        .row_at_index(0)
        .unwrap()
        .child()
        .unwrap()
        .downcast()
        .unwrap()
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let xml="<?xml version='1.0'?>\r\n<r title='Köln 🙂'><a id='A'>🚀 First</a>\r\n<a id='B'><![CDATA[ 雪 second ]]></a></r>".to_owned();
    ui.add_document("xpath-雪.xml", &xml);
    let doc = ui.active().unwrap();
    let page = ui.tabs.current_page();
    let state = Rc::new(RefCell::new(None::<Rc<State>>));
    let phase = Cell::new(0);
    let started = Instant::now();
    let pause = Cell::new(None::<Instant>);
    let held = RefCell::new(None::<gtk::Button>);
    let original = xml.clone();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "XPath UI phase {} {}",
            phase.get(),
            ui.status.text()
        );
        match phase.get() {
            0 => {
                let mut all = Vec::new();
                widgets(ui.window.upcast_ref(), &mut all);
                let menu = all
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::MenuButton>().ok())
                    .find(|b| b.label().as_deref() == Some(ui.lang.text("Werkzeuge", "Tools")))
                    .unwrap();
                menu.popup();
                assert!(click(
                    menu.popover().unwrap().upcast_ref(),
                    ui.lang.text("XPath-Navigation …", "XPath navigation …")
                ));
                phase.set(1);
            }
            1 => {
                let title = ui.lang.text(
                    "XML · XPath-Quellnavigation",
                    "XML · XPath source navigation",
                );
                let Some(window) = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<gtk::Window>().ok())
                    .find(|w| w.is_visible() && w.title().as_deref() == Some(title))
                else {
                    return glib::ControlFlow::Continue;
                };
                window.close();
                let new = open_for(&ui, &doc);
                git_view::test_size(&new.window);
                *state.borrow_mut() = Some(new);
                phase.set(2);
            }
            _ => {
                let state = state.borrow().clone().unwrap();
                if state.parse_running.get() || state.query_running.get() {
                    return glib::ControlFlow::Continue;
                }
                match phase.get() {
                    2 => {
                        assert!(state.index.borrow().is_some(), "{}", state.status.text());
                        state.query.set_text("//a[@id='B']/text()");
                        phase.set(3);
                    }
                    3 => {
                        assert_eq!(state.matches.borrow().len(), 1, "{}", state.status.text());
                        let button = row(&state);
                        button.emit_clicked();
                        let (a, b) = doc.buffer.selection_bounds().unwrap();
                        assert_eq!(doc.buffer.text(&a, &b, true), "雪 second");
                        assert_eq!(
                            a.offset() as usize,
                            original[..original.find("雪 second").unwrap()]
                                .chars()
                                .count()
                        );
                        assert_eq!(buffer_text(&doc.buffer), original);
                        *held.borrow_mut() = Some(button);
                        pause.set(Some(Instant::now()));
                        phase.set(4);
                    }
                    4 => {
                        if pause.get().unwrap().elapsed() < Duration::from_millis(350) {
                            return glib::ControlFlow::Continue;
                        }
                        capture(&state.window, "xpath-results");
                        ui.add_document("foreign.xml", "<foreign/>");
                        let foreign = ui.active().unwrap();
                        assert_eq!(foreign.revision.get(), doc.revision.get());
                        held.borrow().as_ref().unwrap().emit_clicked();
                        assert!(foreign.buffer.selection_bounds().is_none());
                        assert_eq!(buffer_text(&foreign.buffer), "<foreign/>");
                        ui.tabs.set_current_page(page);
                        let insert = original.find("\r\n").unwrap() + 2;
                        let offset = original[..insert].chars().count() as i32;
                        doc.buffer.insert(
                            &mut doc.buffer.iter_at_offset(offset),
                            "<!-- changed 🚀 -->\r\n",
                        );
                        doc.buffer.place_cursor(&doc.buffer.start_iter());
                        held.borrow().as_ref().unwrap().emit_clicked();
                        assert_eq!(doc.buffer.cursor_position(), 0);
                        assert!(state.matches.borrow().is_empty());
                        state.build.emit_clicked();
                        phase.set(5);
                    }
                    5 => {
                        assert_eq!(state.matches.borrow().len(), 1, "{}", state.status.text());
                        doc.buffer.place_cursor(&doc.buffer.start_iter());
                        held.borrow().as_ref().unwrap().emit_clicked();
                        assert_eq!(
                            doc.buffer.cursor_position(),
                            0,
                            "late old widget must not navigate rebuilt model"
                        );
                        row(&state).emit_clicked();
                        let (a, b) = doc.buffer.selection_bounds().unwrap();
                        assert_eq!(doc.buffer.text(&a, &b, true), "雪 second");
                        state.query.set_text("//a[last()]");
                        phase.set(6);
                    }
                    6 => {
                        assert!(state.matches.borrow().is_empty());
                        assert!(
                            state
                                .status
                                .text()
                                .contains(ui.lang.text("Nicht unterstützt", "Unsupported")),
                            "{}",
                            state.status.text()
                        );
                        pause.set(Some(Instant::now()));
                        phase.set(7);
                    }
                    7 => {
                        if pause.get().unwrap().elapsed() < Duration::from_millis(350) {
                            return glib::ControlFlow::Continue;
                        }
                        capture(&state.window, "xpath-error");
                        let mut paged = "<r title='雪'>\r\n".to_owned();
                        for n in 0..205 {
                            paged += &format!("<a id='{n}'/>\r\n");
                        }
                        paged += "</r>";
                        doc.buffer.set_text(&paged);
                        state.query.set_text("//a");
                        state.build.emit_clicked();
                        phase.set(11);
                    }
                    8 => {
                        assert!(state.matches.borrow().is_empty());
                        assert!(state.index.borrow().is_none());
                        assert!(state.build.is_sensitive());
                        doc.buffer.set_text(&original);
                        state.build.emit_clicked();
                        phase.set(9);
                    }
                    9 => {
                        state.query.set_text("//a[@id='B']/text()");
                        phase.set(10);
                    }
                    10 => {
                        assert_eq!(state.matches.borrow().len(), 1);
                        doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
                        assert!(doc.source_edits_locked());
                        doc.buffer.place_cursor(&doc.buffer.start_iter());
                        row(&state).emit_clicked();
                        assert_eq!(doc.buffer.cursor_position(), 0);
                        assert_eq!(buffer_text(&doc.buffer), original);
                        ui.window.set_visible(false);
                        assert!(!state.window.is_visible());
                        assert!(state.parse_cancel.borrow().check().is_err());
                        assert!(state.query_cancel.borrow().check().is_err());
                        println!("FASTRA_XPATH_UI_OK real-tools-menu/Unicode-CRLF/attribute-CDATAranges/foreign-tab/same-revision/revision-change/late-widget/unsupported/pagination205/query-cancel-no-restart/parser-cancel/Rich-lock/parent-hide-stop/no-text-write");
                        ui.window.application().unwrap().quit();
                        return glib::ControlFlow::Break;
                    }
                    11 => {
                        assert_eq!(state.matches.borrow().len(), 205);
                        assert!(state.list.row_at_index(99).is_some());
                        assert!(state.list.row_at_index(100).is_none());
                        state.next_page.emit_clicked();
                        assert_eq!(state.page.get(), 1);
                        state.next_page.emit_clicked();
                        assert_eq!(state.page.get(), 2);
                        assert!(state.list.row_at_index(4).is_some());
                        assert!(state.list.row_at_index(5).is_none());
                        state.previous_page.emit_clicked();
                        assert_eq!(state.page.get(), 1);
                        row(&state).emit_clicked();
                        let (a, b) = doc.buffer.selection_bounds().unwrap();
                        assert_eq!(doc.buffer.text(&a, &b, true), "a");
                        let text = buffer_text(&doc.buffer);
                        let at = text.find("<a id='100'").unwrap() + 1;
                        assert_eq!(a.offset() as usize, text[..at].chars().count());
                        pause.set(Some(Instant::now()));
                        phase.set(12);
                    }
                    12 => {
                        if pause.get().unwrap().elapsed() < Duration::from_millis(350) {
                            return glib::ControlFlow::Continue;
                        }
                        capture(&state.window, "xpath-pagination");
                        state.query.set_text("//*");
                        assert!(state.query_running.get());
                        state.query.set_text("//a");
                        assert!(state.query_pending.get());
                        state.cancel_button.emit_clicked();
                        phase.set(13);
                    }
                    13 => {
                        assert!(state.matches.borrow().is_empty());
                        assert!(state.index.borrow().is_some());
                        let large = "<r>\n".to_owned() + &"<a>safe</a>\n".repeat(5000) + "</r>";
                        doc.buffer.set_text(&large);
                        state.build.emit_clicked();
                        state.cancel_button.emit_clicked();
                        phase.set(8);
                    }
                    _ => unreachable!(),
                }
            }
        }
        gtk::glib::ControlFlow::Continue
    });
}
