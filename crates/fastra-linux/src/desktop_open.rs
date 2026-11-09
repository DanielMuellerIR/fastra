#[cfg(debug_assertions)]
use super::project_view;
use super::{git_view, Ui};
use gtk::{gio, prelude::*};
use std::{cell::Cell, collections::HashSet, path::PathBuf, rc::Rc};

const MAX_ITEMS: usize = 32;
struct Items {
    files: Vec<PathBuf>,
    project: Option<PathBuf>,
}
fn inspect(paths: Vec<PathBuf>) -> Result<Items, String> {
    if paths.is_empty() || paths.len() > MAX_ITEMS {
        return Err("1–32".into());
    }
    let mut seen = HashSet::new();
    let mut items = Items {
        files: Vec::new(),
        project: None,
    };
    for path in paths {
        let path = std::fs::canonicalize(path).map_err(|e| e.to_string())?;
        if !seen.insert(path.clone()) {
            continue;
        }
        let metadata = std::fs::metadata(&path).map_err(|e| e.to_string())?;
        if metadata.is_file() {
            items.files.push(path);
        } else if metadata.is_dir() && items.project.is_none() {
            items.project = Some(path);
        } else {
            return Err("Regular files and at most one directory required".into());
        }
    }
    Ok(items)
}
struct State {
    ui: std::rc::Weak<Ui>,
    generation: Cell<u64>,
}
impl State {
    fn cancel(&self) {
        self.generation.set(self.generation.get().wrapping_add(1));
    }
    fn request(self: &Rc<Self>, files: &[gio::File]) -> bool {
        let Some(ui) = self.ui.upgrade().filter(|ui| ui.window.is_visible()) else {
            return false;
        };
        self.cancel();
        let generation = self.generation.get();
        if files.is_empty() || files.len() > MAX_ITEMS {
            ui.status.set_text(ui.lang.text(
                "Öffnen abgewiesen: 1–32 lokale Dateien und höchstens ein Ordner pro Vorgang.",
                "Open refused: 1–32 local files and at most one folder per operation.",
            ));
            return false;
        }
        let paths: Option<Vec<PathBuf>> = files.iter().map(gio::File::path).collect();
        let Some(paths) = paths else {
            ui.status.set_text(ui.lang.text(
                "Nur lokale Dateien und Ordner öffnen; entfernte Adressen werden nicht geladen.",
                "Only local files and folders can be opened; remote addresses are not loaded.",
            ));
            return false;
        };
        ui.status.set_text(ui.lang.text(
            "Lokale Dateien prüfen … Ordner werden als Projekt geöffnet.",
            "Checking local files … Folders open as projects.",
        ));
        let state = self.clone();
        git_view::background(
            move || inspect(paths),
            move |result| {
                let Some(ui) = state
                    .ui
                    .upgrade()
                    .filter(|ui| ui.window.is_visible() && state.generation.get() == generation)
                else {
                    return;
                };
                match result {
                Ok(items) => {
                    ui.status.set_text(ui.lang.text(
                        "Geprüfte Auswahl öffnen; Dateien erhalten eigene Tabs, ein Ordner den Projektbaum.",
                        "Opening checked selection; files use separate tabs and a folder uses the project tree.",
                    ));
                    if let Some(path) = items.project {
                        let state = state.clone();
                        super::import_view::route_open(&ui, path, None, Rc::new(move || state.generation.get() == generation), None);
                    }
                    for path in items.files {
                        let state = state.clone();
                        ui.load_path_owned(path, Rc::new(move || state.generation.get() == generation));
                    }
                }
                Err(error) => ui.status.set_text(&format!("{} {error}", ui.lang.text("Öffnen abgewiesen; reguläre Dateien und höchstens ein Ordner erforderlich:", "Open refused; regular files and at most one folder required:"))),
            }
            },
        );
        true
    }
}
fn state(ui: &Rc<Ui>) -> Rc<State> {
    let state = Rc::new(State {
        ui: Rc::downgrade(ui),
        generation: Cell::new(0),
    });
    let weak = Rc::downgrade(&state);
    ui.window.connect_visible_notify(move |window| {
        if !window.is_visible() {
            if let Some(state) = weak.upgrade() {
                state.cancel();
            }
        }
    });
    state
}
pub(super) fn open_files(ui: &Rc<Ui>, files: &[gio::File]) {
    state(ui).request(files);
}
pub(super) fn install(ui: &Rc<Ui>) {
    let state = state(ui);
    let target = gtk::DropTarget::new(
        gtk::gdk::FileList::static_type(),
        gtk::gdk::DragAction::COPY,
    );
    target.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak=Rc::downgrade(ui);
    target.connect_drop(move |_, value, x, y| {
        value.get::<gtk::gdk::FileList>().is_ok_and(|list| {
            let files=list.files();
            if weak.upgrade().is_some_and(|ui|crate::rich_editor::drop_files_at(&ui,&files,x,y)){return true;}
            state.request(&files)
        })
    });
    ui.window.add_controller(target);
}

#[cfg(debug_assertions)]
mod gui_test;
#[cfg(debug_assertions)]
pub(super) use gui_test::run;
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_drop_plan_preserves_raw_paths_deduplicates_and_rejects_whole_invalid_input() {
        use std::os::unix::{ffi::OsStringExt, fs::symlink};
        let root = tempfile::tempdir().unwrap();
        let file = root
            .path()
            .join(std::ffi::OsString::from_vec(b"a#%\\\n\xff".to_vec()));
        std::fs::write(&file, b"unchanged").unwrap();
        let alias = root.path().join("alias");
        symlink(&file, &alias).unwrap();
        let a = root.path().join("a");
        let b = root.path().join("b");
        std::fs::create_dir(&a).unwrap();
        std::fs::create_dir(&b).unwrap();
        let plan = inspect(vec![file.clone(), alias, a.clone()]).unwrap();
        assert_eq!(plan.files, vec![file.clone()]);
        assert_eq!(plan.project, Some(a.clone()));
        assert!(inspect(vec![file.clone(), root.path().join("missing")]).is_err());
        assert!(inspect(vec![a, b]).is_err());
        let fifo = root.path().join("fifo");
        let path = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        assert!(inspect(vec![fifo]).is_err());
        assert!(inspect(vec![file.clone(); MAX_ITEMS + 1]).is_err());
        assert_eq!(std::fs::read(&file).unwrap(), b"unchanged");
    }
}
