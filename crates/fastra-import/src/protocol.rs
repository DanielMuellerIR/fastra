use crate::{Error, Limits};
use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Format {
    pub format: String,
    pub extensions: Vec<String>,
    #[serde(default)]
    pub container: String,
    #[serde(default)]
    pub containers: Vec<String>,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub available: bool,
    pub unavailable_reason: Option<String>,
}
impl Format {
    pub fn supports_directory(&self, directory: bool) -> bool {
        let expected = if directory { "package" } else { "file" };
        if self.containers.is_empty() {
            self.container == expected
        } else {
            self.containers.iter().any(|c| c == expected)
        }
    }
}
#[derive(Debug, Clone, Deserialize)]
pub struct Catalog {
    pub ok: bool,
    #[serde(default)]
    pub version: String,
    pub formats: Vec<Format>,
}
impl Catalog {
    pub fn format_for(&self, extension: &str, directory: bool) -> Option<&Format> {
        let extension = extension.trim_matches('.').to_lowercase();
        if extension.is_empty() {
            return None;
        }
        self.formats.iter().find(|f| {
            f.supports_directory(directory)
                && f.extensions.iter().any(|e| e.to_lowercase() == extension)
        })
    }
    pub fn decode(bytes: &[u8], limits: Limits) -> Result<Self, Error> {
        bounded_json(bytes, limits)?;
        let catalog: Self =
            serde_json::from_slice(bytes).map_err(|e| Error::Protocol(e.to_string()))?;
        let safe_text = |text: &str| !text.contains('\0') && text.len() <= 16 * 1024;
        if !safe_text(&catalog.version)
            || catalog.formats.iter().any(|f| {
                !safe_text(&f.format)
                    || !safe_text(&f.container)
                    || f.extensions
                        .iter()
                        .chain(&f.containers)
                        .chain(&f.requires)
                        .any(|v| !safe_text(v))
                    || f.unavailable_reason
                        .as_deref()
                        .is_some_and(|v| !safe_text(v))
            })
        {
            return Err(Error::Protocol("invalid format catalog text".into()));
        }
        if !catalog.ok
            || catalog.formats.is_empty()
            || catalog
                .formats
                .iter()
                .any(|f| f.format.is_empty() || f.extensions.is_empty())
        {
            return Err(Error::Protocol("not a successful format catalog".into()));
        }
        Ok(catalog)
    }
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    pub source_index: u64,
    pub title: String,
    pub markdown_file: String,
    #[serde(default)]
    pub assets: Vec<String>,
    #[serde(default)]
    pub metadata: Value,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputFile {
    pub path: String,
    pub sha256: String,
    pub byte_count: u64,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputRange {
    pub file: String,
    pub utf8_offset: u64,
    pub utf8_length: u64,
}
#[derive(Debug, Clone, Deserialize)]
pub struct SourceMapping {
    pub source: Value,
    pub output: OutputRange,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversion {
    pub ok: bool,
    #[serde(default)]
    pub version: String,
    pub input: Option<String>,
    pub output_directory: Option<String>,
    pub markdown_file: String,
    pub assets: Option<Vec<String>>,
    pub warnings: Option<Vec<String>>,
    pub documents: Option<Vec<Document>>,
    pub diagnostics: Option<Vec<Value>>,
    pub diagnostic_groups: Option<Vec<Value>>,
    pub source_identity: Option<Value>,
    pub source_mappings: Option<Vec<SourceMapping>>,
    pub output_files: Option<Vec<OutputFile>>,
    pub report_file: Option<String>,
    #[serde(default)]
    pub metadata: Value,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, Value>,
}
impl Conversion {
    pub fn decode(bytes: &[u8], limits: Limits) -> Result<Self, Error> {
        bounded_json(bytes, limits)?;
        let conversion: Self =
            serde_json::from_slice(bytes).map_err(|e| Error::Protocol(e.to_string()))?;
        if !conversion.ok {
            return Err(Error::Protocol("unsuccessful conversion".into()));
        }
        Ok(conversion)
    }
}
pub(crate) fn bounded_json(bytes: &[u8], limits: Limits) -> Result<(), Error> {
    if bytes.len() > limits.max_json_bytes {
        Err(Error::Limit("JSON byte limit"))
    } else {
        Ok(())
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Utf16Span {
    pub location: u64,
    pub length: u64,
}
/// Ausgabepositionen des Producers sind UTF-8-Bytes, niemals Editor-Offsets.
pub fn utf8_to_utf16(text: &str, offset: u64, length: u64) -> Result<Utf16Span, Error> {
    let start =
        usize::try_from(offset).map_err(|_| Error::Protocol("mapping offset overflow".into()))?;
    let end = offset
        .checked_add(length)
        .and_then(|n| usize::try_from(n).ok())
        .ok_or_else(|| Error::Protocol("mapping range overflow".into()))?;
    if end > text.len() || !text.is_char_boundary(start) || !text.is_char_boundary(end) {
        return Err(Error::Protocol(
            "mapping is not a UTF-8 text boundary".into(),
        ));
    }
    Ok(Utf16Span {
        location: text[..start].encode_utf16().count() as u64,
        length: text[start..end].encode_utf16().count() as u64,
    })
}
