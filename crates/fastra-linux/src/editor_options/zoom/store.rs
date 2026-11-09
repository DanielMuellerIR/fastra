use super::super::store::Store;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(super) struct Levels {
    pub ui: i32,
    pub document: i32,
}
impl Levels {
    fn validate(self) -> Result<Self, String> {
        if !(-3..=5).contains(&self.ui) || !(-4..=8).contains(&self.document) {
            return Err("Invalid zoom levels; existing setting retained".into());
        }
        Ok(self)
    }
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Preference {
    version: u32,
    levels: Levels,
}
fn read(store: &Store) -> Result<Levels, String> {
    let Some(bytes) = store.bytes("zoom.json")? else {
        return Ok(Levels::default());
    };
    if bytes.len() > 4096 {
        return Err("Zoom preference exceeds 4 KiB; existing setting retained".into());
    }
    let preference: Preference =
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    if preference.version != 1 {
        return Err("Unsupported zoom preference version; existing setting retained".into());
    }
    preference.levels.validate()
}
pub(super) fn load(root: &Path) -> Result<Levels, String> {
    read(&Store::open(root)?)
}
pub(super) fn save(root: &Path, levels: Levels) -> Result<(), String> {
    levels.validate()?;
    let store = Store::open(root)?;
    let lock = store.wait_lock()?;
    read(&store)?;
    store.write(
        "zoom.json",
        &serde_json::to_vec(&Preference { version: 1, levels })
            .map_err(|error| error.to_string())?,
        &lock,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    #[test]
    fn independent_zoom_roundtrips_and_preserves_busy_corrupt_or_linked_settings() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load(dir.path()).unwrap(), Levels::default());
        for levels in [
            Levels {
                ui: -3,
                document: 8,
            },
            Levels {
                ui: 5,
                document: -4,
            },
        ] {
            save(dir.path(), levels).unwrap();
            assert_eq!(load(dir.path()).unwrap(), levels);
        }
        let path = dir.path().join("fastra-editor/zoom.json");
        let bytes = std::fs::read(&path).unwrap();
        assert!(save(dir.path(), Levels { ui: 6, document: 0 }).is_err());
        let store = Store::open(dir.path()).unwrap();
        let lock = store.lock().unwrap();
        assert!(save(dir.path(), Levels::default()).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        drop(lock);
        for invalid in [
            r#"{"version":2,"levels":{"ui":0,"document":0}}"#,
            r#"{"version":1,"levels":{"ui":0,"document":9}}"#,
            r#"{"version":1,"levels":{"ui":0,"document":0},"other":true}"#,
        ] {
            std::fs::write(&path, invalid).unwrap();
            assert!(load(dir.path()).is_err());
            assert!(save(dir.path(), Levels::default()).is_err());
            assert_eq!(std::fs::read_to_string(&path).unwrap(), invalid);
        }
        std::fs::remove_file(&path).unwrap();
        let external = dir.path().join("external.json");
        std::fs::write(&external, &bytes).unwrap();
        symlink(&external, &path).unwrap();
        assert!(load(dir.path()).is_err());
        assert!(save(dir.path(), Levels::default()).is_err());
        assert_eq!(std::fs::read(&external).unwrap(), bytes);
    }
}
