//! Begrenzter Komponenten-Snapshot: Quelle, 4DZ-Katalog und exportierte Doku, nie Extraktion.
use super::four_d_index::{open_path, read_bounded};
use fastra_core::{
    four_d::{self, Analysis},
    four_d_completion::Component,
    Cancellation,
};
use std::{
    cell::Cell,
    collections::{BTreeMap, HashSet},
    fs,
    io::{Cursor, Read, Seek, SeekFrom},
    os::fd::AsRawFd,
    path::{Component as PathComponent, Path, PathBuf},
    rc::Rc,
};
const ENTRY_BYTES: usize = 1024 * 1024;
const ARCHIVE_BYTES: usize = 64 * 1024 * 1024;
const METADATA_BYTES: usize = 32 * 1024 * 1024;
const TOTAL_BYTES: usize = 16 * 1024 * 1024;
const MAX_ENTRIES: usize = 4000;
const MAX_METHODS: usize = 2000;
pub(super) struct Index {
    pub methods: Vec<Component>,
    pub warnings: Vec<String>,
}
struct Budget {
    entries: usize,
    bytes: usize,
    entry_limit: usize,
}
impl Budget {
    fn visit(&mut self, cancel: &Cancellation) -> Result<(), String> {
        cancel.check().map_err(|e| e.to_string())?;
        self.entries += 1;
        if self.entries > self.entry_limit {
            return Err(format!("4D component entry limit: {}", self.entry_limit));
        }
        Ok(())
    }
    fn consume(&mut self, size: usize) -> Result<(), String> {
        self.bytes = self
            .bytes
            .checked_add(size)
            .ok_or("4D component source limit")?;
        if self.bytes > TOTAL_BYTES {
            return Err("4D component source limit: 16 MiB".into());
        }
        Ok(())
    }
}
fn children(
    path: &Path,
    budget: &mut Budget,
    cancel: &Cancellation,
) -> Result<Vec<PathBuf>, String> {
    match fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.to_string()),
        Ok(m) if !m.is_dir() => {
            return Err("4D component folder is a link or not a directory".into())
        }
        _ => {}
    }
    let directory = open_path(path, true)?;
    let mut result = Vec::new();
    let mut files = fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))
        .map_err(|e| e.to_string())?;
    loop {
        if budget.entries >= budget.entry_limit {
            return Err(format!("4D component entry limit: {}", budget.entry_limit));
        }
        let Some(entry) = files.next() else { break };
        budget.visit(cancel)?;
        let name = entry.map_err(|e| e.to_string())?.file_name();
        if !name.as_encoded_bytes().starts_with(b".") {
            result.push(path.join(name));
        }
    }
    result.sort_by_key(|p| p.file_name().map(|n| n.to_string_lossy().to_lowercase()));
    Ok(result)
}
fn decode(bytes: &[u8]) -> Result<&str, String> {
    std::str::from_utf8(bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes))
        .map_err(|_| "4D component source must be UTF-8".into())
}
fn shared(source: &str) -> bool {
    let line = source
        .split(['\r', '\n'])
        .next()
        .unwrap_or("")
        .trim_matches([' ', '\t']);
    if !line.starts_with("//%attributes") {
        return false;
    }
    line.split_once('=')
        .and_then(|(_, json)| serde_json::from_str::<serde_json::Value>(json).ok())
        .is_some_and(|v| v["shared"].as_bool() == Some(true))
}
fn safe_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 4096
        && !name
            .chars()
            .any(|c| c.is_control() || matches!(c, '/' | '\\'))
        && !matches!(name, "." | "..")
}
fn signature(source: &str, cancel: &Cancellation) -> Result<Option<String>, String> {
    let analysis = Analysis::build(source, cancel).map_err(|e| e.to_string())?;
    Ok(signature_summary(&analysis.signature))
}
pub(super) fn signature_summary(signature: &four_d::Signature) -> Option<String> {
    if signature.parameters.is_empty() && signature.returns.is_none() {
        return None;
    }
    let mut text = signature
        .parameters
        .iter()
        .map(|p| {
            format!(
                "{}{}",
                p.name,
                p.type_name
                    .as_ref()
                    .map(|t| format!(" : {t}"))
                    .unwrap_or_default()
            )
        })
        .collect::<Vec<_>>()
        .join("; ");
    if let Some(result) = &signature.returns {
        text.push_str(&format!(
            " → {}{}",
            result.name,
            result
                .type_name
                .as_ref()
                .map(|t| format!(" : {t}"))
                .unwrap_or_default()
        ));
    }
    Some(text)
}
fn file_source(path: &Path, budget: &mut Budget, cancel: &Cancellation) -> Result<Vec<u8>, String> {
    let (bytes, _) = read_bounded(path, ENTRY_BYTES, cancel)?;
    budget.consume(bytes.len())?;
    Ok(bytes)
}
fn source_method(
    name: &str,
    component: &str,
    source: &str,
    cancel: &Cancellation,
) -> Result<Option<Component>, String> {
    if !safe_name(name) || !shared(source) {
        return Ok(None);
    }
    Ok(Some(Component {
        name: name.into(),
        component: component.into(),
        signature: signature(source, cancel)?,
    }))
}
struct ArchiveReader {
    bytes: Cursor<Vec<u8>>,
    cancel: Cancellation,
    metadata_remaining: Rc<Cell<Option<usize>>>,
}
impl Read for ArchiveReader {
    fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
        self.cancel
            .check()
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        let remaining = self.metadata_remaining.get();
        let allowed = remaining.map_or(output.len(), |remaining| output.len().min(remaining));
        if allowed == 0 && !output.is_empty() {
            return Err(std::io::Error::other(
                "4DZ actual metadata input limit: 32 MiB",
            ));
        }
        let count = self.bytes.read(&mut output[..allowed])?;
        if let Some(remaining) = remaining {
            self.metadata_remaining.set(Some(remaining - count));
        }
        Ok(count)
    }
}
impl Seek for ArchiveReader {
    fn seek(&mut self, position: SeekFrom) -> std::io::Result<u64> {
        self.cancel
            .check()
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        self.bytes.seek(position)
    }
}
/// Nur Quotenprüfung vor der Metadatenallokation; ZIP-Parsing/CRC/Deflate bleiben bei zip-rs.
fn metadata_budget(bytes: &[u8], cancel: &Cancellation) -> Result<(), String> {
    let mut ends = 0;
    for (offset, header) in bytes.windows(22).enumerate() {
        if offset & 65535 == 0 {
            cancel.check().map_err(|e| e.to_string())?;
        }
        if &header[..4] != b"PK\x05\x06" {
            continue;
        }
        let u16_at = |at| u16::from_le_bytes([header[at], header[at + 1]]) as usize;
        let u32_at = |at| u32::from_le_bytes(header[at..at + 4].try_into().unwrap()) as usize;
        // zip-rs kann auf frühere Endrecords zurückfallen; deshalb alle lesbaren Kandidaten begrenzen.
        if u16_at(20) > bytes.len() - offset - 22 {
            continue;
        }
        ends += 1;
        if ends > MAX_ENTRIES
            || u16_at(8) > MAX_ENTRIES
            || u16_at(10) > MAX_ENTRIES
            || u32_at(12) > METADATA_BYTES
            || u32_at(16) == u32::MAX as usize
        {
            return Err("4DZ declared metadata limit: 4000 entries, 32 MiB directory; no ZIP64 end directory".into());
        }
    }
    Ok(())
}
fn archive(
    path: &Path,
    component: &str,
    documentation: Option<&Path>,
    budget: &mut Budget,
    cancel: &Cancellation,
) -> Result<Vec<Component>, String> {
    let (bytes, _) = read_bounded(path, ARCHIVE_BYTES, cancel)?;
    metadata_budget(&bytes, cancel)?;
    // Die deklarierte Directory-Größe begrenzt zip-rs nicht; tatsächliche Parser-Reads zählen.
    // Seek und frühere EOCD-Kandidaten setzen dieselbe Quote nicht zurück.
    let metadata_remaining = Rc::new(Cell::new(Some(METADATA_BYTES)));
    let mut archive = zip::ZipArchive::new(ArchiveReader {
        bytes: Cursor::new(bytes),
        cancel: cancel.clone(),
        metadata_remaining: metadata_remaining.clone(),
    })
    .map_err(|error| match error {
        zip::result::ZipError::Io(error) => format!("4DZ: {error}"),
        error => format!("4DZ: {error}"),
    })?;
    // Erst jetzt gelten für Nutzdaten die separaten Eintrags-/Gesamtgrenzen.
    metadata_remaining.set(None);
    if archive.len() > MAX_ENTRIES {
        return Err("4DZ entry limit: 4000".into());
    }
    let mut source_entries = Vec::new();
    let mut catalog = None;
    let mut seen = HashSet::new();
    for index in 0..archive.len() {
        budget.visit(cancel)?;
        let entry = archive.by_index(index).map_err(|e| format!("4DZ: {e}"))?;
        // Der Mac-Bestand liest 4DZ-Namen als UTF-8, auch ohne gesetztes ZIP-UTF8-Bit.
        // Die Bibliothek würde hier sonst still CP437 oder verlustbehaftetes UTF-8 wählen.
        let name = std::str::from_utf8(entry.name_raw())
            .map_err(|_| "4DZ entry names must be valid UTF-8")?;
        if entry.encrypted()
            || entry.is_symlink()
            || entry.enclosed_name().is_none()
            || name.contains('\\')
            || Path::new(name)
                .components()
                .any(|c| matches!(c, PathComponent::ParentDir | PathComponent::RootDir))
            || !seen.insert(name.to_owned())
        {
            return Err("4DZ contains encrypted, linked, duplicate or unsafe entries".into());
        }
        if !matches!(
            entry.compression(),
            zip::CompressionMethod::Stored | zip::CompressionMethod::Deflated
        ) {
            return Err("4DZ supports stored/deflate only".into());
        }
        if entry.is_dir() {
            continue;
        }
        let method = name
            .strip_prefix("Project/Sources/Methods/")
            .filter(|name| !name.contains('/') && name.to_lowercase().ends_with(".4dm"));
        if method.is_some() || name == "Project/DerivedData/methodAttributes.json" {
            if entry.size() > ENTRY_BYTES as u64 || entry.compressed_size() > ENTRY_BYTES as u64 {
                return Err("4DZ source entry exceeds 1 MiB".into());
            }
            if let Some(method) = method {
                source_entries.push((index, method[..method.len() - 4].to_string()));
            } else {
                catalog = Some(index);
            }
        }
    }
    let read = |archive: &mut zip::ZipArchive<ArchiveReader>,
                index,
                budget: &mut Budget|
     -> Result<Vec<u8>, String> {
        let mut entry = archive.by_index(index).map_err(|e| e.to_string())?;
        let mut bytes = Vec::new();
        let mut chunk = [0; 16384];
        loop {
            cancel.check().map_err(|e| e.to_string())?;
            let n = entry
                .read(&mut chunk)
                .map_err(|e| format!("4DZ CRC/data: {e}"))?;
            if n == 0 {
                break;
            }
            if bytes.len() + n > ENTRY_BYTES {
                return Err("4DZ expanded entry exceeds 1 MiB".into());
            }
            bytes.extend_from_slice(&chunk[..n]);
        }
        budget.consume(bytes.len())?;
        Ok(bytes)
    };
    let mut methods = Vec::new();
    if !source_entries.is_empty() {
        for (index, name) in source_entries {
            let bytes = read(&mut archive, index, budget)?;
            if let Some(method) = source_method(&name, component, decode(&bytes)?, cancel)? {
                methods.push(method);
            }
        }
        return Ok(methods);
    }
    if let Some(index) = catalog {
        let bytes = read(&mut archive, index, budget)?;
        let value: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|e| format!("4DZ method catalog: {e}"))?;
        let entries = value["methods"]
            .as_object()
            .ok_or("4DZ method catalog missing methods")?;
        for (name, value) in entries {
            budget.visit(cancel)?;
            if !safe_name(name) {
                return Err("4DZ method name is not safe".into());
            }
            if value["attributes"]["shared"].as_bool() != Some(true) {
                continue;
            }
            let mut detail = None;
            if let Some(dir) = documentation {
                let file = dir.join(format!("{name}.md"));
                if fs::symlink_metadata(&file).is_ok() {
                    let bytes = file_source(&file, budget, cancel)?;
                    detail = signature(decode(&bytes)?, cancel)?;
                }
            }
            methods.push(Component {
                name: name.clone(),
                component: component.into(),
                signature: detail,
            });
        }
    }
    Ok(methods)
}
pub(super) struct Bundle {
    pub path: PathBuf,
    pub name: String,
    pub archived: bool,
}
pub(super) struct Discovery {
    pub bundles: Vec<Bundle>,
    pub visited: usize,
}
/// Gemeinsame lokale Komponentenentdeckung; weitere deklarierte Pfade bleiben beim Aufrufer.
pub(super) fn discover(root: &Path, cancel: &Cancellation) -> Result<Discovery, String> {
    discover_with_budget(root, cancel, MAX_ENTRIES)
}
pub(super) fn discover_with_budget(
    root: &Path,
    cancel: &Cancellation,
    remaining_entries: usize,
) -> Result<Discovery, String> {
    if remaining_entries == 0 {
        return Err("4D component discovery budget exhausted".into());
    }
    open_path(root, true)?;
    let mut budget = Budget {
        entries: 0,
        bytes: 0,
        entry_limit: MAX_ENTRIES.min(remaining_entries),
    };
    let mut paths = Vec::new();
    for folder in ["Components", "components"] {
        paths.extend(children(&root.join(folder), &mut budget, cancel)?);
    }
    paths.sort_by_key(|p| p.file_name().map(|n| n.to_string_lossy().to_lowercase()));
    paths.dedup();
    let mut bundles = Vec::new();
    for path in paths {
        let Some(extension) = path
            .extension()
            .and_then(|s| s.to_str())
            .map(str::to_lowercase)
        else {
            continue;
        };
        if !matches!(extension.as_str(), "4dbase" | "4dz") {
            continue;
        }
        let name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .filter(|s| safe_name(s))
            .ok_or("4D component name is not safe UTF-8")?
            .to_string();
        open_path(&path, extension == "4dbase")?;
        bundles.push(Bundle {
            path,
            name,
            archived: extension == "4dz",
        });
    }
    Ok(Discovery {
        bundles,
        visited: budget.entries,
    })
}
pub(super) fn scan(root: &Path, cancel: &Cancellation) -> Result<Index, String> {
    let discovery = discover(root, cancel)?;
    let mut budget = Budget {
        entries: discovery.visited,
        bytes: 0,
        entry_limit: MAX_ENTRIES,
    };
    let mut methods = BTreeMap::new();
    for bundle in discovery.bundles {
        budget.visit(cancel)?;
        let name = &bundle.name;
        let extension = if bundle.archived { "4dz" } else { "4dbase" };
        let bundle = bundle.path;
        let mut found = Vec::new();
        if extension == "4dz" {
            found = archive(&bundle, name, None, &mut budget, cancel)?;
        } else {
            open_path(&bundle, true)?;
            for relative in ["Project/Sources/Methods", "Sources/Methods"] {
                for path in children(&bundle.join(relative), &mut budget, cancel)? {
                    if !path
                        .extension()
                        .is_some_and(|s| s.eq_ignore_ascii_case("4dm"))
                    {
                        continue;
                    }
                    let method = path
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .ok_or("4D method name must be UTF-8")?;
                    let bytes = file_source(&path, &mut budget, cancel)?;
                    if let Some(value) = source_method(method, name, decode(&bytes)?, cancel)? {
                        found.push(value);
                    }
                }
            }
            if found.is_empty() {
                let documentation = ["Contents/Documentation/Methods", "Documentation/Methods"]
                    .iter()
                    .map(|p| bundle.join(p))
                    .find(|p| p.exists());
                if let Some(dir) = &documentation {
                    open_path(dir, true)?;
                }
                if let Some(path) = children(&bundle.join("Contents"), &mut budget, cancel)?
                    .iter()
                    .find(|p| p.extension().is_some_and(|s| s.eq_ignore_ascii_case("4dz")))
                {
                    found = archive(path, name, documentation.as_deref(), &mut budget, cancel)?;
                }
            }
        }
        for value in found {
            methods
                .entry(four_d::method_key(&value.name))
                .or_insert(value);
            if methods.len() > MAX_METHODS {
                return Err("4D component method limit: 2000".into());
            }
        }
    }
    Ok(Index {
        methods: methods.into_values().collect(),
        warnings: Vec::new(),
    })
}
#[cfg(test)]
mod tests;
