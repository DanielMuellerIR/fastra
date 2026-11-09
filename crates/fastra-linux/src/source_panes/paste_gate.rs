use super::*;
use std::time::Instant;
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    ui.window.set_default_size(1100, 1000);
    let original = "abcdefghij\ncafé🙂\tend\r\n";
    ui.add_document("split-paste.txt", original);
    let doc = ui.active().unwrap();
    let mut all = Vec::new();
    super::gate::views(doc.container.upcast_ref(), &mut all);
    super::gate::named::<gtk::CheckButton>(
        doc.container.upcast_ref(),
        ui.lang.text("Quelltextansicht teilen", "Split source editor"),
    )
    .unwrap()
    .set_active(true);
    let kind = std::env::var("FASTRA_SPLIT_PASTE_CASE").unwrap();
    let valid = kind == "valid";
    let bytes = match kind.as_str() {
        "valid" => "é🙂\r\n二".as_bytes().to_vec(),
        "nul" => b"a\0lost".to_vec(),
        "total" => vec![b'\n'; 32 * 1024 * 1024],
        "input-total" => vec![b'\n'; 32 * 1024 * 1024 + 1],
        _ => vec![b'x'; 65537],
    };
    let stage = Cell::new(0);
    let start = Instant::now();
    let pause = Cell::new(start);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            start.elapsed().as_secs() < 45,
            "paste {kind} stage{} status{}",
            stage.get(),
            ui.status.text()
        );
        if pause.get().elapsed() < Duration::from_millis(450) {
            return glib::ControlFlow::Continue;
        }
        super::gate::same(&doc, &all, &format!("paste-{kind}-{}", stage.get()));
        match stage.get() {
            0 => {
                all[1]
                    .clipboard()
                    .set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
                        "text/plain;charset=utf-8",
                        &glib::Bytes::from_owned(bytes.clone()),
                    )))
                    .unwrap();
                crate::git_view::test_click(&all[0], &["ctrl+Home", "Right", "shift+Right"]);
            }
            1 => {
                if kind == "readonly" {
                    all[1].set_editable(false);
                }
                if kind == "close" {
                    doc.close_pending.set(true);
                }
                crate::git_view::test_click(
                    &all[1],
                    &[
                        "ctrl+Home",
                        "Right",
                        "Right",
                        "shift+Right",
                        "shift+Right",
                        "shift+Right",
                        "shift+Right",
                        "shift+Right",
                        "shift+Right",
                        "ctrl+v",
                    ],
                );
            }
            2 => {
                if kind != "readonly" && kind != "close" && linear_paste::test_counts().1 < 1 {
                    return glib::ControlFlow::Continue;
                }
                if valid {
                    assert_eq!(buffer_text(&doc.buffer), "abé🙂\r\n二ij\ncafé🙂\tend\r\n");
                    assert_eq!(doc.revision.get(), 2);
                    crate::git_view::test_click(&all[1], &["ctrl+z"]);
                } else {
                    assert_eq!(
                        buffer_text(&doc.buffer),
                        original,
                        "reject mutated canonical"
                    );
                    assert_eq!(doc.revision.get(), 0);
                    assert!(!doc.buffer.can_undo());
                    assert!(!all[1].buffer().can_undo());
                    assert_eq!(
                        all[1]
                            .buffer()
                            .selection_bounds()
                            .map(|(a, b)| (a.offset(), b.offset())),
                        Some((2, 8))
                    );
                    println!("SPLIT PASTE {kind} PASS complete result rejected before source/canonical mutation, selection+history retained; status={}",ui.status.text());
                    doc.close_pending.set(false);
                    ui.window.application().unwrap().quit();
                    return glib::ControlFlow::Break;
                }
            }
            3 => {
                assert_eq!(buffer_text(&doc.buffer), original);
                assert!(all[0].buffer().can_redo() && all[1].buffer().can_redo());
                crate::git_view::test_click(&all[1], &["ctrl+shift+z"]);
            }
            _ => {
                assert_eq!(buffer_text(&doc.buffer), "abé🙂\r\n二ij\ncafé🙂\tend\r\n");
                println!("SPLIT PASTE valid PASS Unicode native clipboard exact bytes + paired native keyboard undo/redo");
                ui.window.application().unwrap().quit();
                return glib::ControlFlow::Break;
            }
        }
        stage.set(stage.get() + 1);
        pause.set(Instant::now());
        glib::ControlFlow::Continue
    });
}
