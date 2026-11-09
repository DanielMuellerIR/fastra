use super::*;
pub(super) fn start(ui: Rc<Ui>) {
    seed(false);
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("large.txt");
    let source = format!("b\n{}", "preserved\n".repeat(600_000));
    std::fs::write(&path, &source).unwrap();
    assert!(source.len() > 4 * 1024 * 1024);
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let shot = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(100), move || {
        assert!(
            began.elapsed() < Duration::from_secs(70),
            "large snippet phase{} {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(450) {
            return glib::ControlFlow::Continue;
        }
        let Some(doc) = ui
            .active()
            .filter(|d| d.disk_path().as_ref() == Some(&path))
        else {
            return glib::ControlFlow::Continue;
        };
        match phase.get() {
            0 => {
                doc.buffer
                    .select_range(&doc.buffer.start_iter(), &doc.buffer.iter_at_offset(1));
            }
            1 => {
                assert!(doc.buffer.char_count() > 4 * 1024 * 1024);
                if !crate::git_view::try_capture_x11(&ui.window, "snippet-big-source-native", &shot)
                {
                    return glib::ControlFlow::Continue;
                }
                open(&ui);
            }
            2 => {
                let Some(v) = view().filter(|v| v.snapshot.borrow().is_some() && !v.busy.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(v.apply.is_sensitive(), "{}", v.status.text());
                v.values.borrow()[0].1.buffer().set_text("Large");
                v.values.borrow()[1].1.buffer().set_text("test");
            }
            3 => {
                crate::git_view::test_click(&view().unwrap().apply, &[]);
            }
            4 => {
                if view().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let text = buffer_text(&doc.buffer);
                assert!(text.starts_with("Large / test / Large\npreserved\n"));
                assert_eq!(&text["Large / test / Large".len()..], &source[1..]);
                assert_eq!(std::fs::read_to_string(&path).unwrap(), source);
                crate::git_view::test_click(
                    &source_panes::capture(&doc).unwrap().view,
                    &["ctrl+z"],
                );
            }
            _ => {
                assert_eq!(buffer_text(&doc.buffer), source);
                println!("FASTRA_SNIPPET_BIG_SELFTEST_OK 600000-lines/over-4MiB/captured-selection/worker-preflight/native-insert-one-undo/file-unchanged");
                std::process::exit(0);
            }
        }
        eprintln!("large snippet phase{}", phase.get());
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
