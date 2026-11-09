use super::*;
use std::time::Instant;
fn views(root: &gtk::Widget, out: &mut Vec<sourceview5::View>) {
    if let Some(v) = root.downcast_ref::<sourceview5::View>() {
        out.push(v.clone());
    }
    let mut child = root.first_child();
    while let Some(c) = child {
        views(&c, out);
        child = c.next_sibling();
    }
}
fn split(root: &gtk::Widget) -> Option<gtk::CheckButton> {
    if let Some(b) = root.downcast_ref::<gtk::CheckButton>().filter(|b| {
        matches!(
            b.label().as_deref(),
            Some("Split source editor" | "Quelltextansicht teilen")
        )
    }) {
        return Some(b.clone());
    }
    let mut child = root.first_child();
    while let Some(c) = child {
        if let Some(b) = split(&c) {
            return Some(b);
        }
        child = c.next_sibling();
    }
    None
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(1100, 1000);
    let mut original = format!("{}\n", "a".repeat(32767)).repeat(1024);
    original.pop();
    let size = original.len();
    assert_eq!(size, fastra_document::EDITABLE_BYTES - 1);
    let path = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap())
        .join("native-source-size.txt");
    std::fs::write(&path, &original).unwrap();
    ui.load_path(path.clone());
    let secondary = std::env::var_os("FASTRA_SIZE_SECONDARY").is_some();
    let stage = Cell::new(0);
    let undo_count = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    let loaded = RefCell::new(None::<Rc<Document>>);
    let selected = RefCell::new(None::<sourceview5::View>);
    let observed = RefCell::new(None::<serde_json::Value>);
    glib::timeout_add_local(Duration::from_millis(100), move || {
        assert!(
            start.elapsed().as_secs() < 100,
            "size source stage{} status{}",
            stage.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(1000) {
            return glib::ControlFlow::Continue;
        }
        match stage.get() {
            0 => {
                let Some(doc) = ui
                    .active()
                    .filter(|d| d.disk_path().as_ref() == Some(&path))
                else {
                    return glib::ControlFlow::Continue;
                };
                assert!(!doc.is_read_only());
                if secondary {
                    split(doc.container.upcast_ref()).unwrap().set_active(true);
                }
                *loaded.borrow_mut() = Some(doc);
            }
            1 => {
                let doc = loaded.borrow().as_ref().unwrap().clone();
                let mut all = Vec::new();
                views(doc.container.upcast_ref(), &mut all);
                let view = all[usize::from(secondary)].clone();
                if !view.is_mapped() || view.width() <= 0 || view.height() <= 0 {
                    return glib::ControlFlow::Continue;
                }
                view.grab_focus();
                *selected.borrow_mut() = Some(view.clone());
                git_view::test_click(&view, &["ctrl+End", "x"]);
            }
            2 => {
                let doc = loaded.borrow().as_ref().unwrap().clone();
                if doc.buffer.char_count() as usize != size + 1 {
                    return glib::ControlFlow::Continue;
                }
                let view = selected.borrow().as_ref().unwrap().clone();
                assert!(view.has_focus());
                eprintln!(
                    "SIZE first native key received bytes={} rev={}",
                    doc.buffer.char_count(),
                    doc.revision.get()
                );
                git_view::test_click(&view, &["ctrl+End", "y"]);
            }
            3 => {
                let doc = loaded.borrow().as_ref().unwrap().clone();
                if doc.buffer.char_count() as usize != size + 2 {
                    return glib::ControlFlow::Continue;
                }
                let view = selected.borrow().as_ref().unwrap().clone();
                let text = buffer_text(&doc.buffer);
                let result = serde_json::json!({"secondary":secondary,"original_bytes":size,"typed_bytes":text.len(),"revision":doc.revision.get(),"focus":view.has_focus(),"editable":view.is_editable(),"validation_rejects":text_limits::validate(&text,ui.lang).is_err(),"undo":doc.buffer.can_undo(),"dirty":doc.buffer.is_modified()});
                *observed.borrow_mut() = Some(result);
                git_view::test_click(&ui.save, &[]);
            }
            4 => {
                let doc = loaded.borrow().as_ref().unwrap().clone();
                if doc.saving.get() {
                    return glib::ControlFlow::Continue;
                }
                let mut result = observed.borrow_mut();
                let result = result.as_mut().unwrap();
                result["disk_bytes_after_real_save"] =
                    std::fs::metadata(&path).unwrap().len().into();
                result["save_status"] = ui.status.text().to_string().into();
                result["dirty_after_save"] = doc.buffer.is_modified().into();
                git_view::test_click(selected.borrow().as_ref().unwrap(), &["ctrl+z"]);
                undo_count.set(1);
            }
            _ => {
                let doc = loaded.borrow().as_ref().unwrap().clone();
                let restored = buffer_text(&doc.buffer) == original;
                if !restored && undo_count.get() < 3 {
                    git_view::test_click(selected.borrow().as_ref().unwrap(), &["ctrl+z"]);
                    undo_count.set(undo_count.get() + 1);
                    pause.set(Instant::now());
                    return glib::ControlFlow::Continue;
                }
                let mut result = observed.borrow_mut().take().unwrap();
                result["undo_restored_original"] = restored.into();
                result["undo_count"] = undo_count.get().into();
                result["dirty_after_undo"] = doc.buffer.is_modified().into();
                println!("SOURCE_SIZE_ACTUAL {result}");
                assert!(restored);
                std::fs::write(
                    std::path::PathBuf::from(std::env::var_os("FASTRA_TOOL_SCREENSHOTS").unwrap())
                        .join("source-size.json"),
                    serde_json::to_vec_pretty(&result).unwrap(),
                )
                .unwrap();
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
        }
        stage.set(stage.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
