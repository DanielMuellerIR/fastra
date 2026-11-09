//! Eine Katalogentscheidung für Dateiöffnen, Projektdatei und Paket-Drop.
use super::{import_error, owner, set_path, support, Language, Ui};
use crate::LoadValidator;
use gtk::prelude::*;
use std::{path::PathBuf, rc::Rc};
struct Choice {
    directory: bool,
    format: Option<fastra_import::Format>,
    tool: Option<PathBuf>,
    problem: Option<String>,
}
fn inspect(
    path: &std::path::Path,
    tool: Option<PathBuf>,
    lang: Language,
    cancel: &fastra_import::Cancellation,
) -> Result<Choice, String> {
    let metadata = std::fs::metadata(path).map_err(|e| e.to_string())?;
    if !metadata.is_file() && !metadata.is_dir() {
        return Err(lang
            .text(
                "Keine reguläre Datei oder Ordner.",
                "Not a regular file or folder.",
            )
            .into());
    }
    let directory = metadata.is_dir();
    let Some(tool) = tool else {
        return Ok(Choice {
            directory,
            format: None,
            tool: None,
            problem: None,
        });
    };
    let importer = match fastra_import::Importer::new(tool.clone()) {
        Ok(importer) => importer,
        Err(error) => {
            return Ok(Choice {
                directory,
                format: None,
                tool: None,
                problem: Some(import_error(lang, error)),
            })
        }
    };
    let probe = importer.probe_cached(Default::default(), Default::default(), cancel);
    match probe {
        Ok(probe) => {
            let format = path
                .extension()
                .and_then(|e| e.to_str())
                .and_then(|ext| probe.catalog.format_for(ext, directory))
                .cloned();
            Ok(Choice {
                directory,
                format,
                tool: Some(tool),
                problem: None,
            })
        }
        Err(error) => Ok(Choice {
            directory,
            format: None,
            tool: None,
            problem: Some(import_error(lang, error)),
        }),
    }
}
pub(super) fn discover_tool() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("FASTRA_POORMANS_TEXT") {
        if fastra_process::host::is_active().unwrap_or(true) {
            return fastra_process::host::resolve_program(&path).ok().flatten();
        }
        return Some(path.into());
    }
    support::find_program("poormans-text")
}
pub(crate) fn route_open(
    ui: &Rc<Ui>,
    path: PathBuf,
    encoding: Option<fastra_core::encoding::Encoding>,
    guard: Rc<dyn Fn() -> bool>,
    validate: Option<LoadValidator>,
) {
    route_open_completed(ui, path, encoding, guard, validate, None);
}
pub(crate) fn route_open_completed(
    ui: &Rc<Ui>,
    path: PathBuf,
    encoding: Option<fastra_core::encoding::Encoding>,
    guard: Rc<dyn Fn() -> bool>,
    validate: Option<LoadValidator>,
    completed: Option<crate::LoadCompletion>,
) {
    if !guard() || !ui.window.is_visible() {
        return;
    }
    if encoding.is_some() {
        ui.load_path_raw_completed(path, encoding, guard, validate, completed);
        return;
    }
    let expected = owner(ui);
    let worker_path = path.clone();
    let weak = Rc::downgrade(ui);
    let lang = ui.lang;
    let cancel = fastra_import::Cancellation::default();
    let worker_cancel = cancel.clone();
    let guard_poll = guard.clone();
    let poll = weak.clone();
    let complete = Rc::new(std::cell::Cell::new(false));
    let poll_complete = complete.clone();
    gtk::glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
        if poll_complete.get() {
            return gtk::glib::ControlFlow::Break;
        }
        if !guard_poll() || poll.upgrade().is_none_or(|ui| !ui.window.is_visible()) {
            cancel.cancel();
            return gtk::glib::ControlFlow::Break;
        }
        gtk::glib::ControlFlow::Continue
    });
    support::background(
        move || inspect(&worker_path, discover_tool(), lang, &worker_cancel),
        move |result| {
            complete.set(true);
            let Some(ui) = weak
                .upgrade()
                .filter(|ui| ui.window.is_visible() && guard())
            else {
                return;
            };
            let choice = match result {
                Ok(choice) => choice,
                Err(error) => {
                    ui.status.set_text(&error);
                    return;
                }
            };
            let Some(format) = choice.format else {
                if let Some(problem) = choice.problem {
                    ui.status.set_text(&format!(
                        "{} {problem}",
                        lang.text(
                            "Importkatalog nicht verfügbar; Quelle wird geöffnet.",
                            "Import catalog unavailable; opening source."
                        )
                    ));
                }
                if choice.directory {
                    super::super::project_view::open_path(&ui, path);
                } else {
                    ui.load_path_raw_completed(path, encoding, guard, validate, completed);
                }
                return;
            };
            let window = support::window(&ui, lang.text("Dokument öffnen", "Open document"), true);
            window.set_default_size(620, 320);
            window.set_size_request(480, 280);
            let root = support::column();
            root.append(&support::label(&format!(
                "{}\n{}: {}",
                super::super::project_view::display(&path),
                lang.text("Erkanntes Importformat", "Detected import format"),
                format.format
            )));
            root.append(&support::label(lang.text("Als Markdown importieren und die vollständige Vorschau prüfen, oder die Originalquelle öffnen. Die Quelle bleibt erhalten.","Import as Markdown and review the complete preview, or open the original source. The source is preserved.")));
            let import = gtk::Button::with_label(
                lang.text("Als Markdown importieren …", "Import as Markdown …"),
            );
            let source = gtk::Button::with_label(if choice.directory {
                lang.text("Als Ordner öffnen", "Open as folder")
            } else {
                lang.text("Quelltext öffnen", "Open source")
            });
            let cancel = gtk::Button::with_label(lang.text("Abbrechen", "Cancel"));
            let utf8 = path.to_str().is_some();
            import.set_sensitive(format.available && utf8);
            if !format.available {
                root.append(&support::label(&format!(
                    "{} {}",
                    lang.text(
                        "Import derzeit nicht verfügbar:",
                        "Import currently unavailable:"
                    ),
                    format.unavailable_reason.as_deref().unwrap_or(
                        lang.text("Benötigtes Werkzeug fehlt.", "Required tool is missing.")
                    )
                )));
            }
            if !utf8 {
                root.append(&support::label(lang.text("Der Importvertrag unterstützt nur UTF-8-Pfade. Die Quelle kann mit ihrem unveränderten Pfad geöffnet werden.","The import contract supports only UTF-8 paths. The source can be opened with its unchanged path.")));
            }
            let actions = gtk::Box::new(gtk::Orientation::Vertical, 8);
            for button in [&import, &source, &cancel] {
                actions.append(button);
            }
            root.append(&actions);
            window.set_child(Some(&root));
            let import_ui = Rc::downgrade(&ui);
            let import_path = path.clone();
            let import_guard = guard.clone();
            let import_window = window.clone();
            import.connect_clicked(move |_| {
                let Some(ui) = import_ui
                    .upgrade()
                    .filter(|ui| ui.window.is_visible() && import_guard() && owner(ui) == expected)
                else {
                    import_window.close();
                    return;
                };
                let state = super::open(&ui);
                set_path(&state.source, &import_path, &state.status, lang);
                if let Some(tool) = choice.tool.as_ref() {
                    set_path(&state.program, tool, &state.status, lang);
                }
                if let Some(parent) = import_path.parent() {
                    set_path(&state.destination, parent, &state.status, lang);
                }
                import_window.close();
            });
            let source_ui = Rc::downgrade(&ui);
            let source_window = window.clone();
            let validate = std::cell::RefCell::new(validate);
            let completed = std::cell::RefCell::new(completed);
            source.connect_clicked(move |_| {
                let Some(ui) = source_ui
                    .upgrade()
                    .filter(|ui| ui.window.is_visible() && guard())
                else {
                    source_window.close();
                    return;
                };
                if choice.directory {
                    super::super::project_view::open_path(&ui, path.clone());
                } else {
                    ui.load_path_raw_completed(
                        path.clone(),
                        encoding,
                        guard.clone(),
                        validate.borrow_mut().take(),
                        completed.borrow_mut().take(),
                    );
                }
                source_window.close();
            });
            let close = window.clone();
            cancel.connect_clicked(move |_| close.close());
            window.present();
        },
    );
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn absent_tool_preserves_regular_files_packages_and_normal_folders() {
        use std::os::unix::ffi::OsStringExt;
        let dir = tempfile::tempdir().unwrap();
        let file = dir
            .path()
            .join(std::ffi::OsString::from_vec(b"a-\xff.mbox".to_vec()));
        std::fs::write(&file, b"unchanged").unwrap();
        let package = dir.path().join("mail.mbox");
        std::fs::create_dir(&package).unwrap();
        for (path, directory) in [
            (file.as_path(), false),
            (package.as_path(), true),
            (dir.path(), true),
        ] {
            let choice = inspect(path, None, Language(false), &Default::default()).unwrap();
            assert_eq!(choice.directory, directory);
            assert!(choice.format.is_none());
        }
        assert_eq!(std::fs::read(file).unwrap(), b"unchanged");
    }
}
