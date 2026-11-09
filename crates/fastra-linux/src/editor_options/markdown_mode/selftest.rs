use super::super::async_gui_test::{capture, input, inspect, named, reveal, wait, widgets};
use super::*;
use crate::{buffer_text, git_view as support};
use std::time::Duration;
thread_local! {static RUNNING:Cell<bool>=const{Cell::new(false)};}
const TEXT: &str = "# Mode\n\nAlpha café 😀.\n";
async fn settled(state: &State) {
    wait("mode transaction and preference write", || {
        !state.transaction.get() && !state.busy.get() && !state.queued.get()
    })
    .await;
}
fn unchanged(doc: &Document, revision: u64) {
    assert_eq!(buffer_text(&doc.buffer), TEXT);
    assert_eq!(doc.revision.get(), revision);
    assert!(!doc.buffer.is_modified() && !doc.buffer.can_undo());
}
fn settings(app: &gtk::Application) -> Option<gtk::Window> {
    app.windows()
        .into_iter()
        .find(|w| w.widget_name() == "fastra-global-settings")
}
async fn rich(doc: &Document) -> Rc<crate::rich_editor::RichEditor> {
    wait("Rich ready", || {
        doc.rich
            .borrow()
            .as_ref()
            .is_some_and(|r| r.ready_for_saved_source())
    })
    .await;
    doc.rich.borrow().clone().unwrap()
}
async fn source(doc: &Document) {
    wait("source mode", || !doc.is_rich_active()).await;
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
fn geometry(window: &gtk::Window) {
    for widget in widgets(window)
        .into_iter()
        .filter(|w| w.is_mapped() && (w.is::<gtk::Label>() || w.is::<gtk::Button>()))
    {
        let bounds = widget.compute_bounds(window).unwrap();
        if let Some(label) = widget.downcast_ref::<gtk::Label>() {
            let (ink, logical) = label.layout().pixel_extents();
            assert!(
                ink.y() >= -1 && ink.y() + ink.height() <= logical.height() + 1,
                "choice glyph ink must fit line height: {} ink={ink:?} logical={logical:?}",
                label.text()
            );
        }

        assert!(
            bounds.x() >= -1.
                && bounds.y() >= -1.
                && bounds.x() + bounds.width() <= window.width() as f32 + 1.
                && bounds.y() + bounds.height() <= window.height() as f32 + 1.,
            "choice widget{} outside {}x{}: {bounds:?}",
            widget.widget_name(),
            window.width(),
            window.height()
        );
    }
}
pub(super) fn run(ui: Rc<Ui>) {
    if RUNNING.with(|r| r.replace(true)) {
        return;
    }
    assert_eq!(std::env::var("FASTRA_ISOLATED_DISPLAY").as_deref(), Ok("1"));
    let task = glib::MainContext::default().spawn_local(scenario(ui));
    glib::MainContext::default().spawn_local(async move {
        if let Err(error) = task.await {
            eprintln!("Markdown mode selftest failed: {error:?}");
            std::process::exit(1);
        }
    });
}
async fn scenario(ui: Rc<Ui>) {
    let mode = std::env::var("FASTRA_MARKDOWN_MODE_SELFTEST").unwrap();
    let restore = std::env::var("FASTRA_MARKDOWN_MODE_PHASE").as_deref() == Ok("restore");
    let state = state();
    let app = ui.window.application().unwrap();
    wait("mode load or explicit error", || {
        state.loaded.get() || state.error.borrow().is_some()
    })
    .await;
    ui.add_document("mode.md", TEXT);
    let doc = ui.active().unwrap();
    let revision = doc.revision.get();
    support::test_size(ui.window.upcast_ref());
    if restore {
        let expected = std::env::var("FASTRA_MARKDOWN_MODE_EXPECT").as_deref() == Ok("true");
        assert_eq!(state.choice.get(), Some(expected));
        if expected {
            rich(&doc).await;
        } else {
            source(&doc).await;
        }
        glib::timeout_future(Duration::from_millis(250)).await;
        assert!(state.dialog.borrow().is_none());
        assert_eq!(doc.is_rich_active(), expected);
        assert!(doc.markdown_visual_override.get().is_none());
        unchanged(&doc, revision);
        println!("FASTRA_TOOL_SELFTEST_OK markdown-mode fresh-process choice={expected}");
        app.quit();
        return;
    }
    if mode.starts_with("choice") {
        assert!(state.choice.get().is_none());
        assert!(!config_root()
            .unwrap()
            .join("fastra-editor/markdown-mode.json")
            .exists());
        let choice_window = || {
            app.windows()
                .into_iter()
                .find(|w| w.widget_name() == "fastra-markdown-mode-choice")
        };
        wait("first mode choice", || {
            choice_window().is_some_and(|w| w.is_mapped() && w.width() > 0)
        })
        .await;
        let window = choice_window().unwrap();
        if mode == "choice-quit" {
            let _received = support::test_input_completed(&window, &["ctrl+shift+q"], false);
            glib::timeout_future(Duration::from_secs(8)).await;
            panic!("normal Quit must close the first-mode dialog without saving a choice");
        }
        let second = crate::build(&app);
        second.add_document("other.md", TEXT);
        let other = second.active().unwrap();
        support::test_size(second.window.upcast_ref());
        glib::timeout_future(Duration::from_millis(250)).await;
        assert_eq!(
            app.windows()
                .iter()
                .filter(|w| w.widget_name() == "fastra-markdown-mode-choice")
                .count(),
            1
        );
        let scale = super::super::zoom::ui_scale();
        assert!((f64::from(window.width()) - 470. * scale).abs() < 8.);
        geometry(&window);
        capture(&window, "markdown-mode-first-choice").await;
        input(&window, &["Escape"], false).await;
        assert!(window.is_visible() && state.choice.get().is_none());
        let visual = mode.contains("visual");
        input(
            &window,
            &[if visual { "Return" } else { "alt+Return" }],
            false,
        )
        .await;
        settled(&state).await;
        assert_eq!(state.choice.get(), Some(visual));
        assert_eq!(store::load(&config_root().unwrap()).unwrap(), Some(visual));
        assert!(state.dialog.borrow().is_none());
        if visual {
            rich(&doc).await;
            rich(&other).await;
        } else {
            source(&doc).await;
            source(&other).await;
        }
        unchanged(&doc, revision);
        assert!(doc.markdown_visual_override.get().is_none());
        assert!(other.markdown_visual_override.get().is_none());
        input(&ui.window, &["ctrl+alt+shift+m"], false).await;
        if visual {
            source(&doc).await;
        } else {
            rich(&doc).await;
        }
        assert_eq!(doc.markdown_visual_override.get(), Some(!visual));
        assert_eq!(state.choice.get(), Some(visual));
        assert_eq!(other.is_rich_active(), visual);
        ui.add_document("new.md", TEXT);
        let new = ui.active().unwrap();
        if visual {
            rich(&new).await;
        } else {
            source(&new).await;
        }
        assert!(new.markdown_visual_override.get().is_none());
        assert_eq!(new.is_rich_active(), visual);
        assert_eq!(
            app.windows()
                .iter()
                .filter(|w| w.widget_name() == "fastra-markdown-mode-choice")
                .count(),
            0
        );
        println!("FASTRA_TOOL_SELFTEST_OK markdown-mode first-choice/nativeReturnAltReturn/one-owner/noEscape/perdoc-shortcut/new-doc default={visual}");
        app.quit();
        return;
    }
    if mode == "corrupt" {
        corrupt(ui, doc, revision, state, app).await;
        return;
    }
    core(ui, doc, revision, state, app, mode == "busy").await;
}
const RICH:&str="return JSON.stringify({source:fastraVisual.markdown(),selection:getSelection().toString(),undo:document.queryCommandEnabled('undo'),editable:document.getElementById('fastra-visual').contentEditable});";
async fn snapshot(editor: &crate::rich_editor::RichEditor) -> serde_json::Value {
    let began = std::time::Instant::now();
    loop {
        let value = inspect(&editor.view, RICH).await;
        if value["editable"] == "true" {
            return value;
        }
        assert!(
            began.elapsed() < Duration::from_secs(10),
            "owned Rich fence must release"
        );
        glib::timeout_future(Duration::from_millis(40)).await;
    }
}
async fn edit(ui: &Rc<Ui>, doc: &Document) -> serde_json::Value {
    let editor = rich(doc).await;
    ui.window.present();
    assert!(editor.view.grab_focus());
    inspect(&editor.view,"const root=document.getElementById('fastra-visual'),p=root.querySelector('p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);root.focus();return JSON.stringify(true);").await;
    let received = support::test_type(&editor.view, " edited");
    wait("actual Rich type", || received.try_recv().is_ok()).await;
    wait("typed source accepted", || {
        buffer_text(&doc.buffer).contains(" edited") && editor.ready_for_saved_source()
    })
    .await;
    inspect(&editor.view,"const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,5);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);").await;
    let value = snapshot(&editor).await;
    assert_eq!(value["selection"], "Alpha");
    assert_eq!(value["undo"], true);
    value
}
async fn open_settings(app: &gtk::Application) -> gtk::Window {
    app.activate_action("settings", None);
    wait("settings", || settings(app).is_some()).await;
    let window = settings(app).unwrap();
    let switch: gtk::Switch = named(&window, "fastra-markdown-visual-default");
    wait("settings control allocated", || switch.is_mapped() && switch.width() > 0 && switch.height() > 0).await;
    reveal(&switch);
    glib::timeout_future(Duration::from_millis(180)).await;
    window
}
async fn retry(window: &gtk::Window, state: &State) {
    let retry: gtk::Button = named(window, "fastra-markdown-mode-retry");
    reveal(&retry);
    glib::timeout_future(Duration::from_millis(120)).await;
    input(&retry, &[], true).await;
    settled(state).await;
}
async fn corrupt(
    _ui: Rc<Ui>,
    doc: Rc<Document>,
    revision: u64,
    state: Rc<State>,
    app: gtk::Application,
) {
    assert!(!state.loaded.get());
    assert!(state
        .error
        .borrow()
        .as_ref()
        .is_some_and(|e| e.stage == Stage::Load));
    let path = config_root()
        .unwrap()
        .join("fastra-editor/markdown-mode.json");
    let original = std::fs::read(&path).unwrap();
    let window = open_settings(&app).await;
    let switch: gtk::Switch = named(&window, "fastra-markdown-visual-default");
    assert!(!switch.is_sensitive());
    capture(&window, "markdown-mode-corrupt").await;
    retry(&window, &state).await;
    assert!(!state.loaded.get());
    assert_eq!(std::fs::read(&path).unwrap(), original);
    unchanged(&doc, revision);
    let root = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    std::fs::write(root.join("mode-corrupt-preserved"), &original).unwrap();
    std::fs::write(&path, br#"{"version":1,"visual":false}"#).unwrap();
    retry(&window, &state).await;
    assert!(state.loaded.get());
    assert_eq!(state.choice.get(), Some(false));
    assert!(switch.is_sensitive() && !switch.is_active());
    source(&doc).await;
    unchanged(&doc, revision);
    println!("FASTRA_TOOL_SELFTEST_OK markdown-mode corrupt-original-retained/disabled-switch/nativeRetry/explicit-fixture-repair");
    app.quit();
}
async fn core(
    ui: Rc<Ui>,
    one: Rc<Document>,
    one_revision: u64,
    state: Rc<State>,
    app: gtk::Application,
    busy: bool,
) {
    assert_eq!(state.choice.get(), Some(false));
    unchanged(&one, one_revision);
    assert!(state.dialog.borrow().is_none());
    ui.add_document("forced-source.md", TEXT);
    let forced = ui.active().unwrap();
    input(&ui.window, &["ctrl+alt+shift+m"], false).await;
    rich(&forced).await;
    input(&ui.window, &["ctrl+alt+shift+m"], false).await;
    source(&forced).await;
    assert_eq!(forced.markdown_visual_override.get(), Some(false));
    ui.add_document("inactive.md", TEXT);
    let inactive = ui.active().unwrap();
    select(&ui, &one);
    let explicit_ui = crate::build(&app);
    explicit_ui.add_document("explicit.md", TEXT);
    let explicit = explicit_ui.active().unwrap();
    support::test_size(explicit_ui.window.upcast_ref());
    input(&explicit_ui.window, &["ctrl+alt+shift+m"], false).await;
    rich(&explicit).await;
    assert_eq!(explicit.markdown_visual_override.get(), Some(true));
    let explicit_baseline = edit(&explicit_ui, &explicit).await;
    let explicit_editor = explicit.rich.borrow().clone().unwrap();
    let explicit_revision = explicit.revision.get();
    let other_ui = crate::build(&app);
    other_ui.add_document("other.md", TEXT);
    let other = other_ui.active().unwrap();
    support::test_size(other_ui.window.upcast_ref());
    let window = open_settings(&app).await;
    let switch: gtk::Switch = named(&window, "fastra-markdown-visual-default");
    assert!(!switch.is_active());
    let lock = if busy {
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
    settled(&state).await;
    assert_eq!(state.choice.get(), Some(true));
    let one_editor = rich(&one).await;
    rich(&other).await;
    source(&forced).await;
    assert!(inactive.rich.borrow().is_none());
    assert!(
        one.markdown_visual_override.get().is_none()
            && other.markdown_visual_override.get().is_none()
    );
    assert_eq!(explicit.revision.get(), explicit_revision);
    assert_eq!(snapshot(&explicit_editor).await, explicit_baseline);
    if let Some(lock) = lock {
        assert!(state
            .error
            .borrow()
            .as_ref()
            .is_some_and(|e| e.stage == Stage::Save));
        assert_eq!(store::load(&config_root().unwrap()).unwrap(), Some(false));
        assert!(!super::pending());
        assert!(state.hold.borrow().is_none());
        capture(&window, "markdown-mode-save-error").await;
        drop(lock);
        retry(&window, &state).await;
    }
    assert!(state.error.borrow().is_none());
    assert_eq!(store::load(&config_root().unwrap()).unwrap(), Some(true));
    capture(&window, "markdown-mode-default-visual").await;
    let fixture = std::path::PathBuf::from(std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap());
    let readonly_path = fixture.join("mode-readonly.md");
    std::fs::write(&readonly_path, TEXT).unwrap();
    std::fs::hard_link(&readonly_path, fixture.join("mode-readonly-alias.md")).unwrap();
    ui.load_path(readonly_path.clone());
    wait("actual hardlink readonly text", || {
        ui.active()
            .is_some_and(|doc| doc.disk_path().as_ref() == Some(&readonly_path))
    })
    .await;
    let readonly = ui.active().unwrap();
    glib::timeout_future(Duration::from_millis(180)).await;
    assert!(readonly.is_read_only());
    assert!(!readonly.is_rich_active());
    assert!(!readonly
        .rich_toggle
        .borrow()
        .as_ref()
        .unwrap()
        .is_sensitive());
    assert!(readonly.markdown_visual_override.get().is_none());
    unchanged(&readonly, 0);
    assert_eq!(std::fs::read_to_string(&readonly_path).unwrap(), TEXT);
    select(&ui, &one);
    window.close();
    glib::timeout_future(Duration::from_millis(200)).await;
    let one_baseline = edit(&ui, &one).await;
    let one_changed_revision = one.revision.get();
    let one_source = buffer_text(&one.buffer);
    eprintln!("MODE typed Rich source={one_source:?}");
    // Eine echte Tab-Schließung zwischen Vorbereitung und Übernahme macht den
    // gesamten vorbereiteten Ansichtswechsel ungültig, auch den ersten Eintrag.
    let reply = Rc::new(RefCell::new(None));
    let completed = reply.clone();
    crate::rich_editor::mode::prepare(
        &[one.clone(), other.clone()],
        false,
        Box::new(move |value| *completed.borrow_mut() = Some(value)),
    );
    wait("prepared mode tokens", || reply.borrow().is_some()).await;
    let prepared = reply.borrow_mut().take().unwrap().unwrap();
    assert!(prepared.valid());
    crate::tab_close::active(&other_ui);
    wait("target tab closed", || {
        !other_ui
            .documents
            .borrow()
            .iter()
            .any(|d| Rc::ptr_eq(d, &other))
    })
    .await;
    assert!(!prepared.valid());
    assert!(!prepared.commit_sources());
    assert!(one.is_rich_active());
    assert!(Rc::ptr_eq(&one.rich.borrow().clone().unwrap(), &one_editor));
    drop(prepared);
    assert_eq!(snapshot(&one_editor).await, one_baseline);
    other_ui.add_document("replacement.md", TEXT);
    let replacement = other_ui.active().unwrap();
    let replacement_editor = rich(&replacement).await;
    let reply = Rc::new(RefCell::new(None));
    let completed = reply.clone();
    crate::rich_editor::mode::prepare(
        &[one.clone(), replacement.clone()],
        false,
        Box::new(move |value| *completed.borrow_mut() = Some(value)),
    );
    wait("second prepared batch", || reply.borrow().is_some()).await;
    let prepared = reply.borrow_mut().take().unwrap().unwrap();
    assert!(prepared.valid());
    let owned = Rc::new(Cell::new(false));
    let done = owned.clone();
    replacement_editor.synchronize(
        true,
        Box::new(move |ok| {
            assert!(ok);
            done.set(true);
        }),
    );
    assert!(!prepared.valid());
    drop(prepared);
    wait("newer synchronization owns its fence", || owned.get()).await;
    assert_eq!(
        inspect(
            &replacement_editor.view,
            "return JSON.stringify(document.getElementById('fastra-visual').contentEditable);"
        )
        .await,
        "false",
        "dropping old preparation must not release a newer action fence"
    );
    replacement_editor.release();
    snapshot(&replacement_editor).await;
    assert_eq!(snapshot(&one_editor).await, one_baseline);
    select(&ui, &inactive);
    rich(&inactive).await;
    assert!(inactive.markdown_visual_override.get().is_none());
    select(&ui, &one);
    let window = open_settings(&app).await;
    let switch: gtk::Switch = named(&window, "fastra-markdown-visual-default");
    assert!(switch.is_active());
    // Eine laufende echte WebKit-Synchronisation bleibt Eigentümer ihrer Sperre.
    inspect(&one_editor.view,"window.fastraModeOriginalPrepare=fastraVisual.prepareAction;fastraVisual.prepareAction=function(){const until=performance.now()+1500;while(performance.now()<until){};return window.fastraModeOriginalPrepare.call(this);};return JSON.stringify(true);").await;
    let completed = Rc::new(Cell::new(false));
    let done = completed.clone();
    let held = one_editor.clone();
    one_editor.synchronize(
        true,
        Box::new(move |ok| {
            assert!(ok);
            held.release();
            done.set(true);
        }),
    );
    input(&switch, &[], true).await;
    settled(&state).await;
    assert_eq!(state.choice.get(), Some(true));
    assert!(state
        .error
        .borrow()
        .as_ref()
        .is_some_and(|e| e.stage == Stage::Change));
    assert_eq!(store::load(&config_root().unwrap()).unwrap(), Some(true));
    assert!(one.is_rich_active() && replacement.is_rich_active() && inactive.is_rich_active());
    capture(&window, "markdown-mode-busy-change").await;
    wait("original synchronization owner completes", || {
        completed.get()
    })
    .await;
    inspect(
        &one_editor.view,
        "fastraVisual.prepareAction=window.fastraModeOriginalPrepare;return JSON.stringify(true);",
    )
    .await;
    assert_eq!(snapshot(&one_editor).await, one_baseline);
    assert_eq!(one.revision.get(), one_changed_revision);
    assert_eq!(buffer_text(&one.buffer), one_source);
    assert_eq!(
        state.retry_change.get(),
        Some(false),
        "programmatic switch reset must not overwrite the failed user choice"
    );
    // Eine andere bewusst markierte Rich-Ansicht übernimmt unter X11 PRIMARY.
    // Die Auswahl für den jetzt geprüften Wechsel unmittelbar vorher herstellen.
    inspect(&explicit_editor.view,"const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,5);getSelection().removeAllRanges();getSelection().addRange(r);return JSON.stringify(true);").await;
    assert_eq!(snapshot(&explicit_editor).await, explicit_baseline);
    retry(&window, &state).await;
    assert!(state.error.borrow().is_none());
    assert_eq!(state.choice.get(), Some(false));
    source(&one).await;
    source(&replacement).await;
    source(&inactive).await;
    source(&forced).await;
    assert!(explicit.is_rich_active());
    assert_eq!(snapshot(&explicit_editor).await, explicit_baseline);
    assert_eq!(explicit.revision.get(), explicit_revision);
    assert!(
        one.markdown_visual_override.get().is_none()
            && replacement.markdown_visual_override.get().is_none()
    );
    assert_eq!(forced.markdown_visual_override.get(), Some(false));
    assert_eq!(buffer_text(&one.buffer), one_source);
    assert_eq!(one.revision.get(), one_changed_revision);
    assert!(one.buffer.can_undo());
    capture(&window, "markdown-mode-default-source").await;
    window.close();
    glib::timeout_future(Duration::from_millis(200)).await;
    let target = crate::source_panes::capture(&one).unwrap();
    let prefix = TEXT.strip_suffix('\n').unwrap();
    let mut undo_steps = 0;
    while buffer_text(&one.buffer) != TEXT {
        assert!(
            undo_steps < 8 && one.buffer.can_undo(),
            "Source undo must retain the whole Rich insertion: {:?}",
            buffer_text(&one.buffer)
        );
        let previous = buffer_text(&one.buffer);
        input(&target.view, &["ctrl+z"], undo_steps == 0).await;
        undo_steps += 1;
        let current = buffer_text(&one.buffer);
        assert_ne!(
            current,
            previous,
            "native Source Undo must really change the intended document, focus={} editable={}",
            target.view.has_focus(),
            target.view.is_editable()
        );
        let remaining = current
            .strip_prefix(prefix)
            .and_then(|text| text.strip_suffix('\n'))
            .expect("Undo must preserve the original source prefix and line ending");
        // Ein am Absatzende getipptes Leerzeichen wird vom gemeinsamen Rich-
        // Serializer zunächst als &nbsp; erhalten; Undo darf dorthin zurückgehen.
        let visible = remaining.replace("&nbsp;", " ");
        assert!(
            " edited".starts_with(&visible),
            "Source undo step{undo_steps}: remaining={remaining:?}, current={current:?}"
        );
    }
    eprintln!("MODE Source Undo restored exact source in {undo_steps} native steps");
    unchanged(&forced, 0);
    unchanged(&inactive, 0);
    assert_eq!(store::load(&config_root().unwrap()).unwrap(), Some(false));
    assert!(state.hold.borrow().is_none());
    capture(ui.window.upcast_ref(), "markdown-mode-source-after-undo").await;
    println!("FASTRA_TOOL_SELFTEST_OK markdown-mode global-existing/new/inactive/readonly-hardlink/two-overrides/three-windows/realRich-typing-selection-undo/all-target-close-guard/newer-operation-keeps-fence/operation-owned-busy-fence/nativeChangeRetry/nativeSourceUndo/persistence busyStore={busy}");
    app.quit();
}
