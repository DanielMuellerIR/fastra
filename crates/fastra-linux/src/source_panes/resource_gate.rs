use super::*;
use std::time::Instant;
fn memory() -> serde_json::Value {
    let text = std::fs::read_to_string("/proc/self/smaps_rollup").unwrap();
    let get = |name: &str| {
        text.lines()
            .find(|line| line.starts_with(name))
            .unwrap()
            .split_whitespace()
            .nth(1)
            .unwrap()
            .parse::<u64>()
            .unwrap()
    };
    serde_json::json!({"rss_kib":get("Rss:"),"pss_kib":get("Pss:"),"private_dirty_kib":get("Private_Dirty:")})
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let unit = format!("{}\n", "a".repeat(1023));
    let text = unit.repeat(4096);
    assert_eq!(text.len(), 4 * 1024 * 1024);
    text_limits::validate(&text, ui.lang).unwrap();
    ui.add_document("split-resource.txt", &text);
    let doc = ui.active().unwrap();
    let pane = doc.source_panes.borrow().as_ref().unwrap().clone();
    let single = std::env::var_os("FASTRA_SPLIT_SINGLE_HISTORY_MEASUREMENT").is_some();
    if single {
        pane.buffers[1].set_enable_undo(false);
    }
    let stage = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    let before = RefCell::new(None);
    glib::timeout_add_local(Duration::from_millis(80), move || {
        assert!(
            start.elapsed().as_secs() < 80,
            "resource stage{}",
            stage.get()
        );
        if pause.get().elapsed() < Duration::from_millis(250) {
            return glib::ControlFlow::Continue;
        }
        assert_eq!(buffer_text(&pane.buffers[0]), buffer_text(&pane.buffers[1]));
        match stage.get() {
            0 => {
                *before.borrow_mut() = Some(memory());
                assert!(!pane.views[1].upgrade().unwrap().is_mapped());
            }
            1..=8 => {
                let c = char::from(b'a' + stage.get() as u8);
                let value = format!("{}\n", c.to_string().repeat(1023)).repeat(4096);
                replace_result(&doc.buffer, &value);
            }
            9 => {
                let after = memory();
                let result = serde_json::json!({"mode":if single{"measurement-only secondary history disabled"}else{"actual symmetric native histories"},"text_bytes_per_buffer":4*1024*1024,"full_replacements":8,"split_visible":pane.views[1].upgrade().unwrap().is_mapped(),"undo_levels":[pane.buffers[0].max_undo_levels(),pane.buffers[1].max_undo_levels()],"can_undo":[pane.buffers[0].can_undo(),pane.buffers[1].can_undo()],"before":before.borrow().as_ref().unwrap(),"after":after});
                println!("SPLIT RESOURCE {result}");
                std::fs::write(
                    std::path::PathBuf::from(std::env::var_os("FASTRA_TOOL_SCREENSHOTS").unwrap())
                        .join("resource.json"),
                    serde_json::to_vec_pretty(&result).unwrap(),
                )
                .unwrap();
                if !single {
                    assert!(
                        pane.buffers[1].can_undo(),
                        "secondary history built even with Split off"
                    );
                    doc.buffer.undo();
                    assert_eq!(buffer_text(&pane.buffers[0]), buffer_text(&pane.buffers[1]));
                    assert!(pane.buffers.iter().all(|b| b.can_redo()));
                }
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
            _ => unreachable!(),
        }
        stage.set(stage.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
