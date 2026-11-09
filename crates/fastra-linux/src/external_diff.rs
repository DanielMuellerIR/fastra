//! Externe Vergleiche besitzen eigene readonly Fenster und keine Editor-Dokumente.
use super::{git_view as support, Language};
use fastra_diff_helper::{Request, PATH};
use gtk::{gio, glib, prelude::*};
use std::{
    cell::RefCell,
    collections::HashMap,
    rc::Rc,
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc, Arc,
    },
    time::{Duration, Instant},
};
struct WorkerPermit(std::sync::Arc<std::sync::atomic::AtomicUsize>);
impl Drop for WorkerPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}
struct State {
    accepted: HashMap<String, Request>,
    windows: HashMap<String, gtk::ApplicationWindow>,
    pending: usize,
    validators: Arc<AtomicUsize>,
    readers: Arc<AtomicUsize>,
    registration: Option<gio::RegistrationId>,
    hold: Option<gio::ApplicationHoldGuard>,
}
thread_local! {static SERVICE: RefCell<Option<Rc<RefCell<State>>>>=const{RefCell::new(None)};}
fn lang() -> Language {
    Language(
        std::env::var("LANGUAGE")
            .or_else(|_| std::env::var("LANG"))
            .unwrap_or_default()
            .starts_with("de"),
    )
}
fn reply(invocation: gio::DBusMethodInvocation, code: i32) {
    invocation.return_value(Some(&(code,).to_variant()));
}
pub(super) fn start(app: &gtk::Application) {
    let Some(connection) = app.dbus_connection() else {
        return;
    };
    let info=gio::DBusNodeInfo::for_xml("<node><interface name='org.fastra.Diff1'><method name='Deliver'><arg type='s' direction='in'/><arg type='i' direction='out'/></method></interface></node>").expect("constant diff interface");
    let state = Rc::new(RefCell::new(State {
        accepted: HashMap::new(),
        windows: HashMap::new(),
        pending: 0,
        validators: Arc::default(),
        readers: Arc::default(),
        registration: None,
        hold: None,
    }));
    let target = state.clone();
    let weak_app = app.downgrade();
    let registered = connection
        .register_object(PATH, &info.interfaces()[0])
        .method_call(move |_, _, _, _, method, parameters, invocation| {
            if method != "Deliver" {
                reply(invocation, 4);
                return;
            }
            if parameters.size() > fastra_diff_helper::MAX_MESSAGE + 8 {
                reply(invocation, 2);
                return;
            }
            let Some((payload,)) = parameters.get::<(String,)>() else {
                reply(invocation, 4);
                return;
            };
            let request = match Request::decode(&payload) {
                Ok(r) => r,
                Err(code) => {
                    reply(invocation, code);
                    return;
                }
            };
            {
                let mut s = target.borrow_mut();
                let at = fastra_diff_helper::now();
                s.accepted.retain(|_, r| r.deadline + 60. > at);
                if let Some(old) = s.accepted.get(&request.id) {
                    reply(invocation, if old == &request { 0 } else { 6 });
                    return;
                }
                if let Err(code) = request.validate(at) {
                    reply(invocation, code);
                    return;
                }
                if s.pending >= 4
                    || s.validators.load(Ordering::Acquire) >= 4
                    || s.accepted.len() >= 4096
                    || s.windows.len() >= 64
                {
                    reply(invocation, 6);
                    return;
                }
                s.pending += 1;
                s.validators.fetch_add(1, Ordering::AcqRel);
            }
            let Some(app) = weak_app.upgrade() else {
                target.borrow_mut().pending -= 1;
                target.borrow().validators.fetch_sub(1, Ordering::AcqRel);
                reply(invocation, 6);
                return;
            };
            let hold = app.hold();
            let (tx, rx) = mpsc::sync_channel(1);
            let check = request.clone();
            let pending = target.borrow().validators.clone();
            std::thread::spawn(move || {
                let _permit = WorkerPermit(pending);
                let result = check.validate_files();
                let _ = tx.send(result);
            });
            let target = target.clone();
            let invocation = RefCell::new(Some(invocation));
            let held = RefCell::new(Some(hold));
            let deadline = Instant::now()
                + Duration::from_secs_f64((request.deadline - fastra_diff_helper::now()).max(0.));
            glib::timeout_add_local(Duration::from_millis(10), move || {
                let code = if Instant::now() >= deadline {
                    Some(6)
                } else {
                    match rx.try_recv() {
                        Ok(Ok(())) => Some(0),
                        Ok(Err(code)) => Some(code),
                        Err(mpsc::TryRecvError::Empty) => None,
                        Err(_) => Some(6),
                    }
                };
                let Some(mut code) = code else {
                    return glib::ControlFlow::Continue;
                };
                target.borrow_mut().pending -= 1;
                if code == 0 {
                    let old = target.borrow().accepted.get(&request.id).cloned();
                    if let Some(old) = old {
                        if old != request {
                            code = 6;
                        }
                    } else if request.deadline <= fastra_diff_helper::now()
                        || target.borrow().windows.len() >= 64
                        || target.borrow().accepted.len() >= 4096
                    {
                        code = 6;
                    } else {
                        let window = open(&app, &request, &target);
                        if target.borrow().hold.is_none() {
                            target.borrow_mut().hold = Some(app.hold());
                        }
                        target
                            .borrow_mut()
                            .accepted
                            .insert(request.id.clone(), request.clone());
                        target
                            .borrow_mut()
                            .windows
                            .insert(request.id.clone(), window);
                    }
                }
                if let Some(inv) = invocation.borrow_mut().take() {
                    reply(inv, code);
                }
                held.borrow_mut().take();
                glib::ControlFlow::Break
            });
        })
        .build();
    if let Ok(id) = registered {
        state.borrow_mut().registration = Some(id);
        SERVICE.with(|s| *s.borrow_mut() = Some(state));
        #[cfg(debug_assertions)]
        if std::env::var_os("FASTRA_EXTERNAL_DIFF_SELFTEST").is_some() {
            super::diff_view::ReadOnly::start_test(app);
        }
    }
}
pub(super) fn shutdown(app: &gtk::Application) {
    SERVICE.with(|slot| {
        if let Some(s) = slot.borrow_mut().take() {
            let mut s = s.borrow_mut();
            if let (Some(c), Some(id)) = (app.dbus_connection(), s.registration.take()) {
                let _ = c.unregister_object(id);
            }
            for (_, w) in s.windows.drain() {
                w.destroy();
            }
            s.hold.take();
        }
    });
}
fn open(
    app: &gtk::Application,
    request: &Request,
    state: &Rc<RefCell<State>>,
) -> gtk::ApplicationWindow {
    let language = lang();
    let names = [request.left_label.clone(), request.right_label.clone()];
    let title = format!("Diff: {} ↔ {}", names[0], names[1]);
    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title(&title)
        .default_width(1100)
        .default_height(720)
        .build();
    window.set_size_request(940, 420);
    super::chrome::theme(&window);
    let menu = gtk::MenuButton::builder()
        .icon_name("open-menu-symbolic")
        .build();
    menu.set_tooltip_text(Some(language.text("Fastra-Menü", "Fastra menu")));
    let popover = gtk::Popover::new();
    let commands = gtk::Box::new(gtk::Orientation::Vertical, 0);
    commands.add_css_class("command-menu");
    let quit = gtk::Button::with_label(language.text("Fastra beenden", "Quit Fastra"));
    let weak = popover.downgrade();
    quit.connect_clicked(move |_| {
        if let Some(popover) = weak.upgrade() {
            popover.popdown();
        }
        super::application_lifecycle::request_quit();
    });
    commands.append(&quit);
    popover.set_child(Some(&commands));
    menu.set_popover(Some(&popover));
    super::chrome::dialog::decorate_with_accessory(
        window.upcast_ref(),
        &title,
        language,
        Some(menu.upcast_ref()),
    );
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let notice = gtk::Box::new(gtk::Orientation::Horizontal, 5);
    notice.add_css_class("diff-readonly-banner");
    let lock = gtk::Image::from_icon_name("changes-prevent-symbolic");
    lock.set_pixel_size(12);
    notice.append(&lock);
    notice.append(&gtk::Label::new(Some(
        language.text("Schreibgeschützter Vergleich", "Read-only comparison"),
    )));
    root.append(&notice);
    let comparison = super::diff_view::ReadOnly::new(&window, &names, language);
    root.append(&comparison.root);
    window.set_child(Some(&root));
    let cancel = fastra_core::Cancellation::default();
    let diff_cancel = fastra_diff::Cancellation::default();
    let io_cancel = cancel.clone();
    let computation_cancel = diff_cancel.clone();
    let view = comparison.clone();
    let destroy_io = cancel.clone();
    let destroy_diff = diff_cancel.clone();
    let destroyed = comparison.clone();
    window.connect_destroy(move |_| {
        destroy_io.cancel();
        destroy_diff.cancel();
        destroyed.close();
    });
    let target = Rc::downgrade(state);
    let id = request.id.clone();
    window.connect_close_request(move |_| {
        io_cancel.cancel();
        computation_cancel.cancel();
        view.close();
        if let Some(s) = target.upgrade() {
            s.borrow_mut().windows.remove(&id);
        }
        glib::Propagation::Proceed
    });
    let focus = request.focus_diff;
    let request = request.clone();
    let weak = window.downgrade();
    let readers = state.borrow().readers.clone();
    if readers.load(Ordering::Acquire) >= 4 {
        comparison.error(language.text(
            "Vergleichsleser sind noch beschäftigt. Fenster schließen und später erneut aufrufen.",
            "Comparison readers are still busy. Close this window and retry later.",
        ));
        if focus {
            window.present();
        } else {
            window.set_visible(true);
        }
        return window;
    }
    // Nur Main startet Leser; Worker geben ihre Belegung erst nach dem tatsächlichen Ende frei.
    readers.fetch_add(1, Ordering::AcqRel);
    support::background(
        move || {
            let _permit = WorkerPermit(readers);
            compute(&request, &cancel, &diff_cancel, language)
        },
        move |result| {
            let Some(window) = weak.upgrade().filter(|w| w.is_visible()) else {
                return;
            };
            match result {
                Ok(data) => comparison.install(data),
                Err(error) => comparison.error(&error),
            }
            window.queue_draw();
        },
    );
    // Ohne Fokuswunsch wird weder present() noch ein Aktivierungstoken angefordert.
    if focus {
        window.present();
    } else {
        window.set_visible(true);
    }
    window
}
fn compute(
    request: &Request,
    io: &fastra_core::Cancellation,
    cancel: &fastra_diff::Cancellation,
    language: Language,
) -> Result<super::diff_view::ReadOnlyData, String> {
    let load = |path: &str| -> Result<fastra_document::ReadOnlyTextDocument, String> {
        io.check().map_err(|e| e.to_string())?;
        fastra_document::ReadOnlyTextDocument::open_bounded(
            std::path::Path::new(path),
            None,
            4 * 1024 * 1024,
            io,
        )
        .map_err(|error| match error {
            fastra_document::Error::NotText => language
                .text(
                    "Binär-/Abschnittsdateien sind kein vollständiger Textvergleich.",
                    "Binary/section files are not a complete text comparison.",
                )
                .into(),
            fastra_document::Error::Snapshot(fastra_io::Error::Limit) => language
                .text(
                    "Die Vergleichsdatei überschreitet 4 MiB.",
                    "The comparison file exceeds 4 MiB.",
                )
                .into(),
            error => error.to_string(),
        })
    };
    let left = load(&request.left_path)?;
    let right = load(&request.right_path)?;
    if left.text().len() + right.text().len() > 4 * 1024 * 1024 {
        return Err(language
            .text(
                "Die vollständige Vergleichsansicht ist auf 4 MiB Text begrenzt.",
                "The complete comparison view is limited to 4 MiB of text.",
            )
            .into());
    }
    let snap = |side: &str, text: &str| fastra_diff::TextSnapshot {
        document_id: side.into(),
        revision: 0,
        text: text.into(),
    };
    let comparison = fastra_diff::Comparison::compare(
        snap("left", left.text()),
        snap("right", right.text()),
        0,
        Default::default(),
        fastra_diff::Limits {
            max_lines: 5000,
            max_report_bytes: 2 * 1024 * 1024,
            max_output_bytes: 4 * 1024 * 1024,
            ..Default::default()
        },
        cancel,
    )
    .map_err(|e| e.to_string())?;
    let data = super::diff_view::ReadOnlyData::prepare(
        &comparison,
        [&left, &right],
        [
            std::path::PathBuf::from(&request.left_path),
            std::path::PathBuf::from(&request.right_path),
        ],
        &[request.left_label.clone(), request.right_label.clone()],
        language,
        cancel,
    )?;
    left.verify_current(io).map_err(|e| e.to_string())?;
    right.verify_current(io).map_err(|e| e.to_string())?;
    Ok(data)
}
