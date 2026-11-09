use super::*;

fn enter(view: &webkit6::WebView) {
    let surface = view.native().unwrap().surface().unwrap();
    let symbol = unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"gdk_x11_surface_get_xid".as_ptr()) };
    assert!(!symbol.is_null());
    let getter: unsafe extern "C" fn(*mut std::ffi::c_void) -> libc::c_ulong =
        unsafe { std::mem::transmute(symbol) };
    let id = unsafe { getter(surface.as_ptr().cast()) }.to_string();
    std::thread::spawn(move || {
        assert!(std::process::Command::new("xdotool")
            .args([
                "windowfocus",
                "--sync",
                &id,
                "key",
                "--clearmodifiers",
                "Return"
            ])
            .status()
            .unwrap()
            .success());
    });
}

pub(crate) fn start(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let path = root.join("external-links.md");
    let original="# External links\n\n[Web](https://example.invalid/path?q=1)\n\n[Mail](mailto:person@example.invalid)\n\n[File blocked](file:///tmp/forbidden)\n";
    std::fs::write(&path, original).unwrap();
    let receipts = PathBuf::from(std::env::var_os("FASTRA_LINK_TEST_RECEIPT").unwrap());
    assert!(!receipts.exists());
    ui.load_path(path.clone());
    git_view::test_size(ui.window.upcast_ref());
    let stage = Cell::new(0);
    let preview_slot = RefCell::new(None::<Rc<MarkdownView>>);
    let document = RefCell::new(None::<Rc<Document>>);
    let answer = Rc::new(RefCell::new(None::<serde_json::Value>));
    let revision = Cell::new(0);
    let started = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            started.elapsed() < Duration::from_secs(35),
            "links stage{}: {}",
            stage.get(),
            ui.status.text()
        );
        let received = || {
            std::fs::read_to_string(&receipts)
                .unwrap_or_default()
                .lines()
                .map(|line| serde_json::from_str::<String>(line).unwrap())
                .collect::<Vec<_>>()
        };
        match stage.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|doc| doc.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                doc.markdown_toggle
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .set_active(true);
                let preview = doc.markdown.borrow().clone().unwrap();
                let manager = preview.view.user_content_manager().unwrap();
                manager.add_script(&webkit6::UserScript::new("addEventListener('load',()=>setTimeout(()=>{document.querySelector('a[href^=https]')?.click();globalThis.externalAutoDone=true},100))",webkit6::UserContentInjectedFrames::TopFrame,webkit6::UserScriptInjectionTime::Start,&[],&[]));
                revision.set(doc.revision.get());
                *document.borrow_mut() = Some(doc);
                *preview_slot.borrow_mut() = Some(preview);
                stage.set(1);
            }
            1 => {
                let a = answer.clone();
                preview_slot.borrow().as_ref().unwrap().inspect("return JSON.stringify({ready:!!window.fastraPreviewReady,auto:!!window.externalAutoDone,file:document.querySelectorAll('a[href^=file]').length})",move|v|*a.borrow_mut()=Some(v));
                stage.set(2);
            }
            2 => {
                let Some(value) = answer.borrow_mut().take() else {
                    return glib::ControlFlow::Continue;
                };
                if value["ready"] != true || value["auto"] != true {
                    stage.set(1);
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(value["file"], 0);
                assert!(received().is_empty());
                let preview = preview_slot.borrow().clone().unwrap();
                assert_eq!(preview.view.uri().as_deref(), Some(BASE));
                preview.view.grab_focus();
                let a = answer.clone();
                preview.inspect(
                    "document.querySelector('a[href^=https]').focus();return JSON.stringify(true)",
                    move |v| *a.borrow_mut() = Some(v),
                );
                stage.set(3);
            }
            3 => {
                if answer.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                enter(&preview_slot.borrow().as_ref().unwrap().view);
                stage.set(4);
            }
            4 => {
                let rows = received();
                if rows.is_empty() {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(rows, vec!["https://example.invalid/path?q=1"]);
                let a = answer.clone();
                preview_slot.borrow().as_ref().unwrap().inspect(
                    "document.querySelector('a[href^=mailto]').focus();return JSON.stringify(true)",
                    move |v| *a.borrow_mut() = Some(v),
                );
                stage.set(5);
            }
            5 => {
                if answer.borrow_mut().take().is_none() {
                    return glib::ControlFlow::Continue;
                }
                enter(&preview_slot.borrow().as_ref().unwrap().view);
                stage.set(6);
            }
            _ => {
                let rows = received();
                if rows.len() < 2 {
                    return glib::ControlFlow::Continue;
                }
                assert_eq!(
                    rows,
                    vec![
                        "https://example.invalid/path?q=1",
                        "mailto:person@example.invalid"
                    ]
                );
                let doc = document.borrow().clone().unwrap();
                assert_eq!(buffer_text(&doc.buffer), original);
                assert_eq!(doc.revision.get(), revision.get());
                assert!(!doc.buffer.is_modified());
                assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
                assert_eq!(
                    preview_slot
                        .borrow()
                        .as_ref()
                        .unwrap()
                        .view
                        .uri()
                        .as_deref(),
                    Some(BASE)
                );
                if let Some(dir) = std::env::var_os("FASTRA_TOOL_SCREENSHOTS") {
                    let dir = PathBuf::from(dir);
                    std::fs::create_dir_all(&dir).unwrap();
                    assert!(std::process::Command::new("import")
                        .args(["-window", "root"])
                        .arg(dir.join("external-links.png"))
                        .status()
                        .unwrap()
                        .success());
                }
                eprintln!("PASS explicit external links: actual keyboard gesture/default URI handler for https+mailto, automatic click and file target blocked, preview/source/revision/Undo baseline unchanged");
                std::process::exit(0);
            }
        }
        glib::ControlFlow::Continue
    });
}
