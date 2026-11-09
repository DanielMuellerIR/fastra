use super::super::store::Store;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(in crate::editor_options) struct Preference {
    version: u32,
    pub(in crate::editor_options) face: Option<String>,
}
impl Default for Preference {
    fn default() -> Self {
        Self {
            version: 1,
            face: None,
        }
    }
}
pub(super) fn valid_name(face: &str) -> bool {
    !face.is_empty() && face.len() <= 512 && !face.chars().any(char::is_control)
}
impl Preference {
    fn validate(&self) -> Result<(), String> {
        if self.version != 1 || self.face.as_ref().is_some_and(|face| !valid_name(face)) {
            return Err("Invalid document font preference; existing setting retained".into());
        }
        Ok(())
    }
}
fn read(store: &Store, filename: &str) -> Result<Preference, String> {
    let Some(bytes) = store.bytes(filename)? else {
        return Ok(Preference::default());
    };
    if bytes.len() > 4096 {
        return Err("Document font preference exceeds 4 KiB; existing setting retained".into());
    }
    let preference: Preference =
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    preference.validate()?;
    Ok(preference)
}
#[cfg(any(debug_assertions, test))]
pub(super) fn load(root: &Path) -> Result<Preference, String> {
    load_named(root, "source-font.json")
}
#[cfg(test)]
pub(super) fn save(root: &Path, face: Option<String>) -> Result<(), String> {
    save_named(root, "source-font.json", face)
}
pub(in crate::editor_options) fn load_named(
    root: &Path,
    filename: &str,
) -> Result<Preference, String> {
    read(&Store::open(root)?, filename)
}
pub(in crate::editor_options) fn save_named(
    root: &Path,
    filename: &str,
    face: Option<String>,
) -> Result<(), String> {
    let store = Store::open(root)?;
    let lock = store.wait_lock()?;
    // Fremde oder beschädigte Einstellungen nicht durch eine neue Wahl verdecken.
    read(&store, filename)?;
    let preference = Preference { version: 1, face };
    preference.validate()?;
    store.write(
        filename,
        &serde_json::to_vec(&preference).map_err(|error| error.to_string())?,
        &lock,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    #[test]
    fn reading_and_source_choices_are_independent_and_untrusted_reading_settings_survive() {
        let dir = tempfile::tempdir().unwrap();
        save(dir.path(), Some("DejaVu Sans Mono".into())).unwrap();
        let source = dir.path().join("fastra-editor/source-font.json");
        let original = std::fs::read(&source).unwrap();
        let name = "reading-font.json";
        save_named(dir.path(), name, Some("DejaVu Sans Bold Oblique".into())).unwrap();
        assert_eq!(
            load_named(dir.path(), name).unwrap().face.as_deref(),
            Some("DejaVu Sans Bold Oblique")
        );
        let path = dir.path().join("fastra-editor").join(name);
        for bytes in [
            b"broken".as_slice(),
            br#"{"version":1,"face":null,"foreign":true}"#,
            br#"{"version":2,"face":null}"#,
            br#"{"version":1,"face":"bad\nfont"}"#,
            &[b'W'; 4097],
        ] {
            std::fs::write(&path, bytes).unwrap();
            assert!(load_named(dir.path(), name).is_err());
            assert!(save_named(dir.path(), name, None).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
        }
        std::fs::remove_file(&path).unwrap();
        symlink(&source, &path).unwrap();
        assert!(save_named(dir.path(), name, None).is_err());
        assert!(load_named(dir.path(), name).is_err());
        assert_eq!(std::fs::read(&source).unwrap(), original);
        std::fs::remove_file(&path).unwrap();
        save_named(dir.path(), name, None).unwrap();
        assert_eq!(load_named(dir.path(), name).unwrap(), Preference::default());
        assert_eq!(std::fs::read(&source).unwrap(), original);
    }
    #[test]
    fn font_choice_is_optional_atomic_and_corrupt_or_linked_settings_are_retained() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(load(dir.path()).unwrap(), Preference::default());
        assert!(!dir.path().join("fastra-editor/source-font.json").exists());
        save(dir.path(), Some("DejaVu Sans Mono Bold Oblique".into())).unwrap();
        assert_eq!(
            load(dir.path()).unwrap().face.as_deref(),
            Some("DejaVu Sans Mono Bold Oblique")
        );
        let path = dir.path().join("fastra-editor/source-font.json");
        let bytes = std::fs::read(&path).unwrap();
        for face in ["", "bad\nfont", "bad\0font"] {
            assert!(save(dir.path(), Some(face.into())).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
        }
        let store = Store::open(dir.path()).unwrap();
        let lock = store.wait_lock().unwrap();
        assert!(save(dir.path(), None).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        drop(lock);
        std::fs::write(&path, b"{\"version\":2,\"face\":null}").unwrap();
        let corrupt = std::fs::read(&path).unwrap();
        assert!(load(dir.path()).is_err());
        assert!(save(dir.path(), None).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), corrupt);
        let oversized = format!("{{\"{}\":null}}", "W".repeat(5000));
        std::fs::write(&path, &oversized).unwrap();
        let error = load(dir.path()).unwrap_err();
        assert!(error.len() < 128);
        assert!(save(dir.path(), None).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), oversized);
        std::fs::remove_file(&path).unwrap();
        let external = dir.path().join("external.json");
        std::fs::write(&external, &bytes).unwrap();
        symlink(&external, &path).unwrap();
        assert!(load(dir.path()).is_err());
        assert!(save(dir.path(), None).is_err());
        assert_eq!(std::fs::read(&external).unwrap(), bytes);
        std::fs::remove_file(&path).unwrap();
        save(dir.path(), None).unwrap();
        assert_eq!(load(dir.path()).unwrap(), Preference::default());
    }
}
