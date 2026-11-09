use super::*;
use std::time::Instant;
fn detail(root: &gtk::Widget) -> Option<gtk::TextView> {
    if let Some(view) = root
        .downcast_ref::<gtk::TextView>()
        .filter(|view| view.widget_name() == "fastra-search-detail")
    {
        return Some(view.clone());
    }
    chrome::children(root).iter().find_map(detail)
}
pub(crate) fn run(ui: Rc<Ui>) {
    check(ui, "search-detail");
}
pub(super) fn after_live(ui: Rc<Ui>) {
    check(ui, "search-live");
}
fn check(ui: Rc<Ui>, name: &'static str) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.add_document("long-detail.txt", &"A".repeat(600));
    let doc = ui.active().unwrap();
    ui.scope.set_selected(0);
    ui.find.set_text("A{600}");
    ui.replace.set_text("B");
    ui.mode.set_selected(2);
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 20,
            "detail phase{}",
            phase.get()
        );
        if pause.get().elapsed() < Duration::from_millis(240) {
            return glib::ControlFlow::Continue;
        }
        let window = ui.chrome.borrow().as_ref().unwrap().search_window.clone();
        match phase.get() {
            0 => chrome::show_search(&ui),
            1 => {
                let view = detail(window.upcast_ref()).unwrap();
                if !ui.approval.is_ready() || view.buffer().char_count() != 600 {
                    return glib::ControlFlow::Continue;
                }
                if !git_view::try_capture(&window, "search-detail-before") {
                    return glib::ControlFlow::Continue;
                }
            }
            2 => {
                let view = detail(window.upcast_ref()).unwrap();
                view.grab_focus();
                git_view::test_keys(&view, &["ctrl+End"]);
            }
            3 => {
                let view = detail(window.upcast_ref()).unwrap();
                let scroll = view
                    .ancestor(gtk::ScrolledWindow::static_type())
                    .unwrap()
                    .downcast::<gtk::ScrolledWindow>()
                    .unwrap();
                if scroll.hadjustment().value() <= 0. {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(scroll.height(), 28);
                assert_eq!(view.buffer().cursor_position(), 600);
                assert_eq!(buffer_text(&view.buffer()), "A".repeat(600));
                assert_eq!(buffer_text(&doc.buffer), "A".repeat(600));
                assert!(!doc.buffer.can_undo() && !doc.buffer.is_modified());
                if !git_view::try_capture(&window, "search-detail-after") {
                    return glib::ControlFlow::Continue;
                }
                println!(
                    "PASS native detail: fixed28px height, complete600-character match retained, real CtrlEnd scrolls horizontally, source and Undo unchanged"
                );
                window.close();
                git_view::finish(ui.window.clone().upcast(), ui.clone(), name);
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
