//! Bildmutationen gehören der Anwendung bis einschließlich ihres letzten Main-Rückrufs.
use gtk::{gio, prelude::*};
use std::sync::atomic::{AtomicUsize, Ordering};
static PENDING: AtomicUsize = AtomicUsize::new(0);
pub(super) struct Pending {
    _hold: Option<gio::ApplicationHoldGuard>,
}
pub(super) fn begin() -> Pending {
    PENDING.fetch_add(1, Ordering::SeqCst);
    Pending {
        _hold: gio::Application::default().map(|app| app.hold()),
    }
}
impl Drop for Pending {
    fn drop(&mut self) {
        assert!(PENDING.fetch_sub(1, Ordering::SeqCst) > 0);
    }
}
pub(super) fn pending() -> bool {
    PENDING.load(Ordering::SeqCst) != 0
}
#[cfg(debug_assertions)]
pub(super) fn pending_count() -> usize {
    PENDING.load(Ordering::SeqCst)
}
pub(super) fn can_close(ui: &crate::Ui) -> bool {
    if !pending() {
        return true;
    }
    ui.status.set_text(ui.lang.text(
        "Bilddateiaktion läuft noch. Vor dem Schließen vollständig abschließen lassen.",
        "Image file operation is still running. Wait for completion before closing.",
    ));
    false
}
pub(super) fn background<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
    done: impl FnOnce(Result<T, String>) + 'static,
) {
    let owned = begin();
    crate::git_view::background(work, move |result| {
        let finish = move || {
            let _owned = owned;
            done(result);
        };
        #[cfg(debug_assertions)]
        if let Some(root) = std::env::var_os("FASTRA_QUIT_ASSET_IO_TEST_DIR") {
            let root = std::path::PathBuf::from(root);
            if root.join("pause-main").exists() {
                assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
                std::fs::write(
                    root.join("ready-main"),
                    b"worker returned; final Main callback pending",
                )
                .unwrap();
                let mut finish = Some(finish);
                let started = std::time::Instant::now();
                gtk::glib::timeout_add_local(std::time::Duration::from_millis(20), move || {
                    assert!(started.elapsed() < std::time::Duration::from_secs(30));
                    if root.join("release-main").exists() {
                        finish.take().unwrap()();
                        gtk::glib::ControlFlow::Break
                    } else {
                        gtk::glib::ControlFlow::Continue
                    }
                });
                return;
            }
        }
        finish();
    });
}
