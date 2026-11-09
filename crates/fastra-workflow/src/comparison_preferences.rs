//! Vergleichsoptionen, Spaltenteilung und Dateiverlauf teilen die bestehende private Byteablage.
use crate::{store_file::PrivateStore, Error};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    os::unix::ffi::{OsStrExt, OsStringExt},
    path::{Path, PathBuf},
};
const MAX_BYTES: usize = 2 * 1024 * 1024;
const MAX_RECENT: usize = 100;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    version: u32,
    pub options: [bool; 4],
    /// Anteil der linken Spalte in Hundertstelprozent (0 bis 10.000).
    #[serde(default = "default_split_ratio")]
    pub split_ratio: u16,
    recent: Vec<Vec<u8>>,
}
fn default_split_ratio() -> u16 {
    5000
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            version: 2,
            options: [false; 4],
            split_ratio: default_split_ratio(),
            recent: Vec::new(),
        }
    }
}
impl Settings {
    fn decode(bytes: Option<&[u8]>) -> Result<Self, Error> {
        let mut value: Self = match bytes {
            Some(bytes) => serde_json::from_slice(bytes)?,
            None => Self::default(),
        };
        let mut unique = HashSet::new();
        if !(1..=2).contains(&value.version)
            || value.split_ratio > 10_000
            || value.recent.len() > MAX_RECENT
            || value
                .recent
                .iter()
                .any(|path| !valid_path(path) || !unique.insert(path))
        {
            return Err(Error::Invalid("comparison preferences".into()));
        }
        value.version = 2;
        Ok(value)
    }
    pub fn recent_files(&self) -> Vec<PathBuf> {
        self.recent
            .iter()
            .map(|raw| std::ffi::OsString::from_vec(raw.clone()).into())
            .collect()
    }
}
fn valid_path(path: &[u8]) -> bool {
    path.first() == Some(&b'/') && path.len() <= 4096 && !path.contains(&0)
}
pub enum Change {
    SplitRatio(u16),
    Option { index: usize, value: bool },
    Opened(PathBuf),
    Remove(PathBuf),
}
pub struct Store {
    private: PrivateStore,
}
impl Store {
    pub fn open(config: &Path) -> Result<Self, Error> {
        Ok(Self {
            private: PrivateStore::open(config, "fastra-file-comparison", MAX_BYTES)?,
        })
    }
    pub fn load(&self) -> Result<Settings, Error> {
        Settings::decode(self.private.load_bytes()?.as_deref())
    }
    pub fn apply(&self, change: &Change) -> Result<Settings, Error> {
        self.apply_observed(change, || {})
    }
    fn apply_observed(
        &self,
        change: &Change,
        mut observed: impl FnMut(),
    ) -> Result<Settings, Error> {
        if let Change::Opened(path) | Change::Remove(path) = change {
            if !valid_path(path.as_os_str().as_bytes()) {
                return Err(Error::Invalid("recent file path".into()));
            }
        }
        for _ in 0..6 {
            let expected = self.private.load_bytes()?;
            let mut settings = Settings::decode(expected.as_deref())?;
            observed();
            match change {
                Change::SplitRatio(ratio) => settings.split_ratio = *ratio,
                Change::Option { index, value } => {
                    *settings
                        .options
                        .get_mut(*index)
                        .ok_or_else(|| Error::Invalid("comparison option".into()))? = *value
                }
                Change::Opened(path) => {
                    let raw = path.as_os_str().as_bytes();
                    if !valid_path(raw) {
                        return Err(Error::Invalid("recent file path".into()));
                    }
                    settings.recent.retain(|other| other != raw);
                    settings.recent.insert(0, raw.into());
                    settings.recent.truncate(MAX_RECENT);
                }
                Change::Remove(path) => settings
                    .recent
                    .retain(|other| other != path.as_os_str().as_bytes()),
            }
            let bytes = serde_json::to_vec(&settings)?;
            Settings::decode(Some(&bytes))?;
            match self.private.save_bytes(&expected, &bytes, |current| {
                Settings::decode(current.as_deref()).map(|_| ())
            }) {
                Ok(()) => return Ok(settings),
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
    #[test]
    fn concurrent_fields_and_recent_paths_are_merged_after_cas_retry() {
        let root = tempfile::tempdir().unwrap();
        let first = Store::open(root.path()).unwrap();
        let second = Store::open(root.path()).unwrap();
        assert_eq!(first.load().unwrap().options, [false; 4]);
        let raw = PathBuf::from(std::ffi::OsString::from_vec(
            b"/fixture/nonutf8-\xff.txt".to_vec(),
        ));
        let mut interleaved = false;
        first
            .apply_observed(
                &Change::Option {
                    index: 0,
                    value: true,
                },
                || {
                    if !interleaved {
                        interleaved = true;
                        second.apply(&Change::Opened(raw.clone())).unwrap();
                        second
                            .apply(&Change::Option {
                                index: 2,
                                value: true,
                            })
                            .unwrap();
                    }
                },
            )
            .unwrap();
        let settings = second.load().unwrap();
        assert_eq!(settings.options, [true, false, true, false]);
        assert_eq!(settings.recent_files(), [raw]);
    }
    #[test]
    fn recent_files_are_ordered_bounded_and_raw_paths_survive() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::open(root.path()).unwrap();
        for i in 0..=MAX_RECENT {
            store
                .apply(&Change::Opened(PathBuf::from(format!("/fixture/{i}.txt"))))
                .unwrap();
        }
        let paths = store.load().unwrap().recent_files();
        assert_eq!(paths.len(), 100);
        assert_eq!(paths.first().unwrap(), Path::new("/fixture/100.txt"));
        assert_eq!(paths.last().unwrap(), Path::new("/fixture/1.txt"));
        store.apply(&Change::Opened(paths[50].clone())).unwrap();
        let recent = store.load().unwrap().recent_files();
        assert_eq!(recent[0], paths[50]);
        assert_eq!(recent.len(), 100);
        store.apply(&Change::Remove(paths[50].clone())).unwrap();
        assert_eq!(store.load().unwrap().recent_files().len(), 99);
        assert!(store
            .apply(&Change::Opened(PathBuf::from("relative")))
            .is_err());
        assert!(store
            .apply(&Change::Remove(PathBuf::from("relative")))
            .is_err());
    }
    #[test]
    fn future_or_invalid_settings_do_not_get_overwritten() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::open(root.path()).unwrap();
        let path = root.path().join("fastra-file-comparison/library.json");
        let bytes = br#"{"version":99,"options":[false,false,false,false],"recent":[]}"#;
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .unwrap()
            .write_all(bytes)
            .unwrap();
        assert!(store.load().is_err());
        assert!(store
            .apply(&Change::Option {
                index: 0,
                value: true
            })
            .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
    #[test]
    fn legacy_preferences_upgrade_without_losing_options_or_recent_paths() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::open(root.path()).unwrap();
        let legacy = br#"{"version":1,"options":[true,false,true,false],"recent":[[47,97]]}"#;
        store.private.save_bytes(&None, legacy, |_| Ok(())).unwrap();
        let loaded = store.load().unwrap();
        assert_eq!(loaded.version, 2);
        assert_eq!(loaded.split_ratio, 5000);
        assert_eq!(
            std::fs::read(root.path().join("fastra-file-comparison/library.json")).unwrap(),
            legacy
        );
        let migrated = store.apply(&Change::SplitRatio(7250)).unwrap();
        assert_eq!(migrated.options, [true, false, true, false]);
        assert_eq!(migrated.recent_files(), [PathBuf::from("/a")]);
        assert_eq!(migrated.split_ratio, 7250);
        assert!(store.apply(&Change::SplitRatio(10001)).is_err());
        assert_eq!(store.load().unwrap(), migrated);
    }
    #[test]
    fn divider_update_preserves_concurrently_changed_options_and_recent_files() {
        let root = tempfile::tempdir().unwrap();
        let first = Store::open(root.path()).unwrap();
        let second = Store::open(root.path()).unwrap();
        let mut interleaved = false;
        first
            .apply_observed(&Change::SplitRatio(6500), || {
                if !interleaved {
                    interleaved = true;
                    second
                        .apply(&Change::Opened(PathBuf::from("/second")))
                        .unwrap();
                    second
                        .apply(&Change::Option {
                            index: 1,
                            value: true,
                        })
                        .unwrap();
                }
            })
            .unwrap();
        let settings = second.load().unwrap();
        assert_eq!(settings.split_ratio, 6500);
        assert!(settings.options[1]);
        assert_eq!(settings.recent_files(), [PathBuf::from("/second")]);
    }
    #[test]
    fn full_capacity_accepts_maximum_raw_byte_paths() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::open(root.path()).unwrap();
        let settings = Settings {
            recent: (0..MAX_RECENT)
                .map(|i| {
                    let mut raw = vec![b'/'];
                    raw.extend(vec![255; 4090]);
                    raw.extend(format!("{i:05}").bytes());
                    raw
                })
                .collect(),
            ..Settings::default()
        };
        let bytes = serde_json::to_vec(&settings).unwrap();
        assert!(bytes.len() < MAX_BYTES);
        assert_eq!(settings.recent[0].len(), 4096);
        store.private.save_bytes(&None, &bytes, |_| Ok(())).unwrap();
        assert_eq!(store.load().unwrap(), settings);
    }
}
