use super::*;
fn query(ui: &Ui, text: &[&str]) {
    let field = widgets::<gtk::Entry>(window(ui).upcast_ref())
        .into_iter()
        .find(|entry| {
            entry.placeholder_text().as_deref()
                == Some(ui.lang.text("Suchausdruck eingeben…", "Enter a search expression…"))
        })
        .unwrap();
    field.grab_focus();
    git_view::test_keys(&field, text);
}
pub(super) fn run(ui: Rc<Ui>) {
    let open = std::env::var("FASTRA_SINGLE_REPLACE_SELFTEST").as_deref() == Ok("guards-open");
    ui.add_document("guard.txt", "cat");
    let doc = ui.active().unwrap();
    ui.scope.set_selected(u32::from(open));
    ui.mode.set_selected(0);
    ui.case.set_active(true);
    ui.find.set_text("cat");
    ui.replace.set_text("dog");
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let clicked = Cell::new(began);
    let other = RefCell::new(None::<gtk::ApplicationWindow>);
    let epoch = Cell::new(0);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed().as_secs() < 40,
            "single guards phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(240) {
            return glib::ControlFlow::Continue;
        }
        match phase.get() {
            0 => chrome::show_search(&ui),
            1 => {
                if !replace(&ui).is_sensitive() || !count(&ui, 1) {
                    return glib::ControlFlow::Continue;
                }
                std::env::set_var("FASTRA_SINGLE_REPLY_DELAY_MS", "1200");
                git_view::test_click(&replace(&ui), &[]);
                clicked.set(Instant::now());
            }
            2 => {
                assert!(!replace(&ui).is_sensitive());
                query(&ui, &["ctrl+a", "d", "o", "g"]);
            }
            3 => {
                if !count(&ui, 0) {
                    return glib::ControlFlow::Continue;
                }
            }
            4 => {
                if clicked.get().elapsed() < Duration::from_millis(1450) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "cat");
                assert!(!doc.buffer.can_undo() && !doc.buffer.is_modified());
                std::env::remove_var("FASTRA_SINGLE_REPLY_DELAY_MS");
                query(&ui, &["ctrl+a", "c", "a", "t"]);
            }
            5 => {
                if !replace(&ui).is_sensitive() || !count(&ui, 1) {
                    return glib::ControlFlow::Continue;
                }
                epoch.set(source_panes::stamp(&doc).unwrap().3);
                std::env::set_var("FASTRA_SINGLE_REPLY_DELAY_MS", "3000");
                git_view::test_click(&replace(&ui), &[]);
                clicked.set(Instant::now());
            }
            6 => {
                assert!(!replace(&ui).is_sensitive());
                let foreign = gtk::ApplicationWindow::builder()
                    .application(&ui.window.application().unwrap())
                    .title("Other single-test editor")
                    .default_width(400)
                    .default_height(240)
                    .child(&gtk::Label::new(Some("Foreign document window")))
                    .build();
                foreign.present();
                git_view::test_keys(&foreign, &[]);
                *other.borrow_mut() = Some(foreign);
            }
            7 => {
                if !other.borrow().as_ref().unwrap().is_active() {
                    return glib::ControlFlow::Continue;
                }
                window(&ui).present();
                git_view::test_keys(&window(&ui), &[]);
            }
            8 => {
                if !window(&ui).is_active() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    clicked.get().elapsed() < Duration::from_millis(2700),
                    "focus roundtrip must precede delayed result"
                );
                assert_ne!(source_panes::stamp(&doc).unwrap().3, epoch.get());
            }
            9 => {
                if clicked.get().elapsed() < Duration::from_millis(3300) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&doc.buffer), "cat");
                assert!(!doc.buffer.can_undo() && !doc.buffer.is_modified());
                std::env::remove_var("FASTRA_SINGLE_REPLY_DELAY_MS");
                let foreign = other.borrow_mut().take().unwrap();
                foreign.close();
                window(&ui).present();
                query(&ui, &["ctrl+a", "c", "a", "t"]);
            }
            10 => {
                if !replace(&ui).is_sensitive() || !count(&ui, 1) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&replace(&ui), &[]);
            }
            11 => {
                if buffer_text(&doc.buffer) != "dog" {
                    return glib::ControlFlow::Continue;
                }
                undo(&doc);
            }
            12 => {
                if buffer_text(&doc.buffer) != "cat" {
                    return glib::ControlFlow::Continue;
                }
                assert!(!doc.buffer.is_modified());
                println!(
                    "PASS native single guards: changed query cancels delayed result, actual foreign-window focus roundtrip invalidates original owner epoch before response, source/dirty/Undo retained; fresh explicit query restores usable single replacement and native Undo"
                );
                window(&ui).close();
                git_view::finish(
                    ui.window.clone().upcast(),
                    ui.clone(),
                    if open {
                        "single-replace-guards-open"
                    } else {
                        "single-replace-guards"
                    },
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
