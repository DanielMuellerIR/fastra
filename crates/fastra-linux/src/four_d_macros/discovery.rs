//! Begrenzte Makroquellen: explizites Projekt, XDG-Benutzerordner und gewählte Installation.
use super::*;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs,
    io::Write,
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
};
const ENTRIES: usize = 4096;
const SOURCES: usize = 256;
const SETTINGS_BYTES: usize = 128 * 1024;
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub(super) struct Config {
    pub user: Option<PathBuf>,
    pub installation: Option<PathBuf>,
    #[serde(default)]
    pub runtime: Option<PathBuf>,
    #[serde(default)]
    pub engine: Option<PathBuf>,
}
#[derive(Debug, Clone)]
pub(super) struct Source {
    pub path: PathBuf,
    pub label: String,
}
#[derive(Debug)]
pub(super) struct Catalog {
    pub sources: Vec<Source>,
    pub macros: Vec<Macro>,
    pub issues: Vec<String>,
    pub project: Option<PathBuf>,
}
fn xdg(name: &str, fallback: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(fallback)))
}
pub(super) fn settings_path() -> Option<PathBuf> {
    xdg("XDG_CONFIG_HOME", ".config").map(|p| p.join("fastra/4d-macros.json"))
}
pub(super) fn default_user() -> Option<PathBuf> {
    xdg("XDG_DATA_HOME", ".local/share").map(|p| p.join("fastra/4d/Macros v2"))
}
pub(super) fn load_config() -> Result<Config, String> {
    let Some(path) = settings_path() else {
        return Ok(Config::default());
    };
    if !path.exists() {
        return Ok(Config::default());
    }
    let (bytes, _) =
        super::super::four_d_index::read_bounded(&path, SETTINGS_BYTES, &Cancellation::default())?;
    serde_json::from_slice(&bytes).map_err(|e| e.to_string())
}
#[derive(Clone, Copy)]
pub(super) enum Field {
    User,
    Installation,
    Runtime,
    Engine,
}
#[derive(Clone)]
pub(super) enum Change {
    Set(Field, Option<PathBuf>),
    Reset,
}
type Saved = Result<Config, String>;
type PendingSave = std::sync::mpsc::Receiver<Saved>;
struct SettingsStore(std::sync::mpsc::Sender<(PathBuf, Change, std::sync::mpsc::Sender<Saved>)>);
impl SettingsStore {
    fn new() -> Self {
        let (tx, rx) =
            std::sync::mpsc::channel::<(PathBuf, Change, std::sync::mpsc::Sender<Saved>)>();
        std::thread::spawn(move || {
            for (path, change, reply) in rx {
                let result = update_config_at(&path, change);
                let _ = reply.send(result);
            }
        });
        Self(tx)
    }
    fn submit(&self, path: PathBuf, change: Change) -> PendingSave {
        let (tx, rx) = std::sync::mpsc::channel();
        if let Err(e) = self.0.send((path, change, tx)) {
            let (_, _, reply) = e.0;
            let _ = reply.send(Err("Settings worker unavailable".into()));
        }
        rx
    }
}
// Bereits beim UI-Ereignis einreihen, nicht erst in beliebig gestarteten Hintergrundtasks.
// Der eine Writer liest unter dem gehaltenen Eltern-FD für JEDE Feldänderung neu.
pub(super) fn update_config(change: Change) -> PendingSave {
    static STORE: OnceLock<SettingsStore> = OnceLock::new();
    if let Some(path) = settings_path() {
        return STORE.get_or_init(SettingsStore::new).submit(path, change);
    }
    let (tx, rx) = std::sync::mpsc::channel();
    let _ = tx.send(Err("XDG configuration directory unavailable".into()));
    rx
}
fn update_config_at(path: &Path, change: Change) -> Result<Config, String> {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd, FromRawFd};
    let mut directory = fs::File::open("/").map_err(|e| e.to_string())?;
    for part in path.parent().unwrap().components() {
        let name = match part {
            std::path::Component::RootDir => continue,
            std::path::Component::Normal(name) => name,
            _ => return Err("XDG configuration path must not contain parent components".into()),
        };
        let name = CString::new(name.as_bytes()).map_err(|e| e.to_string())?;
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        let mut fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
            if unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) } != 0
                && std::io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST)
            {
                return Err(std::io::Error::last_os_error().to_string());
            }
            fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
        }
        if fd < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        directory = unsafe { fs::File::from_raw_fd(fd) };
    }
    // NON_UNIQUE erlaubt mehrere Appprozesse. Die Sperre gehört zum gehaltenen
    // Eltern-FD und bleibt bis nach Rename/Sync erhalten; dessen Drop gibt sie frei.
    loop {
        if unsafe { libc::flock(directory.as_raw_fd(), libc::LOCK_EX) } == 0 {
            break;
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error.to_string());
        }
    }
    let held = PathBuf::from(format!("/proc/self/fd/{}", directory.as_raw_fd()));
    let target = held.join("4d-macros.json");
    if fs::symlink_metadata(&target).is_ok_and(|m| !m.is_file()) {
        return Err("Configuration is not a regular file".into());
    }
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    let mut config = match fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&target)
    {
        Ok(mut file) => {
            let meta = file.metadata().map_err(|e| e.to_string())?;
            if !meta.is_file() || meta.len() > SETTINGS_BYTES as u64 {
                return Err("Regular settings file up to 128 KiB required".into());
            }
            let mut bytes = Vec::new();
            (&mut file)
                .take((SETTINGS_BYTES + 1) as u64)
                .read_to_end(&mut bytes)
                .map_err(|e| e.to_string())?;
            if bytes.len() > SETTINGS_BYTES || bytes.len() != meta.len() as usize {
                return Err("Settings changed during read".into());
            }
            serde_json::from_slice::<Config>(&bytes).map_err(|e| e.to_string())?
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Config::default(),
        Err(e) => return Err(e.to_string()),
    };
    match change {
        Change::Set(Field::User, path) => config.user = path,
        Change::Set(Field::Installation, path) => config.installation = path,
        Change::Set(Field::Runtime, path) => config.runtime = path,
        Change::Set(Field::Engine, path) => config.engine = path,
        Change::Reset => config = Config::default(),
    }
    let bytes = serde_json::to_vec(&config).map_err(|e| e.to_string())?;
    if bytes.len() > SETTINGS_BYTES {
        return Err("Settings size limit: 128 KiB".into());
    }
    let mut temporary = tempfile::NamedTempFile::new_in(&held).map_err(|e| e.to_string())?;
    temporary
        .write_all(&bytes)
        .and_then(|()| temporary.as_file().sync_all())
        .map_err(|e| e.to_string())?;
    temporary.persist(&target).map_err(|e| e.to_string())?;
    directory.sync_all().map_err(|e| e.to_string())?;
    Ok(config)
}
fn children(
    path: &Path,
    budget: &mut usize,
    cancel: &Cancellation,
) -> Result<Vec<PathBuf>, String> {
    use std::os::fd::AsRawFd;
    cancel.check().map_err(|e| e.to_string())?;
    if *budget == 0 {
        return Err("Directory entry limit: 4096".into());
    }
    let directory = match super::super::four_d_index::open_path(path, true) {
        Ok(d) => d,
        Err(e) => {
            if !path.exists() {
                return Ok(vec![]);
            }
            return Err(e);
        }
    };
    let mut paths = Vec::new();
    let mut entries = fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))
        .map_err(|e| e.to_string())?;
    loop {
        cancel.check().map_err(|e| e.to_string())?;
        if *budget == 0 {
            return Err("Directory entry limit: 4096".into());
        }
        let Some(item) = entries.next() else { break };
        *budget -= 1;
        let item = item.map_err(|e| e.to_string())?;
        paths.push(path.join(item.file_name()));
    }
    paths.sort();
    Ok(paths)
}
fn find_project(
    document: &Path,
    budget: &mut usize,
    cancel: &Cancellation,
) -> Result<Option<PathBuf>, String> {
    let mut current = document.parent();
    for _ in 0..8 {
        let Some(root) = current else { break };
        let entries = match children(&root.join("Project"), budget, cancel) {
            Ok(entries) => entries,
            Err(e) => {
                if cancel.check().is_err() || e.contains("limit") {
                    return Err(e);
                }
                current = root.parent();
                continue;
            }
        };
        if entries.iter().any(|p| {
            p.file_name()
                .is_some_and(|name| !name.as_bytes().starts_with(b"."))
                && p.extension()
                    .is_some_and(|e| e.eq_ignore_ascii_case("4dproject"))
                && super::super::four_d_index::open_path(p, false)
                    .and_then(|f| f.metadata().map_err(|e| e.to_string()))
                    .is_ok_and(|m| m.is_file())
        }) {
            return Ok(Some(root.into()));
        }
        current = root.parent();
    }
    Ok(None)
}
pub(super) fn source_id(path: &Path) -> String {
    let mut out = String::from("unix:");
    for byte in path.as_os_str().as_bytes() {
        use std::fmt::Write;
        write!(&mut out, "{byte:02x}").unwrap();
    }
    out
}
fn xml_files(
    path: &Path,
    label: &str,
    budget: &mut usize,
    sources: &mut Vec<Source>,
    seen: &mut HashSet<PathBuf>,
    cancel: &Cancellation,
) -> Result<Vec<String>, String> {
    if sources.len() >= SOURCES {
        return Err("Macro source limit: 256".into());
    }
    let entries = match children(path, budget, cancel) {
        Ok(entries) => entries,
        Err(e) => {
            if cancel.check().is_err() || e.contains("limit") {
                return Err(e);
            }
            return Ok(vec![format!(
                "{}: {e}",
                super::super::project_view::display(path)
            )]);
        }
    };
    for path in entries {
        if path
            .file_name()
            .is_some_and(|name| !name.as_bytes().starts_with(b"."))
            && path
                .extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("xml"))
            && seen.insert(path.clone())
        {
            if sources.len() >= SOURCES {
                return Err("Macro source limit: 256".into());
            }
            sources.push(Source {
                label: format!(
                    "{label} — {}",
                    super::super::project_view::display(path.file_name().unwrap().as_ref())
                ),
                path,
            });
        }
    }
    Ok(vec![])
}
fn bundle_macros(
    path: &Path,
    label: &str,
    budget: &mut usize,
    sources: &mut Vec<Source>,
    seen: &mut HashSet<PathBuf>,
    cancel: &Cancellation,
) -> Result<Vec<String>, String> {
    let mut issues = Vec::new();
    for relative in ["Macros v2", "Contents/Macros v2"] {
        issues.extend(xml_files(
            &path.join(relative),
            label,
            budget,
            sources,
            seen,
            cancel,
        )?);
    }
    Ok(issues)
}
#[derive(Clone, PartialEq, Eq)]
struct Fingerprint {
    path: PathBuf,
    label: String,
    identity: (u64, u64, u64, i64, i64, i64, i64),
}
struct CacheEntry {
    key: String,
    fingerprints: Vec<Fingerprint>,
    catalog: Arc<Catalog>,
    weight: usize,
}
static CACHE: OnceLock<Mutex<Vec<CacheEntry>>> = OnceLock::new();
fn fingerprint(source: &Source) -> Result<Fingerprint, String> {
    let file = super::super::four_d_index::open_path(&source.path, false)?;
    let m = file.metadata().map_err(|e| e.to_string())?;
    if !m.is_file() || m.len() > 8 * 1024 * 1024 {
        return Err("Regular macro XML up to 8 MiB required".into());
    }
    Ok(Fingerprint {
        path: source.path.clone(),
        label: source.label.clone(),
        identity: (
            m.dev(),
            m.ino(),
            m.len(),
            m.mtime(),
            m.mtime_nsec(),
            m.ctime(),
            m.ctime_nsec(),
        ),
    })
}
fn language_order<'a>(languages: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    let mut order = Vec::new();
    for language in languages.into_iter().chain(["de", "en"]) {
        let normalized = language
            .split(['.', '@'])
            .next()
            .unwrap_or("")
            .to_lowercase()
            .replace('_', "-");
        let mut parts: Vec<_> = normalized.split('-').filter(|p| !p.is_empty()).collect();
        while !parts.is_empty() {
            let candidate = parts.join("-");
            if !order.contains(&candidate) {
                order.push(candidate);
            }
            parts.pop();
        }
    }
    order
}
pub(super) fn load(
    document: &Path,
    selected_root: Option<&Path>,
    config: &Config,
    force: bool,
    cancel: &Cancellation,
    lang: Language,
) -> Result<Arc<Catalog>, String> {
    let mut budget = ENTRIES;
    let project =
        find_project(document, &mut budget, cancel)?.or_else(|| selected_root.map(Path::to_owned));
    let mut sources = Vec::new();
    let mut seen = HashSet::new();
    let mut issues = Vec::new();
    if let Some(root) = &project {
        issues.extend(bundle_macros(
            root,
            lang.text("Projekt", "Project"),
            &mut budget,
            &mut sources,
            &mut seen,
            cancel,
        )?);
        let components =
            match super::super::four_d_components::discover_with_budget(root, cancel, budget) {
                Ok(c) => c,
                Err(e) => {
                    if cancel.check().is_err() || e.contains("limit") {
                        return Err(e);
                    }
                    issues.push(e);
                    budget = budget.saturating_sub(budget.min(4000));
                    super::super::four_d_components::Discovery {
                        bundles: vec![],
                        visited: 0,
                    }
                }
            };
        if components.visited > budget {
            return Err("Directory entry limit: 4096".into());
        }
        budget -= components.visited;
        let mut bundles: Vec<(String, PathBuf)> = components
            .bundles
            .into_iter()
            .filter(|b| !b.archived)
            .map(|b| (b.name, b.path))
            .collect();
        let dependency = root.join("Project/Sources/dependencies.json");
        if dependency.exists() {
            match super::super::four_d_index::read_bounded(&dependency, 8 * 1024 * 1024, cancel)
                .and_then(|(bytes, _)| {
                    serde_json::from_slice::<serde_json::Value>(&bytes).map_err(|e| e.to_string())
                }) {
                Ok(json) => {
                    if let Some(deps) = json.get("dependencies").and_then(|v| v.as_object()) {
                        let mut deps: Vec<_> = deps.iter().collect();
                        deps.sort_by_key(|(k, _)| *k);
                        for (name, value) in deps {
                            if budget == 0 {
                                return Err("Directory entry limit: 4096".into());
                            }
                            budget -= 1;
                            if let Some(path) = value
                                .get("path")
                                .and_then(|v| v.as_str())
                                .filter(|s| !s.is_empty())
                            {
                                let path = if path == "~" || path.starts_with("~/") {
                                    std::env::var_os("HOME")
                                        .map(|h| {
                                            PathBuf::from(h).join(if path == "~" {
                                                ""
                                            } else {
                                                path.trim_start_matches("~/")
                                            })
                                        })
                                        .unwrap_or_default()
                                } else if Path::new(path).is_absolute() {
                                    path.into()
                                } else {
                                    root.join(path)
                                };
                                match fs::canonicalize(&path) {
                                    Ok(path) => bundles.push((name.clone(), path)),
                                    Err(e) => issues.push(format!(
                                        "{}: {e}",
                                        super::super::project_view::display(&path)
                                    )),
                                }
                            }
                        }
                    }
                }
                Err(e) => issues.push(format!("dependencies.json: {e}")),
            }
        }
        let mut bundle_seen = HashSet::new();
        for (name, path) in bundles {
            if bundle_seen.insert(path.clone()) {
                issues.extend(bundle_macros(
                    &path,
                    &format!("{} {name}", lang.text("Komponente", "Component")),
                    &mut budget,
                    &mut sources,
                    &mut seen,
                    cancel,
                )?);
            }
        }
    }
    if let Some(user) = config.user.clone().or_else(default_user) {
        issues.extend(xml_files(
            &user,
            lang.text("Eigene Makros", "User macros"),
            &mut budget,
            &mut sources,
            &mut seen,
            cancel,
        )?);
    }
    if let Some(installation) = &config.installation {
        issues.extend(xml_files(
            installation,
            "4D",
            &mut budget,
            &mut sources,
            &mut seen,
            cancel,
        )?);
        issues.extend(bundle_macros(
            installation,
            "4D",
            &mut budget,
            &mut sources,
            &mut seen,
            cancel,
        )?);
        for resources in [
            installation.join("Resources"),
            installation.join("Contents/Resources"),
        ] {
            let dirs = match children(&resources, &mut budget, cancel) {
                Ok(entries) => entries,
                Err(e) => {
                    if cancel.check().is_err() || e.contains("limit") {
                        return Err(e);
                    }
                    issues.push(e);
                    continue;
                }
            };
            let languages = language_order(gtk::glib::language_names().iter().map(|s| s.as_str()));
            let mut candidates: Vec<_> = dirs
                .into_iter()
                .filter(|p| {
                    p.extension()
                        .is_some_and(|e| e.eq_ignore_ascii_case("lproj"))
                })
                .collect();
            candidates.sort_by_key(|p| {
                let name = p
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_lowercase()
                    .replace('_', "-");
                (
                    languages
                        .iter()
                        .position(|l| l == &name)
                        .unwrap_or(usize::MAX),
                    p.clone(),
                )
            });
            for dir in candidates {
                let path = dir.join("Macros.xml");
                if path.exists() {
                    if seen.insert(path.clone()) {
                        if sources.len() >= SOURCES {
                            return Err("Macro source limit: 256".into());
                        }
                        sources.push(Source {
                            path,
                            label: "4D — Macros.xml".into(),
                        });
                    }
                    break;
                }
            }
        }
    }
    sources.retain(|source| match fingerprint(source) {
        Ok(_) => true,
        Err(e) => {
            issues.push(format!("{}: {e}", source.label));
            false
        }
    });
    let fingerprints: Vec<_> = sources.iter().map(fingerprint).collect::<Result<_, _>>()?;
    let key = format!("{:?}|{:?}|{}", project, config, lang.0);
    let cache = CACHE.get_or_init(Default::default);
    if !force {
        let mut entries = cache.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(index) = entries
            .iter()
            .position(|e| e.key == key && e.fingerprints == fingerprints)
        {
            let entry = entries.remove(index);
            let value = entry.catalog.clone();
            entries.push(entry);
            return Ok(value);
        }
    }
    let (mut macros, mut text_units, mut parts, mut weight) = (Vec::new(), 0usize, 0usize, 0usize);
    for source in &sources {
        cancel.check().map_err(|e| e.to_string())?;
        match super::super::four_d_index::read_bounded(&source.path, 8 * 1024 * 1024, cancel)
            .and_then(|(bytes, _)| {
                core::parse_bytes(
                    &bytes,
                    &source.label,
                    &source_id(&source.path),
                    core::Limits::default(),
                    cancel,
                )
                .map_err(|e| format!("{e:?}"))
            }) {
            Ok(parsed) => {
                let next_text: usize = parsed
                    .iter()
                    .map(|m| {
                        m.display_name.encode_utf16().count()
                            + m.source_label.encode_utf16().count()
                            + m.method_call
                                .as_ref()
                                .map_or(0, |s| s.encode_utf16().count())
                            + m.parts
                                .iter()
                                .map(|p| {
                                    if let core::Part::Literal(s) = p {
                                        s.encode_utf16().count()
                                    } else {
                                        0
                                    }
                                })
                                .sum::<usize>()
                    })
                    .sum();
                let next_parts: usize = parsed.iter().map(|m| m.parts.len()).sum();
                if macros.len() + parsed.len() > 8192
                    || text_units + next_text > 8 * 1024 * 1024
                    || parts + next_parts > 262144
                {
                    return Err("Complete macro catalog exceeds its budget".into());
                }
                text_units += next_text;
                parts += next_parts;
                weight += next_text * 2
                    + next_parts * 32
                    + parsed
                        .iter()
                        .map(|m| {
                            m.id.len() + m.unknown_placeholder.as_ref().map_or(0, String::len) + 128
                        })
                        .sum::<usize>();
                macros.extend(parsed);
            }
            Err(e) => issues.push(format!("{}: {e}", source.label)),
        }
    }
    if sources
        .iter()
        .map(fingerprint)
        .collect::<Result<Vec<_>, _>>()?
        != fingerprints
    {
        return Err("Macro sources changed while reading; refresh".into());
    }
    core::resolve_shortcuts(
        &mut macros,
        &super::super::editor_shortcuts::reserved_macro_keys(),
    );
    let mut diagnostic_bytes = 0usize;
    let issue_count = issues.len();
    issues.retain(|issue| {
        if diagnostic_bytes.saturating_add(issue.len()) > 128 * 1024 {
            return false;
        }
        diagnostic_bytes += issue.len();
        true
    });
    if issues.len() > 255 {
        issues.truncate(255);
    }
    if issues.len() < issue_count {
        issues.push(
            lang.text(
                "Weitere Quellmeldungen wurden nach der Anzeigegrenze ausgelassen.",
                "Further source diagnostics were omitted after the display limit.",
            )
            .into(),
        );
    }
    weight += issues.iter().map(String::len).sum::<usize>()
        + sources
            .iter()
            .map(|s| s.path.as_os_str().as_bytes().len() + s.label.len() + 128)
            .sum::<usize>();
    let catalog = Arc::new(Catalog {
        sources,
        macros,
        issues,
        project,
    });
    if weight <= 16 * 1024 * 1024 {
        let mut entries = cache.lock().unwrap_or_else(|e| e.into_inner());
        entries.retain(|e| e.key != key);
        while entries.len() >= 8
            || entries.iter().map(|e| e.weight).sum::<usize>() + weight > 16 * 1024 * 1024
        {
            entries.remove(0);
        }
        entries.push(CacheEntry {
            key,
            fingerprints,
            catalog: catalog.clone(),
            weight,
        });
    }
    Ok(catalog)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn installation_language_fallback_preserves_script_and_base_order() {
        assert_eq!(
            language_order(["zh_Hant_TW.UTF-8", "fr-CA", "fr"]),
            ["zh-hant-tw", "zh-hant", "zh", "fr-ca", "fr", "de", "en"]
        );
    }
    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let root = tempfile::tempdir_in(
            std::env::var_os("FASTRA_UI_TEST_ROOT").unwrap_or_else(|| "/tmp".into()),
        )
        .unwrap();
        let project = root.path().join("project");
        let doc = project.join("Project/Sources/Methods/A.4dm");
        fs::create_dir_all(doc.parent().unwrap()).unwrap();
        fs::write(project.join("Project/Test.4DProject"), "{}").unwrap();
        fs::write(&doc, "original").unwrap();
        (root, project, doc)
    }
    fn xml(path: &Path, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            path,
            format!("<macros><macro name='A'><text>{text}</text></macro></macros>"),
        )
        .unwrap();
    }
    #[test]
    fn component_versions_declared_paths_user_sources_and_bad_file_stay_independent() {
        let (root, project, doc) = fixture();
        let user = root.path().join("user");
        xml(
            &project.join("Components/Old.4dbase/Macros v2/Macros.xml"),
            "old",
        );
        xml(
            &project.join("components/New.4dbase/Contents/Macros v2/Macros.xml"),
            "new",
        );
        let external = root.path().join("external");
        xml(&external.join("Macros v2/Macros.xml"), "external");
        fs::write(
            project.join("Project/Sources/dependencies.json"),
            serde_json::json!({"dependencies":{"external":{"path":"../external"}}}).to_string(),
        )
        .unwrap();
        xml(&user.join("Macros.xml"), "user");
        fs::write(user.join("broken.xml"), "<broken").unwrap();
        let catalog = load(
            &doc,
            Some(&project),
            &Config {
                user: Some(user),
                installation: None,
                ..Default::default()
            },
            true,
            &Cancellation::default(),
            Language(false),
        )
        .unwrap();
        assert_eq!(catalog.macros.len(), 4);
        assert_eq!(
            catalog
                .macros
                .iter()
                .map(|m| &m.id)
                .collect::<HashSet<_>>()
                .len(),
            4
        );
        assert_eq!(catalog.issues.len(), 1);
        assert_eq!(catalog.project.as_deref(), Some(project.as_path()));
    }
    #[test]
    fn fifo_link_and_oversized_sources_do_not_block_good_xml() {
        use std::os::unix::fs::symlink;
        let (root, project, doc) = fixture();
        let user = root.path().join("user");
        xml(&user.join("good.xml"), "good");
        let fifo = user.join("fifo.xml");
        let raw = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(raw.as_ptr(), 0o600) }, 0);
        symlink(user.join("good.xml"), user.join("link.xml")).unwrap();
        let file = fs::File::create(user.join("large.xml")).unwrap();
        file.set_len(8 * 1024 * 1024 + 1).unwrap();
        let c = load(
            &doc,
            Some(&project),
            &Config {
                user: Some(user),
                installation: None,
                ..Default::default()
            },
            true,
            &Cancellation::default(),
            Language(false),
        )
        .unwrap();
        assert_eq!(c.macros.len(), 1);
        assert_eq!(c.issues.len(), 3);
    }
    #[test]
    fn cache_fingerprints_change_after_xml_replacement_and_ids_keep_raw_bytes() {
        use std::os::unix::ffi::OsStringExt;
        let (root, project, doc) = fixture();
        let user = root.path().join("user");
        let path = user.join("macro.xml");
        xml(&path, "first");
        let config = Config {
            user: Some(user.clone()),
            installation: None,
            ..Default::default()
        };
        let first = load(
            &doc,
            Some(&project),
            &config,
            false,
            &Cancellation::default(),
            Language(false),
        )
        .unwrap();
        let cached = load(
            &doc,
            Some(&project),
            &config,
            false,
            &Cancellation::default(),
            Language(false),
        )
        .unwrap();
        assert!(Arc::ptr_eq(&first, &cached));
        xml(&user.join("replacement.xml"), "second");
        fs::rename(user.join("replacement.xml"), &path).unwrap();
        let second = load(
            &doc,
            Some(&project),
            &config,
            false,
            &Cancellation::default(),
            Language(false),
        )
        .unwrap();
        assert!(!Arc::ptr_eq(&first, &second));
        assert_eq!(
            second.macros[0].parts,
            vec![core::Part::Literal("second".into())]
        );
        assert_ne!(
            source_id(&user.join(std::ffi::OsString::from_vec(b"a\xff.xml".to_vec()))),
            source_id(&user.join("a�.xml"))
        );
    }
    #[test]
    fn installation_resource_roots_share_the_complete_source_limit() {
        let (root, project, doc) = fixture();
        let user = root.path().join("user");
        for index in 0..255 {
            xml(&user.join(format!("{index:03}.xml")), "user");
        }
        let installation = root.path().join("4d");
        let resources = installation.join("Resources/en.lproj/Macros.xml");
        let contents = installation.join("Contents/Resources/en.lproj/Macros.xml");
        xml(&resources, "resource");
        xml(&contents, "contents");
        let config = Config {
            user: Some(user.clone()),
            installation: Some(installation),
            ..Default::default()
        };
        let over_limit = load(
            &doc,
            Some(&project),
            &config,
            true,
            &Cancellation::default(),
            Language(false),
        );
        assert!(matches!(over_limit, Err(ref error) if error == "Macro source limit: 256"));
        fs::remove_file(user.join("254.xml")).unwrap();
        let at_limit = load(
            &doc,
            Some(&project),
            &config,
            true,
            &Cancellation::default(),
            Language(false),
        )
        .unwrap();
        assert_eq!(at_limit.sources.len(), SOURCES);
        for path in [resources, contents] {
            assert!(at_limit.sources.iter().any(|source| source.path == path));
        }
    }
    #[test]
    fn directory_budget_is_shared_and_stops_before_unbounded_scan() {
        let (root, project, doc) = fixture();
        let user = root.path().join("user");
        fs::create_dir(&user).unwrap();
        for i in 0..4100 {
            fs::write(user.join(format!("{i:04}.ignore")), "").unwrap();
        }
        assert!(load(
            &doc,
            Some(&project),
            &Config {
                user: Some(user),
                installation: None,
                ..Default::default()
            },
            true,
            &Cancellation::default(),
            Language(false)
        )
        .is_err());
    }
}

#[cfg(test)]
mod settings_tests;
