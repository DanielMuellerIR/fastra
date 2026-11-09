use super::*;
fn find(root: &gtk::Widget, id: &str) -> Option<gtk::Widget> {
    if root.is_mapped()
        && root.width() > 0
        && root.height() > 0
        && (root.widget_name() == id
            || root
                .downcast_ref::<gtk::MenuButton>()
                .is_some_and(|b| b.tooltip_text().as_deref() == Some(id))
            || root
                .downcast_ref::<gtk::CheckButton>()
                .is_some_and(|b| b.label().as_deref() == Some(id)))
    {
        return Some(root.clone());
    }
    for child in chrome::children(root) {
        if let Some(found) = find(&child, id) {
            return Some(found);
        }
    }
    None
}
fn arrow(f: &Folds, index: usize, region: usize) -> bool {
    let Some(view) = f.views[index].upgrade().filter(|v| v.is_mapped()) else {
        return false;
    };
    let Some(widget) = find(view.upcast_ref(), &format!("fastra-fold-arrows-{index}")) else {
        return false;
    };
    let r = f.regions.borrow()[region].clone();
    let iter = f.buffers[index].iter_at_offset(r.characters.start as i32);
    let rect = view.iter_location(&iter);
    let (_, y) = view.buffer_to_window_coords(gtk::TextWindowType::Widget, rect.x(), rect.y());
    let Some(p) = view.compute_point(
        &widget,
        &gtk::graphene::Point::new(0., (y + rect.height() / 2) as f32),
    ) else {
        return false;
    };
    if p.y() < 0. || p.y() >= widget.height() as f32 {
        return false;
    }
    git_view::test_click_at(&widget, widget.width() as f32 / 2., p.y(), &[]);
    true
}
pub(super) fn run(ui: Rc<Ui>) {
    if std::env::var("FASTRA_FOLDING_SELFTEST").as_deref() == Ok("limits") {
        limits(ui);
        return;
    }
    if std::env::var("FASTRA_FOLDING_SELFTEST").as_deref() == Ok("guards") {
        guards(ui);
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1100);
    ui.window.set_default_size(width, 850);
    let source="fn run(x: bool) {\r\nif x {\r\nprintln!(\"😀 }\");\r\n} else {\r\nprintln!(\"no\");\r\n}\r\n}\r\n";
    ui.add_document("folding.rs", source);
    let doc = ui.active().unwrap();
    let f = doc.syntax_folds.borrow().clone().unwrap();
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let clipboard = Rc::new(RefCell::new(None::<String>));
    let copied = Cell::new(false);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            began.elapsed() < Duration::from_secs(25),
            "folding phase {}: ready={} regions={} status={}",
            phase.get(),
            f.ready.get(),
            f.regions.borrow().len(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(160) {
            return glib::ControlFlow::Continue;
        }
        let views = f.views.each_ref().map(|v| v.upgrade().unwrap());
        let menu = || {
            find(
                doc.container.upcast_ref(),
                ui.lang
                    .text("Darstellung und Bearbeitung", "View and editing"),
            )
        };
        let closed = |index: usize| f.closed[index].borrow().len();
        match phase.get() {
            0 => {
                if !f.ready.get() || f.regions.borrow().len() != 3 || !views[0].is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                let split = find(
                    doc.container.upcast_ref(),
                    ui.lang
                        .text("Quelltextansicht teilen", "Split source editor"),
                )
                .unwrap();
                git_view::test_click(&split, &[]);
            }
            1 => {
                if !views[1].is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                doc.buffer.begin_user_action();
                doc.buffer.insert(&mut doc.buffer.end_iter(), "tail\r\n");
                doc.buffer.end_user_action();
            }
            2 => {
                if !f.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(f.regions.borrow().len(), 3);
                if !arrow(&f, 0, 1) {
                    return glib::ControlFlow::Continue;
                }
            }
            3 => {
                if closed(0) != 1 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(closed(1), 0);
                if !git_view::try_capture(ui.window.upcast_ref(), "folding-child") {
                    return glib::ControlFlow::Continue;
                }
                if !arrow(&f, 0, 0) {
                    return glib::ControlFlow::Continue;
                }
            }
            4 => {
                if closed(0) != 2 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(closed(1), 0);
                if !git_view::try_capture(ui.window.upcast_ref(), "folding-parent") {
                    return glib::ControlFlow::Continue;
                }
                if !arrow(&f, 0, 0) {
                    return glib::ControlFlow::Continue;
                }
            }
            5 => {
                if closed(0) != 1 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(closed(1), 0);
                assert_eq!(buffer_text(&doc.buffer), format!("{source}tail\r\n"));
                if !git_view::try_capture(ui.window.upcast_ref(), "folding-restored-child") {
                    return glib::ControlFlow::Continue;
                }
                let range = f.closed_ranges(0)[0].clone();
                let rect = marker::rect(&views[0], &f.buffers[0], &range);
                git_view::test_double_click_at(
                    &views[0],
                    rect.x() + rect.width() / 2.,
                    rect.y() + rect.height() / 2.,
                );
            }
            6 => {
                if closed(0) != 0 {
                    return glib::ControlFlow::Continue;
                }
                let (a, b) = doc.buffer.selection_bounds().unwrap();
                let region = &f.regions.borrow()[1];
                assert_eq!(a.offset() as u32..b.offset() as u32, region.characters);
                git_view::test_keys(&views[0], &["ctrl+z"]);
            }
            7 => {
                if buffer_text(&doc.buffer) != source || !f.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!doc.buffer.can_undo());
                assert_eq!(buffer_text(&f.buffers[1]), source);
                git_view::test_click(&menu().unwrap(), &[]);
            }
            8 => {
                if !f.buttons[1].is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&f.buttons[1], &[]);
            }
            9 => {
                if closed(0) != 3 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(closed(1), 0);
                git_view::test_keys(&views[0], &["ctrl+a", "ctrl+c"]);
            }
            10 => {
                if !copied.replace(true) {
                    let copied = clipboard.clone();
                    let view = views[0].clone();
                    glib::MainContext::default().spawn_local(async move {
                        *copied.borrow_mut() = view
                            .clipboard()
                            .read_text_future()
                            .await
                            .unwrap()
                            .map(|s| s.to_string());
                    });
                    return glib::ControlFlow::Continue;
                }
                if clipboard.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(clipboard.borrow().as_deref(), Some(source));
                let offset = source[..source.find("println!").unwrap()].chars().count() as i32;
                doc.buffer.place_cursor(&doc.buffer.iter_at_offset(offset));
            }
            11 => {
                if closed(0) != 1 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    f.closed_ranges(0)[0].start as u32,
                    f.regions.borrow()[2].characters.start
                );
                git_view::test_click(&menu().unwrap(), &[]);
            }
            12 => {
                if !f.buttons[2].is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&f.buttons[2], &[]);
            }
            13 => {
                if closed(0) != 0 {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&views[1], &["ctrl+Home"]);
            }
            14 => {
                if f.index() != 1 {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&menu().unwrap(), &[]);
            }
            15 => {
                if !f.buttons[1].is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&f.buttons[1], &[]);
            }
            16 => {
                if closed(1) != 3 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(closed(0), 0);
                if !git_view::try_capture(ui.window.upcast_ref(), "folding-secondary") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&menu().unwrap(), &[]);
            }
            17 => {
                if !f.buttons[2].is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&f.buttons[2], &[]);
            }
            18 => {
                if closed(1) != 0 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(closed(0), 0);
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                git_view::test_click(&menu().unwrap(), &[]);
            }
            19 => {
                if !f.buttons[1].is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&f.buttons[1], &[]);
            }
            20 => {
                if closed(1) != 3 {
                    return glib::ControlFlow::Continue;
                }
                views[1].clipboard().set_text("fold sentinel");
                *clipboard.borrow_mut() = None;
                copied.set(false);
                git_view::test_keys(&views[1], &["ctrl+a", "ctrl+x"]);
            }
            21 => {
                if !buffer_text(&doc.buffer).is_empty() {
                    return glib::ControlFlow::Continue;
                }
                assert!(buffer_text(&f.buffers[1]).is_empty());
                if !copied.replace(true) {
                    let copied = clipboard.clone();
                    let view = views[1].clone();
                    glib::MainContext::default().spawn_local(async move {
                        *copied.borrow_mut() = view
                            .clipboard()
                            .read_text_future()
                            .await
                            .unwrap()
                            .map(|s| s.to_string());
                    });
                    return glib::ControlFlow::Continue;
                }
                if clipboard.borrow().is_none() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(clipboard.borrow().as_deref(), Some(source));
                git_view::test_keys(&views[1], &["ctrl+z"]);
            }
            22 => {
                if buffer_text(&doc.buffer) != source || !f.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&f.buffers[1]), source);
                assert!(!doc.buffer.can_undo());
                assert_eq!(closed(0), 0);
                assert_eq!(closed(1), 0);
                eprintln!("FOLDING SELFTEST PASS actual gutters child/parent/reopen retention, double-click marker/body selection, menu collapse/expand, active independent split, full hidden-source copy/cut, jump reveals ancestors, native Undo preserved; source bytes unchanged");
                ui.window.set_visible(false);
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}

fn guards(ui: Rc<Ui>) {
    use std::sync::atomic::Ordering;
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(1100, 850);
    let source = "Function run($x : Boolean)\r\nIf ($x)\r\nWhile (True)\r\nALERT(\"😀 End if\")\r\nEnd while\r\nElse\r\nALERT(\"no\")\r\nEnd if\r\nFunction other\r\nALERT(\"done\")\r\n";
    ui.add_document("guards.4dm", source);
    let doc = ui.active().unwrap();
    let f = doc.syntax_folds.borrow().clone().unwrap();
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    let pending = RefCell::new(None::<Rc<Document>>);
    let finished = Cell::new(0u64);
    let delete_stage = Cell::new(0u8);
    glib::timeout_add_local(Duration::from_millis(30), move || {
        assert!(
            began.elapsed() < Duration::from_secs(35),
            "fold guards phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(130) {
            return glib::ControlFlow::Continue;
        }
        let view = f.views[0].upgrade().unwrap();
        match phase.get() {
            0 => {
                if !f.ready.get() || f.regions.borrow().len() != 5 {
                    return glib::ControlFlow::Continue;
                }
                if !arrow(&f, 0, 2) {
                    return glib::ControlFlow::Continue;
                }
            }
            1 => {
                if f.closed[0].borrow().len() != 1 {
                    return glib::ControlFlow::Continue;
                }
                let range = f.closed_ranges(0)[0].clone();
                doc.buffer
                    .place_cursor(&doc.buffer.iter_at_offset(range.end));
                git_view::test_keys(&view, &["BackSpace"]);
            }
            2 => match delete_stage.get() {
                0 => {
                    if !f.closed[0].borrow().is_empty() {
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert!(!doc.buffer.can_undo());
                    if !arrow(&f, 0, 2) {
                        return glib::ControlFlow::Continue;
                    }
                    delete_stage.set(1);
                    return glib::ControlFlow::Continue;
                }
                1 => {
                    if f.closed[0].borrow().len() != 1 {
                        return glib::ControlFlow::Continue;
                    }
                    let range = f.closed_ranges(0)[0].clone();
                    doc.buffer
                        .place_cursor(&doc.buffer.iter_at_offset(range.start));
                    git_view::test_keys(&view, &["Delete"]);
                    delete_stage.set(2);
                    return glib::ControlFlow::Continue;
                }
                _ => {
                    if !f.closed[0].borrow().is_empty() {
                        return glib::ControlFlow::Continue;
                    }
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert!(!doc.buffer.can_undo());
                    if !arrow(&f, 0, 2) {
                        return glib::ControlFlow::Continue;
                    }
                }
            },
            3 => {
                if f.closed[0].borrow().len() != 1 {
                    return glib::ControlFlow::Continue;
                }
                doc.buffer.begin_user_action();
                doc.buffer
                    .insert(&mut doc.buffer.start_iter(), "// head\r\n");
                doc.buffer.end_user_action();
                assert!(!f.ready.get());
            }
            4 => {
                if !f.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(f.closed[0].borrow().len(), 1);
                assert_eq!(
                    f.closed_ranges(0)[0].start as u32,
                    f.regions.borrow()[2].characters.start
                );
                git_view::test_keys(&view, &["ctrl+z"]);
            }
            5 => {
                if !f.ready.get() || buffer_text(&doc.buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(f.closed[0].borrow().len(), 1);
                assert!(!doc.buffer.can_undo());
                let offset = source[..source.find("😀").unwrap()].chars().count() as i32;
                doc.buffer.place_cursor(&doc.buffer.iter_at_offset(offset));
                assert!(f.closed[0].borrow().is_empty());
                git_view::test_keys(&view, &["x"]);
            }
            6 => {
                let expected = source.replacen("😀", "x😀", 1);
                if !f.ready.get() || buffer_text(&doc.buffer) != expected {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&view, &["ctrl+z"]);
            }
            7 => {
                if !f.ready.get() || buffer_text(&doc.buffer) != source {
                    return glib::ControlFlow::Continue;
                }
                assert!(!doc.buffer.can_undo());
                finished.set(runtime::FINISHED.load(Ordering::SeqCst));
                ui.add_document(
                    "late-language.rs",
                    "fn pending() {\n println!(\"old\");\n}\n",
                );
                *pending.borrow_mut() = ui.active();
            }
            8 => {
                if runtime::FINISHED.load(Ordering::SeqCst) == finished.get() {
                    return glib::ControlFlow::Continue;
                }
                let current = pending.borrow().clone().unwrap();
                let folds = current.syntax_folds.borrow().clone().unwrap();
                assert!(!folds.ready.get(), "delayed reply must still be pending");
                current.buffer.set_language(None);
            }
            9 => {
                if pause.get().elapsed() < Duration::from_millis(600) {
                    return glib::ControlFlow::Continue;
                }
                let current = pending.borrow().clone().unwrap();
                let folds = current.syntax_folds.borrow().clone().unwrap();
                assert!(folds.ready.get());
                assert!(folds.regions.borrow().is_empty());
                assert_eq!(
                    buffer_text(&current.buffer),
                    "fn pending() {\n println!(\"old\");\n}\n"
                );
                finished.set(runtime::FINISHED.load(Ordering::SeqCst));
                ui.add_document(
                    "late-close.rs",
                    "fn closed() {\n println!(\"closed\");\n}\n",
                );
                *pending.borrow_mut() = ui.active();
            }
            10 => {
                if runtime::FINISHED.load(Ordering::SeqCst) == finished.get() {
                    return glib::ControlFlow::Continue;
                }
                let current = pending.borrow().clone().unwrap();
                let folds = current.syntax_folds.borrow().clone().unwrap();
                assert!(!folds.ready.get());
                let target = folds.views[0].upgrade().unwrap();
                git_view::test_click(&target, &["ctrl+w"]);
            }
            11 => {
                if pause.get().elapsed() < Duration::from_millis(600) {
                    return glib::ControlFlow::Continue;
                }
                let current = pending.borrow().clone().unwrap();
                assert!(!ui
                    .documents
                    .borrow()
                    .iter()
                    .any(|d| Rc::ptr_eq(d, &current)));
                let folds = current.syntax_folds.borrow().clone().unwrap();
                assert!(
                    !folds.ready.get(),
                    "closed document must reject late reply even while a caller retains its Rc"
                );
                assert!(folds.regions.borrow().is_empty());
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                eprintln!("FOLDING GUARDS PASS actual 4D gutters, safe Backspace/Delete, outside edit retains shifted collapse, real typing/Undo, delayed completed old-language reply rejected, closed original identity rejected despite retained document");
                ui.window.set_visible(false);
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}

fn limits(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1100);
    ui.window.set_default_size(width, 850);
    let source = "fn original() {\n println!(\"x\");\n}\n";
    let appended = "fn repeated() {\n x();\n}\n".repeat(10001);
    let expected = format!("{source}{appended}");
    ui.add_document("fold-limit.rs", source);
    let doc = ui.active().unwrap();
    let f = doc.syntax_folds.borrow().clone().unwrap();
    let phase = Cell::new(0);
    let began = Instant::now();
    let pause = Cell::new(began);
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            began.elapsed() < Duration::from_secs(25),
            "fold limit phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(180) {
            return glib::ControlFlow::Continue;
        }
        let view = f.views[0].upgrade().unwrap();
        match phase.get() {
            0 => {
                if !f.ready.get() || f.regions.borrow().len() != 1 {
                    return glib::ControlFlow::Continue;
                }
                if !arrow(&f, 0, 0) {
                    return glib::ControlFlow::Continue;
                }
            }
            1 => {
                if f.closed[0].borrow().len() != 1 {
                    return glib::ControlFlow::Continue;
                }
                doc.buffer.begin_user_action();
                doc.buffer.insert(&mut doc.buffer.end_iter(), &appended);
                doc.buffer.end_user_action();
                assert_eq!(f.closed[0].borrow().len(), 1);
                assert!(!f.ready.get());
            }
            2 => {
                if !f.regions.borrow().is_empty() || !f.closed[0].borrow().is_empty() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!f.ready.get());
                assert_eq!(buffer_text(&doc.buffer), expected);
                assert!(!doc.buffer.iter_at_offset(20).has_tag(&f.tags[0]));
                assert!(f.notice.borrow().is_some());
                if !git_view::try_capture(ui.window.upcast_ref(), "folding-limit") {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_keys(&view, &["ctrl+z"]);
            }
            3 => {
                if buffer_text(&doc.buffer) != source || !f.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(f.regions.borrow().len(), 1);
                assert!(f.closed[0].borrow().is_empty());
                assert!(!doc.buffer.can_undo());
                assert!(f.notice.borrow().is_none());
                if !git_view::try_capture(ui.window.upcast_ref(), "folding-limit-recovered") {
                    return glib::ControlFlow::Continue;
                }
                eprintln!("FOLDING LIMIT PASS 10001 additional regions reject complete plan; retained old collapse opens, unchanged full source, visible notice, native Undo and successful reanalysis clear old notice");
                ui.window.set_visible(false);
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
