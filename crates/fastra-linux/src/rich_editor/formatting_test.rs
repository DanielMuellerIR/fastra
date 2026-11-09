use super::*;
use std::time::Instant;
fn collect<T: IsA<gtk::Widget> + glib::object::ObjectType>(root: &gtk::Widget) -> Vec<T> {
    let mut result = root
        .clone()
        .downcast::<T>()
        .ok()
        .into_iter()
        .collect::<Vec<_>>();
    for child in chrome::children(root) {
        result.extend(collect::<T>(&child));
    }
    result
}
fn chooser(lang: Language) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| {
            w.is_mapped()
                && w.title().as_deref() == Some(lang.text("Tabelle einfügen", "Insert table"))
        })
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(1000, 650);
    ui.add_document("table.md", "雪🙂\n");
    let doc = ui.active().unwrap();
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let response = Rc::new(RefCell::new(None::<Value>));
    let shots = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            began.elapsed().as_secs() < 40,
            "Rich formatting phase{} text{:?}",
            phase.get(),
            buffer_text(&doc.buffer)
        );
        if pause.get().elapsed() < Duration::from_millis(220) {
            return glib::ControlFlow::Continue;
        }
        let editor = doc.rich.borrow().clone();
        match phase.get() {
            0 => {
                git_view::test_click(doc.rich_toggle.borrow().as_ref().unwrap(), &[]);
            }
            1 => {
                let Some(editor) = editor.filter(|e| e.ready.get()) else {
                    return glib::ControlFlow::Continue;
                };
                let reply = response.clone();
                editor.evaluate("const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);",move|v|*reply.borrow_mut()=v);
            }
            2 | 6 => {
                let editor = editor.unwrap();
                if phase.get() == 2 && response.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(
                    &gui_test::button(
                        editor.widget.upcast_ref(),
                        ui.lang.text("Tabelle einfügen …", "Insert table …"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            3 => {
                let Some(window) = chooser(ui.lang) else {
                    return glib::ControlFlow::Continue;
                };
                let field = collect::<gtk::Entry>(window.upcast_ref()).pop().unwrap();
                assert_eq!(field.text(), "3");
                assert!(collect::<gtk::CheckButton>(window.upcast_ref())
                    .pop()
                    .unwrap()
                    .is_active());
                git_view::test_click(
                    &gui_test::button(window.upcast_ref(), ui.lang.text("Abbrechen", "Cancel"))
                        .unwrap(),
                    &[],
                );
            }
            4 => {
                assert_eq!(buffer_text(&doc.buffer), "雪🙂\n");
                git_view::test_keys(&ui.window, &[]);
            }
            5 => {
                if !gui_test::capture(&ui.window, "rich-command-order", &shots) {
                    return glib::ControlFlow::Continue;
                }
            }
            7 => {
                let Some(window) = chooser(ui.lang) else {
                    return glib::ControlFlow::Continue;
                };
                let field = collect::<gtk::Entry>(window.upcast_ref()).pop().unwrap();
                let button = gui_test::button(
                    window.upcast_ref(),
                    ui.lang.text("Tabelle einfügen", "Insert table"),
                )
                .unwrap();
                field.set_text("51");
                assert!(!button.is_sensitive());
                field.set_text("0");
                assert!(!button.is_sensitive());
                field.set_text("2");
                assert!(button.is_sensitive());
                git_view::test_click(
                    &collect::<gtk::CheckButton>(window.upcast_ref())
                        .pop()
                        .unwrap(),
                    &[],
                );
            }
            8 => {
                let window = chooser(ui.lang).unwrap();
                assert!(!collect::<gtk::CheckButton>(window.upcast_ref())
                    .pop()
                    .unwrap()
                    .is_active());
                git_view::test_click(
                    &gui_test::button(
                        window.upcast_ref(),
                        ui.lang.text("Tabelle einfügen", "Insert table"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            9 => {
                if !buffer_text(&doc.buffer).contains('|') {
                    return glib::ControlFlow::Continue;
                }
                let reply = response.clone();
                editor.unwrap().evaluate("const t=document.querySelector('#fastra-visual table');return JSON.stringify({columns:t.rows[0].cells.length,rows:t.rows.length,heading:t.rows[0].textContent});",move|v|*reply.borrow_mut()=v);
            }
            10 => {
                let Some(value) = response.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["columns"], 2);
                assert_eq!(value["rows"], 3);
                assert_eq!(value["heading"], "");
                let editor = editor.unwrap();
                let more = collect::<gtk::MenuButton>(editor.widget.upcast_ref())
                    .into_iter()
                    .find(|b| {
                        b.tooltip_text().as_deref()
                            == Some(ui.lang.text("Weitere Rich-Aktionen", "More rich actions"))
                    })
                    .unwrap();
                git_view::test_click(&more, &[]);
            }
            11 => {
                let editor = editor.unwrap();
                let undo = gui_test::button(
                    editor.widget.upcast_ref(),
                    ui.lang.text("Rückgängig", "Undo"),
                )
                .unwrap();
                assert!(undo.is_mapped());
                git_view::test_click(&undo, &[]);
            }
            12 => {
                if buffer_text(&doc.buffer) != "雪🙂\n" {
                    return glib::ControlFlow::Continue;
                }
                println!("PASS Rich native table toolbar: default3/header/Cancel, invalid count refusal,2columns/header-off Mac structure, More Undo restores exact source");
                git_view::finish(ui.window.clone().upcast(), ui.clone(), "rich-formatting");
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
