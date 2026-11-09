//! Ein Tab-Drag gibt nur die vorhandene Datei weiter, niemals den Editorpuffer.
use super::*;
use std::path::{Path, PathBuf};

#[derive(Debug)]
enum SourceError {
    Metadata(std::io::Error),
    NotFile,
}
impl SourceError {
    fn message(&self, lang: crate::Language) -> String {
        match self {
            Self::Metadata(error) => error.to_string(),
            Self::NotFile => lang
                .text(
                    "Der gespeicherte Pfad ist keine reguläre Datei.",
                    "The saved path is not a regular file.",
                )
                .into(),
        }
    }
}
fn file(path: &Path) -> Result<gio::File, SourceError> {
    fastra_io::check_runtime_path(path).map_err(SourceError::Metadata)?;
    // metadata folgt gültigen Symlinks; ein gebrochener Link oder ein Ordner ist keine Datei.
    if !std::fs::metadata(path)
        .map_err(SourceError::Metadata)?
        .is_file()
    {
        return Err(SourceError::NotFile);
    }
    Ok(gio::File::for_path(path))
}

fn hint(ui: &Ui, doc: &Document) -> &'static str {
    if doc.buffer.is_modified()
        || doc
            .hex_editor
            .borrow()
            .as_ref()
            .is_some_and(|editor| editor.dirty())
    {
        ui.lang.text(
            "Gespeicherte Datei ziehen. Übertragen wird der letzte gespeicherte Stand ohne die ungespeicherten Änderungen.",
            "Drag the saved file. This transfers the last saved version without unsaved changes.",
        )
    } else {
        ui.lang.text(
            "Gespeicherte Datei in den Dateimanager oder eine andere App ziehen.",
            "Drag the saved file to the file manager or another app.",
        )
    }
}

pub(super) fn install(ui: &Rc<Ui>, doc: &Rc<Document>, row: &gtk::Box) {
    let handle = gtk::Image::from_icon_name("fastra-file-symbolic");
    handle.set_pixel_size(13);
    handle.set_widget_name("fastra-tab-file-handle");
    handle.set_size_request(16, 22);
    handle.set_valign(gtk::Align::Center);
    handle.update_property(&[gtk::accessible::Property::Label(
        ui.lang.text("Gespeicherte Datei ziehen", "Drag saved file"),
    )]);
    row.append(&handle);
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    let weak_handle = handle.downgrade();
    let refresh = Rc::new(move || {
        let (Some(ui), Some(doc), Some(handle)) =
            (weak_ui.upgrade(), weak_doc.upgrade(), weak_handle.upgrade())
        else {
            return;
        };
        handle.set_visible(doc.disk_path().is_some());
        let text = hint(&ui, &doc);
        handle.set_tooltip_text(Some(text));
        handle.update_property(&[gtk::accessible::Property::Description(text)]);
    });
    refresh();
    // update_label aktualisiert den Tooltip auch beim ersten Speichern mit gleichem Dateinamen.
    for property in ["label", "tooltip-text"] {
        let refresh = refresh.clone();
        doc.label
            .connect_notify_local(Some(property), move |_, _| refresh());
    }
    let source = gtk::DragSource::builder()
        .actions(gtk::gdk::DragAction::COPY)
        .build();
    let weak_ui = Rc::downgrade(ui);
    let weak_doc = Rc::downgrade(doc);
    source.connect_prepare(move |_, _, _| {
        let (Some(ui), Some(doc)) = (weak_ui.upgrade(), weak_doc.upgrade()) else {
            return None;
        };
        if !current(&ui, &doc) || doc.close_pending.get() || ui.window_close_dialog.get() {
            return None;
        }
        let path: PathBuf = doc.disk_path()?;
        match file(&path) {
            Ok(file) => Some(gtk::gdk::ContentProvider::for_value(
                &gtk::gdk::FileList::from_array(&[file]).to_value(),
            )),
            Err(error) => {
                ui.status.set_text(&format!(
                    "{}: {}",
                    ui.lang.text(
                        "Die gespeicherte Datei ist zum Ziehen nicht verfügbar",
                        "The saved file is unavailable for dragging"
                    ),
                    error.message(ui.lang)
                ));
                None
            }
        }
    });
    handle.add_controller(source);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn regular_file_and_symlinks_export_only_original_uri() {
        use std::os::unix::{ffi::OsStringExt, fs::symlink};
        let dir = tempfile::tempdir().unwrap();
        let source = dir
            .path()
            .join(std::ffi::OsString::from_vec(b"space % # \xff.txt".to_vec()));
        std::fs::write(&source, b"saved").unwrap();
        let link = dir.path().join("link");
        symlink(&source, &link).unwrap();
        assert_eq!(file(&source).unwrap().path().as_ref(), Some(&source));
        assert_eq!(file(&link).unwrap().path().as_ref(), Some(&link));
        assert_eq!(
            std::fs::read(file(&link).unwrap().path().unwrap()).unwrap(),
            b"saved"
        );
        assert!(file(dir.path()).is_err());
        std::fs::remove_file(&source).unwrap();
        assert!(file(&source).is_err());
        assert!(file(&link).is_err());
    }
    #[test]
    fn native_overlay_retargeted_drag_source_denied() {
        if std::env::var("FASTRA_POLICY_TEST_CASE").as_deref() != Ok("overlay") {
            return;
        }
        use std::os::unix::fs::symlink;
        fastra_io::initialize_runtime_policy().unwrap();
        let fixture =
            tempfile::tempdir_in(std::env::var_os("FASTRA_POLICY_TEST_ROOT").unwrap()).unwrap();
        let source = fixture.path().join("saved.txt");
        std::fs::write(&source, b"allowed saved bytes").unwrap();
        assert!(file(&source).is_ok());
        std::fs::remove_file(&source).unwrap();
        symlink("/usr/bin/bwrap", &source).unwrap();
        assert!(
            matches!(file(&source),Err(SourceError::Metadata(error)) if error.kind()==std::io::ErrorKind::PermissionDenied)
        );
        assert!(file(Path::new("/usr/share/zoneinfo/Etc/UTC")).is_ok());
    }
}
