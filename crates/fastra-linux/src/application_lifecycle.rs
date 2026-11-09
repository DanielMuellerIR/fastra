//! Eine native GApplication pro Desktop-Sitzung, mit gemeinsamem Fensterinventar.
use super::{build, local_control, Ui};
use glib::translate::ToGlibPtr;
use gtk::{gio, glib, prelude::*};
use std::{cell::RefCell, rc::Rc};
mod quit;
pub(super) use quit::{request as request_quit, abort as abort_quit, shortcut as quit_shortcut, ordinary_windows};
pub(super) fn quit_button(ui:&Rc<Ui>,toolbar:&gtk::FlowBox) {
    let button=gtk::Button::with_label(ui.lang.text("Fastra beenden","Quit Fastra"));
    button.set_tooltip_text(Some(ui.lang.text("Alle Fastra-Fenster sicher schließen (Ctrl+Shift+Q)","Safely close all Fastra windows (Ctrl+Shift+Q)")));
    button.connect_clicked(|_|request_quit());toolbar.insert(&button,-1);
}

pub(super) fn install(app: &gtk::Application) {
    super::editor_options::zoom::install(app);
    super::editor_options::printing::install(app);
    super::editor_options::appearance::install(app);
    super::editor_options::reading_font::install(app);
    super::editor_options::markdown_preview::install(app);
    super::editor_options::markdown_mode::install(app);
    app.add_main_option(
        "local-control-service",
        glib::Char::from(0),
        glib::OptionFlags::HIDDEN,
        glib::OptionArg::None,
        "Run the local read-only controller without opening an editor window",
        None,
    );
    app.add_main_option("external-diff-service", glib::Char::from(0), glib::OptionFlags::HIDDEN,
        glib::OptionArg::None, "Receive external read-only comparisons without opening an editor", None);
    let windows: Rc<RefCell<Vec<Rc<Ui>>>> = Rc::default();
    quit::install(app, &windows);
    let states = windows.clone();
    let factory: super::editor_options::startup::WindowFactory = Rc::new(move |app| {
        let ui = build(app);
        local_control::register(&ui);
        states.borrow_mut().push(ui.clone());
        ui
    });
    super::editor_options::startup::install(app, factory);
    app.connect_activate(super::editor_options::startup::activate);
    app.connect_open(|app, files, _| super::editor_options::startup::open(app, files));
    let states = windows.clone();
    app.connect_window_removed(move |_, window| {
        // close-request kann wegen ungesicherter Änderungen abgewiesen werden.
        // Erst GTKs tatsächliches Entfernen gibt den zugehörigen Zustand frei.
        states.borrow_mut().retain(|ui| ui.window != *window);
    });
    let service_hold: Rc<RefCell<Option<gio::ApplicationHoldGuard>>> = Rc::default();
    let hold = service_hold.clone();
    app.connect_command_line(move |app, command| {
        if command.options_dict().contains("external-diff-service") {
            let hold = app.hold();
            glib::timeout_add_local_once(std::time::Duration::from_secs(11), move || drop(hold));
            return glib::ExitCode::SUCCESS;
        }
        if command.options_dict().contains("local-control-service") {
            if let Err(error) = local_control::service_ready() {
                let message = std::ffi::CString::new(format!("{error}\n")).unwrap_or_else(|_| {
                    std::ffi::CString::new("Local-control startup failed.\n").unwrap()
                });
                // GIO vor 2.80 bietet nur die variadische API. Der konstante Formatstring
                // schützt Prozentzeichen und liefert den Fehler auch an Remote-Aufrufer.
                unsafe {
                    gio::ffi::g_application_command_line_printerr(
                        command.to_glib_none().0,
                        c"%s".as_ptr(),
                        message.as_ptr(),
                    );
                }
                return glib::ExitCode::FAILURE;
            }
            if hold.borrow().is_none() {
                *hold.borrow_mut() = Some(app.hold());
            }
            return glib::ExitCode::SUCCESS;
        }
        // GApplication übermittelt rohe Unixargumente samt Arbeitsverzeichnis.
        // create_file_for_arg löst relative Pfade beim Aufrufer auf, nicht hier.
        let mut arguments = command.arguments();
        // GLib erhält den Separator vor Bindestrich-Dateinamen auch hinter anderen
        // Pfaden. Nur diesen einen Eintrag entfernen; eine echte Datei "--" bleibt.
        if let Some(index) = arguments.iter().skip(1).position(|arg| arg == "--") {
            arguments.remove(index + 1);
        }
        let files: Vec<_> = arguments
            .iter()
            .skip(1)
            .map(|arg| command.create_file_for_arg(arg))
            .collect();
        if files.is_empty() {
            app.activate();
        } else {
            app.open(&files, "");
        }
        glib::ExitCode::SUCCESS
    });
    let shutdown_hold = service_hold.clone();
    let shutdown_windows = windows.clone();
    app.connect_shutdown(move |app| {
        super::external_diff::shutdown(app);
        local_control::shutdown();
        shutdown_windows.borrow_mut().clear();
        shutdown_hold.borrow_mut().take();
    });
    #[cfg(debug_assertions)]
    {
        // Nur der primäre Prozess darf den gemeinsamen Beobachtungsstand schreiben.
        let observed_windows = windows.clone();
        let observed_hold = service_hold.clone();
        app.connect_startup(move |app| selftest::install(app, &observed_windows, &observed_hold));
    }
}

#[cfg(debug_assertions)]
mod selftest;
#[cfg(debug_assertions)]
mod quit_observe;
