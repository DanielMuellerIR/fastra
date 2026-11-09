use super::super::async_gui_test::{capture, input, inspect, named, reveal, wait, widgets};
use super::*;
use crate::{buffer_text, git_view as support};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
thread_local! {static RUNNING:Cell<bool>=const{Cell::new(false)};}
const TEXT: &str = "# Preview\n\nAlpha café 😀.\n";
fn settings(app: &gtk::Application) -> Option<gtk::Window> {
    app.windows()
        .into_iter()
        .find(|w| w.widget_name() == "fastra-global-settings")
}
async fn saved(state: &State) {
    wait("preference write", || {
        !state.busy.get() && !state.queued.get()
    })
    .await;
}
fn preview_on(doc: &Document) -> bool {
    doc.markdown_toggle.borrow().as_ref().unwrap().is_active()
}
async fn rendered(doc: &Document) {
    wait("mapped preview", || {
        doc.markdown.borrow().as_ref().is_some_and(|v| {
            v.visible.get() && v.view.is_mapped() && v.print_token(doc.revision.get()).is_some()
        })
    })
    .await;
    let view = doc.markdown.borrow().as_ref().unwrap().view.clone();
    let began = Instant::now();
    loop {
        let value=inspect(&view,"return JSON.stringify(window.fastraPreviewReady===true&&document.querySelector('p')?.textContent.includes('Alpha'));").await;
        if value == true {
            break;
        }
        assert!(began.elapsed() < Duration::from_secs(10));
        glib::timeout_future(Duration::from_millis(40)).await;
    }
}
fn select(ui: &Ui, doc: &Rc<Document>) {
    let index = ui
        .documents
        .borrow()
        .iter()
        .position(|d| Rc::ptr_eq(d, doc))
        .unwrap();
    ui.tabs.set_current_page(Some(index as u32));
}
fn toolbar(ui: &Ui) -> gtk::Button {
    widgets(&ui.window)
        .into_iter()
        .find_map(|w| {
            w.downcast::<gtk::Button>().ok().filter(|b| {
                b.tooltip_text().as_deref()
                    == Some(ui.lang.text(
                        "Markdown-Vorschau ein-/ausblenden",
                        "Toggle Markdown preview",
                    ))
            })
        })
        .unwrap()
}
fn unchanged(doc: &Document, revision: u64) {
    assert_eq!(buffer_text(&doc.buffer), TEXT);
    assert_eq!(doc.revision.get(), revision);
    assert!(!doc.buffer.is_modified() && !doc.buffer.can_undo());
}
const RICH:&str="return JSON.stringify({source:fastraVisual.markdown(),selection:getSelection().toString(),undo:document.queryCommandEnabled('undo')});";
pub(super) fn run(ui: Rc<Ui>) {
    if RUNNING.with(|r| r.replace(true)) {
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let task = glib::MainContext::default().spawn_local(scenario(ui));
    glib::MainContext::default().spawn_local(async move {
        if let Err(error) = task.await {
            eprintln!("Markdown preview selftest failed: {error:?}");
            std::process::exit(1);
        }
    });
}
async fn scenario(ui: Rc<Ui>) {
    let mode = std::env::var("FASTRA_MARKDOWN_PREVIEW_SELFTEST").unwrap();
    let restore = std::env::var("FASTRA_MARKDOWN_PREVIEW_PHASE").as_deref() == Ok("restore");
    let root = PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let state = state();
    let app = ui.window.application().unwrap();
    wait("preference loaded or explicit error", || {
        state.loaded.get() || state.error.borrow().is_some()
    })
    .await;
    ui.add_document("one.md", TEXT);
    let one = ui.active().unwrap();
    let revision = one.revision.get();
    support::test_size(ui.window.upcast_ref());
    if restore {
        assert!(state.loaded.get() && !state.shown.get());
        glib::timeout_future(Duration::from_millis(300)).await;
        assert!(!preview_on(&one));
        assert!(one.markdown.borrow().is_none());
        unchanged(&one, revision);
        println!("FASTRA_TOOL_SELFTEST_OK markdown-preview fresh-process false preference");
        app.quit();
        return;
    }
    if mode == "corrupt" {
        let path = config_root()
            .unwrap()
            .join("fastra-editor/markdown-preview.json");
        let original = std::fs::read(&path).unwrap();
        assert!(!state.loaded.get());
        input(&toolbar(&ui), &[], true).await;
        assert!(!preview_on(&one));
        assert!(one.markdown.borrow().is_none());
        assert!(ui
            .status
            .text()
            .contains(ui.lang.text("nicht geladen", "not loaded")));
        assert_eq!(std::fs::read(&path).unwrap(), original);
        app.activate_action("settings", None);
        wait("settings", || settings(&app).is_some()).await;
        let window = settings(&app).unwrap();
        let switch: gtk::Switch = named(&window, "fastra-markdown-preview-default");
        assert!(!switch.is_sensitive());
        reveal(&switch);
        capture(&window, "markdown-preview-corrupt").await;
        // Die Fixture simuliert eine ausdrückliche externe Reparatur. Der
        // Produktfehlerpfad musste die ursprünglichen Bytes zuvor erhalten.
        std::fs::write(root.join("corrupt-preserved"), &original).unwrap();
        std::fs::write(&path, br#"{"version":1,"shown":false}"#).unwrap();
        let retry: gtk::Button = named(&window, "fastra-markdown-preview-retry");
        reveal(&retry);
        glib::timeout_future(Duration::from_millis(150)).await;
        input(&retry, &[], true).await;
        wait("explicit load retry", || {
            state.loaded.get() && !state.busy.get()
        })
        .await;
        assert!(!state.shown.get());
        assert!(switch.is_sensitive() && !switch.is_active());
        assert!(!preview_on(&one));
        unchanged(&one, revision);
        println!(
            "FASTRA_TOOL_SELFTEST_OK markdown-preview corrupt retained and explicit load retry"
        );
        app.quit();
        return;
    }
    assert!(state.shown.get());
    assert!(!config_root()
        .unwrap()
        .join("fastra-editor/markdown-preview.json")
        .exists());
    ui.add_document("inactive.md", TEXT);
    let inactive = ui.active().unwrap();
    ui.add_document("note.txt", TEXT);
    let plain = ui.active().unwrap();
    select(&ui, &one);
    let second = crate::build(&app);
    second.add_document("rich.md", TEXT);
    let rich_doc = second.active().unwrap();
    support::test_size(second.window.upcast_ref());
    rendered(&one).await;
    rendered(&rich_doc).await;
    assert!(preview_on(&one) && preview_on(&rich_doc));
    assert!(
        inactive.markdown.borrow().is_none(),
        "inactive tab must not start a hidden WebView"
    );
    assert!(plain.markdown.borrow().is_none());
    unchanged(&one, revision);
    let inactive_revision = inactive.revision.get();
    let plain_revision = plain.revision.get();
    rich_doc
        .rich_toggle
        .borrow()
        .as_ref()
        .unwrap()
        .set_active(true);
    wait("Rich ready", || {
        rich_doc
            .rich
            .borrow()
            .as_ref()
            .is_some_and(|r| r.ready_for_saved_source())
    })
    .await;
    let rich = rich_doc.rich.borrow().clone().unwrap();
    assert!(!preview_on(&rich_doc));
    assert!(
        state.shown.get(),
        "Rich internal preview shutdown must not persist false"
    );
    second.window.present();
    assert!(rich.view.grab_focus());
    assert_eq!(inspect(&rich.view,"const root=document.getElementById('fastra-visual'),p=root.querySelector('p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);root.focus();return JSON.stringify(true);").await,true);
    let received = support::test_type(&rich.view, " edited");
    wait("native Rich typing", || received.try_recv().is_ok()).await;
    wait("Rich source sync", || {
        buffer_text(&rich_doc.buffer).contains(" edited") && rich.ready_for_saved_source()
    })
    .await;
    inspect(&rich.view,"const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,5);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);").await;
    let baseline = inspect(&rich.view, RICH).await;
    assert_eq!(baseline["selection"], "Alpha");
    assert_eq!(baseline["undo"], true);
    let rich_revision = rich_doc.revision.get();
    let rich_source = buffer_text(&rich_doc.buffer);
    app.activate_action("settings", None);
    wait("settings", || settings(&app).is_some()).await;
    let window = settings(&app).unwrap();
    let switch: gtk::Switch = named(&window, "fastra-markdown-preview-default");
    reveal(&switch);
    glib::timeout_future(Duration::from_millis(200)).await;
    assert!(switch.is_active());
    let lock = if mode == "busy" {
        Some(
            super::super::store::Store::open(&config_root().unwrap())
                .unwrap()
                .wait_lock()
                .unwrap(),
        )
    } else {
        None
    };
    input(&switch, &[], true).await;
    saved(&state).await;
    assert!(!state.shown.get());
    assert!(!preview_on(&one));
    assert!(!preview_on(&rich_doc));
    assert!(rich_doc.is_rich_active());
    assert_eq!(inspect(&rich.view, RICH).await, baseline);
    assert_eq!(rich_doc.revision.get(), rich_revision);
    assert_eq!(buffer_text(&rich_doc.buffer), rich_source);
    if let Some(lock) = lock {
        assert!(state.error.borrow().is_some());
        assert!(!super::pending());
        assert!(state.hold.borrow().is_none());
        assert!(store::load(&config_root().unwrap()).unwrap());
        capture(&window, "markdown-preview-save-error").await;
        drop(lock);
        let retry: gtk::Button = named(&window, "fastra-markdown-preview-retry");
        reveal(&retry);
        glib::timeout_future(Duration::from_millis(150)).await;
        input(&retry, &[], true).await;
        saved(&state).await;
    }
    assert!(state.error.borrow().is_none());
    assert!(!store::load(&config_root().unwrap()).unwrap());
    capture(&window, "markdown-preview-off").await;
    window.close();
    glib::timeout_future(Duration::from_millis(200)).await;
    inspect(&rich.view,"document.getElementById('fastra-visual').focus();document.execCommand('undo');fastraVisual.flush();return JSON.stringify(true);").await;
    wait("Rich native undo", || {
        buffer_text(&rich_doc.buffer) == TEXT && rich.ready_for_saved_source()
    })
    .await;
    rich_doc
        .rich_toggle
        .borrow()
        .as_ref()
        .unwrap()
        .set_active(false);
    wait("held source transition", || {
        rich_doc.rich.borrow().is_none()
    })
    .await;
    assert!(
        !preview_on(&rich_doc),
        "Source return must use current false preference, not captured true"
    );
    assert!(!state.shown.get());
    assert_eq!(buffer_text(&rich_doc.buffer), TEXT);
    select(&ui, &inactive);
    glib::timeout_future(Duration::from_millis(200)).await;
    assert!(!preview_on(&inactive));
    assert!(inactive.markdown.borrow().is_none());
    input(&toolbar(&ui), &[], true).await;
    saved(&state).await;
    assert!(state.shown.get());
    rendered(&inactive).await;
    rendered(&rich_doc).await;
    select(&ui, &plain);
    glib::timeout_future(Duration::from_millis(100)).await;
    assert!(!toolbar(&ui).is_sensitive());
    assert!(plain.markdown.borrow().is_none());
    unchanged(&plain, plain_revision);
    plain.buffer.set_language(
        sourceview5::LanguageManager::default()
            .language("markdown")
            .as_ref(),
    );
    rendered(&plain).await;
    plain.buffer.set_language(None);
    wait("non-Markdown preview closes", || {
        !preview_on(&plain) && !plain.markdown.borrow().as_ref().unwrap().visible.get()
    })
    .await;
    assert!(state.shown.get());
    unchanged(&plain, plain_revision);
    select(&ui, &one);
    rendered(&one).await;
    unchanged(&one, revision);
    unchanged(&inactive, inactive_revision);
    second.add_document("new.md", TEXT);
    let new = second.active().unwrap();
    rendered(&new).await;
    assert!(preview_on(&new));
    capture(ui.window.upcast_ref(), "markdown-preview-global-on").await;
    capture(second.window.upcast_ref(), "markdown-preview-new").await;
    input(&toolbar(&second), &[], true).await;
    saved(&state).await;
    assert!(!state.shown.get());
    assert!(!preview_on(&new) && !preview_on(&one));
    assert!(!store::load(&config_root().unwrap()).unwrap());
    select(&ui, &inactive);
    glib::timeout_future(Duration::from_millis(100)).await;
    assert!(!preview_on(&inactive));
    unchanged(&inactive, inactive_revision);
    println!("FASTRA_TOOL_SELFTEST_OK markdown-preview global/default-on/lazy-inactive/Settings/toolbar/two-windows/new-tabs/non-Markdown/Rich-selection-undo/current-policy-source-return/persistence");
    app.quit();
}
