use super::super::store::Store;
use serde::{Deserialize, Serialize};
use std::path::Path;

const FILE: &str = "printing.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Values {
    pub line_numbers: bool,
    pub header_footer: bool,
    pub syntax_colors: bool,
    pub font_size: u8,
}
impl Default for Values {
    fn default() -> Self {
        Self {
            line_numbers: true,
            header_footer: true,
            syntax_colors: true,
            font_size: 10,
        }
    }
}
#[derive(Clone, Copy, Default)]
pub(super) struct Changes {
    pub line_numbers: Option<bool>,
    pub header_footer: Option<bool>,
    pub syntax_colors: Option<bool>,
    pub font_size: Option<u8>,
}
impl Changes {
    pub(super) fn merge(&mut self, newer: Self) {
        if newer.line_numbers.is_some() {
            self.line_numbers = newer.line_numbers;
        }
        if newer.header_footer.is_some() {
            self.header_footer = newer.header_footer;
        }
        if newer.syntax_colors.is_some() {
            self.syntax_colors = newer.syntax_colors;
        }
        if newer.font_size.is_some() {
            self.font_size = newer.font_size;
        }
    }
    pub(super) fn apply(self, mut values: Values) -> Values {
        if let Some(value) = self.line_numbers {
            values.line_numbers = value;
        }
        if let Some(value) = self.header_footer {
            values.header_footer = value;
        }
        if let Some(value) = self.syntax_colors {
            values.syntax_colors = value;
        }
        if let Some(value) = self.font_size {
            values.font_size = value;
        }
        values
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Preference {
    version: u32,
    values: Values,
}

fn read(store: &Store) -> Result<Values, String> {
    let Some(bytes) = store.bytes(FILE)? else {
        return Ok(Values::default());
    };
    if bytes.len() > 4096 {
        return Err("Print preferences exceed 4 KiB; existing data retained".into());
    }
    let preference: Preference =
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    if preference.version != 1 || !(6..=18).contains(&preference.values.font_size) {
        return Err("Invalid print preference version or font size; existing data retained".into());
    }
    Ok(preference.values)
}
pub(super) fn load(root: &Path) -> Result<Values, String> {
    read(&Store::open(root)?)
}
pub(super) fn save(root: &Path, changes: Changes) -> Result<Values, String> {
    let store = Store::open(root)?;
    let lock = store.wait_lock()?;
    let values = changes.apply(read(&store)?);
    if !(6..=18).contains(&values.font_size) {
        return Err("Print font size must be between 6 and 18 pt".into());
    }
    store.write(
        FILE,
        &serde_json::to_vec(&Preference { version: 1, values })
            .map_err(|error| error.to_string())?,
        &lock,
    )?;
    Ok(values)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn changed_fields_preserve_other_writers_and_font_limits() {
        let root = tempfile::tempdir().unwrap();
        assert_eq!(load(root.path()).unwrap(), Values::default());
        let saved = save(
            root.path(),
            Changes {
                header_footer: Some(false),
                font_size: Some(18),
                ..Changes::default()
            },
        )
        .unwrap();
        assert!(!saved.header_footer);
        let saved = save(
            root.path(),
            Changes {
                syntax_colors: Some(false),
                ..Changes::default()
            },
        )
        .unwrap();
        assert_eq!(saved.font_size, 18);
        assert!(!saved.header_footer && !saved.syntax_colors && saved.line_numbers);
        assert_eq!(load(root.path()).unwrap(), saved);
        let file = root.path().join("fastra-editor/printing.json");
        let prior = std::fs::read(&file).unwrap();
        assert!(save(
            root.path(),
            Changes {
                font_size: Some(5),
                ..Changes::default()
            }
        )
        .is_err());
        assert_eq!(std::fs::read(&file).unwrap(), prior);
        save(
            root.path(),
            Changes {
                font_size: Some(6),
                ..Changes::default()
            },
        )
        .unwrap();
        assert_eq!(load(root.path()).unwrap().font_size, 6);
    }
    #[test]
    fn corrupt_linked_and_busy_preferences_are_never_replaced() {
        let root = tempfile::tempdir().unwrap();
        save(root.path(), Changes::default()).unwrap();
        let file = root.path().join("fastra-editor/printing.json");
        for bytes in [
            b"broken".as_slice(),
            br#"{"version":2,"values":{"line_numbers":true,"header_footer":true,"syntax_colors":true,"font_size":10}}"#,
            br#"{"version":1,"values":{"line_numbers":true,"header_footer":true,"syntax_colors":true,"font_size":19}}"#,
            br#"{"version":1,"values":{"line_numbers":true,"header_footer":true,"syntax_colors":true,"font_size":10,"other":false}}"#,
            &[b'X'; 4097],
        ] {
            std::fs::write(&file, bytes).unwrap();
            assert!(load(root.path()).is_err());
            assert!(save(root.path(), Changes { line_numbers: Some(false), ..Changes::default() }).is_err());
            assert_eq!(std::fs::read(&file).unwrap(), bytes);
        }
        std::fs::remove_file(&file).unwrap();
        let target = root.path().join("unrelated");
        std::fs::write(&target, b"keep").unwrap();
        std::os::unix::fs::symlink(&target, &file).unwrap();
        assert!(save(root.path(), Changes::default()).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"keep");
        std::fs::remove_file(&file).unwrap();
        save(root.path(), Changes::default()).unwrap();
        let prior = std::fs::read(&file).unwrap();
        let store = Store::open(root.path()).unwrap();
        let _lock = store.wait_lock().unwrap();
        assert!(save(
            root.path(),
            Changes {
                font_size: Some(12),
                ..Changes::default()
            }
        )
        .is_err());
        assert_eq!(std::fs::read(&file).unwrap(), prior);
    }
}
