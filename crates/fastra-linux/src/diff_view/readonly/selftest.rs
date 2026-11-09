use super::super::export_selftest::{accept, button, chooser_for, typing_finished};
use super::*;
use std::time::{Duration, Instant};
fn target(widget: &gtk::Widget, tooltip: &str) -> Option<gtk::Widget> {
    if widget.is_mapped() && widget.tooltip_text().as_deref() == Some(tooltip) {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(found) = target(&widget, tooltip) {
            return Some(found);
        }
        child = widget.next_sibling();
    }
    None
}
fn deliver(request_paths: [PathBuf; 2], accepted: Rc<Cell<bool>>) {
    support::background(
        move || {
            let result =
                std::process::Command::new(std::env::var_os("FASTRA_EXTERNAL_HELPER").unwrap())
                    .args([
                        "--left-label",
                        "Original α",
                        "--right-label",
                        "Modified β",
                        "--",
                    ])
                    .args(request_paths)
                    .output()
                    .map_err(|error| error.to_string())?;
            assert!(
                result.status.success(),
                "actual helper delivery: {:?}",
                result.status
            );
            assert!(result.stdout.is_empty() && result.stderr.is_empty());
            Ok(())
        },
        move |result| {
            result.expect("actual helper IPC");
            accepted.set(true);
        },
    );
}
pub(super) fn start(app: &gtk::Application) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let paths = [root.join("left α.txt"), root.join("right 右.txt")];
    let text = |side| {
        (0..110)
            .map(|line| match line {
                3 => format!(
                    "{} café 👩🏽‍💻 {}\n",
                    if side == 0 { "old" } else { "new" },
                    "long source 界 e\u{301} ".repeat(8)
                ),
                103 => format!(
                    "{} second difference\n",
                    if side == 0 { "before" } else { "after" }
                ),
                _ => format!("common line {line}\n"),
            })
            .collect::<String>()
    };
    let originals = [text(0), text(1)];
    for (path, text) in paths.iter().zip(&originals) {
        std::fs::write(path, text).unwrap();
        std::fs::hard_link(path, path.with_extension("linked-source")).unwrap();
        assert!(matches!(fastra_io::Snapshot::read(path, &fastra_core::Cancellation::default()), Err(fastra_io::Error::UnsupportedMetadata)));
    }
    let delivered = Rc::new(Cell::new(false));
    deliver(paths.clone(), delivered.clone());
    let app = app.clone();
    let pinned = RefCell::new(None::<Rc<ReadOnly>>);
    let pinned_window = RefCell::new(None::<gtk::Window>);
    let copied = Rc::new(RefCell::new(None::<String>));
    let typed = RefCell::new(None::<std::sync::mpsc::Receiver<()>>);
    let before_folds = Cell::new(0);
    let report = root.join("external-report.txt");
    let renamed = root.join("renamed-source.txt");
    let phase = Rc::new(Cell::new(0));
    let quitting = phase.clone();
    app.connect_shutdown(move |app| {
        assert_eq!(quitting.get(),23,"native Quit reaches shutdown only after the full UI checks");
        assert!(app.windows().is_empty());
        assert!(LAST.with(|last|last.borrow().upgrade().is_none_or(|this|this.closed.get())));
        eprintln!("READONLY_DIFF_SELFTEST PASS real helper IPC without editor window, shared readonly renderer, source labels, min940x420/broad1100x720, native nav/ruler/fold/copy, full localized atomic export, renamed source overwrite rejected, native Close releases view, second helper delivery and actual menu Quit complete shutdown");
    });
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            began.elapsed() < Duration::from_secs(45),
            "readonly native phase{}",
            phase.get()
        );
        if pause.get().elapsed() < Duration::from_millis(300) {
            return glib::ControlFlow::Continue;
        }
        if phase.get() == 20 {
            assert!(
                LAST.with(|last| last.borrow().upgrade().is_none()),
                "closed readonly controller released"
            );
            delivered.set(false);
            deliver([renamed.clone(), paths[1].clone()], delivered.clone());
            phase.set(21);
            pause.set(Instant::now());
            return glib::ControlFlow::Continue;
        }
        if phase.get() == 23 {
            return glib::ControlFlow::Continue;
        }

        let Some(this) = pinned
            .borrow()
            .clone()
            .or_else(|| LAST.with(|last| last.borrow().upgrade()))
        else {
            return glib::ControlFlow::Continue;
        };
        let window = pinned_window
            .borrow()
            .clone()
            .or_else(|| this.window.upgrade())
            .unwrap();
        let view = &this.view;
        let lang = this.lang;
        let chooser = || chooser_for(&window, lang);
        match phase.get() {
            0 => {
                if !delivered.get() || !view.ready.get() || view.alignment.test_pending() {
                    return glib::ControlFlow::Continue;
                }
                *pinned.borrow_mut() = Some(this.clone());
                *pinned_window.borrow_mut() = Some(window.clone());
                assert_eq!(
                    app.windows().len(),
                    1,
                    "no ordinary editor or editable tabs"
                );
                assert!(window.title().unwrap().contains("Original α ↔ Modified β"));
                assert_eq!(view.names[0].text(), "Original α");
                assert_eq!(view.names[1].text(), "Modified β");
                for text in &view.texts {
                    assert!(!text.is_editable());
                    assert_eq!(text.wrap_mode(), gtk::WrapMode::WordChar);
                }
                assert!(!view.transfer[0].is_visible() && !view.transfer[1].is_visible());
                assert!(!view.refresh.is_visible());
                assert_eq!(view.data.borrow().as_ref().unwrap().blocks.len(), 2);
                assert!(
                    gtk::IconTheme::for_display(&gtk::prelude::WidgetExt::display(&window))
                        .has_icon("fastra-share-symbolic")
                );
                if !support::try_capture(window.upcast_ref(), "external-broad") {
                    return glib::ControlFlow::Continue;
                }
                window.set_default_size(940, 420);
            }
            1 => {
                if window.width() != 940 || window.height() != 420 {
                    return glib::ControlFlow::Continue;
                }
                if !support::try_capture(window.upcast_ref(), "external-minimum") {
                    return glib::ControlFlow::Continue;
                }
                support::test_click_at(&view.texts[0], 70., 8., &["alt+Down"]);
            }
            2 => {
                assert_eq!(view.selection.selected(), 1);
                support::test_click(&view.ruler.test_button(0).unwrap(), &[]);
            }
            3 => {
                assert_eq!(view.selection.selected(), 0);
                if window.height() != 720 {
                    window.set_default_size(1100, 720);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                if view.alignment.test_pending() || view.folding.test_button(0).is_none() {
                    return glib::ControlFlow::Continue;
                }
                before_folds.set(
                    view.folding
                        .hidden(view.data.borrow().as_ref().unwrap())
                        .len(),
                );
                assert!(before_folds.get() > 0);
                support::test_click(&view.folding.test_button(0).unwrap(), &[]);
            }
            4 => {
                assert!(
                    view.folding
                        .hidden(view.data.borrow().as_ref().unwrap())
                        .len()
                        < before_folds.get()
                );
                support::test_click_at(&view.texts[0], 80., 8., &["ctrl+a", "ctrl+c"]);
            }
            5 => {
                let copied = copied.clone();
                view.texts[0].clipboard().read_text_async(
                    None::<&gio::Cancellable>,
                    move |result| {
                        *copied.borrow_mut() = Some(result.unwrap().unwrap().to_string());
                    },
                );
            }
            6 => {
                let Some(text) = copied.borrow().clone() else {
                    return glib::ControlFlow::Continue;
                };
                assert!(text.contains("old café 👩🏽‍💻") && text.contains("common line 50"));
                assert!(!text.contains("⋯") && !text.contains("   1 |"));
                support::test_click(&view.export, &[]);
            }
            7 | 13 => {
                let Some(dialog) = chooser() else {
                    return glib::ControlFlow::Continue;
                };
                if phase.get() == 13 {
                    std::fs::rename(&paths[0], &renamed).unwrap();
                }
                support::test_keys(&dialog, &["ctrl+l", "ctrl+a"]);
            }
            8 | 14 => {
                let dialog = chooser().unwrap();
                *typed.borrow_mut() = Some(support::test_type(
                    &dialog,
                    if phase.get() == 8 { &report } else { &renamed }
                        .to_str()
                        .unwrap(),
                ));
            }
            9 | 15 => {
                if !typing_finished(&typed) {
                    return glib::ControlFlow::Continue;
                }
                support::test_keys(&chooser().unwrap(), &["Return"]);
            }
            10 | 16 => {
                let confirmation = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|widget| widget.downcast::<gtk::Window>().ok())
                    .any(|candidate| {
                        candidate.is_visible()
                            && candidate != window
                            && chooser().as_ref() != Some(&candidate)
                    });
                if !confirmation {
                    if let Some(dialog) = chooser() {
                        support::test_click(&accept(&dialog), &[]);
                    }
                }
            }
            11 => {
                if !report.exists() {
                    return glib::ControlFlow::Continue;
                }
                let text = std::fs::read_to_string(&report).unwrap();
                assert!(
                    text.contains(lang.text("Differenzen-Liste", "Difference list"))
                        && text.contains("Original α")
                        && text.contains("Modified β")
                );
                assert!(
                    text.contains("- 4 | old café")
                        && text.contains("+ 104 | after second difference")
                );
                assert!(text.contains(lang.text("Datei", "File")));
                assert_eq!(std::fs::read_to_string(&paths[0]).unwrap(), originals[0]);
            }
            12 => {
                support::test_click(&view.export, &[]);
            }
            17 => {
                let confirmation = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|widget| widget.downcast::<gtk::Window>().ok())
                    .find(|candidate| {
                        candidate.is_visible()
                            && candidate != &window
                            && chooser().as_ref() != Some(candidate)
                    });
                if let Some(dialog) = confirmation {
                    support::test_click(
                        &button(dialog.upcast_ref(), &["Replace", "Ersetzen"])
                            .expect("native Replace"),
                        &[],
                    );
                } else if !view.status.text().contains(lang.text(
                    "Vergleichsquelle überschreiben",
                    "overwrite a comparison source",
                )) {
                    assert!(
                        pause.get().elapsed() < Duration::from_secs(4),
                        "source guard: status={:?}, windows={:?}, files={:?}",
                        view.status.text(),
                        gtk::Window::list_toplevels()
                            .iter()
                            .filter_map(|widget| widget.downcast_ref::<gtk::Window>())
                            .map(|window| (window.title(), window.is_visible()))
                            .collect::<Vec<_>>(),
                        std::fs::read_dir(&root)
                            .unwrap()
                            .map(|entry| entry.unwrap().file_name())
                            .collect::<Vec<_>>()
                    );
                    return glib::ControlFlow::Continue;
                }
            }
            18 => {
                if !view.status.text().contains(lang.text(
                    "Vergleichsquelle überschreiben",
                    "overwrite a comparison source",
                )) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(std::fs::read_to_string(&renamed).unwrap(), originals[0]);
                assert_eq!(std::fs::read_to_string(&paths[1]).unwrap(), originals[1]);
                support::test_click(
                    &target(window.upcast_ref(), lang.text("Schließen", "Close")).unwrap(),
                    &[],
                );
            }
            21 => {
                if !delivered.get() || !view.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                support::test_click(
                    &target(window.upcast_ref(), lang.text("Fastra-Menü", "Fastra menu")).unwrap(),
                    &[],
                );
            }
            22 => {
                let Some(quit) = button(
                    window.upcast_ref(),
                    &[lang.text("Fastra beenden", "Quit Fastra")],
                )
                .filter(|button| button.is_mapped()) else {
                    return glib::ControlFlow::Continue;
                };
                support::test_click(&quit, &[]);
            }
            _ => {
                if window.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert!(this.closed.get() && this.report.borrow().is_none());
                assert!(app.windows().is_empty());
                pinned.borrow_mut().take();
                pinned_window.borrow_mut().take();
            }
        }
        eprintln!("readonly native phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
