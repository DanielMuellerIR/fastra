use super::super::store::Store;
use serde::{Deserialize, Serialize};
use std::path::Path;
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(super) enum Mode {
    #[default]
    System,
    Light,
    Dark,
}
impl Mode {
    pub(super) fn explicit(self) -> Option<bool> {
        match self {
            Self::System => None,
            Self::Light => Some(false),
            Self::Dark => Some(true),
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Preference {
    version: u32,
    mode: Mode,
}
fn read(store: &Store) -> Result<Mode, String> {
    let Some(bytes) = store.bytes("appearance.json")? else {
        return Ok(Mode::System);
    };
    if bytes.len() > 4096 {
        return Err("Appearance preference exceeds 4 KiB; existing setting retained".into());
    }
    let preference: Preference =
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    if preference.version != 1 {
        return Err("Unsupported appearance preference version; existing setting retained".into());
    }
    Ok(preference.mode)
}
pub(super) fn load(root: &Path) -> Result<Mode, String> {
    read(&Store::open(root)?)
}
pub(super) fn save(root: &Path, mode: Mode) -> Result<(), String> {
    let store = Store::open(root)?;
    let lock = store.wait_lock()?;
    read(&store)?;
    store.write(
        "appearance.json",
        &serde_json::to_vec(&Preference { version: 1, mode }).map_err(|error| error.to_string())?,
        &lock,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    #[test]
    fn appearance_restores_and_never_overwrites_busy_corrupt_or_linked_preferences() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load(dir.path()).unwrap(), Mode::System);
        for mode in [Mode::Dark, Mode::Light, Mode::System] {
            save(dir.path(), mode).unwrap();
            assert_eq!(load(dir.path()).unwrap(), mode);
        }
        let path = dir.path().join("fastra-editor/appearance.json");
        let bytes = std::fs::read(&path).unwrap();
        let store = Store::open(dir.path()).unwrap();
        let lock = store.lock().unwrap();
        assert!(save(dir.path(), Mode::Dark).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        drop(lock);
        for corrupt in [
            r#"{"version":2,"mode":"dark"}"#,
            r#"{"version":1,"mode":"unknown"}"#,
            r#"{"version":1,"mode":"system","extra":true}"#,
        ] {
            std::fs::write(&path, corrupt).unwrap();
            assert!(load(dir.path()).is_err());
            assert!(save(dir.path(), Mode::Dark).is_err());
            assert_eq!(std::fs::read_to_string(&path).unwrap(), corrupt);
        }
        std::fs::remove_file(&path).unwrap();
        let external = dir.path().join("external.json");
        std::fs::write(&external, &bytes).unwrap();
        symlink(&external, &path).unwrap();
        assert!(load(dir.path()).is_err());
        assert!(save(dir.path(), Mode::Dark).is_err());
        assert_eq!(std::fs::read(external).unwrap(), bytes);
    }
}
