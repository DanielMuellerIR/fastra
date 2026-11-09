use super::super::store::Store;
use serde::{Deserialize, Serialize};
use std::path::Path;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Preference {
    version: u32,
    shown: bool,
}
fn read(store: &Store) -> Result<bool, String> {
    let Some(bytes) = store.bytes("markdown-preview.json")? else {
        return Ok(true);
    };
    if bytes.len() > 4096 {
        return Err("Markdown preview preference exceeds 4 KiB; existing setting retained".into());
    }
    let preference: Preference =
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    if preference.version != 1 {
        return Err(
            "Unsupported Markdown preview preference version; existing setting retained".into(),
        );
    }
    Ok(preference.shown)
}
pub(super) fn load(root: &Path) -> Result<bool, String> {
    read(&Store::open(root)?)
}
pub(super) fn save(root: &Path, shown: bool) -> Result<(), String> {
    let store = Store::open(root)?;
    let lock = store.wait_lock()?;
    read(&store)?;
    store.write(
        "markdown-preview.json",
        &serde_json::to_vec(&Preference { version: 1, shown })
            .map_err(|error| error.to_string())?,
        &lock,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    #[test]
    fn preview_defaults_on_and_preserves_untrusted_preferences_and_other_domains() {
        let root = tempfile::tempdir().unwrap();
        assert!(load(root.path()).unwrap());
        let path = root.path().join("fastra-editor/markdown-preview.json");
        assert!(!path.exists());
        for shown in [false, true, false] {
            save(root.path(), shown).unwrap();
            assert_eq!(load(root.path()).unwrap(), shown);
        }
        let bytes = std::fs::read(&path).unwrap();
        let store = Store::open(root.path()).unwrap();
        let lock = store.wait_lock().unwrap();
        assert!(save(root.path(), true).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        drop(lock);
        for corrupt in [
            b"broken".as_slice(),
            br#"{"version":2,"shown":false}"#,
            br#"{"version":1,"shown":false,"extra":true}"#,
            br#"{"version":1,"shown":"false"}"#,
            &[b'W'; 4097],
        ] {
            std::fs::write(&path, corrupt).unwrap();
            assert!(load(root.path()).is_err());
            assert!(save(root.path(), true).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), corrupt);
        }
        std::fs::remove_file(&path).unwrap();
        let external = root.path().join("external.json");
        std::fs::write(&external, &bytes).unwrap();
        symlink(&external, &path).unwrap();
        assert!(load(root.path()).is_err());
        assert!(save(root.path(), true).is_err());
        assert_eq!(std::fs::read(&external).unwrap(), bytes);
        std::fs::remove_file(&path).unwrap();
        save(root.path(), true).unwrap();
        assert!(load(root.path()).unwrap());
        assert!(!root.path().join("fastra-editor/reading-font.json").exists());
    }
}
