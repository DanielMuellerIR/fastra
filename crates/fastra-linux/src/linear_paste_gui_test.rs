use super::*;
use std::{cell::RefCell, time::Instant};
fn sources(root: &gtk::Widget, out: &mut Vec<sourceview5::View>) {
    if let Some(view) = root.downcast_ref::<sourceview5::View>() {
        out.push(view.clone());
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        sources(&widget, out);
        child = widget.next_sibling();
    }
}
fn label(root: &gtk::Widget, text: &str) -> Option<gtk::Widget> {
    if root.is_mapped()
        && root
            .downcast_ref::<gtk::Label>()
            .is_some_and(|l| l.text() == text)
    {
        return Some(root.clone());
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        if let Some(w) = label(&widget, text) {
            return Some(w);
        }
        child = widget.next_sibling();
    }
    None
}
fn split(root: &gtk::Widget) -> Option<gtk::CheckButton> {
    if let Some(button) = root.downcast_ref::<gtk::CheckButton>().filter(|b| {
        matches!(
            b.label().as_deref(),
            Some("Split source editor" | "Quelltextansicht teilen")
        )
    }) {
        return Some(button.clone());
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        if let Some(w) = split(&widget) {
            return Some(w);
        }
        child = widget.next_sibling();
    }
    None
}
fn keys(view: &sourceview5::View, sequence: &[&str]) {
    let native = view.native().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let xid: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { xid(native.surface().unwrap().as_ptr().cast()) }.to_string();
    let sequence: Vec<String> = sequence.iter().map(|s| s.to_string()).collect();
    std::thread::spawn(move || {
        assert!(std::process::Command::new("xdotool")
            .args(["windowfocus", "--sync", &id, "key", "--clearmodifiers"])
            .args(sequence)
            .status()
            .unwrap()
            .success());
    });
}
fn provider(view: &sourceview5::View, bytes: Vec<u8>) {
    view.clipboard()
        .set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
            "text/plain;charset=utf-8",
            &glib::Bytes::from_owned(bytes),
        )))
        .unwrap();
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    crate::git_view::test_size(ui.window.upcast_ref());
    let kind = std::env::var("FASTRA_LINEAR_PASTE_CASE").unwrap_or_else(|_| "line".into());
    let original = if kind == "stale-scroll-selection" {
        format!("abcde\r\n{}", "tail\n".repeat(1000))
    } else {
        "abcde\r\nz\r\n".to_string()
    };
    ui.add_document("linear-paste.txt", &original);
    let doc = ui.active().unwrap();
    if kind == "scroll-post-selection" {
        let weak = Rc::downgrade(&doc);
        let fired = Cell::new(false);
        source_panes::buffer(&doc).connect_end_user_action(move |buffer| {
            if buffer.char_count() < 1000 || fired.replace(true) {
                return;
            }
            let weak = weak.clone();
            glib::idle_add_local_once(move || {
                if let Some(doc) = weak.upgrade() {
                    source_panes::buffer(&doc)
                        .place_cursor(&source_panes::buffer(&doc).iter_at_offset(2000));
                }
            });
        });
    }
    let positive = matches!(
        kind.as_str(),
        "scroll-valid"
            | "scroll-pane2"
            | "scroll-context"
            | "scroll-wide"
            | "scroll-post-selection"
            | "valid"
            | "valid-context"
            | "valid-shift"
            | "exact"
            | "total-valid"
            | "rapid"
            | "rect-context"
    );
    let payload = match kind.as_str() {
        "scroll-valid"
        | "scroll-pane2"
        | "scroll-context"
        | "scroll-post-selection"
        | "stale-scroll-selection" => "row\n".repeat(1000).into_bytes(),
        "scroll-wide" => "x".repeat(2000).into_bytes(),
        "nul" => b"safe\0lost".to_vec(),
        "total" => vec![b'\n'; 32 * 1024 * 1024],
        "input-total" => vec![b'\n'; 32 * 1024 * 1024 + 1],
        "prefix" => vec![b'x'; 65536],
        "utf8-line" => "é".repeat(32768).into_bytes(),
        "total-valid" => [vec![b'x'; 65535], vec![b'\n']].concat().repeat(512),
        "valid" | "valid-context" | "valid-shift" => "é🙂\r\n二".as_bytes().to_vec(),
        "exact" => vec![b'x'; 65534],
        "empty" => vec![],
        "rapid" => b"OLD".to_vec(),
        "rect-context" => b"X".to_vec(),
        k if k.starts_with("stale-") => b"PASTE".to_vec(),
        _ => vec![b'x'; 65537],
    };
    let expected = match kind.as_str() {
        "scroll-valid" | "scroll-pane2" | "scroll-context" | "scroll-post-selection" => {
            format!("a{}e\r\nz\r\n", "row\n".repeat(1000))
        }
        "scroll-wide" => format!("a{}e\r\nz\r\n", "x".repeat(2000)),
        "valid" | "valid-context" | "valid-shift" => "aé🙂\r\n二e\r\nz\r\n".to_string(),
        "exact" => format!("a{}e\r\nz\r\n", "x".repeat(65534)),
        "total-valid" => String::from_utf8(payload.clone()).unwrap(),
        "rapid" => "aNEWe\r\nz\r\n".to_string(),
        "rect-context" => "aXe\r\nzX\r\n".to_string(),
        "stale-source" | "history-reject" => format!("{original}!"),
        _ => original.to_string(),
    };
    let phase = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    let receipt = Cell::new(None::<Instant>);
    let view = RefCell::new(None::<sourceview5::View>);
    let secondary = RefCell::new(None::<sourceview5::View>);
    glib::timeout_add_local(Duration::from_millis(60), move || {
        assert!(
            start.elapsed() < Duration::from_secs(40),
            "linear {kind} stage={} counts={:?} status={}",
            phase.get(),
            linear_paste::test_counts(),
            ui.status.text()
        );
        match phase.get() {
            0 => {
                if pause.get().elapsed() < Duration::from_millis(400) {
                    return glib::ControlFlow::Continue;
                }
                let mut all = Vec::new();
                sources(doc.container.upcast_ref(), &mut all);
                let Some(source) = all.iter().find(|v| v.is_mapped()).cloned() else {
                    return glib::ControlFlow::Continue;
                };
                *view.borrow_mut() = Some(source.clone());
                if kind.starts_with("scroll-") || kind == "stale-scroll-selection" {
                    source.set_wrap_mode(gtk::WrapMode::None);
                }
                if matches!(kind.as_str(), "stale-pane" | "scroll-pane2") {
                    if secondary.borrow().is_none() {
                        split(doc.container.upcast_ref()).unwrap().set_active(true);
                        *secondary.borrow_mut() = Some(all[1].clone());
                        pause.set(Instant::now());
                        return glib::ControlFlow::Continue;
                    }
                    if source.width() <= 0 || all[1].width() <= 0 {
                        return glib::ControlFlow::Continue;
                    }
                }
                let source = if kind == "scroll-pane2" {
                    all[1].clone()
                } else {
                    source
                };
                if kind == "scroll-pane2" {
                    *view.borrow_mut() = Some(source.clone());
                    *secondary.borrow_mut() = Some(all[0].clone());
                    source.set_wrap_mode(gtk::WrapMode::None);
                }
                if kind == "readonly" {
                    source.set_editable(false);
                }
                if kind == "history-reject" {
                    source_panes::buffer(&doc).begin_user_action();
                    source_panes::buffer(&doc)
                        .insert(&mut source_panes::buffer(&doc).end_iter(), "!");
                    source_panes::buffer(&doc).end_user_action();
                }
                provider(&source, payload.clone());
                let mut select = if kind == "total-valid" {
                    vec!["ctrl+a"]
                } else if kind == "stale-selection-aba" {
                    vec!["ctrl+Home", "Right"]
                } else {
                    vec![
                        "ctrl+Home",
                        "Right",
                        "shift+Right",
                        "shift+Right",
                        "shift+Right",
                    ]
                };
                if kind == "rect-context" {
                    select.push("ctrl+shift+Down");
                }
                select.push(if kind.ends_with("context") {
                    "shift+F10"
                } else if kind == "valid-shift" {
                    "shift+Insert"
                } else {
                    "ctrl+v"
                });
                crate::git_view::test_click(&source, &select);
                pause.set(Instant::now());
                phase.set(if kind.ends_with("context") { 1 } else { 2 });
            }
            1 => {
                let Some(paste) = label(ui.window.upcast_ref(), ui.lang.text("Einfügen", "Paste"))
                    .or_else(|| label(ui.window.upcast_ref(), "Paste"))
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(paste.is_mapped());
                if kind == "rect-context" {
                    assert!(doc.rectangles.borrow()[0].is_selected());
                }
                let shots =
                    std::path::PathBuf::from(std::env::var_os("FASTRA_TOOL_SCREENSHOTS").unwrap());
                std::fs::create_dir_all(&shots).unwrap();
                assert!(std::process::Command::new("import")
                    .args(["-window", "root"])
                    .arg(shots.join("native-context-menu.png"))
                    .status()
                    .unwrap()
                    .success());
                crate::git_view::test_click(&paste, &[]);
                phase.set(2);
            }
            2 => {
                if !matches!(kind.as_str(), "readonly" | "rect-context")
                    && linear_paste::test_counts().0 < 1
                {
                    return glib::ControlFlow::Continue;
                }
                let v = view.borrow().as_ref().unwrap().clone();
                match kind.as_str() {
                    "stale-selection" | "stale-scroll-selection" => source_panes::buffer(&doc)
                        .place_cursor(&source_panes::buffer(&doc).end_iter()),
                    "stale-selection-aba" => {
                        source_panes::buffer(&doc)
                            .place_cursor(&source_panes::buffer(&doc).end_iter());
                        source_panes::buffer(&doc)
                            .place_cursor(&source_panes::buffer(&doc).iter_at_offset(1));
                    }
                    "stale-meta" => {
                        crate::line_endings::select_for_test(
                            &doc,
                            fastra_core::encoding::LineEnding::Lf,
                        );
                    }
                    "stale-source" => {
                        source_panes::buffer(&doc).begin_user_action();
                        source_panes::buffer(&doc)
                            .insert(&mut source_panes::buffer(&doc).end_iter(), "!");
                        source_panes::buffer(&doc).end_user_action();
                    }
                    "stale-tab" => {
                        let index = ui.tabs.current_page();
                        ui.add_document("other-linear.txt", "OTHER");
                        ui.tabs.set_current_page(index);
                    }
                    "stale-pane" => {
                        assert!(secondary.borrow().as_ref().unwrap().is_mapped());
                        assert!(secondary.borrow().as_ref().unwrap().grab_focus());
                        assert!(v.grab_focus());
                    }
                    "stale-buffer" => {
                        let foreign = sourceview5::Buffer::new(None::<&gtk::TextTagTable>);
                        foreign.set_text("foreign");
                        source_panes::bind_view(&v, &foreign);
                        source_panes::bind_view(&v, &doc.buffer);
                    }
                    "stale-readonly" => {
                        v.set_editable(false);
                        v.set_editable(true);
                    }
                    "stale-clipboard" => provider(&v, b"REPLACED".to_vec()),
                    "stale-close" => {
                        if let Some(ticket) = close_protocol::prepare(
                            &ui,
                            Box::new(|result| {
                                if let Ok(permit) = result {
                                    permit.cancel();
                                }
                            }),
                        ) {
                            ticket.cancel();
                        }
                    }
                    "rapid" => {
                        provider(&v, b"NEW".to_vec());
                        keys(&v, &["ctrl+v"]);
                    }
                    _ => (),
                };
                phase.set(3);
            }
            3 => {
                let (started, ended) = linear_paste::test_counts();
                if kind == "rapid" && started < 2 {
                    return glib::ControlFlow::Continue;
                }
                if ended < started {
                    return glib::ControlFlow::Continue;
                }
                if kind.starts_with("scroll-") || kind == "stale-scroll-selection" {
                    let completed = receipt.get().unwrap_or_else(|| {
                        let now = Instant::now();
                        receipt.set(Some(now));
                        now
                    });
                    if completed.elapsed() < Duration::from_millis(700) {
                        return glib::ControlFlow::Continue;
                    }
                }
                let current = buffer_text(&source_panes::buffer(&doc));
                if kind == "rect-context" && current != expected {
                    return glib::ControlFlow::Continue;
                }
                if matches!(kind.as_str(), "stale-selection" | "stale-scroll-selection") {
                    assert_eq!(
                        (
                            source_panes::buffer(&doc).cursor_position(),
                            source_panes::buffer(&doc)
                                .iter_at_mark(&source_panes::buffer(&doc).selection_bound())
                                .offset()
                        ),
                        (
                            source_panes::buffer(&doc).char_count(),
                            source_panes::buffer(&doc).char_count()
                        )
                    );
                }
                if kind == "stale-selection-aba" {
                    assert_eq!(
                        (
                            source_panes::buffer(&doc).cursor_position(),
                            source_panes::buffer(&doc)
                                .iter_at_mark(&source_panes::buffer(&doc).selection_bound())
                                .offset()
                        ),
                        (1, 1)
                    );
                }
                if kind == "stale-tab" {
                    assert_eq!(
                        buffer_text(&ui.documents.borrow().last().unwrap().buffer),
                        "OTHER"
                    );
                }
                if kind == "stale-close" {
                    assert!(!close_protocol::active(&ui));
                }
                if kind == "stale-meta" {
                    assert_eq!(
                        doc.line_endings.pending(),
                        Some(fastra_core::encoding::LineEnding::Lf)
                    );
                    assert!(source_panes::buffer(&doc).is_modified());
                }
                eprintln!(
                    "LINEAR case={kind} completed={started}/{ended} bytes={} exact={} modified={} undo={}",
                    current.len(),
                    current == expected,
                    source_panes::buffer(&doc).is_modified(),
                    source_panes::buffer(&doc).can_undo()
                );
                assert_eq!(
                    current.len(),
                    expected.len(),
                    "complete native paste result bytes"
                );
                assert!(
                    current == expected,
                    "complete native paste expected exact bytes"
                );
                if kind.starts_with("scroll-") && kind != "scroll-post-selection" {
                    let v = view.borrow().as_ref().unwrap().clone();
                    let caret = v.iter_location(
                        &source_panes::buffer(&doc)
                            .iter_at_mark(&source_panes::buffer(&doc).get_insert()),
                    );
                    let visible = v.visible_rect();
                    eprintln!(
                        "NATIVE PASTE CARET {caret:?} VISIBLE {visible:?} focused={}",
                        v.has_focus()
                    );
                    assert!(
                        caret.x() >= visible.x()
                            && caret.x() + caret.width() <= visible.x() + visible.width(),
                        "completed paste caret horizontally visible"
                    );
                    if kind == "scroll-pane2" {
                        assert_eq!(
                            secondary.borrow().as_ref().unwrap().visible_rect().y(),
                            0,
                            "successful pane2 paste must not scroll pane1"
                        );
                    }
                    assert!(
                        caret.y() >= visible.y()
                            && caret.y() + caret.height() <= visible.y() + visible.height(),
                        "completed normal paste leaves insertion caret visible"
                    );
                }
                if kind == "scroll-valid" {
                    let shots = std::path::PathBuf::from(
                        std::env::var_os("FASTRA_TOOL_SCREENSHOTS").unwrap(),
                    );
                    std::fs::create_dir_all(&shots).unwrap();
                    assert!(std::process::Command::new("import")
                        .args(["-window", "root"])
                        .arg(shots.join("caret-after-paste.png"))
                        .status()
                        .unwrap()
                        .success());
                }
                if kind == "scroll-post-selection" {
                    let v = view.borrow().as_ref().unwrap().clone();
                    let caret = v.iter_location(
                        &source_panes::buffer(&doc)
                            .iter_at_mark(&source_panes::buffer(&doc).get_insert()),
                    );
                    eprintln!(
                        "SUPERSEDED SCROLL CARET {caret:?} VISIBLE {:?}",
                        v.visible_rect()
                    );
                    assert_eq!(source_panes::buffer(&doc).cursor_position(), 2000);
                    assert!(caret.y() > v.visible_rect().height());
                    assert_eq!(
                        v.visible_rect().y(),
                        0,
                        "new selection after accepted paste cancels deferred scroll"
                    );
                }
                if kind == "stale-scroll-selection" {
                    let v = view.borrow().as_ref().unwrap().clone();
                    let caret = v.iter_location(
                        &source_panes::buffer(&doc)
                            .iter_at_mark(&source_panes::buffer(&doc).get_insert()),
                    );
                    eprintln!(
                        "CANCELLED PASTE CARET {caret:?} VISIBLE {:?}",
                        v.visible_rect()
                    );
                    assert!(caret.y() > v.visible_rect().height());
                    assert_eq!(
                        v.visible_rect().y(),
                        0,
                        "cancelled paste must not scroll to a newer selection"
                    );
                }
                if positive || kind == "history-reject" {
                    assert!(source_panes::buffer(&doc).can_undo());
                    keys(view.borrow().as_ref().unwrap(), &["ctrl+z"]);
                    phase.set(4);
                } else {
                    if kind == "stale-source" {
                        assert!(source_panes::buffer(&doc).can_undo());
                        source_panes::buffer(&doc).undo();
                        assert_eq!(buffer_text(&source_panes::buffer(&doc)), original);
                    }
                    assert!(
                        !source_panes::buffer(&doc).can_undo(),
                        "rejection/stale completion adds no Undo"
                    );
                    if !kind.starts_with("stale-") && kind != "readonly" {
                        assert!(!source_panes::buffer(&doc).is_modified());
                        assert_eq!(
                            (
                                source_panes::buffer(&doc).cursor_position(),
                                source_panes::buffer(&doc)
                                    .iter_at_mark(&source_panes::buffer(&doc).selection_bound())
                                    .offset()
                            ),
                            (4, 1),
                            "reject preserves selected caret direction"
                        );
                    }
                    println!(
                        "PASS actual normal paste {kind}: complete result checked before first mutation; source/Undo/selection guards retained"
                    );
                    std::process::exit(0);
                }
            }
            4 => {
                if buffer_text(&source_panes::buffer(&doc)) != original {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    !source_panes::buffer(&doc).can_undo(),
                    "one complete Paste owns exactly one Undo action"
                );
                keys(view.borrow().as_ref().unwrap(), &["ctrl+shift+z"]);
                phase.set(5);
            }
            5 => {
                if buffer_text(&source_panes::buffer(&doc)) != expected {
                    return glib::ControlFlow::Continue;
                }
                assert!(!source_panes::buffer(&doc).can_redo());
                println!(
                    "PASS actual normal paste {kind}: exact Unicode/CRLF bytes, native one Undo/Redo, visible menu when requested"
                );
                std::process::exit(0);
            }
            _ => unreachable!(),
        };
        glib::ControlFlow::Continue
    });
}
