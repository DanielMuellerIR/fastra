use super::super::store::Store;
use serde::{Deserialize, Serialize};
use std::path::Path;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Preference {
    version: u32,
    visual: bool,
}
fn read(store: &Store) -> Result<Option<bool>, String> {
    let Some(bytes) = store.bytes("markdown-mode.json")? else {
        return Ok(None);
    };
    if bytes.len() > 4096 {
        return Err("Markdown mode preference exceeds 4 KiB; existing setting retained".into());
    }
    let preference: Preference =
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    if preference.version != 1 {
        return Err("Unsupported Markdown mode version; existing setting retained".into());
    }
    Ok(Some(preference.visual))
}
pub(super) fn load(root: &Path) -> Result<Option<bool>, String> {
    read(&Store::open(root)?)
}
pub(super) fn save(root: &Path, visual: bool) -> Result<(), String> {
    let store = Store::open(root)?;
    let lock = store.wait_lock()?;
    read(&store)?;
    store.write(
        "markdown-mode.json",
        &serde_json::to_vec(&Preference { version: 1, visual }).map_err(|e| e.to_string())?,
        &lock,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    #[test]
    fn unset_choice_differs_from_source_and_untrusted_mode_files_are_preserved() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(load(root.path()).unwrap(), None);
        let path = root.path().join("fastra-editor/markdown-mode.json");
        assert!(!path.exists());
        for visual in [false, true, false] {
            save(root.path(), visual).unwrap();
            assert_eq!(load(root.path()).unwrap(), Some(visual));
        }
        let original = std::fs::read(&path).unwrap();
        let store = Store::open(root.path()).unwrap();
        let lock = store.wait_lock().unwrap();
        assert!(save(root.path(), true).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        drop(lock);
        for bytes in [
            b"broken".as_slice(),
            br#"{"version":2,"visual":false}"#,
            br#"{"version":1,"visual":null}"#,
            br#"{"version":1,"visual":false,"extra":true}"#,
            &[b'W'; 4097],
        ] {
            std::fs::write(&path, bytes).unwrap();
            assert!(load(root.path()).is_err());
            assert!(save(root.path(), true).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
        }
        std::fs::remove_file(&path).unwrap();
        let other = root.path().join("other.json");
        std::fs::write(&other, &original).unwrap();
        symlink(&other, &path).unwrap();
        assert!(load(root.path()).is_err());
        assert!(save(root.path(), true).is_err());
        assert_eq!(std::fs::read(&other).unwrap(), original);
        std::fs::remove_file(&path).unwrap();
        save(root.path(), true).unwrap();
        assert_eq!(load(root.path()).unwrap(), Some(true));
        assert!(!root
            .path()
            .join("fastra-editor/markdown-preview.json")
            .exists());
        assert!(!root.path().join("fastra-editor/reading-font.json").exists());
    }
}
