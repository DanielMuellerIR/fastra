use super::*;
use std::time::Instant;

fn find(widget: &gtk::Widget, text: &str) -> Option<gtk::Button> {
    if let Some(button) = widget.downcast_ref::<gtk::Button>().filter(|b| {
        b.is_mapped()
            && (b.label().as_deref() == Some(text) || b.tooltip_text().as_deref() == Some(text))
    }) {
        return Some(button.clone());
    }
    chrome::children(widget)
        .iter()
        .find_map(|child| find(child, text))
}
fn window(title: &str) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk::Window>().ok())
        .find(|w| w.is_mapped() && w.title().as_deref() == Some(title))
}
fn dropdowns(widget: &gtk::Widget) -> Vec<gtk::DropDown> {
    if let Some(dropdown) = widget.downcast_ref::<gtk::DropDown>() {
        return vec![dropdown.clone()];
    }
    chrome::children(widget)
        .iter()
        .flat_map(dropdowns)
        .collect()
}
fn labels(widget: &gtk::Widget) -> String {
    let own = widget
        .downcast_ref::<gtk::Label>()
        .map(|v| v.text().to_string())
        .unwrap_or_default();
    own + &chrome::children(widget)
        .iter()
        .map(labels)
        .collect::<Vec<_>>()
        .join(" ")
}
pub(crate) fn run(ui: Rc<Ui>) {
    static STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if STARTED.swap(true, std::sync::atomic::Ordering::Relaxed) {
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.add_document("source.txt", "cat cat");
    let source = ui.active().unwrap();
    let source_page = ui.tabs.current_page().unwrap();
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let foreign = RefCell::new(None::<Rc<Ui>>);
    let clipboard = Rc::new(RefCell::new(None::<String>));
    let tab_count = Cell::new(0usize);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            began.elapsed().as_secs() < 45,
            "search parity phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(220) {
            return glib::ControlFlow::Continue;
        }
        let shell = ui.chrome.borrow().clone().unwrap();
        let surface = ui.approval.search.borrow().clone().unwrap();
        match phase.get() {
            0 | 4 | 10 | 18 => {
                ui.tabs.set_current_page(Some(source_page));
                chrome::show_search(&ui);
                ui.find.set_text("cat");
                ui.replace.set_text("dog");
                ui.mode.set_selected(0);
                git_view::test_keys(&ui.find, &[]);
            }
            1 | 5 | 11 | 19 => {
                ui.search();
            }
            2 => {
                if !surface.available() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.approval.approvals(), Some(vec![vec![]]));
                assert!(!ui.apply.is_sensitive() && !surface.review.is_sensitive());
                let button = find(
                    shell.search_window.upcast_ref(),
                    ui.lang.text("Treffer extrahieren", "Extract matches"),
                )
                .unwrap();
                git_view::test_click(&button, &[]);
            }
            3 => {
                let Some(extract) = window(ui.lang.text("Treffer extrahieren", "Extract matches"))
                else {
                    return glib::ControlFlow::Continue;
                };
                git_view::capture(&extract, "search-extract");
                git_view::test_click(
                    &find(extract.upcast_ref(), ui.lang.text("Extrahieren", "Extract")).unwrap(),
                    &[],
                );
                phase.set(300);
                return glib::ControlFlow::Continue;
            }
            300 => {
                if Rc::ptr_eq(&ui.active().unwrap(), &source) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "dog\ndog\n");
                assert!(ui.active().unwrap().buffer.is_modified());
                assert_eq!(buffer_text(&source.buffer), "cat cat");
                phase.set(4);
                return glib::ControlFlow::Continue;
            }
            6 => {
                if !surface.available() {
                    return glib::ControlFlow::Continue;
                }
                if !ui.approval.has_approvals() {
                    git_view::test_click(&surface.all, &[]);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                phase.set(61);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            61 => {
                if !surface.available() || !surface.review.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                surface.review.grab_focus();
                git_view::test_keys(&surface.review, &["space"]);
                phase.set(7);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            7 => {
                if !ui.apply.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                let other = crate::build(&ui.window.application().unwrap());
                other.window.set_title(Some("Foreign editor"));
                other.add_document("other.txt", "other");
                git_view::test_keys(&other.window, &[]);
                *foreign.borrow_mut() = Some(other);
            }
            8 => {
                if !foreign.borrow().as_ref().unwrap().window.is_active() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&ui.apply, &[]);
            }
            9 => {
                if ui.pending.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    buffer_text(&source.buffer),
                    "cat cat",
                    "foreign-window roundtrip invalidates original target"
                );
                let other = foreign.borrow_mut().take().unwrap();
                other.discard_confirmed.set(true);
                other.window.close();
            }
            12 => {
                if !surface.available() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&surface.all, &[]);
                phase.set(120);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            120 => {
                if !surface.available() || ui.approval.approvals() != Some(vec![vec![0, 1]]) {
                    return glib::ControlFlow::Continue;
                }
                let button = find(
                    shell.search_window.upcast_ref(),
                    ui.lang.text("Keine", "None"),
                )
                .unwrap();
                git_view::test_click(&button, &[]);
                phase.set(13);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            13 => {
                if ui.approval.approvals() != Some(vec![vec![]]) {
                    return glib::ControlFlow::Continue;
                }
                assert!(!ui.apply.is_sensitive());
                let button = find(
                    shell.search_window.upcast_ref(),
                    ui.lang.text("Alle", "All"),
                )
                .unwrap();
                git_view::test_click(&button, &[]);
            }
            14 => {
                if ui.approval.approvals() != Some(vec![vec![0, 1]]) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&surface.review, &[]);
            }
            15 => {
                if !ui.apply.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(ui.approval.test_display(0), "cat cat");
                assert_eq!(ui.approval.test_display(1), "dog dog");
                git_view::capture(&surface.window, "search-reviewed");
                git_view::test_click(&ui.apply, &[]);
            }
            16 => {
                if buffer_text(&source.buffer) != "dog dog" {
                    return glib::ControlFlow::Continue;
                }
                shell.search_window.close();
                phase.set(160);
                return glib::ControlFlow::Continue;
            }
            160 => {
                if shell.search_window.is_mapped() || ui.apply.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                let target = source_panes::capture(&source).unwrap();
                git_view::test_click(&target.view, &["ctrl+z"]);
                phase.set(17);
                pause.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            17 => {
                if buffer_text(&source.buffer) != "cat cat" {
                    return glib::ControlFlow::Continue;
                }
            }
            20 | 22 | 27 => {
                if !surface.available() {
                    return glib::ControlFlow::Continue;
                }
                tab_count.set(ui.documents.borrow().len());
                git_view::test_click(
                    &find(
                        shell.search_window.upcast_ref(),
                        ui.lang.text("Treffer extrahieren", "Extract matches"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            21 => {
                let Some(dialog) = window(ui.lang.text("Treffer extrahieren", "Extract matches"))
                else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(
                    &find(dialog.upcast_ref(), ui.lang.text("Abbrechen", "Cancel")).unwrap(),
                    &[],
                );
            }
            23 => {
                assert_eq!(ui.documents.borrow().len(), tab_count.get());
                let Some(dialog) = window(ui.lang.text("Treffer extrahieren", "Extract matches"))
                else {
                    return glib::ControlFlow::Continue;
                };
                git_view::test_click(&dropdowns(dialog.upcast_ref())[1], &["Down", "Return"]);
            }
            24 => {
                let dialog =
                    window(ui.lang.text("Treffer extrahieren", "Extract matches")).unwrap();
                if dropdowns(dialog.upcast_ref())[1].selected() != 1 {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(
                    &find(dialog.upcast_ref(), ui.lang.text("Extrahieren", "Extract")).unwrap(),
                    &[],
                );
            }
            25 => {
                if window(ui.lang.text("Treffer extrahieren", "Extract matches")).is_some() {
                    return glib::ControlFlow::Continue;
                }
                let received = clipboard.clone();
                surface.list.clipboard().read_text_async(
                    None::<&gio::Cancellable>,
                    move |result| {
                        *received.borrow_mut() = Some(result.unwrap().unwrap().to_string());
                    },
                );
            }
            26 => {
                let Some(text) = clipboard.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(text, "dog\ndog\n");
                assert_eq!(ui.documents.borrow().len(), tab_count.get());
                surface.list.clipboard().set_text("retained clipboard");
            }
            28 => {
                if window(ui.lang.text("Treffer extrahieren", "Extract matches")).is_none() {
                    return glib::ControlFlow::Continue;
                }
                ui.find.set_text("missing");
                assert!(!surface.available());
            }
            29 => {
                let dialog =
                    window(ui.lang.text("Treffer extrahieren", "Extract matches")).unwrap();
                git_view::test_click(
                    &find(dialog.upcast_ref(), ui.lang.text("Extrahieren", "Extract")).unwrap(),
                    &[],
                );
            }
            30 => {
                let dialog =
                    window(ui.lang.text("Treffer extrahieren", "Extract matches")).unwrap();
                assert!(labels(dialog.upcast_ref())
                    .contains(ui.lang.text("Trefferbasis geändert", "Matches changed")));
                assert_eq!(ui.documents.borrow().len(), tab_count.get());
                assert_eq!(buffer_text(&source.buffer), "cat cat");
                dialog.close();
                let item = |name: &str, text: &str| Item {
                    label: name.into(),
                    preview: Arc::new(
                        fastra_core::preview(
                            text,
                            1,
                            1,
                            &SearchRequest {
                                pattern: "cat".into(),
                                replacement: "dog".into(),
                                mode: SearchMode::Literal,
                                case_sensitive: true,
                                range: None,
                            },
                            Limits::default(),
                            &Cancellation::default(),
                        )
                        .unwrap(),
                    ),
                };
                ui.approval.set_items(vec![
                    item("no matches.txt", "none"),
                    item("source.txt", "cat cat"),
                ]);
            }
            31 => {
                if !ui.approval.test_approve_initial() {
                    return glib::ControlFlow::Continue;
                }
                if !surface.available() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    ui.approval.files.selected(),
                    0,
                    "visible file index excludes zero-match inputs"
                );
                assert_eq!(ui.approval.test_display(0), "cat cat");
                assert_eq!(ui.approval.test_display(1), "dog dog");
                ui.approval.set_items(vec![Item {
                    label: "empty match.txt".into(),
                    preview: Arc::new(
                        fastra_core::preview(
                            "xcat",
                            1,
                            1,
                            &SearchRequest {
                                pattern: "(?=x)|cat".into(),
                                replacement: "dog".into(),
                                mode: SearchMode::Regex,
                                case_sensitive: true,
                                range: None,
                            },
                            Limits::default(),
                            &Cancellation::default(),
                        )
                        .unwrap(),
                    ),
                }]);
            }
            32 => {
                if !surface.available() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(
                    &find(
                        shell.search_window.upcast_ref(),
                        ui.lang.text("Treffer kopieren", "Copy matches"),
                    )
                    .unwrap(),
                    &[],
                );
            }
            33 => {
                let received = clipboard.clone();
                surface.list.clipboard().read_text_async(
                    None::<&gio::Cancellable>,
                    move |result| {
                        *received.borrow_mut() = Some(result.unwrap().unwrap().to_string());
                    },
                );
            }
            34 => {
                let Some(text) = clipboard.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(text, "\ncat", "empty first match retains its separator");
                assert_eq!(buffer_text(&source.buffer), "cat cat");
                source_appearance::cleanup_schemes();
                eprintln!(
                    "SEARCH_PARITY_SELFTEST PASS native extraction/new dirty document, Cancel, clipboard destination and stale-input rejection without new documents, zero-match input before a matching file, copy with empty first match, grouped approvals All/None, separate review, unrelated window target rejection, fresh review/apply/Undo, original source retained"
                );
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
