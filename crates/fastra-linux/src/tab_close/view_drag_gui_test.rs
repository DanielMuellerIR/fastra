//! Gegenprobe der nachträglichen Dokumentbindung aus echten Ladepfaden.
use super::*;
use sha2::{Digest, Sha256};
use std::{
    cell::{Cell, RefCell},
    io::{Read, Write},
    path::Path,
    time::{Duration, Instant},
};
fn digest(path: &Path) -> Vec<u8> {
    let mut file = std::fs::File::open(path).unwrap();
    let mut hash = Sha256::new();
    let mut chunk = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut chunk).unwrap();
        if n == 0 {
            break;
        }
        hash.update(&chunk[..n]);
    }
    hash.finalize().to_vec()
}
pub(super) fn run(ui: Rc<Ui>) {
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let case = std::env::var("FASTRA_TAB_FILE_DRAG_VIEWS_CASE").unwrap();
    let fixture = tempfile::tempdir_in(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap()).unwrap();
    let source = fixture.path().join(match case.as_str() {
        "png" => "Image # %.png",
        "hex" => "Binary # %.bin",
        "section" => "Large # %.txt",
        _ => panic!("unknown view case"),
    });
    match case.as_str() {
        "png" => {
            std::fs::write(&source, include_bytes!("../../tests/fixtures/pixel-1.png")).unwrap()
        }
        "hex" => std::fs::write(&source, [0, 1, 255, 0, 2, 3]).unwrap(),
        "section" => {
            let mut file = std::fs::File::create(&source).unwrap();
            let chunk = b"Section line, unchanged bytes.\r\n".repeat(2048);
            for _ in 0..550 {
                file.write_all(&chunk).unwrap();
            }
        }
        _ => unreachable!(),
    }
    if case == "section" {
        assert!(std::fs::metadata(&source).unwrap().len() > 32 * 1024 * 1024);
    }
    let expected = digest(&source);
    let ready = fixture.path().join("ready");
    let result = fixture.path().join("result");
    let mut child =
        std::process::Command::new(std::env::var_os("FASTRA_TAB_FILE_DRAG_RECEIVER").unwrap())
            .arg(&ready)
            .arg(&result)
            .spawn()
            .unwrap();
    ui.load_path(source.clone());
    super::super::git_view::test_size(ui.window.upcast_ref());
    let phase = Cell::new(0);
    let started = Instant::now();
    let baseline = RefCell::new(None::<(Rc<Document>, u64, String, bool)>);
    let fixture = RefCell::new(Some(fixture));
    glib::timeout_add_local(Duration::from_millis(50), move || {
        assert!(
            started.elapsed() < Duration::from_secs(25),
            "view drag {case} phase{}: {}",
            phase.get(),
            ui.status.text()
        );
        match phase.get() {
            0 => {
                let doc = ui
                    .documents
                    .borrow()
                    .iter()
                    .find(|doc| doc.disk_path().as_ref() == Some(&source))
                    .cloned();
                let Some(doc) = doc else {
                    return glib::ControlFlow::Continue;
                };
                if case == "png" {
                    assert!(doc.visual_view.borrow().is_some());
                } else {
                    assert!(doc.section_view.borrow().is_some());
                }
                let icon = super::drag_gui_test::handle(&ui, &doc);
                assert!(
                    icon.is_visible(),
                    "bound {case} source has no visible file-drag handle"
                );
                let snapshot = (
                    doc.clone(),
                    doc.revision.get(),
                    crate::buffer_text(&doc.buffer),
                    doc.buffer.can_undo(),
                );
                *baseline.borrow_mut() = Some(snapshot);
                phase.set(1);
            }
            1 if ready.is_file() => {
                let doc = baseline.borrow().as_ref().unwrap().0.clone();
                let icon = super::drag_gui_test::handle(&ui, &doc);
                if !icon.is_mapped() {
                    return glib::ControlFlow::Continue;
                }
                let target = std::fs::read_to_string(&ready).unwrap();
                target.trim().parse::<u64>().unwrap();
                if !super::super::git_view::try_capture(
                    ui.window.upcast_ref(),
                    &format!("tab-file-drag-view-{case}"),
                ) {
                    return glib::ControlFlow::Continue;
                }
                super::drag_gui_test::native_drag(
                    icon.upcast_ref(),
                    target.trim().into(),
                    "175".into(),
                    "75".into(),
                    ui.window.width(),
                );
                phase.set(2);
            }
            2 if result.is_file() => {
                let receipt = glib::KeyFile::new();
                receipt
                    .load_from_file(&result, glib::KeyFileFlags::NONE)
                    .unwrap();
                assert_eq!(
                    receipt.string("drop", "uri").unwrap(),
                    gio::File::for_path(&source).uri()
                );
                let bytes = glib::base64_decode(receipt.string("drop", "bytes").unwrap().as_str());
                assert_eq!(Sha256::digest(&bytes).as_slice(), expected.as_slice());
                assert_eq!(digest(&source), expected);
                let baseline = baseline.borrow();
                let (doc, revision, text, undo) = baseline.as_ref().unwrap();
                assert_eq!(doc.revision.get(), *revision);
                assert_eq!(crate::buffer_text(&doc.buffer), *text);
                assert_eq!(doc.buffer.can_undo(), *undo);
                assert!(!doc.buffer.is_modified());
                phase.set(3);
            }
            3 => {
                if let Some(status) = child.try_wait().unwrap() {
                    assert!(status.success());
                    fixture.borrow_mut().take();
                    println!("PASS real load-path tab-file drag: {case}, late model binding -> visible handle, independent native receiver exact URI and SHA256, unchanged disk/buffer/revision/Undo");
                    std::process::exit(0);
                }
            }
            _ => {}
        }
        glib::ControlFlow::Continue
    });
}
