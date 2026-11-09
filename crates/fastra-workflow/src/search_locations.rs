//! Private Suchquellen und projektgebundene Datei-Sets; Änderungen laden vor dem Schreiben neu.
use crate::{store_file::PrivateStore, Error};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    os::unix::ffi::{OsStrExt, OsStringExt},
    path::{Component, Path, PathBuf},
};
const MAX_BYTES: usize = 4 * 1024 * 1024;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Folder {
    pub path: Vec<u8>,
    pub enabled: bool,
}
impl Folder {
    pub fn path(&self) -> PathBuf {
        std::ffi::OsString::from_vec(self.path.clone()).into()
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct FileSet {
    pub id: String,
    pub name: String,
    pub paths: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub root: Vec<u8>,
    pub sets: Vec<FileSet>,
    pub active: String,
    pub known_text: bool,
    pub exclusions: String,
}
impl Project {
    pub fn fresh(root: &Path) -> Self {
        Self {
            root: root.as_os_str().as_bytes().into(),
            sets: vec![FileSet {
                id: "all".into(),
                name: "".into(),
                paths: vec![".".into()],
            }],
            active: "all".into(),
            known_text: true,
            exclusions: ".git, .build, build, DerivedData".into(),
        }
    }
    pub fn selected(&self) -> &FileSet {
        self.sets
            .iter()
            .find(|s| s.id == self.active)
            .expect("validated project")
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    version: u32,
    pub folders: Vec<Folder>,
    pub known_text: bool,
    pub projects: Vec<Project>,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            version: 1,
            folders: vec![],
            known_text: true,
            projects: vec![],
        }
    }
}
fn absolute(path: &[u8]) -> bool {
    path.first() == Some(&b'/') && path.len() <= 4096 && !path.contains(&0)
}
fn relative(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 4096
        && !path.contains('\0')
        && Path::new(path)
            .components()
            .all(|c| matches!(c, Component::Normal(_) | Component::CurDir))
}
fn valid_set(set: &FileSet) -> bool {
    !set.id.is_empty()
        && set.id.len() <= 128
        && !set.id.contains('\0')
        && set.name.len() <= 64 * 1024
        && !set.name.contains('\0')
        && !set.paths.is_empty()
        && set.paths.len() <= 10_000
        && set.paths.iter().all(|p| relative(p))
}
impl Settings {
    pub fn project(&self, root: &Path) -> Project {
        self.projects
            .iter()
            .find(|p| p.root == root.as_os_str().as_bytes())
            .cloned()
            .unwrap_or_else(|| Project::fresh(root))
    }
    fn decode(bytes: Option<&[u8]>) -> Result<Self, Error> {
        let s: Self = match bytes {
            Some(b) => serde_json::from_slice(b)?,
            None => Self::default(),
        };
        let mut roots = HashSet::new();
        let mut folders = HashSet::new();
        if s.version != 1
            || s.folders
                .iter()
                .any(|f| !absolute(&f.path) || !folders.insert(&f.path))
            || s.projects.iter().any(|p| {
                let mut ids = HashSet::new();
                !absolute(&p.root)
                    || !roots.insert(&p.root)
                    || p.sets.is_empty()
                    || p.sets
                        .iter()
                        .any(|set| !valid_set(set) || !ids.insert(&set.id))
                    || !p.sets.iter().any(|set| set.id == p.active)
                    || p.exclusions.len() > 64 * 1024
                    || p.exclusions.contains('\0')
            })
        {
            return Err(Error::Invalid("search settings".into()));
        }
        Ok(s)
    }
}
#[derive(Clone)]
pub enum ProjectChange {
    Add(FileSet),
    Remove(String),
    Select(String),
    Exclusions(String),
    KnownText(bool),
}
#[derive(Clone)]
pub enum Change {
    AddFolders(Vec<PathBuf>),
    EnableFolder(PathBuf, bool),
    RemoveFolder(PathBuf),
    KnownText(bool),
    Project(PathBuf, ProjectChange),
}
pub struct Store {
    private: PrivateStore,
}
impl Store {
    pub fn open(root: &Path) -> Result<Self, Error> {
        if !root.is_absolute() {
            return Err(Error::Invalid("configuration root".into()));
        }
        Ok(Self {
            private: PrivateStore::open(root, "fastra-search-locations", MAX_BYTES)?,
        })
    }
    pub fn load(&self) -> Result<Settings, Error> {
        Settings::decode(self.private.load_bytes()?.as_deref())
    }
    pub fn apply(&self, change: &Change) -> Result<Settings, Error> {
        for _ in 0..6 {
            let expected = self.private.load_bytes()?;
            let mut s = Settings::decode(expected.as_deref())?;
            match change {
                Change::AddFolders(paths) => {
                    for path in paths {
                        let bytes = path.as_os_str().as_bytes();
                        if !absolute(bytes) {
                            return Err(Error::Invalid("folder path".into()));
                        }
                        if let Some(f) = s.folders.iter_mut().find(|f| f.path == bytes) {
                            f.enabled = true;
                        } else {
                            s.folders.push(Folder {
                                path: bytes.into(),
                                enabled: true,
                            });
                        }
                    }
                }
                Change::EnableFolder(path, enabled) => {
                    let f = s
                        .folders
                        .iter_mut()
                        .find(|f| f.path == path.as_os_str().as_bytes())
                        .ok_or_else(|| Error::Missing("folder".into()))?;
                    f.enabled = *enabled;
                }
                Change::RemoveFolder(path) => {
                    s.folders.retain(|f| f.path != path.as_os_str().as_bytes())
                }
                Change::KnownText(value) => s.known_text = *value,
                Change::Project(root, change) => {
                    if !absolute(root.as_os_str().as_bytes()) {
                        return Err(Error::Invalid("project root".into()));
                    }
                    if !s
                        .projects
                        .iter()
                        .any(|p| p.root == root.as_os_str().as_bytes())
                    {
                        s.projects.push(Project::fresh(root));
                    }
                    let p = s
                        .projects
                        .iter_mut()
                        .find(|p| p.root == root.as_os_str().as_bytes())
                        .unwrap();
                    match change {
                        ProjectChange::Add(set) => {
                            if !valid_set(set)
                                || set.name.trim().is_empty()
                                || p.sets.iter().any(|s| s.id == set.id)
                            {
                                return Err(Error::Invalid("file set".into()));
                            }
                            p.sets.push(set.clone());
                            p.active = set.id.clone();
                        }
                        ProjectChange::Remove(id) => {
                            if p.sets.len() <= 1 || !p.sets.iter().any(|s| s.id == *id) {
                                return Err(Error::Invalid("last/missing file set".into()));
                            }
                            p.sets.retain(|s| s.id != *id);
                            if p.active == *id {
                                p.active = p.sets[0].id.clone();
                            }
                        }
                        ProjectChange::Select(id) => {
                            if !p.sets.iter().any(|s| s.id == *id) {
                                return Err(Error::Missing("file set".into()));
                            }
                            p.active = id.clone();
                        }
                        ProjectChange::Exclusions(text) => p.exclusions = text.clone(),
                        ProjectChange::KnownText(value) => p.known_text = *value,
                    }
                }
            }
            let bytes = serde_json::to_vec(&s)?;
            Settings::decode(Some(&bytes))?;
            match self.private.save_bytes(&expected, &bytes, |current| {
                Settings::decode(current.as_deref()).map(|_| ())
            }) {
                Ok(()) => return Ok(s),
                Err(Error::Stale) => continue,
                Err(e) => return Err(e),
            }
        }
        Err(Error::Stale)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roots_flags_file_sets_and_fresh_writers_survive_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let a = Store::open(dir.path()).unwrap();
        let b = Store::open(dir.path()).unwrap();
        let raw: PathBuf = std::ffi::OsString::from_vec(b"/raw-\xff\n".to_vec()).into();
        a.apply(&Change::AddFolders(vec!["/first".into(), raw.clone()]))
            .unwrap();
        b.apply(&Change::EnableFolder(raw.clone(), false)).unwrap();
        let set = FileSet {
            id: "one".into(),
            name: "Source".into(),
            paths: vec!["src".into(), "README.md".into()],
        };
        a.apply(&Change::Project(
            "/project".into(),
            ProjectChange::Add(set.clone()),
        ))
        .unwrap();
        b.apply(&Change::Project(
            "/other".into(),
            ProjectChange::KnownText(false),
        ))
        .unwrap();
        let result = Store::open(dir.path()).unwrap().load().unwrap();
        assert_eq!(result.folders[1].path(), raw);
        assert!(!result.folders[1].enabled);
        assert_eq!(result.project(Path::new("/project")).selected(), &set);
        assert!(!result.project(Path::new("/other")).known_text);
        assert!(a
            .apply(&Change::Project(
                "/other".into(),
                ProjectChange::Remove("all".into())
            ))
            .is_err());
        let result = a
            .apply(&Change::Project(
                "/project".into(),
                ProjectChange::Remove("one".into()),
            ))
            .unwrap();
        assert_eq!(result.project(Path::new("/project")).active, "all");
        for path in ["", "../outside", "src/../outside", "/absolute", "a\0b"] {
            let mut bad = set.clone();
            bad.paths = vec![path.into()];
            assert!(a
                .apply(&Change::Project("/project".into(), ProjectChange::Add(bad)))
                .is_err());
        }
        assert_eq!(a.load().unwrap(), result);
    }
    #[test]
    fn corrupt_or_linked_settings_cannot_be_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.apply(&Change::KnownText(false)).unwrap();
        let path = dir.path().join("fastra-search-locations/library.json");
        std::fs::write(&path, b"broken").unwrap();
        assert!(store.load().is_err());
        assert!(store.apply(&Change::KnownText(true)).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"broken");
        std::fs::remove_file(&path).unwrap();
        let outside = dir.path().join("outside");
        std::fs::write(&outside, b"retained").unwrap();
        std::os::unix::fs::symlink(&outside, &path).unwrap();
        assert!(store.load().is_err());
        assert!(store.apply(&Change::KnownText(true)).is_err());
        assert_eq!(std::fs::read(outside).unwrap(), b"retained");
    }
}
