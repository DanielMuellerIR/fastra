use super::*;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
fn window(title: &str) -> Option<gtk::Window> {
    gtk::Window::list_toplevels()
        .iter()
        .filter_map(|widget| widget.clone().downcast::<gtk::Window>().ok())
        .find(|window| window.is_visible() && window.title().as_deref() == Some(title))
}
fn click(window: &gtk::Window, label: &str) -> bool {
    let Some(button) = super::super::gui_test::button(window.child().unwrap().upcast_ref(), label)
        .filter(|button| {
            button.is_mapped() && button.width() > 0 && button.height() > 0 && button.is_sensitive()
        })
    else {
        return false;
    };
    super::super::gui_test::input(&button, true, &[]);
    true
}
fn find<T: IsA<gtk::Widget> + glib::object::IsClass + glib::types::StaticType>(
    widget: &gtk::Widget,
) -> Option<T> {
    if let Ok(value) = widget.clone().downcast::<T>() {
        return Some(value);
    }
    let mut child = widget.first_child();
    while let Some(next) = child {
        if let Some(found) = find::<T>(&next) {
            return Some(found);
        }
        child = next.next_sibling();
    }
    None
}
fn target_text(window: &gtk::Window) -> String {
    let pane = find::<gtk::Paned>(window.child().unwrap().upcast_ref()).unwrap();
    let view = find::<sourceview5::View>(pane.end_child().unwrap().upcast_ref()).unwrap();
    buffer_text(&view.buffer())
}
fn choose(dialog: &gtk::Window, path: PathBuf) {
    let id = super::super::gui_test::xid(dialog);
    std::thread::spawn(move || {
        let call = |args: &[&str]| {
            assert!(std::process::Command::new("timeout")
                .args(["5s", "xdotool"])
                .args(args)
                .status()
                .unwrap()
                .success())
        };
        call(&[
            "windowraise",
            &id,
            "windowfocus",
            "--sync",
            &id,
            "key",
            "ctrl+l",
            "ctrl+a",
        ]);
        std::thread::sleep(Duration::from_millis(100));
        call(&["type", "--clearmodifiers", "--", path.to_str().unwrap()]);
        call(&["key", "Return"]);
    });
}
fn js(editor: &Rc<RichEditor>, code: &str, reply: &Rc<RefCell<Option<Value>>>) {
    let value = reply.clone();
    value.borrow_mut().take();
    editor.evaluate(code, move |result| *value.borrow_mut() = result);
}
fn original_files(root: &std::path::Path) -> std::collections::BTreeMap<PathBuf, Vec<u8>> {
    fn visit(path: &std::path::Path, result: &mut std::collections::BTreeMap<PathBuf, Vec<u8>>) {
        for entry in std::fs::read_dir(path).unwrap() {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_dir() {
                visit(&entry.path(), result);
            } else {
                result.insert(entry.path(), std::fs::read(entry.path()).unwrap());
            }
        }
    }
    let mut result = std::collections::BTreeMap::new();
    visit(root, &mut result);
    result
}
fn verify_originals(files: &std::collections::BTreeMap<PathBuf, Vec<u8>>) {
    for (path, bytes) in files {
        assert_eq!(
            &std::fs::read(path).unwrap(),
            bytes,
            "original {}",
            path.display()
        );
    }
}
pub(super) fn run(ui: Rc<Ui>) {
    if std::env::var_os("FASTRA_SAVE_AS_EOL_SELFTEST").is_some() {
        run_eol(ui);
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    if let Some(path) = std::env::var_os("FASTRA_SAVE_AS_COLD_OPEN") {
        return cold(ui, PathBuf::from(path));
    }
    let root = PathBuf::from(std::env::var_os("FASTRA_SAVE_AS_TEST_ROOT").unwrap());
    std::fs::create_dir_all(&root).unwrap();
    let old = root.join("old");
    let new = root.join("new");
    let published = root.join("published");
    for path in [
        &old.join("art"),
        &old.join("images"),
        &new.join("images"),
        &published,
    ] {
        std::fs::create_dir_all(path).unwrap();
    }
    let png = include_bytes!("../../../tests/fixtures/pixel-1.png").to_vec();
    assert!(std::process::Command::new("/usr/bin/convert")
        .args(["-size", "64x32", "xc:#3f7ac0", "-strip"])
        .arg(old.join("art/base#a.png"))
        .status()
        .unwrap()
        .success());
    let baseline = std::fs::read(old.join("art/base#a.png")).unwrap();
    std::fs::write(old.join("images/1.png"), b"foreign old image").unwrap();
    std::fs::write(new.join("images/1.png"), b"foreign target image").unwrap();
    let source="Before **Bold**\n\n![Baseline](art/base%23a.png)\n\n![Again][base]\n\n[base]: art/base%23a.png\n\nAfter untouched\n";
    let path = old.join("original.md");
    let source_bytes = if std::env::var_os("FASTRA_SAVE_AS_UTF16").is_some() {
        fastra_core::encoding::decode(&[0xff, 0xfe], None)
            .unwrap()
            .encode(source)
            .unwrap()
    } else {
        source.as_bytes().to_vec()
    };
    std::fs::write(&path, source_bytes).unwrap();
    let same = old.join("same folder.md");
    let target = new.join("copy.md");
    let drift = published.join("drift.md");
    ui.window.set_default_size(
        std::env::var("FASTRA_SAVE_AS_WIDTH")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(1180),
        850,
    );
    project_view::open_path(&ui, old.clone());
    ui.window.present();
    ui.load_path(path.clone());
    let phase = Cell::new(0u32);
    let started = Instant::now();
    let since = Cell::new(Instant::now());
    let reply = Rc::new(RefCell::new(None::<Value>));
    let shots = RefCell::new(None);
    let doc = RefCell::new(None::<Rc<Document>>);
    let old_files = RefCell::new(None);
    let same_files = RefCell::new(None);
    let approved = RefCell::new(String::new());
    let chooser_retry = Cell::new(false);
    let files_phase = Cell::new(0u8);
    let plain_saved = RefCell::new(String::new());
    glib::timeout_add_local(Duration::from_millis(40), move || {
        assert!(
            started.elapsed() < Duration::from_secs(180),
            "save-as phase {}: {}",
            phase.get(),
            ui.status.text()
        );
        if since.get().elapsed() < Duration::from_millis(180) {
            return glib::ControlFlow::Continue;
        }
        let next = |value| {
            eprintln!("Save-as phase {value}");
            phase.set(value);
            since.set(Instant::now());
            chooser_retry.set(false);
        };
        let review = || window(ui.lang.text("Speichern unter prüfen", "Review Save as"));
        let chooser = || window(ui.lang.text("Speichern unter …", "Save as …"));
        match phase.get() {
            0 => {
                let Some(value) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                *doc.borrow_mut() = Some(value.clone());
                if let Some(preview) = value.markdown_toggle.borrow().as_ref() {
                    preview.set_active(true);
                }
                let toggle = mode_toggle(&value, ui.lang);
                if !toggle.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                super::super::gui_test::input(&toggle, true, &[]);
                next(1);
            }
            1 => {
                let document = doc.borrow().clone().unwrap();
                let Some(editor) = document
                    .rich
                    .borrow()
                    .clone()
                    .filter(|editor| editor.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                js(&editor,"const root=document.getElementById('fastra-visual'),range=document.createRange();range.selectNodeContents(root.lastElementChild);range.collapse(false);getSelection().removeAllRanges();getSelection().addRange(range);root.focus();return JSON.stringify(true);",&reply);
                next(2);
            }
            2 => {
                if reply.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                let document = doc.borrow().clone().unwrap();
                let editor = document.rich.borrow().clone().unwrap();
                editor
                    .view
                    .clipboard()
                    .set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
                        "image/png",
                        &glib::Bytes::from_owned(png.clone()),
                    )))
                    .unwrap();
                super::super::gui_test::input(&editor.view, false, &["ctrl+v"]);
                next(3);
            }
            3 => {
                let Some(window) = window(
                    ui.lang
                        .text("Bilder und Dateien einfügen", "Insert images and files"),
                ) else {
                    return glib::ControlFlow::Continue;
                };
                if !click(
                    &window,
                    ui.lang
                        .text("Bilder speichern und einfügen", "Save images and insert"),
                ) {
                    return glib::ControlFlow::Continue;
                }
                next(4);
            }
            4 => {
                let document = doc.borrow().clone().unwrap();
                if !buffer_text(&document.buffer).contains("images/2.png") {
                    return glib::ControlFlow::Continue;
                }
                let editor = document.rich.borrow().clone().unwrap();
                if editor.busy.get() {
                    return glib::ControlFlow::Continue;
                }
                super::super::gui_test::input(&editor.view, false, &["ctrl+s"]);
                next(5);
            }
            5 => {
                let document = doc.borrow().clone().unwrap();
                if document.saving.get() || document.buffer.is_modified() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    document.snapshot.borrow().as_ref().unwrap().bytes(),
                    document
                        .format
                        .borrow()
                        .encode(&buffer_text(&document.buffer))
                        .unwrap()
                );
                assert!(has_assets(&document));
                *old_files.borrow_mut() = Some(original_files(&old));
                if !click(
                    ui.window.upcast_ref(),
                    ui.lang.text("Speichern unter …", "Save as …"),
                ) {
                    return glib::ControlFlow::Continue;
                }
                next(10);
            }
            10 | 20 | 30 | 40 | 50 | 60 | 70 => {
                let Some(dialog) =
                    chooser().filter(|window| window.is_mapped() && window.width() > 0)
                else {
                    return glib::ControlFlow::Continue;
                };
                if !super::super::gui_test::capture(
                    &dialog,
                    &format!("save-as-dialog-{}", phase.get()),
                    &shots,
                ) {
                    return glib::ControlFlow::Continue;
                }
                let path = match phase.get() {
                    10 => same.clone(),
                    20 => target.clone(),
                    30 => drift.clone(),
                    40 => published.join("cancelled.md"),
                    50 => published.join("stale.md"),
                    _ => published.join("plain-copy.txt"),
                };
                choose(&dialog, path);
                next(phase.get() + 1);
            }
            11 | 21 | 31 | 41 | 51 | 61 | 71 => {
                let Some(window) = review() else {
                    if matches!(phase.get(), 61 | 71) {
                        for window in gtk::Window::list_toplevels()
                            .iter()
                            .filter_map(|widget| widget.clone().downcast::<gtk::Window>().ok())
                            .filter(|window| window.is_visible())
                        {
                            for label in ["_Replace", "Replace", "_Ersetzen", "Ersetzen"] {
                                if click(&window, label) {
                                    return glib::ControlFlow::Continue;
                                }
                            }
                        }
                    }
                    if let Some(dialog) = chooser() {
                        if since.get().elapsed() > Duration::from_secs(2)
                            && !chooser_retry.replace(true)
                        {
                            super::super::gui_test::input(&dialog, false, &["Return"]);
                        }
                    }
                    return glib::ControlFlow::Continue;
                };
                if matches!(phase.get(), 61 | 71) {
                    let Some(check) =
                        find::<gtk::CheckButton>(window.child().unwrap().upcast_ref())
                    else {
                        return glib::ControlFlow::Continue;
                    };
                    if !check.is_active() {
                        if check.is_mapped() && check.width() > 0 {
                            super::super::gui_test::input(&check, true, &[]);
                        }
                        return glib::ControlFlow::Continue;
                    }
                }
                let label = ui
                    .lang
                    .text("Geprüft speichern unter", "Save reviewed target");
                let Some(button) =
                    super::super::gui_test::button(window.child().unwrap().upcast_ref(), label)
                        .filter(|button| {
                            button.is_sensitive() && button.is_mapped() && button.width() > 0
                        })
                else {
                    return glib::ControlFlow::Continue;
                };
                if phase.get() == 21
                    && files_phase.get() == 2
                    && find::<gtk::Notebook>(window.child().unwrap().upcast_ref())
                        .unwrap()
                        .current_page()
                        != Some(0)
                {
                    return glib::ControlFlow::Continue;
                }
                if !(phase.get() == 21 && files_phase.get() == 1)
                    && !super::super::gui_test::capture(
                        &window,
                        &format!("save-as-preview-{}", phase.get()),
                        &shots,
                    )
                {
                    return glib::ControlFlow::Continue;
                }
                if phase.get() == 21 && files_phase.get() < 2 {
                    let notebook =
                        find::<gtk::Notebook>(window.child().unwrap().upcast_ref()).unwrap();
                    if files_phase.get() == 0 {
                        let page = notebook.nth_page(Some(1)).unwrap();
                        super::super::gui_test::input(
                            &notebook.tab_label(&page).unwrap(),
                            true,
                            &[],
                        );
                        files_phase.set(1);
                        return glib::ControlFlow::Continue;
                    }
                    if notebook.current_page() != Some(1) {
                        return glib::ControlFlow::Continue;
                    }
                    if !super::super::gui_test::capture(&window, "save-as-all-image-copies", &shots)
                    {
                        return glib::ControlFlow::Continue;
                    }
                    let page = notebook.nth_page(Some(0)).unwrap();
                    super::super::gui_test::input(&notebook.tab_label(&page).unwrap(), true, &[]);
                    files_phase.set(2);
                    return glib::ControlFlow::Continue;
                }
                if phase.get() == 51 {
                    project_view::open_path(&ui, new.clone());
                    project_view::open_path(&ui, old.clone());
                    super::super::gui_test::input(&button, true, &[]);
                    next(52);
                } else if phase.get() == 41 {
                    if !click(&window, ui.lang.text("Abbrechen", "Cancel")) {
                        return glib::ControlFlow::Continue;
                    }
                    next(42);
                } else if matches!(phase.get(), 31 | 71) {
                    *approved.borrow_mut() = target_text(&window);
                    button.emit_clicked();
                    let document = ui.active().unwrap();
                    let mut end = document.buffer.end_iter();
                    document.buffer.insert(&mut end, "Newer input retained\n");
                    next(phase.get() + 1);
                } else {
                    super::super::gui_test::input(&button, true, &[]);
                    next(phase.get() + 1);
                }
            }
            12 => {
                let document = doc.borrow().clone().unwrap();
                if document.saving.get() || document.disk_path().as_ref() != Some(&same) {
                    return glib::ControlFlow::Continue;
                }
                assert!(!document.buffer.can_undo());
                assert_eq!(project_view::current_binding(&ui).unwrap().root.path, old);
                verify_originals(old_files.borrow().as_ref().unwrap());
                assert!(origin_paths(&document).contains(&old.join("images/2.png")));
                let Some(editor) = document
                    .rich
                    .borrow()
                    .clone()
                    .filter(|editor| editor.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(editor.assets.borrow().bytes, 0);
                *same_files.borrow_mut() = Some(original_files(&old));
                js(&editor,"return JSON.stringify({images:[...document.querySelectorAll('img')].map(image=>image.naturalWidth)});",&reply);
                next(13);
            }
            13 => {
                let Some(value) = reply.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["images"], json!([64, 64, 1]));
                let document = doc.borrow().clone().unwrap();
                let editor = document.rich.borrow().clone().unwrap();
                super::super::gui_test::input(&editor.view, false, &["ctrl+shift+s"]);
                next(20);
            }
            22 => {
                let document = doc.borrow().clone().unwrap();
                if document.saving.get() || document.disk_path().as_ref() != Some(&target) {
                    return glib::ControlFlow::Continue;
                }
                assert!(!document.buffer.can_undo());
                verify_originals(same_files.borrow().as_ref().unwrap());
                assert_eq!(
                    std::fs::read(new.join("images/1.png")).unwrap(),
                    b"foreign target image"
                );
                assert_eq!(std::fs::read(new.join("images/2.png")).unwrap(), baseline);
                assert_eq!(std::fs::read(new.join("images/3.png")).unwrap(), png);
                let Some(editor) = document
                    .rich
                    .borrow()
                    .clone()
                    .filter(|editor| editor.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                js(&editor,"return JSON.stringify({images:[...document.querySelectorAll('img')].map(image=>image.naturalWidth),text:fastraVisual.clipboardState().markdown});",&reply);
                next(23);
            }
            23 => {
                let Some(value) = reply.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["images"], json!([64, 64, 1]));
                assert!(!value["text"]
                    .as_str()
                    .unwrap()
                    .contains("art/base%23a.png)"));
                if !super::super::gui_test::capture(&ui.window, "save-as-target-rich", &shots) {
                    return glib::ControlFlow::Continue;
                }
                let document = doc.borrow().clone().unwrap();
                super::super::gui_test::input(&mode_toggle(&document, ui.lang), true, &[]);
                next(24);
            }
            24 => {
                let document = doc.borrow().clone().unwrap();
                if document.is_rich_active() {
                    return glib::ControlFlow::Continue;
                }
                assert!(
                    document
                        .markdown_toggle
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .is_active(),
                    "source preview preference survives Save as and Rich rebuild"
                );
                if !click(
                    ui.window.upcast_ref(),
                    ui.lang.text("Speichern unter …", "Save as …"),
                ) {
                    return glib::ControlFlow::Continue;
                }
                next(30);
            }
            32 => {
                let document = doc.borrow().clone().unwrap();
                if document.saving.get() || !drift.exists() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(document.disk_path().as_ref(), Some(&target));
                assert!(buffer_text(&document.buffer).ends_with("Newer input retained\n"));
                assert!(document.buffer.is_modified());
                assert_eq!(
                    std::fs::read(&drift).unwrap(),
                    document.format.borrow().encode(&approved.borrow()).unwrap()
                );
                assert_eq!(
                    std::fs::read(published.join("images/1.png")).unwrap(),
                    baseline
                );
                assert_eq!(std::fs::read(published.join("images/2.png")).unwrap(), png);
                assert!(ui.status.text().contains(
                    ui.lang
                        .text("Ziel wurde veröffentlicht", "Target was published")
                ));
                verify_originals(same_files.borrow().as_ref().unwrap());
                ui.load_path(drift.clone());
                next(33);
            }
            33 => {
                let Some(document) = ui
                    .active()
                    .filter(|document| document.disk_path().as_ref() == Some(&drift))
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!Rc::ptr_eq(&document, doc.borrow().as_ref().unwrap()));
                super::super::gui_test::input(&mode_toggle(&document, ui.lang), true, &[]);
                next(34);
            }
            34 => {
                let Some(editor) = ui
                    .active()
                    .and_then(|document| document.rich.borrow().clone())
                    .filter(|editor| editor.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                js(&editor,"return JSON.stringify({images:[...document.querySelectorAll('img')].map(image=>image.naturalWidth)});",&reply);
                next(35);
            }
            35 => {
                let Some(value) = reply.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["images"], json!([64, 64, 1]));
                if !super::super::gui_test::capture(&ui.window, "save-as-fresh-reopen", &shots) {
                    return glib::ControlFlow::Continue;
                }
                if !click(
                    ui.window.upcast_ref(),
                    ui.lang.text("Speichern unter …", "Save as …"),
                ) {
                    return glib::ControlFlow::Continue;
                }
                next(40);
            }
            42 => {
                if review().is_some() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!published.join("cancelled.md").exists());
                assert!(!ui.active().unwrap().saving.get());
                verify_originals(same_files.borrow().as_ref().unwrap());
                assert!(buffer_text(&doc.borrow().as_ref().unwrap().buffer)
                    .contains("Newer input retained"));
                if !click(
                    ui.window.upcast_ref(),
                    ui.lang.text("Speichern unter …", "Save as …"),
                ) {
                    return glib::ControlFlow::Continue;
                }
                next(50);
            }
            52 => {
                if review().is_some() || ui.active().unwrap().saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!published.join("stale.md").exists());
                let plain = root.join("plain-original.txt");
                let bytes = [
                    b"\xef\xbb\xbf".as_slice(),
                    "Café\r\nBefore\rAfter\n".as_bytes(),
                ]
                .concat();
                std::fs::write(&plain, &bytes).unwrap();
                std::fs::write(
                    published.join("plain-copy.txt"),
                    "Foreign existing target\n",
                )
                .unwrap();
                ui.load_path(plain);
                next(59);
            }
            59 => {
                if !project_view::current_binding(&ui)
                    .is_some_and(|binding| binding.is_current() && binding.root.path == old)
                {
                    return glib::ControlFlow::Continue;
                }
                let Some(document) = ui.active().filter(|document| {
                    document.disk_path().as_ref() == Some(&root.join("plain-original.txt"))
                }) else {
                    return glib::ControlFlow::Continue;
                };
                document.buffer.begin_user_action();
                let mut end = document.buffer.end_iter();
                document.buffer.insert(&mut end, "Added");
                document.buffer.end_user_action();
                assert!(document.buffer.can_undo());
                if !click(
                    ui.window.upcast_ref(),
                    ui.lang.text("Speichern unter …", "Save as …"),
                ) {
                    return glib::ControlFlow::Continue;
                }
                next(60);
            }
            62 => {
                let document = ui.active().unwrap();
                if document.saving.get()
                    || document.disk_path().as_ref() != Some(&published.join("plain-copy.txt"))
                {
                    return glib::ControlFlow::Continue;
                }
                assert!(document.buffer.can_undo());
                assert!(!document.buffer.is_modified());
                assert_eq!(
                    std::fs::read(root.join("plain-original.txt")).unwrap(),
                    [
                        b"\xef\xbb\xbf".as_slice(),
                        "Café\r\nBefore\rAfter\n".as_bytes()
                    ]
                    .concat()
                );
                assert_eq!(
                    std::fs::read(published.join("plain-copy.txt")).unwrap(),
                    document
                        .format
                        .borrow()
                        .encode("Café\r\nBefore\rAfter\nAdded")
                        .unwrap()
                );
                if !click(ui.window.upcast_ref(), ui.lang.text("Rückgängig", "Undo")) {
                    return glib::ControlFlow::Continue;
                }
                next(63);
            }
            63 => {
                let document = ui.active().unwrap();
                if buffer_text(&document.buffer).contains("Added") {
                    return glib::ControlFlow::Continue;
                }
                assert!(document.buffer.is_modified());
                if !click(ui.window.upcast_ref(), ui.lang.text("Speichern", "Save")) {
                    return glib::ControlFlow::Continue;
                }
                next(64);
            }
            64 => {
                let document = ui.active().unwrap();
                if document.saving.get() || document.buffer.is_modified() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    std::fs::read(published.join("plain-copy.txt")).unwrap(),
                    std::fs::read(root.join("plain-original.txt")).unwrap()
                );
                document.buffer.begin_user_action();
                let mut end = document.buffer.end_iter();
                document.buffer.insert(&mut end, "Before commit\n");
                document.buffer.end_user_action();
                if !click(
                    ui.window.upcast_ref(),
                    ui.lang.text("Speichern unter …", "Save as …"),
                ) {
                    return glib::ControlFlow::Continue;
                }
                next(70);
            }
            65 => {
                if since.get().elapsed() < Duration::from_secs(2) {
                    return glib::ControlFlow::Continue;
                }
                let document = ui.active().unwrap();
                assert_eq!(buffer_text(&document.buffer), plain_saved.borrow().as_str());
                assert_eq!(
                    document.disk_path().as_ref(),
                    Some(&published.join("plain-copy.txt"))
                );
                let changed = document
                    .format
                    .borrow()
                    .encode("External target mutation\n")
                    .unwrap();
                std::fs::write(published.join("plain-copy.txt"), changed).unwrap();
                next(66);
            }
            66 => {
                fn warning(widget: &gtk::Widget, text: &str) -> bool {
                    if widget
                        .downcast_ref::<gtk::Label>()
                        .is_some_and(|label| label.is_mapped() && label.text().contains(text))
                    {
                        return true;
                    }
                    let mut child = widget.first_child();
                    while let Some(next) = child {
                        if warning(&next, text) {
                            return true;
                        }
                        child = next.next_sibling();
                    }
                    false
                }
                let document = ui.active().unwrap();
                if !warning(
                    document.container.upcast_ref(),
                    ui.lang.text(
                        "Die Datei wurde extern geändert",
                        "The file changed externally",
                    ),
                ) {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(buffer_text(&document.buffer), plain_saved.borrow().as_str());
                verify_originals(same_files.borrow().as_ref().unwrap());
                if !super::super::gui_test::capture(
                    &ui.window,
                    "save-as-new-target-watcher",
                    &shots,
                ) {
                    return glib::ControlFlow::Continue;
                }
                println!("FASTRA Save-as selftest PASS: native FileDialog/XTest mouse and CtrlShiftS, real old PNG ticket + distinct uncached raster, same-folder origin/Undo separation, complete relocation/file-list preview and exact bytes, postpublication newer input retained, fresh target-root WebKit images, cancel and isolated project ABA no-write, actual bound overwrite, plain-text Undo + subsequent Save targets new path, source and target watcher separation, original image/document bytes unchanged");
                std::process::exit(0);
            }
            72 => {
                let document = ui.active().unwrap();
                if document.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(document.buffer.is_modified());
                assert!(buffer_text(&document.buffer).ends_with("Newer input retained\n"));
                assert_eq!(*document.original.borrow(), *approved.borrow());
                assert_eq!(
                    document.snapshot.borrow().as_ref().unwrap().bytes(),
                    document.format.borrow().encode(&approved.borrow()).unwrap()
                );
                if !click(ui.window.upcast_ref(), ui.lang.text("Speichern", "Save")) {
                    return glib::ControlFlow::Continue;
                }
                next(73);
            }
            73 => {
                let document = ui.active().unwrap();
                if document.saving.get() || document.buffer.is_modified() {
                    return glib::ControlFlow::Continue;
                }
                *plain_saved.borrow_mut() = buffer_text(&document.buffer);
                assert_eq!(
                    std::fs::read(published.join("plain-copy.txt")).unwrap(),
                    document
                        .format
                        .borrow()
                        .encode(&plain_saved.borrow())
                        .unwrap()
                );
                std::fs::write(
                    root.join("plain-original.txt"),
                    "External old-source mutation\n",
                )
                .unwrap();
                next(65);
            }
            _ => unreachable!(),
        }
        glib::ControlFlow::Continue
    });
}

fn cold(ui: Rc<Ui>, path: PathBuf) {
    assert!(path.starts_with("/test"));
    ui.load_path(path.clone());
    let phase = Cell::new(0);
    let start = Instant::now();
    let reply = Rc::new(RefCell::new(None::<Value>));
    let shots = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            start.elapsed() < Duration::from_secs(30),
            "cold reopen phase {}",
            phase.get()
        );
        match phase.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                mode_toggle(&doc, ui.lang).set_active(true);
                phase.set(1);
            }
            1 => {
                let Some(editor) = ui
                    .active()
                    .and_then(|doc| doc.rich.borrow().clone())
                    .filter(|editor| editor.ready.get())
                else {
                    return glib::ControlFlow::Continue;
                };
                js(&editor,"return JSON.stringify({images:[...document.querySelectorAll('img')].map(image=>image.naturalWidth)});",&reply);
                phase.set(2);
            }
            _ => {
                let Some(value) = reply.borrow().as_ref().cloned() else {
                    return glib::ControlFlow::Continue;
                };
                assert_eq!(value["images"], json!([64, 64, 1]));
                assert!(!std::path::Path::new("/work/evidence").exists());
                if !super::super::gui_test::capture(&ui.window, "save-as-cold-target-only", &shots)
                {
                    return glib::ControlFlow::Continue;
                }
                println!("FASTRA Save-as cold reopen PASS: fresh process, read-only target tree only, original paths unavailable, distinct raster images loaded against new base");
                std::process::exit(0);
            }
        }
        glib::ControlFlow::Continue
    });
}

fn run_eol(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    use fastra_core::encoding::LineEnding;
    let root = PathBuf::from(std::env::var_os("FASTRA_SAVE_AS_TEST_ROOT").unwrap());
    let path = root.join("original-eol.md");
    let target = root.join("published-eol.md");
    let cancelled = root.join("cancel-eol.md");
    let source = if std::env::var_os("FASTRA_SAVE_AS_EOL_MATH_SELFTEST").is_some() {
        "# Save as\r\n\r\ntext café 🙂 $x^2$ after\rfinal\n"
    } else {
        "# Save as\r\n\r\ntext café 🙂\rfinal\n"
    };
    let format = std::sync::Arc::new(if std::env::var_os("FASTRA_SAVE_AS_UTF16").is_some() {
        fastra_core::encoding::decode(b"\xff\xfe", None).unwrap()
    } else {
        fastra_core::encoding::decode(b"", None).unwrap()
    });
    let original = format.encode(source).unwrap();
    std::fs::write(&path, &original).unwrap();
    let snapshot = fastra_io::Snapshot::read(&path, &fastra_core::Cancellation::default()).unwrap();
    let doc = ui.add_loaded_text(
        "original-eol.md",
        std::sync::Arc::new(fastra_core::encoding::decode(&original, None).unwrap()),
        snapshot,
    );
    let rich = std::env::var_os("FASTRA_SAVE_AS_EOL_RICH").is_some();
    crate::line_endings::select_for_test(&doc, LineEnding::Lf);
    if rich {
        mode_toggle(&doc, ui.lang).set_active(true);
    }
    crate::git_view::test_size(ui.window.upcast_ref());
    let phase = Cell::new(0);
    let start = Instant::now();
    let since = Cell::new(start);
    let retried = Cell::new(false);
    let reply = Rc::new(RefCell::new(None::<Value>));
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            start.elapsed() < Duration::from_secs(80),
            "EOL save-as phase {} {}",
            phase.get(),
            ui.status.text()
        );
        let chooser = || window(ui.lang.text("Speichern unter …", "Save as …"));
        let review = || window(ui.lang.text("Speichern unter prüfen", "Review Save as"));
        match phase.get() {
            0 | 8 => {
                if rich
                    && doc
                        .rich
                        .borrow()
                        .as_ref()
                        .is_none_or(|editor| !editor.ready.get())
                {
                    return glib::ControlFlow::Continue;
                }
                if !click(
                    ui.window.upcast_ref(),
                    ui.lang.text("Speichern unter …", "Save as …"),
                ) {
                    return glib::ControlFlow::Continue;
                }
            }
            1 | 4 | 9 => {
                let Some(dialog) = chooser().filter(|w| w.is_mapped() && w.width() > 0) else {
                    return glib::ControlFlow::Continue;
                };
                choose(
                    &dialog,
                    if phase.get() == 1 {
                        cancelled.clone()
                    } else {
                        target.clone()
                    },
                );
                retried.set(false);
                since.set(Instant::now());
            }
            2 | 5 | 10 => {
                let Some(window) = review() else {
                    for window in gtk::Window::list_toplevels()
                        .iter()
                        .filter_map(|w| w.clone().downcast::<gtk::Window>().ok())
                        .filter(|w| w.is_visible())
                    {
                        for label in ["Replace", "_Replace", "Ersetzen", "_Ersetzen"] {
                            if click(&window, label) {
                                return glib::ControlFlow::Continue;
                            }
                        }
                    }
                    if since.get().elapsed() > Duration::from_secs(2) && !retried.replace(true) {
                        if let Some(dialog) = chooser() {
                            super::super::gui_test::input(&dialog, false, &["Return"]);
                        }
                    }
                    return glib::ControlFlow::Continue;
                };
                if phase.get() == 10 {
                    let Some(check) =
                        find::<gtk::CheckButton>(window.child().unwrap().upcast_ref())
                    else {
                        return glib::ControlFlow::Continue;
                    };
                    if !check.is_active() {
                        if check.is_mapped() && check.width() > 0 {
                            super::super::gui_test::input(&check, true, &[]);
                        }
                        return glib::ControlFlow::Continue;
                    }
                }
                let Some(_) = super::super::gui_test::button(
                    window.child().unwrap().upcast_ref(),
                    ui.lang
                        .text("Geprüft speichern unter", "Save reviewed target"),
                )
                .filter(|button| button.is_sensitive() && button.is_mapped() && button.width() > 0) else {
                    return glib::ControlFlow::Continue;
                };
                let expected = if phase.get() == 10 {
                    LineEnding::Cr.convert(source)
                } else {
                    LineEnding::Lf.convert(source)
                };
                assert_eq!(
                    target_text(&window),
                    expected,
                    "complete visible Save As output includes the pending EOL conversion"
                );
                assert_eq!(std::fs::read(&path).unwrap(), original);
                if phase.get() == 2 {
                    assert_eq!(buffer_text(&doc.buffer), source);
                    assert!(!cancelled.exists());
                    if !click(&window, ui.lang.text("Abbrechen", "Cancel")) {
                        return glib::ControlFlow::Continue;
                    }
                } else if !click(
                    &window,
                    ui.lang
                        .text("Geprüft speichern unter", "Save reviewed target"),
                ) {
                    return glib::ControlFlow::Continue;
                }
            }
            3 => {
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                assert!(!cancelled.exists());
                assert_eq!(buffer_text(&doc.buffer), source);
                assert_eq!(doc.line_endings.pending(), Some(LineEnding::Lf));
                if !click(
                    ui.window.upcast_ref(),
                    ui.lang.text("Speichern unter …", "Save as …"),
                ) {
                    return glib::ControlFlow::Continue;
                }
            }
            6 => {
                if doc.saving.get() || doc.disk_path().as_ref() != Some(&target) {
                    return glib::ControlFlow::Continue;
                }
                let expected = LineEnding::Lf.convert(source);
                assert_eq!(buffer_text(&doc.buffer), expected);
                assert_eq!(
                    std::fs::read(&target).unwrap(),
                    format.encode(&expected).unwrap()
                );
                assert_eq!(std::fs::read(&path).unwrap(), original);
                assert!(doc.line_endings.pending().is_none());
                assert!(!doc.buffer.is_modified());
                if rich {
                    if doc
                        .rich
                        .borrow()
                        .as_ref()
                        .is_none_or(|editor| !editor.ready_for_saved_source())
                    {
                        return glib::ControlFlow::Continue;
                    }
                    mode_toggle(&doc, ui.lang).set_active(false);
                }
            }
            7 => {
                if doc.rich.borrow().is_some() {
                    return glib::ControlFlow::Continue;
                }
                crate::line_endings::select_for_test(&doc, LineEnding::Cr);
                if rich {
                    mode_toggle(&doc, ui.lang).set_active(true);
                }
            }
            11 => {
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                let expected = LineEnding::Cr.convert(source);
                assert_eq!(doc.disk_path().as_ref(), Some(&target));
                assert_eq!(buffer_text(&doc.buffer), expected);
                assert_eq!(
                    std::fs::read(&target).unwrap(),
                    format.encode(&expected).unwrap()
                );
                assert_eq!(std::fs::read(&path).unwrap(), original);
                assert!(doc.line_endings.pending().is_none());
                assert!(!doc.buffer.is_modified());
                if rich {
                    let Some(editor) = doc
                        .rich
                        .borrow()
                        .clone()
                        .filter(|ed| ed.ready_for_saved_source())
                    else {
                        return glib::ControlFlow::Continue;
                    };
                    js(
                        &editor,
                        "return JSON.stringify(fastraVisual.clipboardState());",
                        &reply,
                    );
                }
            }
            12 => {
                if rich {
                    let Some(value) = reply.borrow_mut().take() else {
                        return glib::ControlFlow::Continue;
                    };
                    assert_eq!(
                        value["markdown"].as_str(),
                        Some(LineEnding::Cr.convert(source).as_str())
                    );
                }
                println!("PASS EOL Save As rich={rich}: actual chooser/full converted preview/Cancel preserves pending and original; reviewed new path and same-path overwrite preserve encoding/BOM/source and rebase live Rich to exact CR");
                std::process::exit(0);
            }
            _ => unreachable!(),
        }
        phase.set(phase.get() + 1);
        glib::ControlFlow::Continue
    });
}
