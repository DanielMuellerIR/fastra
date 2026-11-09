//! Ausdrücklich verwendete Such-/Ersetz-Paare; keine Flags, Bereiche oder Dokumentinhalte.
use crate::{store_file::PrivateStore, Error};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::Path};

pub const MAX_ENTRIES: usize = 15;
pub const MAX_FIELD_BYTES: usize = 64 * 1024;
const MAX_BYTES: usize = MAX_ENTRIES * MAX_FIELD_BYTES * 12 + 4096;

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub find: String,
    pub replace: String,
}
impl Entry {
    fn validate(&self) -> Result<(), Error> {
        if self.find.len() > MAX_FIELD_BYTES || self.replace.len() > MAX_FIELD_BYTES {
            return Err(Error::Limit);
        }
        Ok(())
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct List {
    version: u32,
    entries: Vec<Entry>,
}
impl List {
    fn decode(bytes: Option<&[u8]>) -> Result<Self, Error> {
        let list: Self = match bytes {
            Some(bytes) => serde_json::from_slice(bytes)?,
            None => Self {
                version: 1,
                entries: Vec::new(),
            },
        };
        let mut seen = HashSet::new();
        if list.version != 1 || list.entries.len() > MAX_ENTRIES {
            return Err(Error::Invalid("search history format".into()));
        }
        for entry in &list.entries {
            entry.validate()?;
            if entry.find.is_empty() || !seen.insert(entry) {
                return Err(Error::Invalid("search history pair".into()));
            }
        }
        Ok(list)
    }
}
#[derive(Clone)]
pub enum Change {
    Remember(Entry),
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
            private: PrivateStore::open(config_root, "fastra-search-history", MAX_BYTES)?,
        })
    }
    pub fn load(&self) -> Result<Vec<Entry>, Error> {
        Ok(List::decode(self.private.load_bytes()?.as_deref())?.entries)
    }
    pub fn apply(&self, change: &Change) -> Result<Vec<Entry>, Error> {
        self.apply_observed(change, || {})
    }
    fn apply_observed(
        &self,
        change: &Change,
        mut observed: impl FnMut(),
    ) -> Result<Vec<Entry>, Error> {
        if let Change::Remember(entry) = change {
            // Auch ein überlanges Ersetzfeld ist bei leerer Suche ohne Bedeutung.
            if entry.find.is_empty() {
                return self.load();
            }
            entry.validate()?;
        }
        for _ in 0..6 {
            let expected = self.private.load_bytes()?;
            let mut list = List::decode(expected.as_deref())?;
            observed();
            match change {
                Change::Remember(entry) => {
                    list.entries.retain(|existing| existing != entry);
                    list.entries.insert(0, entry.clone());
                    list.entries.truncate(MAX_ENTRIES);
                }
                Change::Clear => list.entries.clear(),
            }
            let bytes = serde_json::to_vec(&list)?;
            match self.private.save_bytes(&expected, &bytes, |current| {
                List::decode(current.as_deref()).map(|_| ())
            }) {
                Ok(()) => return Ok(list.entries),
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
    use std::os::{
        fd::AsRawFd,
        unix::fs::{symlink, PermissionsExt},
    };
    fn pair(find: &str, replace: &str) -> Entry {
        Entry {
            find: find.into(),
            replace: replace.into(),
        }
    }
    fn remember(store: &Store, find: &str, replace: &str) -> Vec<Entry> {
        store.apply(&Change::Remember(pair(find, replace))).unwrap()
    }
    #[test]
    fn exact_pairs_move_to_front_and_survive_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        assert!(store.load().unwrap().is_empty());
        for n in 0..18 {
            remember(&store, &format!("f{n}"), "");
        }
        remember(&store, "f10", "other");
        remember(&store, "f10", "");
        remember(&store, "雪\n\\($1)\0", "Ä\n$2");
        let entries = Store::open(dir.path()).unwrap().load().unwrap();
        assert_eq!(entries.len(), MAX_ENTRIES);
        assert_eq!(
            entries[..3],
            [
                pair("雪\n\\($1)\0", "Ä\n$2"),
                pair("f10", ""),
                pair("f10", "other")
            ]
        );
        assert!(!entries.iter().any(|e| e.find == "f0"));
        assert_eq!(
            remember(&store, "", &"x".repeat(MAX_FIELD_BYTES + 1)),
            entries
        );
    }
    #[test]
    fn old_windows_reload_before_remember_and_explicit_clear() {
        let dir = tempfile::tempdir().unwrap();
        let a = Store::open(dir.path()).unwrap();
        let b = Store::open(dir.path()).unwrap();
        assert!(a.load().unwrap().is_empty());
        remember(&a, "alpha", "one");
        assert_eq!(
            remember(&b, "beta", "two"),
            [pair("beta", "two"), pair("alpha", "one")]
        );
        a.apply(&Change::Clear).unwrap();
        assert_eq!(remember(&b, "new", ""), [pair("new", "")]);
    }
    #[test]
    fn racing_compare_and_swap_merges_fresh_pairs_and_bounds_retries() {
        let dir = tempfile::tempdir().unwrap();
        let a = Store::open(dir.path()).unwrap();
        let b = Store::open(dir.path()).unwrap();
        let mut once = true;
        assert_eq!(
            a.apply_observed(&Change::Remember(pair("a", "")), || {
                if once {
                    once = false;
                    remember(&b, "b", "");
                }
            })
            .unwrap(),
            [pair("a", ""), pair("b", "")]
        );
        let mut count = 0;
        assert!(matches!(
            a.apply_observed(&Change::Clear, || {
                count += 1;
                remember(&b, &count.to_string(), "");
            }),
            Err(Error::Stale)
        ));
        assert_eq!(count, 6);
        assert_eq!(b.load().unwrap()[0].find, "6");
    }
    #[test]
    fn limits_and_corruption_do_not_overwrite_saved_data() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        remember(&store, "good", "");
        let file = dir.path().join("fastra-search-history/library.json");
        let before = std::fs::read(&file).unwrap();
        for entry in [
            pair(&"x".repeat(MAX_FIELD_BYTES + 1), ""),
            pair("x", &"y".repeat(MAX_FIELD_BYTES + 1)),
        ] {
            assert!(matches!(
                store.apply(&Change::Remember(entry)),
                Err(Error::Limit)
            ));
            assert_eq!(std::fs::read(&file).unwrap(), before);
        }
        for bytes in [
            b"broken".as_slice(),
            br#"{"version":2,"entries":[]}"#,
            br#"{"version":1,"entries":[{"find":"","replace":""}]}"#,
            br#"{"version":1,"entries":[{"find":"x","replace":""},{"find":"x","replace":""}]}"#,
        ] {
            std::fs::write(&file, bytes).unwrap();
            assert!(store.load().is_err());
            assert!(store.apply(&Change::Clear).is_err());
            assert_eq!(std::fs::read(&file).unwrap(), bytes);
        }
        std::fs::write(&file, vec![b' '; MAX_BYTES + 1]).unwrap();
        assert!(matches!(store.load(), Err(Error::Limit)));
        let list = List {
            version: 1,
            entries: (0..16).map(|n| pair(&n.to_string(), "")).collect(),
        };
        std::fs::write(&file, serde_json::to_vec(&list).unwrap()).unwrap();
        assert!(store.load().is_err());
    }
    #[test]
    fn private_permissions_symlinks_hardlinks_and_busy_store_are_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        remember(&store, "retained", "");
        let folder = dir.path().join("fastra-search-history");
        let file = folder.join("library.json");
        assert_eq!(
            std::fs::metadata(&folder).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
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
        std::fs::hard_link(&file, folder.join("hardlink")).unwrap();
        assert!(store.load().is_err());
        std::fs::remove_file(folder.join("hardlink")).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(store.load().is_err());
        std::fs::remove_file(&file).unwrap();
        symlink("/missing", &file).unwrap();
        assert!(store.load().is_err());
        let other = tempfile::tempdir().unwrap();
        symlink(&folder, other.path().join("fastra-search-history")).unwrap();
        assert!(Store::open(other.path()).is_err());
        assert!(Store::open(Path::new("relative")).is_err());
    }
}
