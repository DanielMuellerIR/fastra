use super::*;
use crate::editor_options::gui_test as input;

pub(super) fn run(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_WRAP_TAG_COUNT_SELFTEST").is_some() {
        tag_count(ui);
        return;
    }
    use std::time::{Duration, Instant};
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let expected = std::env::var("FASTRA_WRAP_EXPECT_CAPABLE").as_deref() == Ok("1");
    assert_eq!(capable(), expected, "verified native ABI capability");
    let width = std::env::var("FASTRA_TOOL_WIDTH")
        .unwrap_or_else(|_| "1100".into())
        .parse::<i32>()
        .unwrap();
    ui.window.set_default_size(width, 950);
    let text = format!(
        "    {}\n\t \t {}\n{}{}\n{}\n",
        "a".repeat(130),
        "b".repeat(100),
        "\t".repeat(17),
        "c".repeat(120),
        "🙂e\u{301}漢字👩‍💻 ".repeat(35)
    ) + &format!("{}\n", "z".repeat(140));
    ui.add_document("native-wrap.txt", &text);
    let doc = ui.active().unwrap();
    let state = doc.editor_options.borrow().as_ref().unwrap().clone();
    let split = input::checkbox(
        doc.container.upcast_ref(),
        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
    )
    .unwrap();
    split.set_active(true);
    doc.buffer.begin_user_action();
    doc.buffer.insert(&mut doc.buffer.end_iter(), "temporary");
    doc.buffer.end_user_action();
    doc.buffer.undo();
    let stage = Cell::new(0u32);
    let started = Instant::now();
    let last = Cell::new(started);
    let baseline = Cell::new(None::<(u64, bool, bool, bool)>);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "wrap stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        if last.get().elapsed() < Duration::from_millis(250)
            || state.language_pending.get()
            || profile::pending()
            || !page_guide::ready()
        {
            return glib::ControlFlow::Continue;
        }
        let views: Vec<_> = state.views.iter().filter_map(|v| v.upgrade()).collect();
        if views
            .iter()
            .any(|v| !v.is_mapped() || v.visible_rect().width() < 20)
        {
            return glib::ControlFlow::Continue;
        }
        if stage.get() == 0 {
            for (i, v) in views.iter().enumerate() {
                let b = v.buffer();
                b.select_range(
                    &b.iter_at_offset(if i == 0 { 2 } else { 18 }),
                    &b.iter_at_offset(if i == 0 { 18 } else { 2 }),
                );
            }
            baseline.set(Some((
                doc.revision.get(),
                doc.buffer.is_modified(),
                doc.buffer.can_undo(),
                doc.buffer.can_redo(),
            )));
            stage.set(1);
            last.set(Instant::now());
            return glib::ControlFlow::Continue;
        }
        assert_eq!(crate::buffer_text(&doc.buffer), text);
        assert_eq!(
            baseline.get(),
            Some((
                doc.revision.get(),
                doc.buffer.is_modified(),
                doc.buffer.can_undo(),
                doc.buffer.can_redo()
            ))
        );
        for (i, v) in views.iter().enumerate() {
            let b = v.buffer();
            assert_eq!(
                b.cursor_position(),
                if i == 0 { 2 } else { 18 },
                "head retained at stage {}",
                stage.get()
            );
            assert_eq!(
                b.iter_at_mark(&b.selection_bound()).offset(),
                if i == 0 { 18 } else { 2 },
                "anchor retained at stage {}",
                stage.get()
            );
            assert_eq!(b.text(&b.start_iter(), &b.end_iter(), true).as_str(), text);
            assert_eq!(
                (b.is_modified(), b.can_undo(), b.can_redo()),
                (
                    doc.buffer.is_modified(),
                    doc.buffer.can_undo(),
                    doc.buffer.can_redo()
                )
            );
            if stage.get() > 1 {
                let first = b.start_iter();
                let mut next = first;
                assert!(v.forward_display_line(&mut next));
                let cell = f64::from(v.create_pango_layout(Some(" ")).size().0)
                    / f64::from(gtk::pango::SCALE);
                let available =
                    (v.visible_rect().width() - v.left_margin() - v.right_margin() - 1).max(1);
                let columns = match state.soft_wrap.target.get() {
                    Target::Window => None,
                    Target::PageGuide => Some(v.right_margin_position()),
                    Target::FixedColumn => Some(state.soft_wrap.column.get()),
                };
                let max_width = columns
                    .map_or(available, |n| (f64::from(n) * cell).ceil() as i32)
                    .min(available)
                    .max(1);
                let mode = state.soft_wrap.indentation.get();
                let expected_offset = (if mode == Indentation::FlushLeft {
                    0.
                } else {
                    (4. + if mode == Indentation::Reverse {
                        if v.is_insert_spaces_instead_of_tabs() {
                            f64::from(v.indent_width())
                        } else {
                            f64::from(v.tab_width())
                        }
                    } else {
                        0.
                    }) * cell
                })
                .min(f64::from(max_width - 1));
                let actual = v.iter_location(&next).x() - v.iter_location(&first).x();
                if expected {
                    assert_eq!(
                        v.iter_location(&first).x(),
                        v.left_margin(),
                        "first line remains unchanged"
                    );
                }
                eprintln!("WRAP stage={} pane={i} target={:?} mode={mode:?} max_width={max_width} first_count={} continuation_x={actual} expected_x={expected_offset}",stage.get(),state.soft_wrap.target.get(),next.offset());
                if expected {
                    assert!(
                        (f64::from(actual) - expected_offset).abs() < 2.,
                        "native continuation geometry"
                    );
                    let plain = b.iter_at_line(4).unwrap();
                    let mut plain_next = plain;
                    assert!(v.forward_display_line(&mut plain_next));
                    let count = plain_next.offset() - plain.offset();
                    assert!(
                        (f64::from(count) * cell - f64::from(max_width)).abs() < cell + 1.,
                        "native wrap width count={count} max_width={max_width} cell={cell}"
                    );
                }
                if expected {
                    check_fragment_bounds(v, max_width);
                }
                let mut current = first;
                let mut previous = -1;
                let mut count = 0;
                loop {
                    assert!(current.offset() > previous, "native grapheme progress");
                    previous = current.offset();
                    count += 1;
                    if !v.forward_display_line(&mut current) {
                        break;
                    }
                    assert!(count < 10000);
                }
            }
        }
        let n = stage.get() - 1;
        if n < 18 {
            let target = match n / 6 {
                0 => Target::Window,
                1 => Target::PageGuide,
                _ => Target::FixedColumn,
            };
            let mode = match (n / 2) % 3 {
                0 => Indentation::FlushLeft,
                1 => Indentation::FirstLine,
                _ => Indentation::Reverse,
            };
            let column = if n.is_multiple_of(2) { 20 } else { 80 };
            // A/B ist derselbe Produktpfad: Die fehlende ABI muss jede Layoutänderung abweisen.
            state.change_profile(profile::Patch {
                tab: Some(8),
                indent: Some(2),
                spaces: Some(n.is_multiple_of(2)),
                wrap: Some(true),
                wrap_target: Some(target),
                wrap_column: Some(column),
                wrap_indentation: Some(mode),
            });
            for view in &views {
                view.set_right_margin_position(column);
            }
            ui.window.set_default_size(
                if n.is_multiple_of(2) {
                    width
                } else {
                    if width < 1000 {
                        1100
                    } else {
                        760
                    }
                },
                950,
            );
            stage.set(stage.get() + 1);
            last.set(Instant::now());
            // Vorherigen Zustand erst im nächsten Tick messen; allfällige Tags wirken nativ.
            return glib::ControlFlow::Continue;
        }
        assert_eq!(crate::buffer_text(&doc.buffer), text);
        assert_eq!(
            baseline.get(),
            Some((
                doc.revision.get(),
                doc.buffer.is_modified(),
                doc.buffer.can_undo(),
                doc.buffer.can_redo()
            ))
        );
        for (i, view) in views.iter().enumerate() {
            let b = view.buffer();
            assert_eq!(b.text(&b.start_iter(), &b.end_iter(), true).as_str(), text);
            assert_eq!(b.cursor_position(), if i == 0 { 2 } else { 18 });
            assert_eq!(
                b.iter_at_mark(&b.selection_bound()).offset(),
                if i == 0 { 18 } else { 2 }
            );
            assert_eq!(b.is_modified(), doc.buffer.is_modified());
            let pane = state.soft_wrap.panes[i].borrow();
            assert_eq!(!pane.tags.is_empty(), expected);
            if expected {
                let peer = state.soft_wrap.panes[1 - i].borrow();
                assert!(
                    pane.tags.iter().all(|t| !peer.tags.contains(t)),
                    "shared tag table has pane-unique tags"
                );
            }
        }
        if n == 18 {
            state.change_profile(profile::Patch {
                wrap: Some(true),
                wrap_target: Some(Target::FixedColumn),
                wrap_column: Some(20),
                wrap_indentation: Some(Indentation::FirstLine),
                ..Default::default()
            });
            stage.set(stage.get() + 1);
            last.set(Instant::now());
            return glib::ControlFlow::Continue;
        }
        if n == 19 {
            for (i, view) in views.iter().enumerate() {
                let b = view.buffer();
                let first = b.start_iter();
                let mut next = first;
                assert!(view.forward_display_line(&mut next));
                let first_loc = view.iter_location(&first);
                let next_loc = view.iter_location(&next);
                let cell = f64::from(view.create_pango_layout(Some(" ")).size().0)
                    / f64::from(gtk::pango::SCALE);
                eprintln!("WRAP pane={i} width={} visible={} cell={cell} first={:?} next_offset={} next={:?}",view.width(),view.visible_rect().width(),first_loc,next.offset(),next_loc);
                if expected {
                    let plain = b.iter_at_line(4).unwrap();
                    let mut plain_next = plain;
                    assert!(view.forward_display_line(&mut plain_next));
                    assert_eq!(
                        plain_next.offset() - plain.offset(),
                        20,
                        "fixed column is genuine native wrapping"
                    );
                    assert!(
                        (f64::from(next_loc.x() - first_loc.x()) - 4. * cell).abs() < 2.,
                        "native continuation indentation"
                    );
                }
                let mut current = b.start_iter();
                let mut count = 0;
                let mut previous = -1;
                loop {
                    assert!(
                        current.offset() > previous,
                        "native wrapping makes forward progress"
                    );
                    previous = current.offset();
                    count += 1;
                    if !view.forward_display_line(&mut current) {
                        break;
                    }
                    assert!(count < 10000);
                }
                eprintln!("WRAP native-display-lines pane={i} count={count}");
            }
            crate::git_view::capture(ui.window.upcast_ref(), "wrap-source");
            state.show();
            stage.set(stage.get() + 1);
            last.set(Instant::now());
            return glib::ControlFlow::Continue;
        }
        let w = state.window.borrow().as_ref().unwrap().upgrade().unwrap();
        crate::git_view::capture(&w, "wrap-options");
        let scroll = input::find::<gtk::ScrolledWindow>(w.upcast_ref()).unwrap();
        let adjustment = scroll.vadjustment();
        adjustment.set_value((adjustment.upper() - adjustment.page_size()).max(0.));
        incremental_selftest(
            ui.clone(),
            doc.clone(),
            state.clone(),
            text.clone(),
            w,
            expected,
        );
        glib::ControlFlow::Break
    });
}

fn check_fragment_bounds(view: &sourceview5::View, max_width: i32) {
    let b = view.buffer();
    let mut start = b.start_iter();
    let bound = view.left_margin() + max_width;
    let mut oversized = 0;
    let mut trailing_whitespace = 0;
    loop {
        let mut next = start;
        let more = view.forward_display_line(&mut next);
        let mut end = next;
        if !more || next.line() != start.line() {
            end = start;
            end.forward_to_line_end();
        }
        let mut q = start;
        let mut oversized_seen = false;
        while q < end {
            let r = view.iter_location(&q);
            if !matches!(q.char(), ' ' | '\t' | '\n' | '\r') {
                if r.x() + r.width() > bound {
                    assert!(q.offset()==start.offset() && r.width()>bound-r.x(),"additional visible grapheme exceeds native wrap bound line={} offset={} x={} width={} bound={bound}",q.line(),q.line_offset(),r.x(),r.width());
                    oversized += 1;
                    oversized_seen = true;
                } else {
                    assert!(
                        !oversized_seen,
                        "oversized first grapheme occupies its own fragment"
                    );
                }
            } else if r.x() + r.width() > bound {
                trailing_whitespace += 1;
            }
            if !q.forward_cursor_position() {
                break;
            }
        }
        if !more {
            break;
        }
        assert!(next > start);
        start = next;
    }
    eprintln!("WRAP_BOUND first-oversized-graphemes={oversized} nonpainted-whitespace-rectangles={trailing_whitespace}");
}
fn native_spaces_width(view: &sourceview5::View, count: usize) -> i32 {
    let width = view.create_pango_layout(Some(&" ".repeat(count))).size().0;
    (f64::from(width) / f64::from(gtk::pango::SCALE)).round() as i32
}

fn incremental_selftest(
    ui: Rc<Ui>,
    doc: Rc<Document>,
    state: Rc<Options>,
    text: String,
    window: gtk::Window,
    expected: bool,
) {
    use std::time::{Duration, Instant};
    let stage = Cell::new(0);
    let revision = Cell::new(doc.revision.get());
    let started = Instant::now();
    glib::timeout_add_local(Duration::from_millis(300), move || {
        assert!(
            started.elapsed() < Duration::from_secs(20),
            "native wrap controls stage {}",
            stage.get()
        );
        if profile::pending() {
            return glib::ControlFlow::Continue;
        }
        let views: Vec<_> = state.views.iter().filter_map(|v| v.upgrade()).collect();
        if stage.get() < 6 {
            assert_eq!(crate::buffer_text(&doc.buffer), text);
            assert_eq!(doc.revision.get(), revision.get());
            assert!(!doc.buffer.is_modified());
            assert!(!doc.buffer.can_undo());
            assert!(doc.buffer.can_redo());
        }
        match stage.get() {
            0 => {
                crate::git_view::capture(&window, "wrap-options-bottom");
                let scroll = input::find::<gtk::ScrolledWindow>(window.upcast_ref()).unwrap();
                scroll.vadjustment().set_value(0.);
                if !expected {
                    window.close();
                    stage.set(4);
                }
            }
            1 => {
                let spin = state.soft_wrap.controls.borrow()[1]
                    .upgrade()
                    .unwrap()
                    .downcast::<gtk::SpinButton>()
                    .unwrap();
                let input = input::find::<gtk::Text>(spin.upcast_ref()).unwrap();
                input::click(
                    &window,
                    &input,
                    vec!["ctrl+a".into(), "3".into(), "0".into(), "Return".into()],
                );
            }
            2 => {
                if state.soft_wrap.column.get() != 30 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(state.soft_wrap.target.get(), Target::FixedColumn);
                for view in &views {
                    let b = view.buffer();
                    let plain = b.iter_at_line(4).unwrap();
                    let mut next = plain;
                    assert!(view.forward_display_line(&mut next));
                    assert_eq!(
                        next.offset() - plain.offset(),
                        30,
                        "native spin text changes real wrap column"
                    );
                }
                let mode = state.soft_wrap.controls.borrow()[2]
                    .upgrade()
                    .unwrap()
                    .downcast::<gtk::DropDown>()
                    .unwrap();
                input::click(&window, &mode, vec!["End".into(), "Return".into()]);
            }
            3 => {
                if state.soft_wrap.indentation.get() != Indentation::Reverse {
                    return glib::ControlFlow::Continue;
                }
                for view in &views {
                    let b = view.buffer();
                    let mut next = b.start_iter();
                    assert!(view.forward_display_line(&mut next));
                    assert_eq!(
                        view.iter_location(&next).x(),
                        view.left_margin() + native_spaces_width(view, 12),
                        "native dropdown applies tab-width extra indentation"
                    );
                }
                crate::git_view::capture(&window, "wrap-options-native-changed");
                window.close();
            }
            4 => {
                state.change_profile(profile::Patch {
                    wrap_column: Some(20),
                    wrap_indentation: Some(Indentation::FirstLine),
                    ..Default::default()
                });
            }
            5 => {
                revision.set(doc.revision.get());
                doc.buffer.begin_user_action();
                doc.buffer.insert(&mut doc.buffer.start_iter(), " ");
                doc.buffer.end_user_action();
            }
            6 => {
                assert_eq!(crate::buffer_text(&doc.buffer), format!(" {text}"));
                for view in &views {
                    let b = view.buffer();
                    let mut next = b.start_iter();
                    assert!(view.forward_display_line(&mut next));
                    if expected {
                        assert_eq!(
                            view.iter_location(&next).x(),
                            view.left_margin() + native_spaces_width(view, 5),
                            "changed prefix updates only native paragraph styling"
                        );
                    }
                }
                doc.buffer.undo();
            }
            _ => {
                assert_eq!(crate::buffer_text(&doc.buffer), text);
                assert_eq!(doc.revision.get(), revision.get() + 2);
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                assert!(doc.buffer.can_redo());
                for view in &views {
                    let b = view.buffer();
                    assert_eq!(b.text(&b.start_iter(), &b.end_iter(), true).as_str(), text);
                    let mut next = b.start_iter();
                    assert!(view.forward_display_line(&mut next));
                    if expected {
                        assert_eq!(
                            view.iter_location(&next).x(),
                            view.left_margin() + native_spaces_width(view, 4),
                            "undo recomputes native paragraph styling"
                        );
                    }
                }
                println!("FASTRA WRAP_PROFILE PASS capable={expected} targets=3 modes=3 resizes=18 text/revision/dirty/undo/redo/directed-marks/pane-tags retained native-controls incremental-prefix/undo");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
        }
        stage.set(stage.get() + 1);
        glib::ControlFlow::Continue
    });
}

fn tag_count(ui: Rc<Ui>) {
    use std::time::{Duration, Instant};
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    assert!(capable());
    let mut text = String::new();
    for row in 0..100_000 {
        text.push_str(if row < 50_000 || row % 2 == 0 {
            "    short\n"
        } else {
            "\tshort\n"
        });
    }
    ui.add_document("wrap-count.txt", &text);
    let doc = ui.active().unwrap();
    let state = doc.editor_options.borrow().as_ref().unwrap().clone();
    input::checkbox(
        doc.container.upcast_ref(),
        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
    )
    .unwrap()
    .set_active(true);
    let stage = Cell::new(0);
    let start = Instant::now();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            start.elapsed() < Duration::from_secs(45),
            "100k native paragraph styling timeout"
        );
        if state.language_pending.get() || profile::pending() {
            return glib::ControlFlow::Continue;
        }
        if stage.get() == 0 {
            state.change_profile(profile::Patch {
                tab: Some(8),
                wrap: Some(true),
                wrap_target: Some(Target::FixedColumn),
                wrap_column: Some(80),
                wrap_indentation: Some(Indentation::FirstLine),
                ..Default::default()
            });
            stage.set(1);
            return glib::ControlFlow::Continue;
        }
        for pane in &state.soft_wrap.panes {
            let pane = pane.borrow();
            if pane.geometry.is_none() || pane.next.is_some() || pane.dirty.is_some() {
                return glib::ControlFlow::Continue;
            }
        }
        for (index, view) in state.views.iter().filter_map(|v| v.upgrade()).enumerate() {
            let pane = state.soft_wrap.panes[index].borrow();
            assert_eq!(
                pane.tags.len(),
                2,
                "100k paragraphs reuse two native tags per pane"
            );
            let b = view.buffer();
            let mut ranges = 0;
            for tag in &pane.tags {
                let mut iter = b.start_iter();
                let mut begins = usize::from(iter.has_tag(tag));
                while iter.forward_to_tag_toggle(Some(tag)) {
                    if iter.has_tag(tag) {
                        begins += 1;
                    }
                }
                ranges += begins;
            }
            assert_eq!(
                ranges, 50_000,
                "adjacent equal prefixes coalesce in native tag ranges"
            );
            assert_eq!(b.text(&b.start_iter(), &b.end_iter(), true).as_str(), text);
            assert!(!b.is_modified());
            assert!(!b.can_undo());
            println!("WRAP_TAG_COUNT pane={index} paragraphs=100000 tags={} native_ranges={ranges} shared_table_tags={}",pane.tags.len(),b.tag_table().size());
        }
        if let Ok(status) = std::fs::read_to_string("/proc/self/status") {
            for line in status
                .lines()
                .filter(|line| line.starts_with("VmRSS:") || line.starts_with("VmHWM:"))
            {
                println!("WRAP_TAG_MEMORY {line}");
            }
        }
        println!("FASTRA WRAP_TAG_COUNT PASS paragraphs=100000 equal+alternating-prefixes native-tags-per-pane=2 ranges=50000 elapsed_ms={}",start.elapsed().as_millis());
        ui.window.application().unwrap().quit();
        glib::ControlFlow::Break
    });
}
