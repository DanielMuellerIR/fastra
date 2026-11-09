//! Zuletzt ausdrücklich gewählte Projekte; nur Pfade, keine Dokumentinhalte oder Autostarts.
use crate::{store_file::PrivateStore, Error};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    os::unix::ffi::{OsStrExt, OsStringExt},
    path::{Path, PathBuf},
};

const MAX_PROJECTS: usize = 12;
const MAX_BYTES: usize = 256 * 1024;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct List {
    version: u32,
    paths: Vec<Vec<u8>>,
}
impl Default for List {
    fn default() -> Self {
        Self {
            version: 1,
            paths: Vec::new(),
        }
    }
}
fn valid(path: &[u8]) -> bool {
    path.first() == Some(&b'/') && path.len() <= 4096 && !path.contains(&0)
}
impl List {
    fn decode(bytes: Option<&[u8]>) -> Result<Self, Error> {
        let list: Self = match bytes {
            Some(bytes) => serde_json::from_slice(bytes)?,
            None => Self::default(),
        };
        let mut seen = HashSet::new();
        if list.version != 1
            || list.paths.len() > MAX_PROJECTS
            || list.paths.iter().any(|p| !valid(p) || !seen.insert(p))
        {
            return Err(Error::Invalid("recent projects".into()));
        }
        Ok(list)
    }
    fn paths(self) -> Vec<PathBuf> {
        self.paths
            .into_iter()
            .map(|p| std::ffi::OsString::from_vec(p).into())
            .collect()
    }
}
#[derive(Clone)]
pub enum Change {
    Remember(PathBuf),
    Remove(PathBuf),
    Clear,
}
pub struct Store {
    private: PrivateStore,
}
impl Store {
    pub fn open(config_root: &Path) -> Result<Self, Error> {
        if !config_root.is_absolute() {
            return Err(Error::Invalid("configuration directory".into()));
        }
        Ok(Self {
            private: PrivateStore::open(config_root, "fastra-recent-projects", MAX_BYTES)?,
        })
    }
    pub fn load(&self) -> Result<Vec<PathBuf>, Error> {
        let bytes = self.private.load_bytes()?;
        Ok(List::decode(bytes.as_deref())?.paths())
    }
    pub fn apply(&self, change: &Change) -> Result<Vec<PathBuf>, Error> {
        self.apply_observed(change, || {})
    }
    fn apply_observed(
        &self,
        change: &Change,
        mut observed: impl FnMut(),
    ) -> Result<Vec<PathBuf>, Error> {
        if let Change::Remember(path) | Change::Remove(path) = change {
            if !valid(path.as_os_str().as_bytes()) {
                return Err(Error::Invalid("project path".into()));
            }
        }
        for _ in 0..6 {
            let expected = self.private.load_bytes()?;
            let mut list = List::decode(expected.as_deref())?;
            observed();
            match change {
                Change::Remember(path) => {
                    let path = path.as_os_str().as_bytes();
                    list.paths.retain(|p| p != path);
                    list.paths.insert(0, path.to_vec());
                    list.paths.truncate(MAX_PROJECTS);
                }
                Change::Remove(path) => list.paths.retain(|p| p != path.as_os_str().as_bytes()),
                Change::Clear => list.paths.clear(),
            }
            let bytes = serde_json::to_vec(&list)?;
            match self.private.save_bytes(&expected, &bytes, |current| {
                List::decode(current.as_deref()).map(|_| ())
            }) {
                Ok(()) => return Ok(list.paths()),
                Err(Error::Stale) => continue,
                Err(error) => return Err(error),
            }
        }
        Err(Error::Stale)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    fn remember(store: &Store, path: &str) {
        store.apply(&Change::Remember(path.into())).unwrap();
    }
    #[test]
    fn mru_limit_dedup_and_raw_paths_survive_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        for n in 0..15 {
            remember(&store, &format!("/project-{n}"));
        }
        let raw: PathBuf = std::ffi::OsString::from_vec(b"/raw-\xff\n\\".to_vec()).into();
        store.apply(&Change::Remember(raw.clone())).unwrap();
        remember(&store, "/project-10");
        let paths = Store::open(dir.path()).unwrap().load().unwrap();
        assert_eq!(paths.len(), 12);
        assert_eq!(paths[0], Path::new("/project-10"));
        assert_eq!(paths[1], raw);
        assert_eq!(
            paths
                .iter()
                .filter(|p| p == &Path::new("/project-10"))
                .count(),
            1
        );
        assert!(!paths.contains(&PathBuf::from("/project-0")));
    }
    #[test]
    fn old_windows_merge_fresh_remove_and_clear() {
        let dir = tempfile::tempdir().unwrap();
        let a = Store::open(dir.path()).unwrap();
        let b = Store::open(dir.path()).unwrap();
        assert!(a.load().unwrap().is_empty());
        remember(&b, "/b");
        remember(&a, "/a");
        a.apply(&Change::Remove("/b".into())).unwrap();
        remember(&b, "/c");
        assert_eq!(
            a.load().unwrap(),
            vec![PathBuf::from("/c"), PathBuf::from("/a")]
        );
        b.apply(&Change::Clear).unwrap();
        assert!(a.load().unwrap().is_empty());
    }
    #[test]
    fn racing_cas_reloads_and_merges_instead_of_overwriting() {
        let dir = tempfile::tempdir().unwrap();
        let a = Store::open(dir.path()).unwrap();
        let b = Store::open(dir.path()).unwrap();
        let mut once = true;
        let paths = a
            .apply_observed(&Change::Remember("/a".into()), || {
                if once {
                    once = false;
                    remember(&b, "/b");
                }
            })
            .unwrap();
        assert_eq!(paths, vec![PathBuf::from("/a"), PathBuf::from("/b")]);
        let mut n = 0;
        assert!(matches!(
            a.apply_observed(&Change::Clear, || {
                n += 1;
                remember(&b, &format!("/race-{n}"));
            }),
            Err(Error::Stale)
        ));
        assert_eq!(n, 6);
        assert_eq!(b.load().unwrap()[0], Path::new("/race-6"));
    }
    #[test]
    fn invalid_paths_corruption_and_unsafe_files_are_retained() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        remember(&store, "/ok");
        for path in [
            PathBuf::from("relative"),
            std::ffi::OsString::from_vec(b"/nul\0".to_vec()).into(),
            PathBuf::from(format!("/{}", "a".repeat(4096))),
        ] {
            assert!(store.apply(&Change::Remember(path)).is_err());
        }
        assert_eq!(store.load().unwrap(), vec![PathBuf::from("/ok")]);
        let file = dir.path().join("fastra-recent-projects/library.json");
        for bytes in [
            b"broken".as_slice(),
            br#"{"version":2,"paths":[]}"#,
            br#"{"version":1,"paths":[[47],[47]]}"#,
            br#"{"version":1,"paths":[[0]]}"#,
        ] {
            std::fs::write(&file, bytes).unwrap();
            assert!(store.apply(&Change::Clear).is_err());
            assert_eq!(std::fs::read(&file).unwrap(), bytes);
        }
        std::fs::remove_file(&file).unwrap();
        symlink("/missing", &file).unwrap();
        assert!(store.load().is_err());
        std::fs::remove_file(&file).unwrap();
        std::fs::write(&file, b"{}").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(store.load().is_err());
    }
    #[test]
    fn bounded_file_and_busy_store_never_replace_existing_data() {
        use std::os::fd::AsRawFd;
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        remember(&store, "/ok");
        let folder = dir.path().join("fastra-recent-projects");
        let file = folder.join("library.json");
        let before = std::fs::read(&file).unwrap();
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(folder.join(".lock"))
            .unwrap();
        assert_eq!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        assert!(store.apply(&Change::Clear).is_err());
        assert_eq!(std::fs::read(&file).unwrap(), before);
        drop(lock);
        std::fs::write(&file, vec![b' '; MAX_BYTES + 1]).unwrap();
        assert!(matches!(store.load(), Err(Error::Limit)));
        assert!(store.apply(&Change::Clear).is_err());
        assert_eq!(
            std::fs::metadata(&file).unwrap().len(),
            (MAX_BYTES + 1) as u64
        );
        let too_many = List {
            version: 1,
            paths: (0..13)
                .map(|n| format!("/project-{n}").into_bytes())
                .collect(),
        };
        std::fs::write(&file, serde_json::to_vec(&too_many).unwrap()).unwrap();
        assert!(store.load().is_err());
    }
}
