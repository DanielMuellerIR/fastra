use super::*;
fn click(widget: &gtk::Widget, label: &str) -> bool {
    if let Some(button) = widget.downcast_ref::<gtk::Button>() {
        if button.label().as_deref() == Some(label) {
            button.emit_clicked();
            return true;
        }
    }
    let mut child = widget.first_child();
    while let Some(item) = child {
        if click(&item, label) {
            return true;
        }
        child = item.next_sibling();
    }
    false
}
pub(crate) fn start(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_SOURCE_SYNC_SELFTEST").is_some() {
        source_sync(ui);
        return;
    }
    if std::env::var_os("FASTRA_OUTLINE_FALLBACK_SELFTEST").is_some() {
        fallback(ui);
        return;
    }
    popup_test(ui);
}
fn widgets<T: IsA<gtk::Widget> + glib::object::ObjectType>(root: &gtk::Widget) -> Vec<T> {
    let mut out = root
        .clone()
        .downcast::<T>()
        .ok()
        .into_iter()
        .collect::<Vec<_>>();
    for child in chrome::children(root) {
        out.extend(widgets::<T>(&child));
    }
    out
}
fn row(view: &View, title: &str) -> gtk::Widget {
    let text = widgets::<gtk::Label>(view.popup.upcast_ref())
        .into_iter()
        .find(|l| l.is_mapped() && l.text() == title)
        .unwrap();
    let mut row = text.upcast::<gtk::Widget>();
    while !row.has_css_class("document-outline-row") {
        row = row.parent().unwrap();
    }
    row
}
fn popup_test(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let source=format!("🙂\r\n# First &amp; **bold**\r\n\r\n{}\r\n## Second `code`\r\n\r\n{}\r\n# First &amp; **bold**\r\n", "paragraph\r\n\r\n".repeat(30),"tail\r\n\r\n".repeat(30));
    ui.add_document("outline.md", &source);
    let doc = ui.active().unwrap();
    doc.buffer.place_cursor(&doc.buffer.start_iter());
    git_view::test_size(ui.window.upcast_ref());
    let phase = Cell::new(0);
    let began = std::time::Instant::now();
    let pause = Cell::new(None::<std::time::Instant>);
    let capture = RefCell::new(None);
    let four_d = RefCell::new(None::<Rc<Document>>);
    let refused_at = Cell::new(0);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            began.elapsed() < Duration::from_secs(40),
            "outline phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        let view = doc.outline.borrow().clone().unwrap();
        match phase.get() {
            0 => {
                if !view.root.is_mapped() || !view.ready.get() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(view.headings.borrow().len(), 3);
                assert!(!view.back.is_sensitive() && !view.forward.is_sensitive());
                git_view::test_click(&view.menu, &[]);
                pause.set(Some(std::time::Instant::now()));
            }
            1 => {
                if pause.get().unwrap().elapsed() < Duration::from_millis(160)
                    || !view.popup.is_visible()
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(widgets::<gtk::Entry>(view.popup.upcast_ref()).is_empty());
                assert_eq!(view.popup.child().unwrap().width() + 28, 320);
                if !git_view::try_capture_x11(&view.popup, "outline-markdown-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&row(&view, "Second code"), &[]);
            }
            2 => {
                if view.popup.is_visible()
                    || doc.buffer.cursor_position() != view.headings.borrow()[1].offset
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(view.back.is_sensitive());
                let mut start = doc.buffer.start_iter();
                doc.buffer.begin_user_action();
                doc.buffer.insert(&mut start, "prefix\r\n");
                doc.buffer.end_user_action();
            }
            3 => {
                if !view.ready.get() || view.revision.get() != doc.revision.get() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&view.back, &[]);
            }
            4 => {
                if doc.buffer.cursor_position() != 8 || !view.forward.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!view.back.is_sensitive());
                git_view::test_click(&view.forward, &[]);
            }
            5 => {
                if doc.buffer.cursor_position() != view.headings.borrow()[1].offset
                    || view.forward.is_sensitive()
                {
                    return glib::ControlFlow::Continue;
                }
                ui.add_document("outline.4dm","// Function fake()\r\nexposed Function get title()\r\nFunction set title($value)\r\nBegin SQL\r\nFunction hidden()\r\nEnd SQL\r\nFunction query books()\r\nshared Class constructor()\r\n");
                let next = ui.active().unwrap();
                next.buffer.place_cursor(&next.buffer.start_iter());
                *four_d.borrow_mut() = Some(next);
            }
            6 => {
                let next = four_d.borrow().clone().unwrap();
                let v = next.outline.borrow().clone().unwrap();
                if !v.ready.get() || !v.root.is_mapped() || v.menu.width() <= 0 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(v.headings.borrow().len(), 4);
                assert_eq!(language(&next), "fastra-4d");
                if !git_view::try_capture_x11(&ui.window, "outline-four-d-owner-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&v.menu, &[]);
                pause.set(Some(std::time::Instant::now()));
            }
            7 => {
                let next = four_d.borrow().clone().unwrap();
                let v = next.outline.borrow().clone().unwrap();
                if pause.get().unwrap().elapsed() < Duration::from_millis(160)
                    || !v.popup.is_visible()
                {
                    return glib::ControlFlow::Continue;
                }
                if !git_view::try_capture_x11(&v.popup, "outline-four-d-native", &capture) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&row(&v, "get title"), &[]);
            }
            8 => {
                let next = four_d.borrow().clone().unwrap();
                let v = next.outline.borrow().clone().unwrap();
                if v.popup.is_visible() || next.buffer.selection_bounds().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let (a, b) = next.buffer.selection_bounds().unwrap();
                assert_eq!(next.buffer.text(&a, &b, true), "exposed Function get title");
                git_view::test_click(&v.back, &[]);
            }
            9 => {
                let next = four_d.borrow().clone().unwrap();
                if next.buffer.cursor_position() != 0 || next.buffer.selection_bounds().is_some() {
                    return glib::ControlFlow::Continue;
                }
                let v = next.outline.borrow().clone().unwrap();
                git_view::test_click(&v.back, &[]);
            }
            10 => {
                if !ui.active().is_some_and(|d| Rc::ptr_eq(&d, &doc))
                    || doc.buffer.cursor_position() != 8
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(!view.back.is_sensitive());
                let next = four_d.borrow().clone().unwrap();
                tab_close::request(&ui, &next);
            }
            11 => {
                let next = four_d.borrow().clone().unwrap();
                if ui.documents.borrow().iter().any(|d| Rc::ptr_eq(d, &next)) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&view.forward, &[]);
                pause.set(Some(std::time::Instant::now()));
            }
            12 => {
                if pause.get().unwrap().elapsed() < Duration::from_millis(200) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(doc.buffer.cursor_position(), 8);
                assert!(!view.back.is_sensitive() && view.forward.is_sensitive());
                assert_eq!(
                    ui.status.text(),
                    ui.lang.text(
                        "Das Dokument im Sprungverlauf wurde geschlossen oder ersetzt.",
                        "The document in the jump history was closed or replaced."
                    )
                );
                git_view::test_click(&view.menu, &[]);
                pause.set(Some(std::time::Instant::now()));
            }
            13 => {
                if pause.get().unwrap().elapsed() < Duration::from_millis(160)
                    || !view.popup.is_visible()
                {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&row(&view, "Second code"), &[]);
            }
            14 => {
                if view.popup.is_visible() || !view.back.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&view.back, &[]);
            }
            15 => {
                if view.back.is_sensitive() || !view.forward.is_sensitive() {
                    return glib::ControlFlow::Continue;
                }
                doc.buffer.begin_user_action();
                doc.buffer
                    .insert(&mut doc.buffer.end_iter(), "\r\n## Second `code`\r\n");
                doc.buffer.end_user_action();
                refused_at.set(doc.buffer.cursor_position());
            }
            16 => {
                if !view.ready.get() || view.headings.borrow().len() != 4 {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&view.forward, &[]);
                pause.set(Some(std::time::Instant::now()));
            }
            17 => {
                if pause.get().unwrap().elapsed() < Duration::from_millis(240) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(doc.buffer.cursor_position(), refused_at.get());
                assert!(!view.back.is_sensitive() && view.forward.is_sensitive());
                assert_eq!(
                    ui.status.text(),
                    ui.lang.text(
                        "Das Ziel im Sprungverlauf wurde geändert oder ist nicht mehr eindeutig.",
                        "The jump history destination changed or is no longer unique."
                    )
                );
                doc.buffer.undo();
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), source);
                println!("PASS native document outline: compact Markdown/4D popup, auto revision refresh, actual heading clicks, selected declaration, current caret, context history after edits, cross-document back, closed-document and ambiguous-heading refusal, branch pruning, navigation adds no Undo or file writes");
                git_view::finish(ui.window.clone().upcast(), ui.clone(), "outline");
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        eprintln!("outline phase{} complete", phase.get());
        phase.set(phase.get() + 1);
        glib::ControlFlow::Continue
    });
}
fn fallback(ui: Rc<Ui>) {
    ui.add_document("Method.4dm", "// no definitions\r\n");
    let doc = ui.active().unwrap();
    doc.buffer.place_cursor(&doc.buffer.start_iter());
    git_view::test_size(ui.window.upcast_ref());
    let phase = Cell::new(0);
    let start = std::time::Instant::now();
    let pause = Cell::new(None::<std::time::Instant>);
    let capture = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            start.elapsed() < Duration::from_secs(15),
            "outline fallback phase{}",
            phase.get()
        );
        let view = doc.outline.borrow().clone().unwrap();
        match phase.get() {
            0 => {
                if !view.ready.get() || !view.root.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(view.headings.borrow().len(), 1);
                assert_eq!(view.headings.borrow()[0].kind, Kind::Method);
                git_view::test_click(&view.menu, &[]);
                pause.set(Some(std::time::Instant::now()));
            }
            1 => {
                if pause.get().unwrap().elapsed() < Duration::from_millis(160)
                    || !view.popup.is_visible()
                {
                    return glib::ControlFlow::Continue;
                }
                if !git_view::try_capture_x11(
                    &view.popup,
                    "outline-method-fallback-native",
                    &capture,
                ) {
                    return glib::ControlFlow::Continue;
                }
                git_view::test_click(&row(&view, "Method.4dm"), &[]);
            }
            2 => {
                if view.popup.is_visible() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!view.back.is_sensitive() && !view.forward.is_sensitive());
                assert!(!doc.buffer.can_undo());
                assert_eq!(buffer_text(&doc.buffer), "// no definitions\r\n");
                ui.add_document("plain.txt", "ordinary text");
            }
            3 => {
                let plain = ui.active().unwrap();
                assert!(!plain.outline.borrow().as_ref().unwrap().root.is_visible());
                println!("PASS native outline fallback: current method/file symbol and line1 without definitions; same-place jump creates no back/forward; unsupported plain document hides controls without usable history; no source edits or Undo");
                git_view::finish(ui.window.clone().upcast(), ui.clone(), "outline-fallback");
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        glib::ControlFlow::Continue
    });
}
fn source_views(widget: &gtk::Widget, found: &mut Vec<sourceview5::View>) {
    if let Some(view) = widget.downcast_ref::<sourceview5::View>() {
        found.push(view.clone());
    }
    let mut next = widget.first_child();
    while let Some(child) = next {
        source_views(&child, found);
        next = child.next_sibling();
    }
}
fn native_click(ui: &Ui, widget: &gtk::Widget, x: f64, y: f64) {
    assert!(
        x >= 0. && y >= 0. && x < f64::from(widget.width()) && y < f64::from(widget.height()),
        "native click outside widget: {x},{y} in {}x{}",
        widget.width(),
        widget.height()
    );
    let point = widget
        .compute_point(&ui.window, &gtk::graphene::Point::new(x as f32, y as f32))
        .unwrap();
    let title = ui.window.title().unwrap().to_string();
    let x = (point.x() as i32).to_string();
    let y = (point.y() as i32).to_string();
    std::thread::spawn(move || {
        let output = std::process::Command::new("xdotool")
            .args(["search", "--onlyvisible", "--name", &format!("^{title}$")])
            .output()
            .unwrap();
        assert!(output.status.success());
        let windows = String::from_utf8(output.stdout).unwrap();
        let id = windows.lines().last().unwrap();
        assert!(
            std::process::Command::new("xdotool")
                .args([
                    "windowfocus",
                    id,
                    "mousemove",
                    "--window",
                    id,
                    &x,
                    &y,
                    "click",
                    "1"
                ])
                .status()
                .unwrap()
                .success()
        );
    });
}
fn native_drag(ui: &Ui, widget: &gtk::Widget, x: f64, y: f64) {
    let p = widget
        .compute_point(&ui.window, &gtk::graphene::Point::new(x as f32, y as f32))
        .unwrap();
    let title = ui.window.title().unwrap().to_string();
    std::thread::spawn(move || {
        let output = std::process::Command::new("xdotool")
            .args(["search", "--onlyvisible", "--name", &format!("^{title}$")])
            .output()
            .unwrap();
        let text = String::from_utf8(output.stdout).unwrap();
        let id = text.lines().last().unwrap();
        assert!(
            std::process::Command::new("xdotool")
                .args([
                    "windowfocus",
                    id,
                    "mousemove",
                    "--window",
                    id,
                    &(p.x() as i32).to_string(),
                    &(p.y() as i32).to_string(),
                    "mousedown",
                    "1",
                    "mousemove",
                    "--sync",
                    "--window",
                    id,
                    &(p.x() as i32 + 80).to_string(),
                    &(p.y() as i32).to_string(),
                    "mouseup",
                    "1"
                ])
                .status()
                .unwrap()
                .success()
        );
    });
}
fn check(widget: &gtk::Widget, label: &str) -> bool {
    if let Some(button) = widget.downcast_ref::<gtk::CheckButton>() {
        if button.label().as_deref() == Some(label) {
            button.set_active(true);
            return true;
        }
    }
    let mut next = widget.first_child();
    while let Some(child) = next {
        if check(&child, label) {
            return true;
        }
        next = child.next_sibling();
    }
    false
}
fn source_sync(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    git_view::test_size(ui.window.upcast_ref());
    let source = format!(
        "# Click sync\r\n\r\n雪🙂\r\n\r\nLine A\r\nLine B\r\nLine C\r\n\r\n[Anchor](#deep) and [Blocked](https://example.invalid)\r\n\r\n| A | B |\r\n| --- | --- |\r\n| cell A | CELL B |\r\n\r\n{}\r\n## Deep\r\n\r\nDEEP TARGET 雪🙂\r\n\r\n{}",
        "ordinary paragraph\r\n\r\n".repeat(90),
        "tail\r\n\r\n".repeat(70)
    );
    let fixture = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap())
        .join("source-click.md");
    std::fs::write(&fixture, source.as_bytes()).unwrap();
    ui.load_path(fixture.clone());
    let doc_slot = RefCell::new(None::<Rc<Document>>);
    let stage = Cell::new(0);
    let started = std::time::Instant::now();
    let entered = Cell::new(started);
    let answer = Rc::new(RefCell::new(None::<serde_json::Value>));
    let in_flight = Rc::new(Cell::new(false));
    let expected = RefCell::new(String::new());
    let original_revision = Cell::new(0);
    let stale_token = RefCell::new(String::new());
    let stale_epoch = RefCell::new(String::new());
    let caret = Cell::new(0);
    let current_token = RefCell::new(String::new());
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            started.elapsed() < Duration::from_secs(85),
            "source-sync stage {}: {}",
            stage.get(),
            ui.status.text()
        );
        if stage.get() == 0 {
            let Some(doc) = ui
                .active()
                .filter(|doc| doc.disk_path().as_ref() == Some(&fixture))
            else {
                return glib::ControlFlow::Continue;
            };
            *expected.borrow_mut() = buffer_text(&doc.buffer);
            assert_eq!(*expected.borrow(), source);
            original_revision.set(doc.revision.get());
            *doc_slot.borrow_mut() = Some(doc.clone());
            doc.markdown_toggle
                .borrow()
                .as_ref()
                .unwrap()
                .set_active(true);
            stage.set(1);
            return glib::ControlFlow::Continue;
        }
        let doc = doc_slot.borrow().as_ref().unwrap().clone();
        let preview = doc.markdown.borrow().as_ref().unwrap().clone();
        let mut views = Vec::new();
        source_views(doc.container.upcast_ref(), &mut views);
        let view = views[0].clone();
        let query = |code: &str| {
            if !in_flight.replace(true) {
                let slot = answer.clone();
                let flight = in_flight.clone();
                preview.inspect(code, move |value| {
                    *slot.borrow_mut() = Some(value);
                    flight.set(false);
                });
            }
        };
        let advance = |next| {
            println!("Source sync stage {next}");
            stage.set(next);
            entered.set(std::time::Instant::now());
        };
        match stage.get() {
            1 => {
                if let Some(value) = answer.borrow_mut().take() {
                    if value["ready"] == true && value["epoch"].as_str().is_some() {
                        assert_eq!(value["handlers"], serde_json::json!(["markdownCodeCopy","markdownPosition"]));
                        assert_eq!(value["blocked"], true);
                        *stale_token.borrow_mut() = value["token"].as_str().unwrap().to_owned();
                        *stale_epoch.borrow_mut() = value["epoch"].as_str().unwrap().to_owned();
                        native_click(
                            &ui,
                            preview.view.upcast_ref(),
                            value["x"].as_f64().unwrap(),
                            value["y"].as_f64().unwrap(),
                        );
                        advance(2);
                    }
                }
                if stage.get() == 1 {
                    query(
                        "const p=[...document.querySelectorAll('p')].find(p=>p.textContent.includes('Line C'));if(!p||!window.fastraPreviewReady)return JSON.stringify({ready:false});const node=p.firstChild;const r=document.createRange();const i=node.textContent.indexOf('Line C')+5;r.setStart(node,i);r.setEnd(node,i+1);const b=r.getBoundingClientRect();try{await fetch('https://example.invalid/fastra-position-csp')}catch{}await new Promise(resolve=>setTimeout(resolve,25));return JSON.stringify({blocked:fastraPreviewViolations.some(value=>value.blocked.startsWith('https:')),ready:true,x:b.x+b.width/2,y:b.y+b.height/2,token:document.documentElement.dataset.fastraRender,epoch:document.documentElement.dataset.fastraPositionEpoch,handlers:['markdownPosition','visualMarkdown','markdownCopy','markdownCodeCopy','apply','save','writeFile','execute'].filter(name=>typeof window.webkit?.messageHandlers?.[name]?.postMessage==='function').sort()});",
                    );
                }
            }
            2 if doc.buffer.iter_at_mark(&doc.buffer.get_insert()).line() == 6
                && view.has_focus() =>
            {
                println!(
                    "FASTRA_SOURCE_SYNC_EXCLUSION_OK actual-XTest-preview-click/three-line-paragraph/Unicode/CRLF/source-focus"
                );
                query(
                    "const td=[...document.querySelectorAll('td')].find(e=>e.textContent==='CELL B');td.scrollIntoView({block:'center'});const r=document.createRange();r.setStart(td.firstChild,0);r.setEnd(td.firstChild,1);const b=r.getBoundingClientRect();return JSON.stringify({x:b.x+b.width/2,y:b.y+b.height/2});",
                );
                advance(201);
            }
            201 => {
                if let Some(value) = answer.borrow_mut().take() {
                    native_click(
                        &ui,
                        preview.view.upcast_ref(),
                        value["x"].as_f64().unwrap(),
                        value["y"].as_f64().unwrap(),
                    );
                    advance(202);
                }
            }
            202 if doc.buffer.iter_at_mark(&doc.buffer.get_insert()).line() == 12
                && view.has_focus() =>
            {
                let offset = expected.borrow().find("DEEP TARGET").unwrap();
                let chars = expected.borrow()[..offset].chars().count();
                let mut at = doc.buffer.iter_at_offset(chars as i32);
                view.scroll_to_iter(&mut at, 0.1, true, 0., 0.5);
                preview.inspect("window.scrollTo(0,0);return JSON.stringify(true);", |_| {});
                advance(3);
            }
            3 if entered.get().elapsed() > Duration::from_millis(250) => {
                let offset = expected.borrow().find("DEEP TARGET").unwrap();
                let at = doc
                    .buffer
                    .iter_at_offset(expected.borrow()[..offset].chars().count() as i32);
                let rect = view.iter_location(&at);
                let (x, y) = view.buffer_to_window_coords(
                    gtk::TextWindowType::Widget,
                    rect.x() + 4,
                    rect.y() + rect.height() / 2,
                );
                native_click(&ui, view.upcast_ref(), f64::from(x), f64::from(y));
                advance(4);
            }
            4 => {
                if let Some(value) = answer.borrow_mut().take() {
                    if value["y"].as_f64().is_some_and(|n| n > 500.)
                        && value["top"]
                            .as_f64()
                            .is_some_and(|n| (0. ..600.).contains(&n))
                    {
                        if !git_view::try_capture(ui.window.upcast_ref(), "source-preview-clicks") {
                            return glib::ControlFlow::Continue;
                        }
                        caret.set(doc.buffer.cursor_position());
                        assert!(!doc.buffer.is_modified());
                        assert!(!doc.buffer.can_undo());
                        assert_eq!(doc.revision.get(), original_revision.get());
                        advance(5);
                    }
                }
                if stage.get() == 4 {
                    query(
                        "const p=[...document.querySelectorAll('p')].find(p=>p.textContent.includes('DEEP TARGET'));return JSON.stringify({y:scrollY,top:p.getBoundingClientRect().top});",
                    );
                }
            }
            5 => {
                // Auswahl und Links dürfen die Quellauswahl nicht überschreiben.
                let code = "const p=[...document.querySelectorAll('p')].find(p=>p.textContent.includes('Line C'));p.scrollIntoView();const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);const b=p.getBoundingClientRect();p.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:b.x+2,clientY:b.y+2}));getSelection().removeAllRanges();document.querySelector('.blocked-link').dispatchEvent(new MouseEvent('click',{bubbles:true}));return JSON.stringify(true);";
                query(code);
                advance(6);
            }
            6 if entered.get().elapsed() > Duration::from_millis(250) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                query(&format!(
                    "window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1}});return JSON.stringify(true);",
                    serde_json::json!("0".repeat(32))
                ));
                advance(7);
            }
            7 if entered.get().elapsed() > Duration::from_millis(200) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                // Gleiche Revision eines anderen Dokuments ist keine Owner-Bindung.
                ui.add_document("other-click.md", "# Other");
                query(&format!(
                    "window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1}});return JSON.stringify(true);",
                    serde_json::json!(stale_token.borrow().as_str())
                ));
                advance(8);
            }
            8 if entered.get().elapsed() > Duration::from_millis(200) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                assert_eq!(buffer_text(&ui.active().unwrap().buffer), "# Other");
                let index = ui
                    .documents
                    .borrow()
                    .iter()
                    .position(|item| Rc::ptr_eq(item, &doc))
                    .unwrap();
                ui.tabs.set_current_page(Some(index as u32));
                query(&format!(
                    "window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:{},line:1,column:1}});return JSON.stringify(true);",
                    serde_json::json!(stale_token.borrow().as_str()),
                    serde_json::json!(stale_epoch.borrow().as_str())
                ));
                advance(80);
            }
            80 if entered.get().elapsed() > Duration::from_millis(200) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                query(&format!(
                    "window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:document.documentElement.dataset.fastraPositionEpoch,line:7,column:1}});return JSON.stringify(true);",
                    serde_json::json!(stale_token.borrow().as_str())
                ));
                advance(81);
            }
            81 if entered.get().elapsed() > Duration::from_millis(200) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.iter_at_mark(&doc.buffer.get_insert()).line(), 6);
                caret.set(doc.buffer.cursor_position());
                doc.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(false);
                query(&format!(
                    "window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1}});return JSON.stringify(true);",
                    serde_json::json!(stale_token.borrow().as_str())
                ));
                advance(9);
            }
            9 if entered.get().elapsed() > Duration::from_millis(200) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                doc.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                advance(10);
            }
            10 => {
                if let Some(value) = answer.borrow_mut().take() {
                    if value["ready"] == true
                        && value["token"].as_str() != Some(stale_token.borrow().as_str())
                    {
                        *current_token.borrow_mut() = value["token"].as_str().unwrap().to_owned();
                        assert_ne!(value["token"].as_str(), Some(stale_token.borrow().as_str()));
                        query(&format!(
                            "window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1}});return JSON.stringify(true);",
                            serde_json::json!(stale_token.borrow().as_str())
                        ));
                        advance(11);
                    }
                }
                if stage.get() == 10 {
                    query(
                        "return JSON.stringify({ready:window.fastraPreviewReady===true,token:document.documentElement.dataset.fastraRender});",
                    );
                }
            }
            11 if entered.get().elapsed() > Duration::from_millis(200) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                assert_eq!(buffer_text(&doc.buffer), *expected.borrow());
                assert_eq!(std::fs::read(&fixture).unwrap(), source.as_bytes());
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                // Ein tatsächlich schreibgeschützter Abschnitt darf keine alte
                // Source-Navigation annehmen, selbst bei identischer Dokument-Rc.
                let section =
                    fastra_document::Document::open_hex(&fixture, &Cancellation::default())
                        .unwrap();
                *doc.section_view.borrow_mut() = Some(document_view::DocumentView::new(
                    section,
                    true,
                    ui.lang,
                    Rc::new(|| {}),
                ));
                assert!(doc.is_read_only());
                query(&format!(
                    "window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1}});return JSON.stringify(true);",
                    serde_json::json!(current_token.borrow().as_str())
                ));
                advance(12);
            }
            12 if entered.get().elapsed() > Duration::from_millis(200) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                doc.section_view.borrow_mut().take();
                doc.close_pending.set(true);
                query(&format!(
                    "window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1}});return JSON.stringify(true);",
                    serde_json::json!(current_token.borrow().as_str())
                ));
                advance(13);
            }
            13 if entered.get().elapsed() > Duration::from_millis(200) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                doc.close_pending.set(false);
                let held = doc.clone();
                preview.inspect(&format!("window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1}});return JSON.stringify(true);",serde_json::json!(current_token.borrow().as_str())),move|_|{let at=held.buffer.iter_at_line(2).unwrap();held.buffer.place_cursor(&at);});
                advance(14);
            }
            14 if entered.get().elapsed() > Duration::from_millis(250) => {
                assert_eq!(doc.buffer.iter_at_mark(&doc.buffer.get_insert()).line(), 2);
                caret.set(doc.buffer.cursor_position());
                let held = doc.clone();
                preview.inspect(&format!("window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1}});return JSON.stringify(true);",serde_json::json!(current_token.borrow().as_str())),move|_|{let mut end=held.buffer.end_iter();held.buffer.begin_user_action();held.buffer.insert(&mut end,"changed");held.buffer.end_user_action();});
                advance(15);
            }
            15 if entered.get().elapsed() > Duration::from_millis(250) => {
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                assert!(buffer_text(&doc.buffer).ends_with("changed"));
                doc.buffer.undo();
                assert_eq!(buffer_text(&doc.buffer), *expected.borrow());
                original_revision.set(doc.revision.get());
                advance(16);
            }
            16 => {
                if let Some(value) = answer.borrow_mut().take() {
                    if value["ready"] == true
                        && preview.print_token(doc.revision.get()).as_deref()
                            == value["token"].as_str()
                    {
                        *current_token.borrow_mut() = value["token"].as_str().unwrap().to_owned();
                        let a = doc.buffer.iter_at_line(4).unwrap();
                        let b = doc.buffer.iter_at_line(7).unwrap();
                        doc.buffer.select_range(&a, &b);
                        assert!(click(
                            doc.container.upcast_ref(),
                            ui.lang.text("Auswahl falten", "Fold selection")
                        ));
                        assert!(doc.folded.borrow().is_some());
                        query(&format!(
                            "const token={};window.webkit.messageHandlers.markdownPosition.postMessage({{token,epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1}});window.webkit.messageHandlers.markdownPosition.postMessage({{token,epoch:document.documentElement.dataset.fastraPositionEpoch,line:7,column:1}});return JSON.stringify(true);",
                            serde_json::json!(current_token.borrow().as_str())
                        ));
                        advance(17);
                    }
                }
                if stage.get() == 16 {
                    query(
                        "return JSON.stringify({ready:window.fastraPreviewReady===true,token:document.documentElement.dataset.fastraRender});",
                    );
                }
            }
            17 if entered.get().elapsed() > Duration::from_millis(250) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.iter_at_mark(&doc.buffer.get_insert()).line(), 6);
                assert!(doc.folded.borrow().is_none());
                assert!(view.has_focus());
                caret.set(doc.buffer.cursor_position());
                query(
                    "const p=[...document.querySelectorAll('p')].find(p=>p.textContent.includes('Line C'));p.scrollIntoView();const r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,1);const b=r.getBoundingClientRect();window.webkit.messageHandlers.markdownPosition.postMessage({token:document.documentElement.dataset.fastraRender,epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1});return JSON.stringify({x:b.x+1,y:b.y+b.height/2});",
                );
                advance(18);
            }
            18 => {
                if let Some(value) = answer.borrow_mut().take() {
                    native_drag(
                        &ui,
                        preview.view.upcast_ref(),
                        value["x"].as_f64().unwrap(),
                        value["y"].as_f64().unwrap(),
                    );
                    advance(19);
                }
            }
            19 if entered.get().elapsed() > Duration::from_millis(250) => {
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                query("return JSON.stringify({selection:getSelection().toString()});");
                advance(20);
            }
            20 => {
                if let Some(value) = answer.borrow_mut().take() {
                    assert!(
                        !value["selection"].as_str().unwrap().is_empty(),
                        "actual native drag selection"
                    );
                    doc.rich_toggle.borrow().as_ref().unwrap().set_active(true);
                    assert!(doc.is_rich_active());
                    query(&format!(
                        "window.webkit.messageHandlers.markdownPosition.postMessage({{token:{},epoch:document.documentElement.dataset.fastraPositionEpoch,line:1,column:1}});return JSON.stringify(true);",
                        serde_json::json!(current_token.borrow().as_str())
                    ));
                    advance(21);
                }
            }
            21 if entered.get().elapsed() > Duration::from_millis(700) => {
                answer.borrow_mut().take();
                assert_eq!(doc.buffer.cursor_position(), caret.get());
                doc.rich_toggle.borrow().as_ref().unwrap().set_active(false);
                advance(22);
            }
            22 if !doc.is_rich_active() => {
                assert_eq!(buffer_text(&doc.buffer), *expected.borrow());
                assert_eq!(std::fs::read(&fixture).unwrap(), source.as_bytes());
                assert!(!doc.buffer.is_modified());
                assert!(!doc.buffer.can_undo());
                assert_eq!(doc.revision.get(), original_revision.get());
                assert!(check(
                    doc.container.upcast_ref(),
                    ui.lang.text("Quelltextansicht teilen", "Split source editor")
                ));
                let offset = expected.borrow().find("DEEP TARGET").unwrap();
                let mut at = views[1].buffer().iter_at_offset(expected.borrow()[..offset].chars().count() as i32);
                views[1].scroll_to_iter(&mut at, 0.1, true, 0., 0.5);
                advance(23);
            }
            23 if entered.get().elapsed() > Duration::from_millis(300) => {
                assert!(views[1].is_mapped());
                let offset = expected.borrow().find("DEEP TARGET").unwrap();
                let mut at = views[1].buffer().iter_at_offset(expected.borrow()[..offset].chars().count() as i32);
                views[1].scroll_to_iter(&mut at, 0.1, true, 0., 0.5);
                advance(230);
            }
            230 if entered.get().elapsed() > Duration::from_millis(250) => {
                assert!(views[1].is_mapped());
                let offset = expected.borrow().find("DEEP TARGET").unwrap();
                let at = views[1].buffer().iter_at_offset(expected.borrow()[..offset].chars().count() as i32);
                let b = views[1].iter_location(&at);
                let visible = views[1].visible_rect();
                assert!(
                    b.y() >= visible.y() && b.y() + b.height() <= visible.y() + visible.height(),
                    "second source target must be visible before real XTest input: {b:?} vs {visible:?}"
                );
                let (x, y) = views[1].buffer_to_window_coords(
                    gtk::TextWindowType::Widget,
                    b.x() + 4,
                    b.y() + b.height() / 2,
                );
                preview.schedule(&doc, ui.lang);
                assert!(preview.print_token(doc.revision.get()).is_none());
                preview.inspect("window.scrollTo(0,0);return JSON.stringify(true);", |_| {});
                native_click(&ui, views[1].upcast_ref(), f64::from(x), f64::from(y));
                advance(24);
            }
            24 => {
                if let Some(value) = answer.borrow_mut().take() {
                    if value["ready"] == true
                        && value["y"].as_f64().is_some_and(|n| n > 500.)
                        && preview.print_token(doc.revision.get()).as_deref()
                            == value["token"].as_str()
                    {
                        assert_eq!(buffer_text(&doc.buffer), *expected.borrow());
                        assert_eq!(std::fs::read(&fixture).unwrap(), source.as_bytes());
                        assert!(!doc.buffer.is_modified());
                        assert!(!doc.buffer.can_undo());
                        assert_eq!(doc.revision.get(), original_revision.get());
                        println!(
                            "FASTRA_SOURCE_SYNC_SELFTEST_OK actual-XTest-both-directions/table-cell-source-line/visible-focus-and-scroll/actual-drag-selection/blocked-link/stale-token/changed-tab/tab-ABA-replay-and-new-click/hidden-view/rebuilt-view/read-only-hex/close-pending/native-selection-race/source-revision-race/latest-jump-wins/unfold/rich-mode/second-source-pane/pending-render-reveal/unchanged-file-revision-undo"
                        );
                        ui.discard_confirmed.set(true);
                        ui.window.application().unwrap().quit();
                        return glib::ControlFlow::Break;
                    }
                }
                query(
                    "return JSON.stringify({ready:window.fastraPreviewReady===true,token:document.documentElement.dataset.fastraRender,y:scrollY});",
                );
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
