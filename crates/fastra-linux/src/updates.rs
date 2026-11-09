//! Der Pakethelfer prüft und installiert außerhalb des GUI-Threads.
use super::{git_view, Ui};
use gtk::{glib, prelude::*};
use serde_json::Value;
use std::{cell::RefCell, path::PathBuf, rc::Rc};

fn helper() -> Result<PathBuf, String> {
    let binary = std::env::current_exe().map_err(|error| error.to_string())?;
    let script = binary.parent().ok_or("Missing runtime directory")?
        .join("fastra-update/update.py");
    script.is_file().then_some(script).ok_or_else(|| "Updates require an installed Linux package".into())
}

fn run(arguments: Vec<String>) -> Result<Value, String> {
    let installing = arguments.first().is_some_and(|action| action == "install");
    let arguments: Vec<std::ffi::OsString> = std::iter::once("-B".into())
        .chain(std::iter::once(helper()?.into_os_string()))
        .chain(arguments.into_iter().map(Into::into)).collect();
    let output = fastra_process::run_with_stderr(
        std::path::Path::new("/usr/bin/python3"), std::path::Path::new("/"), &arguments,
        fastra_process::Policy {
            timeout: std::time::Duration::from_secs(if installing { 900 } else { 90 }),
            stdout_bytes: 64 * 1024, stderr_bytes: 16 * 1024, ..Default::default()
        },
        &Default::default(), &fastra_process::Environment { remove_prefixes: vec!["LD_".into()], set: Vec::new() },
        fastra_process::ParentLoss::Terminate, &mut |_| {},
    ).map_err(|error| error.to_string())?;
    let value: Value = serde_json::from_slice(&output.stdout).map_err(|error| error.to_string())?;
    if !output.success() || value["status"] == "error" {
        return Err(value["error"].as_str().unwrap_or("Update helper failed").into());
    }
    Ok(value)
}

pub(super) fn button(ui: &Rc<Ui>) -> gtk::Button {
    let button = gtk::Button::with_label(ui.lang.text("Updates …", "Updates …"));
    let weak = Rc::downgrade(ui);
    button.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() { open(&ui, None); }
    });
    // Quellbuilds haben keinen Pakethelfer und erzeugen keinen Netzwerkverkehr.
    if helper().is_ok() {
        let weak = Rc::downgrade(ui);
        glib::timeout_add_local_once(std::time::Duration::from_secs(3), move || {
            git_view::background(
                || run(vec!["check".into(), "--automatic".into()]),
                move |result| {
                    if let (Some(ui), Ok(value)) = (weak.upgrade(), result) {
                        if ui.window.is_visible() && value["status"] == "available" {
                            open(&ui, Some(value));
                        }
                    }
                },
            );
        });
    }
    button
}

fn description(ui: &Ui, value: &Value) -> String {
    match value["status"].as_str() {
        Some("available") => format!("{} {}", ui.lang.text("Neue Version verfügbar:", "New version available:"), value["version"].as_str().unwrap_or("?")),
        Some("installed") => ui.lang.text("Update installiert. Bitte Fastra regulär beenden und erneut öffnen. Ungesicherte Dokumente bleiben bis dahin in dieser Sitzung.", "Update installed. Please quit Fastra normally and reopen it. Unsaved documents remain in this session until then.").into(),
        Some("no-linux-package") => ui.lang.text("Noch kein neueres Linux-Paket auf GitHub veröffentlicht.", "No newer Linux package has been published on GitHub yet.").into(),
        _ => ui.lang.text("Diese Version ist aktuell.", "This version is up to date.").into(),
    }
}

fn open(ui: &Rc<Ui>, initial: Option<Value>) {
    let window = gtk::Window::builder().title(ui.lang.text("Fastra-Updates", "Fastra updates"))
        .transient_for(&ui.window).destroy_with_parent(true).modal(true).default_width(500).build();
    let root = git_view::column();
    root.append(&git_view::label(&format!("Fastra {} · Linux", env!("CARGO_PKG_VERSION"))));
    root.append(&git_view::label(ui.lang.text(
        "Updates werden von GitHub geladen und vor der Installation geprüft. Die laufende Sitzung wird nicht neu gestartet. Die bisherige Version bleibt für eine Rücknahme erhalten.",
        "Updates are downloaded from GitHub and verified before installation. The running session is not restarted. The previous version is retained for rollback.")));
    let automatic = gtk::CheckButton::with_label(ui.lang.text("Automatisch nach Updates suchen (einmal täglich)", "Check for updates automatically (once a day)"));
    automatic.set_sensitive(false);
    root.append(&automatic);
    let status = git_view::label(ui.lang.text("Update-Einstellungen laden …", "Loading update settings …"));
    status.set_selectable(true);
    root.append(&status);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let check = gtk::Button::with_label(ui.lang.text("Jetzt prüfen", "Check now"));
    let install = gtk::Button::with_label(ui.lang.text("Update installieren", "Install update"));
    install.set_sensitive(initial.is_some());
    let close = gtk::Button::with_label(ui.lang.text("Schließen", "Close"));
    row.append(&check); row.append(&install); row.append(&close); root.append(&row);
    window.set_child(Some(&root));
    let weak = window.downgrade();
    close.connect_clicked(move |_| { if let Some(window) = weak.upgrade() { window.close(); } });
    let ticket = Rc::new(RefCell::new(initial));
    if let Some(value) = ticket.borrow().as_ref() { status.set_text(&description(ui, value)); }
    let weak_status = status.downgrade();
    let weak_toggle = automatic.downgrade();
    let has_initial = ticket.borrow().is_some();
    git_view::background(|| run(vec!["preferences".into()]), move |result| {
        if let (Some(status), Some(toggle)) = (weak_status.upgrade(), weak_toggle.upgrade()) {
            match result {
                Ok(value) => {
                    toggle.set_active(value["automatic"].as_bool().unwrap_or(false));
                    toggle.set_sensitive(true);
                    if !has_initial { status.set_text(""); }
                    let weak_status = status.downgrade();
                    toggle.connect_toggled(move |toggle| {
                        let action = if toggle.is_active() { "enable" } else { "disable" };
                        toggle.set_sensitive(false);
                        let weak_toggle = toggle.downgrade();
                        let weak_status = weak_status.clone();
                        git_view::background(move || run(vec![action.into()]), move |result| {
                            if let Some(toggle) = weak_toggle.upgrade() { toggle.set_sensitive(true); }
                            if let (Some(status), Err(error)) = (weak_status.upgrade(), result) { status.set_text(&error); }
                        });
                    });
                }
                Err(error) => status.set_text(&error),
            }
        }
    });
    let weak_ui = Rc::downgrade(ui);
    let weak_status = status.downgrade();
    let weak_install = install.downgrade();
    let check_ticket = ticket.clone();
    check.connect_clicked(move |button| {
        button.set_sensitive(false);
        if let Some(install) = weak_install.upgrade() { install.set_sensitive(false); }
        *check_ticket.borrow_mut() = None;
        if let Some(status) = weak_status.upgrade() {
            if let Some(ui) = weak_ui.upgrade() { status.set_text(ui.lang.text("GitHub prüfen …", "Checking GitHub …")); }
        }
        let (weak_button, weak_status, weak_install, weak_ui, ticket) = (button.downgrade(), weak_status.clone(), weak_install.clone(), weak_ui.clone(), check_ticket.clone());
        git_view::background(|| run(vec!["check".into()]), move |result| {
            if let (Some(button), Some(status), Some(install), Some(ui)) = (weak_button.upgrade(), weak_status.upgrade(), weak_install.upgrade(), weak_ui.upgrade()) {
                button.set_sensitive(true);
                match result {
                    Ok(value) => {
                        status.set_text(&description(&ui, &value));
                        install.set_sensitive(value["status"] == "available");
                        *ticket.borrow_mut() = Some(value);
                    }
                    Err(error) => status.set_text(&format!("{} {error}", ui.lang.text("Updateprüfung fehlgeschlagen:", "Update check failed:"))),
                }
            }
        });
    });
    let weak_ui = Rc::downgrade(ui);
    let weak_status = status.downgrade();
    let weak_check = check.downgrade();
    install.connect_clicked(move |button| {
        let Some(value) = ticket.borrow_mut().take() else { return; };
        let arguments = vec!["install".into(), "--version".into(), value["version"].as_str().unwrap_or("").into(), "--sha256".into(), value["sha256"].as_str().unwrap_or("").into()];
        button.set_sensitive(false);
        if let Some(check) = weak_check.upgrade() { check.set_sensitive(false); }
        if let (Some(status), Some(ui)) = (weak_status.upgrade(), weak_ui.upgrade()) { status.set_text(ui.lang.text("Update laden, prüfen und installieren …", "Downloading, verifying and installing update …")); }
        let (weak_status, weak_ui, weak_check) = (weak_status.clone(), weak_ui.clone(), weak_check.clone());
        git_view::background(move || run(arguments), move |result| {
            if let (Some(status), Some(ui)) = (weak_status.upgrade(), weak_ui.upgrade()) {
                match result {
                    Ok(value) => status.set_text(&description(&ui, &value)),
                    Err(error) => {
                        status.set_text(&format!("{} {error}", ui.lang.text("Update nicht installiert:", "Update was not installed:")));
                        if let Some(check) = weak_check.upgrade() { check.set_sensitive(true); }
                    }
                }
            }
        });
    });
    window.present();
}
