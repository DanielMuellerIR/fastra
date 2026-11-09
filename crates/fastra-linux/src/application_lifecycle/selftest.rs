//! Beobachtung für getrennte Prozesse in einer privaten D-Bus-/Xvfb-Sitzung.
use super::*;
use std::{os::unix::ffi::OsStrExt, path::PathBuf, time::Duration};

pub(super) fn install(
    app: &gtk::Application,
    windows: &Rc<RefCell<Vec<Rc<Ui>>>>,
    hold: &Rc<RefCell<Option<gio::ApplicationHoldGuard>>>,
) {
    let Some(root) = std::env::var_os("FASTRA_LIFECYCLE_SELFTEST_DIR") else {
        return;
    };
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let root = PathBuf::from(root);
    assert!(root.is_absolute() && root.is_dir());
    let shutdown_root = root.clone();
    let weak_app = app.downgrade();
    let states = Rc::downgrade(windows);
    let held = Rc::downgrade(hold);
    glib::timeout_add_local(Duration::from_millis(50), move || {
        let (Some(app), Some(states), Some(held)) =
            (weak_app.upgrade(), states.upgrade(), held.upgrade())
        else {
            return glib::ControlFlow::Break;
        };
        let windows: Vec<_> = states.borrow().iter().map(|ui| {
            let documents: Vec<_> = ui.documents.borrow().iter().map(|doc| {
                serde_json::json!({
                    "pathBytes": doc.disk_path().map(|p| p.as_os_str().as_bytes().to_vec()),
                    "text": doc.buffer.text(&doc.buffer.start_iter(), &doc.buffer.end_iter(), true).as_str(),
                    "dirty": doc.buffer.is_modified(),"readOnly":doc.is_read_only(),"section":doc.section_view.borrow().is_some(),"visual":doc.visual_view.borrow().is_some(),
                    "revision": doc.revision.get(),"saving":doc.saving.get(),"rich":doc.is_rich_active(),
                    "active":ui.active().is_some_and(|active|Rc::ptr_eq(&active,doc)),
                    "tab":Some(crate::chrome::tab_header(ui, doc)).and_then(|widget|widget.compute_bounds(&ui.window)).map(|bounds|serde_json::json!({"x":bounds.x()+bounds.width()/2.,"y":bounds.y()+bounds.height()/2.})),
                })
            }).collect();
            serde_json::json!({"xid":super::quit_observe::xid(ui.window.upcast_ref()),"visible": ui.window.is_visible(), "width":ui.window.width(),"height":ui.window.height(),"maximized":ui.window.is_maximized(),"position":crate::editor_options::startup::observed_position(&ui.window),"project":crate::project_view::requested_path(ui).map(|path|path.as_os_str().as_bytes().to_vec()), "documents": documents,"status":ui.status.text().as_str(),"closeActive":crate::close_protocol::active(ui),"sessionEnabled":ui.session.borrow().as_ref().is_some_and(|state|state.is_enabled()),"session":ui.session.borrow().as_ref().map(|state|state.close_observation())})
        }).collect();
        let state = serde_json::json!({"printing":crate::editor_options::printing::observation(),"startup":crate::editor_options::startup::observation(),"held": held.borrow().is_some(), "windows": windows,"native":super::quit_observe::windows(),"pendingAssetIO":crate::asset_io::pending_count()});
        std::fs::write(root.join("state.tmp"), serde_json::to_vec(&state).unwrap()).unwrap();
        std::fs::rename(root.join("state.tmp"), root.join("state.json")).unwrap();
        if root.join("quit").exists() {
            // Native quit muss auch einen zuvor gehaltenen Dienst beenden.
            app.quit();
            return glib::ControlFlow::Break;
        }
        glib::ControlFlow::Continue
    });
    let windows = windows.clone();
    let hold = hold.clone();
    app.connect_shutdown(move |_| {
        assert!(
            windows.borrow().is_empty(),
            "ordinary registry retained after shutdown"
        );
        assert!(
            hold.borrow().is_none(),
            "service hold retained after shutdown"
        );
        std::fs::write(
            shutdown_root.join("shutdown.json"),
            br#"{"registryEmpty":true,"holdReleased":true}"#,
        )
        .unwrap();
        println!("FASTRA application lifecycle shutdown: registry cleared, hold released");
    });
}
