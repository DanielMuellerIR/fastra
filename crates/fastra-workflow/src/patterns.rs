//! Originales Swift-Arrayformat; Auswahl füllt nur ein Suchformular.
use crate::{store_file::PrivateStore, Error};
use fastra_core::{Cancellation, Limits, PreparedSearch, SearchFlags, SearchMode, SearchRequest};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    path::Path,
};
pub const MAX_BYTES: usize = 1024 * 1024;
pub const MAX_PATTERNS: usize = 100;
pub const CATEGORIES: &[&str] = &[
    "Identifikatoren",
    "Datum & Zeit",
    "Text-Strukturen",
    "Zahlen",
    "Wörter & Zeilen",
    "Leerraum & Aufräumen",
];
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pattern {
    pub id: String,
    pub name: String,
    pub category: String,
    pub regex: String,
    pub example_match: String,
    pub group_labels: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_replacement: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}
impl Pattern {
    pub fn validate(&self, cancel: &Cancellation) -> Result<(), Error> {
        for (field, text, max) in [
            ("id", self.id.as_str(), 256),
            ("name", &self.name, 512),
            ("category", &self.category, 128),
            ("regex", &self.regex, 16 * 1024),
            ("exampleMatch", &self.example_match, 16 * 1024),
            (
                "defaultReplacement",
                self.default_replacement.as_deref().unwrap_or(""),
                16 * 1024,
            ),
        ] {
            if text.len() > max {
                return Err(Error::Limit);
            }
            if text.contains('\0') {
                return Err(Error::Invalid(format!("{field}: U+0000")));
            }
        }
        if self.id.trim().is_empty()
            || self.name.trim().is_empty()
            || self.category.trim().is_empty()
        {
            return Err(Error::Invalid("id/name/category".into()));
        }
        if self.group_labels.len() > 64 || self.group_labels.iter().any(|label| label.len() > 1024)
        {
            return Err(Error::Limit);
        }
        if self.group_labels.iter().any(|label| label.contains('\0')) {
            return Err(Error::Invalid("groupLabels: U+0000".into()));
        }
        PreparedSearch::new(
            &SearchRequest {
                pattern: self.regex.clone(),
                replacement: String::new(),
                mode: SearchMode::Regex,
                case_sensitive: true,
                range: None,
            },
            SearchFlags::default(),
            Limits::default(),
            cancel,
        )?;
        Ok(())
    }
    pub fn usable(&self, cancel: &Cancellation) -> Result<(), Error> {
        self.validate(cancel)?;
        if !CATEGORIES.contains(&self.category.as_str()) {
            return Err(Error::Unsupported(vec![format!(
                "category: {}",
                serde_json::to_string(&self.category)?
            )]));
        }
        if !self.extra.is_empty() {
            return Err(Error::Unsupported(
                self.extra
                    .keys()
                    .map(|key| serde_json::to_string(key).unwrap())
                    .collect(),
            ));
        }
        Ok(())
    }
}
pub fn builtins() -> Result<Vec<Pattern>, Error> {
    Ok(serde_json::from_slice(include_bytes!(
        "../resources/pattern-builtins.json"
    ))?)
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Collection(pub Vec<Pattern>);
impl Collection {
    pub fn validate(&self, cancel: &Cancellation) -> Result<(), Error> {
        cancel.check()?;
        if self.0.len() > MAX_PATTERNS {
            return Err(Error::Limit);
        }
        let reserved: HashSet<_> = builtins()?.into_iter().map(|value| value.id).collect();
        let mut ids = HashSet::new();
        for value in &self.0 {
            cancel.check()?;
            if reserved.contains(&value.id) || !ids.insert(&value.id) {
                return Err(Error::Invalid(format!(
                    "reserved/duplicate id: {}",
                    serde_json::to_string(&value.id)?
                )));
            }
            value.validate(cancel)?;
        }
        Ok(())
    }
    pub fn decode(bytes: &[u8], cancel: &Cancellation) -> Result<Self, Error> {
        if bytes.len() > MAX_BYTES {
            return Err(Error::Limit);
        }
        let collection: Self = serde_json::from_slice(bytes)?;
        collection.validate(cancel)?;
        Ok(collection)
    }
    pub fn encode(&self, cancel: &Cancellation) -> Result<Vec<u8>, Error> {
        self.validate(cancel)?;
        let bytes = serde_json::to_vec_pretty(self)?;
        if bytes.len() > MAX_BYTES {
            return Err(Error::Limit);
        }
        Ok(bytes)
    }
    pub fn merged(&self, incoming: &Self, cancel: &Cancellation) -> Result<Self, Error> {
        self.validate(cancel)?;
        incoming.validate(cancel)?;
        let ids: HashSet<_> = incoming.0.iter().map(|value| value.id.as_str()).collect();
        let mut merged: Vec<_> = self
            .0
            .iter()
            .filter(|value| !ids.contains(value.id.as_str()))
            .cloned()
            .collect();
        merged.extend(incoming.0.iter().cloned());
        let result = Self(merged);
        result.encode(cancel)?;
        Ok(result)
    }
}
#[derive(Clone)]
pub struct Snapshot {
    pub collection: Collection,
    bytes: Option<Vec<u8>>,
}
pub struct Store {
    private: PrivateStore,
}
impl Store {
    pub fn open(root: &Path) -> Result<Self, Error> {
        Ok(Self {
            private: PrivateStore::open(root, "fastra-patterns", MAX_BYTES)?,
        })
    }
    fn decode(bytes: Option<Vec<u8>>, cancel: &Cancellation) -> Result<Snapshot, Error> {
        cancel.check()?;
        let collection = match &bytes {
            Some(bytes) => Collection::decode(bytes, cancel)?,
            None => Collection::default(),
        };
        Ok(Snapshot { collection, bytes })
    }
    pub fn load(&self, cancel: &Cancellation) -> Result<Snapshot, Error> {
        cancel.check()?;
        Self::decode(self.private.load_bytes()?, cancel)
    }
    pub fn save(
        &self,
        expected: &Snapshot,
        collection: &Collection,
        cancel: &Cancellation,
    ) -> Result<Snapshot, Error> {
        let bytes = collection.encode(cancel)?;
        self.private
            .save_bytes(&expected.bytes, &bytes, |current| {
                Self::decode(current, cancel).map(|_| ())
            })?;
        Ok(Snapshot {
            collection: collection.clone(),
            bytes: Some(bytes),
        })
    }
}
