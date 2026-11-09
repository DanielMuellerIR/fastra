//! Private lokale Sammlung mit Sperre und Vergleich des zuletzt gelesenen Stands.
use crate::store_file::PrivateStore;
use crate::{Error, SnippetArchive, WorkflowArchive, MAX_ARCHIVE_BYTES};
use serde::{Deserialize, Serialize};
use std::path::Path;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Library {
    pub schema_version: u32,
    pub workflows: WorkflowArchive,
    pub snippets: SnippetArchive,
    #[serde(flatten)]
    pub extra: std::collections::BTreeMap<String, serde_json::Value>,
}
impl Default for Library {
    fn default() -> Self {
        Self {
            schema_version: 1,
            workflows: WorkflowArchive::empty(),
            snippets: SnippetArchive::empty(),
            extra: Default::default(),
        }
    }
}
impl Library {
    pub fn validate(&self) -> Result<(), Error> {
        if self.schema_version != 1 {
            return Err(Error::Invalid("library version".into()));
        }
        self.workflows.encode()?;
        self.snippets.encode()?;
        Ok(())
    }
}
#[derive(Clone)]
pub struct Snapshot {
    pub library: Library,
    bytes: Option<Vec<u8>>,
}
pub struct Store {
    private: PrivateStore,
}
const MAX_LIBRARY: usize = 2 * MAX_ARCHIVE_BYTES + 64 * 1024;
impl Store {
    pub fn open(config_root: &Path) -> Result<Self, Error> {
        Ok(Self {
            private: PrivateStore::open(config_root, "fastra-workflow", MAX_LIBRARY)?,
        })
    }
    fn decode(bytes: Option<Vec<u8>>) -> Result<Snapshot, Error> {
        let library = match &bytes {
            Some(bytes) => serde_json::from_slice::<Library>(bytes)?,
            None => Library::default(),
        };
        library.validate()?;
        Ok(Snapshot { library, bytes })
    }
    pub fn load(&self) -> Result<Snapshot, Error> {
        Self::decode(self.private.load_bytes()?)
    }
    pub fn save(&self, expected: &Snapshot, library: &Library) -> Result<Snapshot, Error> {
        library.validate()?;
        let bytes = serde_json::to_vec_pretty(library)?;
        self.private
            .save_bytes(&expected.bytes, &bytes, |current| {
                Self::decode(current).map(|_| ())
            })?;
        Self::decode(Some(bytes))
    }
}
