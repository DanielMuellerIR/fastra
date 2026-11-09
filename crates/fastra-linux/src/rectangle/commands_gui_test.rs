use super::*;
use crate::{
    buffer_text,
    rectangle_selftest::{input, source_view},
    Ui,
};
use std::time::{Duration, Instant};
fn read(view: &sourceview5::View, reply: &Rc<RefCell<Option<String>>>) {
    let clipboard = view.clipboard();
    let reply = reply.clone();
    glib::MainContext::default().spawn_local(async move {
        let value = clipboard
            .read_text_future()
            .await
            .unwrap()
            .unwrap()
            .to_string();
        assert!(!clipboard.formats().contain_mime_type("text/html"));
        assert!(!clipboard.formats().contain_mime_type("text/rtf"));
        *reply.borrow_mut() = Some(value);
    });
}
fn label(widget: &gtk::Widget, text: &str) -> Option<gtk::Widget> {
    if widget.is_mapped()
        && widget
            .downcast_ref::<gtk::Label>()
            .is_some_and(|label| label.text() == text)
    {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(found) = label(&widget, text) {
            return Some(found);
        }
        child = widget.next_sibling();
    }
    None
}
fn reset(doc: &crate::Document, text: &str) {
    doc.buffer.set_enable_undo(false);
    doc.buffer.set_text(text);
    doc.buffer.set_enable_undo(true);
    doc.buffer.set_modified(false);
    *doc.original.borrow_mut() = text.to_owned();
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let ending = match std::env::var("FASTRA_RECTANGLE_COMMAND_EOL").as_deref() {
        Ok("crlf") => "\r\n",
        Ok("cr") => "\r",
        _ => "\n",
    };
    let copied_first = if std::env::var_os("FASTRA_RECTANGLE_COMMAND_UNICODE").is_some() {
        "C🙂"
    } else {
        "CD"
    };
    let tail = if std::env::var_os("FASTRA_RECTANGLE_COMMAND_WRAP").is_some() {
        " long wrapped words".repeat(150)
    } else {
        String::new()
    };
    let first = format!("ab{copied_first}ef{tail}");
    let source = [first.as_str(), "abXYef", "ab12ef"].join(ending);
    let expected = [copied_first, "XY", "12", ""].join(ending);
    let cut_first = format!("abef{tail}");
    let cut_source = [cut_first.as_str(), "abef", "abef"].join(ending);
    let title = format!("Fastra Rectangle Commands {}", std::process::id());
    ui.window.set_title(Some(&title));
    crate::git_view::test_size(ui.window.upcast_ref());
    ui.add_document("rectangle-commands.txt", &source);
    let doc = ui.active().unwrap();
    doc.buffer.set_modified(false);
    let revision = doc.revision.get();
    let view = source_view(doc.container.upcast_ref()).unwrap();
    view.set_tab_width(4);
    view.set_insert_spaces_instead_of_tabs(true);
    let rect = doc.rectangles.borrow()[0].clone();
    let reply = Rc::new(RefCell::new(None));
    let padded_base = ["abcdef", "ab", "abc"].join(ending);
    let mismatch_base = ["aBc", "xYz", "mNo", "TAIL"].join(ending);
    let short_base = ["abCD", "x", "ab12"].join(ending);
    let foreign = Rc::new(RefCell::new(None::<gtk::Window>));
    let pending = Rc::new(RefCell::new(None::<clipboard::Request>));
    let foreign_result = Rc::new(Cell::new(None::<bool>));
    let stage = Cell::new(0);
    let started = Instant::now();
    let changed = Cell::new(Instant::now());
    glib::timeout_add_local(Duration::from_millis(100), move || {
        assert!(
            started.elapsed() < Duration::from_secs(75),
            "rectangle commands stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        if changed.get().elapsed() < Duration::from_millis(450) {
            return glib::ControlFlow::Continue;
        }
        let key = |value: &str| input(title.clone(), vec!["key".into(), value.into()]);
        match stage.get() {
            0 => {
                view.grab_focus();
                let a = doc.buffer.iter_at_line_offset(0, 2).unwrap();
                let b = doc.buffer.iter_at_line_offset(0, 4).unwrap();
                doc.buffer.select_range(&a, &b);
            }
            1 => {
                assert!(view.has_focus());
                if !tail.is_empty() {
                    let top = view.iter_location(&doc.buffer.start_iter());
                    let wrapped =
                        view.iter_location(&doc.buffer.iter_at_line_offset(0, 200).unwrap());
                    assert!(
                        wrapped.y() > top.y(),
                        "long logical line must really soft-wrap"
                    );
                }
                key("ctrl+shift+Down");
            }
            2 => {
                assert_eq!(rect.marks.borrow().len(), 2);
                key("ctrl+shift+Down");
            }
            3 => {
                assert_eq!(rect.marks.borrow().len(), 3);
                let old = gtk::gdk::ContentProvider::new_union(&[
                    gtk::gdk::ContentProvider::for_value(&"old".to_value()),
                    gtk::gdk::ContentProvider::for_bytes(
                        "text/html",
                        &glib::Bytes::from_static(b"<b>old</b>"),
                    ),
                    gtk::gdk::ContentProvider::for_bytes(
                        "text/rtf",
                        &glib::Bytes::from_static(br"{\rtf1 old}"),
                    ),
                ]);
                view.clipboard().set_content(Some(&old)).unwrap();
                key("ctrl+c");
            }
            4 => {
                assert_eq!(buffer_text(&doc.buffer), source);
                assert_eq!(doc.revision.get(), revision);
                assert!(!doc.buffer.is_modified());
                read(&view, &reply);
            }
            5 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value, expected);
                assert!(rect.is_selected());
                key("ctrl+x");
            }
            6 => {
                assert_eq!(buffer_text(&doc.buffer), cut_source);
                read(&view, &reply);
            }
            7 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value, expected);
                key("ctrl+z");
            }
            8 => {
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                let a = doc.buffer.iter_at_line_offset(0, 2).unwrap();
                let b = doc.buffer.iter_at_line_offset(0, 4).unwrap();
                doc.buffer.select_range(&a, &b);
                key("ctrl+shift+Down");
            }
            9 => {
                assert_eq!(rect.marks.borrow().len(), 2);
                key("ctrl+shift+Down");
            }
            10 => {
                assert_eq!(rect.marks.borrow().len(), 3);
                key("ctrl+shift+Up");
            }
            11 => {
                assert_eq!(rect.marks.borrow().len(), 2);
                key("ctrl+shift+Up");
            }
            12 => {
                assert_eq!(rect.marks.borrow().len(), 1);
                key("ctrl+c");
            }
            13 => {
                read(&view, &reply);
            }
            14 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value, copied_first);
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                reset(&doc, &padded_base);
                rect.select((0, 4), (2, 5));
                view.grab_focus();
                view.clipboard().set_text(&["X", "Y", "Z", ""].join(ending));
                key("ctrl+v");
            }
            15 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["abcdXf", "abY", "abcZ"].join(ending),
                    "normal rectangle paste does not pad short rows"
                );
                key("ctrl+z");
            }
            16 => {
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                assert!(!doc.buffer.can_undo());
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text(&["X", "Y", "Z", ""].join(ending));
                crate::git_view::test_click(
                    &crate::rectangle_selftest::document_menu(&ui, &doc),
                    &[],
                );
                stage.set(160);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            160 => {
                input(
                    title.clone(),
                    vec!["snapshot:rectangle-document-menu".into()],
                );
                stage.set(161);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            161 => {
                let button = label(
                    doc.container.upcast_ref(),
                    ui.lang.text("Spaltenpaste", "Column paste"),
                )
                .unwrap();
                crate::git_view::test_click(&button, &[]);
                stage.set(17);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            17 => {
                assert!(
                    !crate::rectangle_selftest::document_menu(&ui, &doc)
                        .popover()
                        .unwrap()
                        .is_visible(),
                    "Column paste must dismiss its command popover"
                );
                assert!(
                    view.has_focus(),
                    "Column paste must return keyboard input to the source: active={} status={} text={:?}", ui.window.is_active(), ui.status.text(), buffer_text(&doc.buffer)
                );
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["abcdXf", "ab  Y", "abc Z"].join(ending),
                    "visible column paste pads short rows"
                );
                input(
                    title.clone(),
                    vec![
                        "snapshot:rectangle-column-pasted".into(),
                        "key".into(),
                        "ctrl+z".into(),
                    ],
                );
            }
            18 => {
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                assert!(!doc.buffer.can_undo());
                rect.select((0, 4), (2, 5));
                view.grab_focus();
                view.clipboard().set_text("Q");
                key("ctrl+v");
            }
            19 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["abcdQf", "abQ", "abcQ"].join(ending)
                );
                key("ctrl+z");
            }
            20 => {
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                reset(&doc, &mismatch_base);
                rect.select((0, 1), (2, 2));
                view.grab_focus();
                view.clipboard().set_text(&["P", "Q", ""].join(ending));
                key("ctrl+v");
            }
            21 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["aPc", "xQz", "mo", "TAIL"].join(ending),
                    "missing clipboard rows clear only selected characters"
                );
                key("ctrl+z");
            }
            22 => {
                assert_eq!(buffer_text(&doc.buffer), mismatch_base);
                assert!(!doc.buffer.can_undo());
                rect.select((0, 1), (1, 2));
                view.grab_focus();
                view.clipboard()
                    .set_text(&["P", "Q", "R", "S", "T"].join(ending));
                key("ctrl+v");
            }
            23 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["aPc", "xQz", "mRNo", "TSAIL", " T"].join(ending),
                    "extra clipboard rows continue in following lines and beyond EOF"
                );
                key("ctrl+z");
            }
            24 => {
                assert_eq!(buffer_text(&doc.buffer), mismatch_base);
                assert!(!doc.buffer.can_undo());
                assert!(!rect.is_selected());
                doc.buffer
                    .place_cursor(&doc.buffer.iter_at_line_offset(0, 1).unwrap());
                view.clipboard()
                    .set_text(&["I", "J", "K", "L", "M"].join(ending));
                crate::git_view::test_click(
                    &crate::rectangle_selftest::document_menu(&ui, &doc),
                    &[],
                );
                stage.set(240);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            240 => {
                let button = label(
                    doc.container.upcast_ref(),
                    ui.lang.text("Spaltenpaste", "Column paste"),
                )
                .unwrap();
                crate::git_view::test_click(&button, &[]);
                stage.set(25);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            25 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["aIBc", "xJYz", "mKNo", "TLAIL", " M"].join(ending),
                    "column paste works from the native caret without an existing rectangle"
                );
                key("ctrl+z");
            }
            26 => {
                assert_eq!(buffer_text(&doc.buffer), mismatch_base);
                assert!(!doc.buffer.can_undo());
                reset(&doc, &short_base);
                rect.select((0, 2), (2, 4));
                view.grab_focus();
                key("ctrl+x");
            }
            27 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["ab", "x", "ab"].join(ending),
                    "cut leaves unselected short-row character intact"
                );
                read(&view, &reply);
            }
            28 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value, ["CD", "", "12", ""].join(ending));
                view.grab_focus();
                key("ctrl+v");
            }
            29 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    short_base,
                    "copy final separator and internal empty row survive native paste"
                );
                key("ctrl+z");
            }
            30 => {
                assert_eq!(buffer_text(&doc.buffer), ["ab", "x", "ab"].join(ending));
                key("ctrl+z");
            }
            31 => {
                assert_eq!(buffer_text(&doc.buffer), short_base);
                assert!(!doc.buffer.can_undo());
                reset(&doc, &padded_base);
                view.set_tab_width(4);
                view.set_insert_spaces_instead_of_tabs(false);
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text(&["X", "Y", "Z"].join(ending));
                crate::git_view::test_click(
                    &crate::rectangle_selftest::document_menu(&ui, &doc),
                    &[],
                );
                stage.set(310);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            310 => {
                let button = label(
                    doc.container.upcast_ref(),
                    ui.lang.text("Spaltenpaste", "Column paste"),
                )
                .unwrap();
                crate::git_view::test_click(&button, &[]);
                stage.set(32);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            32 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["abcdXf", "ab\tY", "abc\tZ"].join(ending),
                    "column padding follows active tabs profile"
                );
                key("ctrl+z");
            }
            33 => {
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                assert!(!doc.buffer.can_undo());
                view.set_insert_spaces_instead_of_tabs(true);
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text("stale");
                rect.paste_mode(false);
                rect.clear();
            }
            34 => {
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                assert!(!doc.buffer.can_undo());
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text("old request");
                rect.paste_mode(false);
                view.clipboard().set_text("new owner");
            }
            35 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    padded_base,
                    "clipboard owner change before first async poll must invalidate request"
                );
                assert!(!doc.buffer.can_undo());
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text("late source");
                rect.paste_mode(false);
                doc.buffer.begin_user_action();
                let mut end = doc.buffer.end_iter();
                doc.buffer.insert(&mut end, "!");
                doc.buffer.end_user_action();
            }
            36 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["abcd!f", "ab!", "abc!"].join(ending),
                    "late clipboard must not overwrite changed source"
                );
                key("ctrl+z");
            }
            37 => {
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                assert!(!doc.buffer.can_undo());
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text("late tab");
                rect.paste_mode(false);
                ui.add_document("other.txt", "other");
            }
            38 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    padded_base,
                    "late clipboard must not edit inactive source"
                );
                assert!(!doc.buffer.can_undo());
                let index = ui
                    .documents
                    .borrow()
                    .iter()
                    .position(|item| Rc::ptr_eq(item, &doc))
                    .unwrap();
                ui.tabs.set_current_page(Some(index as u32));
            }
            39 => {
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                reset(&doc, &source);
                rect.select((0, 2), (2, 4));
                view.grab_focus();
                let menu = crate::rectangle_selftest::menu_button(
                    ui.window.upcast_ref(),
                    ui.lang.text("Fastra-Menü", "Fastra menu"),
                )
                .unwrap();
                crate::git_view::test_click(&menu, &[]);
                stage.set(390);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            390 => {
                let menu =
                    crate::rectangle_selftest::menu_button(ui.window.upcast_ref(), "Text").unwrap();
                crate::git_view::test_click(&menu, &[]);
                stage.set(40);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            40 => {
                let button = label(
                    ui.window.upcast_ref(),
                    ui.lang.text("Rechteckauswahl", "Rectangle selection"),
                )
                .unwrap();
                crate::git_view::test_click(&button, &[]);
            }
            41 => {
                input(
                    title.clone(),
                    vec![
                        "snapshot:rectangle-text-menu".into(),
                        "key".into(),
                        "Shift_L".into(),
                    ],
                );
            }
            42 => {
                let button = label(
                    ui.window.upcast_ref(),
                    ui.lang.text("Rechteck kopieren", "Copy rectangle"),
                )
                .unwrap();
                crate::git_view::test_click(&button, &[]);
            }
            43 => {
                read(&view, &reply);
            }
            44 => {
                let Some(value) = reply.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value, expected);
                assert_eq!(buffer_text(&doc.buffer), source);
                assert!(!doc.buffer.can_undo());
                reset(&doc, &padded_base);
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text(&["X", "Y", "Z"].join(ending));
                rect.paste_mode(true);
                rect.paste_mode(false);
            }
            45 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["abcdXf", "abY", "abcZ"].join(ending),
                    "newest paste mode must win even before either request polls"
                );
                reset(&doc, "a");
                rect.select((0, 1), (0, 1));
                for value in [
                    "x".repeat(65536),
                    "x".repeat(65537),
                    "é".repeat(32768),
                    "x\n".repeat(2002),
                    "x".repeat(4 * 1024 * 1024 + 1),
                    "visible\0hidden".into(),
                ] {
                    let revision = doc.revision.get();
                    assert!(matches!(
                        rect.apply_clipboard(&value, false),
                        Err(Error::Limit)
                    ));
                    assert_eq!(buffer_text(&doc.buffer), "a");
                    assert_eq!(doc.revision.get(), revision);
                    assert!(!doc.buffer.can_undo());
                }
                assert!(rect.apply_clipboard(&"x".repeat(65535), false).is_ok());
                assert_eq!(buffer_text(&doc.buffer).len(), 65536);
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), "a");
                assert!(!doc.buffer.can_undo());
                reset(&doc, &padded_base);
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text("deferred selection");
                rect.paste();
                rect.clear();
            }
            46 => {
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                assert!(!doc.buffer.can_undo());
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text("deferred clipboard");
                rect.paste();
                view.clipboard().set_text("new clipboard owner");
            }
            47 => {
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                assert!(!doc.buffer.can_undo());
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text(&["X", "Y", "Z"].join(ending));
                rect.paste();
                rect.paste_mode(false);
            }
            48 => {
                assert_eq!(
                    buffer_text(&doc.buffer),
                    ["abcdXf", "abY", "abcZ"].join(ending)
                );
                reset(&doc, &padded_base);
                rect.select((0, 4), (2, 5));
                view.clipboard().set_text("foreign window");
                *pending.borrow_mut() =
                    Some(clipboard::Request::new(view.clipboard(), view.clone()));
                let window = gtk::Window::builder()
                    .application(&ui.window.application().unwrap())
                    .title("Rectangle focus guard")
                    .default_width(320)
                    .default_height(180)
                    .child(&gtk::Label::new(Some("Foreign window")))
                    .build();
                window.present();
                *foreign.borrow_mut() = Some(window);
                stage.set(480);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            480 => {
                crate::git_view::test_click(foreign.borrow().as_ref().unwrap(), &[]);
                stage.set(49);
                changed.set(Instant::now());
                return glib::ControlFlow::Continue;
            }
            49 => {
                assert!(foreign.borrow().as_ref().unwrap().is_active());
                assert!(!ui.window.is_active());
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                rect.paste();
                let request = pending.borrow_mut().take().unwrap();
                let result = foreign_result.clone();
                glib::MainContext::default().spawn_local(async move {
                    result.set(Some(request.read().await.is_ok()));
                });
            }
            50 => {
                assert!(foreign.borrow().as_ref().unwrap().is_active());
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                assert!(!doc.buffer.can_undo());
                crate::git_view::test_click(&ui.window, &[]);
            }
            51 => {
                assert!(ui.window.is_active());
                assert_eq!(
                    foreign_result.get(),
                    Some(false),
                    "real window loss cancels pending clipboard read"
                );
                assert_eq!(buffer_text(&doc.buffer), padded_base);
                assert!(!doc.buffer.can_undo());
                foreign.borrow_mut().take().unwrap().close();
                println!("PASS rectangle native keyboard and actual Text submenu; Copy/Cut exact EOL+Unicode+empty rows/plain MIME/one Undo; logical extension and shrink under real soft wrap; normal versus profile-padded column paste, menu dismissal and source focus, one/under/oversupplied rows and native caret/EOF, complete Cut/Paste/two Undo; stale cursor/clipboard-before-poll/source/tab and deferred selection/clipboard rejected; latest request wins across deferral; actual foreign-window focus cancels deferred paste and pending read without text or Undo; exact 64KiB/Unicode/NUL/row/total budgets preflight without mutation");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        changed.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
