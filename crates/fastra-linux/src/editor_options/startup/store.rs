use super::super::store::Store;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    ffi::OsString,
    os::unix::ffi::{OsStrExt, OsStringExt},
    path::{Path, PathBuf},
};

const FILE: &str = "startup.json";
pub(super) const MAX_WINDOWS: usize = 64;
pub(super) const MAX_DOCUMENTS: usize = 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Position {
    pub x: i32,
    pub y: i32,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Window {
    pub project: Option<Vec<u8>>,
    pub documents: Vec<Vec<u8>>,
    pub active: Option<Vec<u8>>,
    pub width: i32,
    pub height: i32,
    pub maximized: bool,
    pub position: Option<Position>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Preference {
    version: u32,
    pub restore: bool,
    pub windows: Vec<Window>,
}
impl Default for Preference {
    fn default() -> Self {
        Self {
            version: 1,
            restore: true,
            windows: vec![],
        }
    }
}
pub(super) fn raw(path: &Path) -> Vec<u8> {
    path.as_os_str().as_bytes().to_vec()
}
pub(super) fn path(raw: &[u8]) -> PathBuf {
    PathBuf::from(OsString::from_vec(raw.to_vec()))
}
fn valid_path(path: &[u8]) -> bool {
    path.first() == Some(&b'/') && path.len() <= 4096 && !path.contains(&0)
}
impl Preference {
    fn validate(&self) -> Result<(), String> {
        let mut count = 0usize;
        if self.version != 1
            || self.windows.len() > MAX_WINDOWS
            || !self.restore && !self.windows.is_empty()
        {
            return Err("Invalid startup state; existing data retained".into());
        }
        for window in &self.windows {
            count = count.saturating_add(window.documents.len());
            let mut seen = HashSet::new();
            if count > MAX_DOCUMENTS
                || window.documents.is_empty()
                || !(1..=32768).contains(&window.width)
                || !(1..=32768).contains(&window.height)
                || window.position.is_some_and(|position| {
                    position.x.unsigned_abs() > 1_000_000 || position.y.unsigned_abs() > 1_000_000
                })
                || window
                    .project
                    .as_ref()
                    .is_some_and(|path| !valid_path(path))
                || window
                    .documents
                    .iter()
                    .any(|path| !valid_path(path) || !seen.insert(path))
                || window
                    .active
                    .as_ref()
                    .is_some_and(|active| !window.documents.contains(active))
            {
                return Err("Invalid startup window or path; existing data retained".into());
            }
        }
        Ok(())
    }
}
fn read(store: &Store) -> Result<Preference, String> {
    let preference: Preference = store
        .bytes(FILE)?
        .map(|bytes| serde_json::from_slice(&bytes).map_err(|error| error.to_string()))
        .transpose()?
        .unwrap_or_default();
    preference.validate()?;
    Ok(preference)
}
fn write(store: &Store, preference: &Preference, lock: &std::fs::File) -> Result<(), String> {
    let bytes = serde_json::to_vec(preference).map_err(|error| error.to_string())?;
    if bytes.len() > 1024 * 1024 {
        return Err("Startup state exceeds 1 MiB; existing state retained".into());
    }
    store.write(FILE, &bytes, lock)
}
pub(super) fn load(root: &Path) -> Result<Preference, String> {
    read(&Store::open(root)?)
}
pub(super) fn choose(root: &Path, restore: bool) -> Result<Preference, String> {
    let store = Store::open(root)?;
    let lock = store.wait_lock()?;
    let mut preference = read(&store)?;
    preference.restore = restore;
    if !restore {
        preference.windows.clear();
    }
    write(&store, &preference, &lock)?;
    Ok(preference)
}
pub(super) fn capture(root: &Path, windows: Vec<Window>) -> Result<Preference, String> {
    // Beim Beenden nur die vorhandenen Pfade übernehmen. Verfügbarkeit und
    // Symlinks werden beim nächsten Start geprüft, ohne fremde Laufwerke hier
    // nochmals anzufassen.
    let mut windows = windows;
    for window in &mut windows {
        let mut seen = HashSet::new();
        window.documents.retain(|path| seen.insert(path.clone()));
    }
    let store = Store::open(root)?;
    let lock = store.wait_lock()?;
    let mut preference = read(&store)?;
    preference.windows = if preference.restore { windows } else { vec![] };
    preference.validate()?;
    write(&store, &preference, &lock)?;
    Ok(preference)
}
pub(super) fn available(windows: Vec<Window>) -> Vec<Window> {
    windows
        .into_iter()
        .filter_map(|mut window| {
            let mut seen = HashSet::new();
            window.documents = window
                .documents
                .into_iter()
                .filter_map(|raw_path| {
                    let path = path(&raw_path).canonicalize().ok()?;
                    (path.is_file() && seen.insert(path.clone())).then(|| raw(&path))
                })
                .collect();
            window.project = window.project.and_then(|raw_path| {
                let path = path(&raw_path).canonicalize().ok()?;
                path.is_dir().then(|| raw(&path))
            });
            window.active = window
                .active
                .and_then(|active| path(&active).canonicalize().ok())
                .map(|active| raw(&active))
                .filter(|active| window.documents.contains(active));
            (!window.documents.is_empty()).then_some(window)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    fn window(path: &Path) -> Window {
        Window {
            project: path.parent().map(raw),
            documents: vec![raw(path)],
            active: Some(raw(path)),
            width: 900,
            height: 700,
            maximized: false,
            position: None,
        }
    }
    #[test]
    fn paths_only_roundtrip_raw_names_latest_optout_and_missing_windows() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir
            .path()
            .join(OsString::from_vec(b"name-\xff.md".to_vec()));
        std::fs::write(&file, b"PRIVATE UNSAVED CONTENT MUST NOT BE STORED").unwrap();
        assert!(load(dir.path()).unwrap().restore);
        let mut first = window(&file);
        let alias = dir.path().join("alias");
        symlink(&file, &alias).unwrap();
        first.documents.push(raw(&alias));
        let saved = capture(dir.path(), vec![first, window(&dir.path().join("missing"))]).unwrap();
        assert_eq!(
            saved.windows.len(),
            2,
            "capture does not access or discard unavailable source files"
        );
        let restored = available(saved.windows.clone());
        assert_eq!(restored.len(), 1);
        assert_eq!(restored[0].documents, vec![raw(&file)]);
        let bytes = std::fs::read(dir.path().join("fastra-editor/startup.json")).unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains("PRIVATE UNSAVED"));
        assert_eq!(load(dir.path()).unwrap(), saved);
        choose(dir.path(), false).unwrap();
        assert!(capture(dir.path(), vec![window(&file)])
            .unwrap()
            .windows
            .is_empty());
        choose(dir.path(), true).unwrap();
        assert!(load(dir.path()).unwrap().windows.is_empty());
    }
    #[test]
    fn invalid_locked_and_linked_state_is_never_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let file = dir.path().join("fastra-editor/startup.json");
        for data in [
            b"broken".as_slice(),
            br#"{"version":2,"restore":true,"windows":[]}"#,
            br#"{"version":1,"restore":true,"windows":[],"content":"secret"}"#,
        ] {
            std::fs::write(&file, data).unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
            assert!(load(dir.path()).is_err());
            assert!(choose(dir.path(), false).is_err());
            assert!(capture(dir.path(), vec![]).is_err());
            assert_eq!(std::fs::read(&file).unwrap(), data);
        }
        std::fs::remove_file(&file).unwrap();
        symlink("/not-a-file", &file).unwrap();
        assert!(choose(dir.path(), false).is_err());
        std::fs::remove_file(&file).unwrap();
        let _lock = store.lock().unwrap();
        assert!(choose(dir.path(), false).is_err());
        assert!(!file.exists());
    }
    #[test]
    fn malformed_windows_paths_counts_and_oversize_are_retained() {
        let dir = tempfile::tempdir().unwrap();
        Store::open(dir.path()).unwrap();
        let file = dir.path().join("fastra-editor/startup.json");
        let valid = window(Path::new("/safe.txt"));
        let mut cases = vec![Preference {
            version: 1,
            restore: true,
            windows: vec![valid.clone(); MAX_WINDOWS + 1],
        }];
        for change in 0..9 {
            let mut window = valid.clone();
            match change {
                0 => window.documents.clear(),
                1 => window.documents.push(window.documents[0].clone()),
                2 => window.documents[0] = b"relative".to_vec(),
                3 => window.documents[0] = b"/nul\0path".to_vec(),
                4 => window.documents[0] = vec![b'/'; 4097],
                5 => window.active = Some(b"/not-in-window".to_vec()),
                6 => window.width = 0,
                7 => window.height = 32769,
                _ => window.position = Some(Position { x: i32::MIN, y: 0 }),
            }
            cases.push(Preference {
                version: 1,
                restore: true,
                windows: vec![window],
            });
        }
        cases.push(Preference {
            version: 1,
            restore: false,
            windows: vec![valid],
        });
        let mut payloads: Vec<_> = cases
            .iter()
            .map(|case| serde_json::to_vec(case).unwrap())
            .collect();
        payloads.push(vec![b' '; 1024 * 1024 + 1]);
        for data in payloads {
            std::fs::write(&file, &data).unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
            assert!(load(dir.path()).is_err());
            assert!(choose(dir.path(), false).is_err());
            assert!(capture(dir.path(), vec![]).is_err());
            assert_eq!(std::fs::read(&file).unwrap(), data);
        }
    }
}
