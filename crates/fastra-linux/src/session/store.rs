//! Private, atomare Sitzungsdateien; pro Fenster hält ein flock die lebende Sicherung exklusiv.
use serde::{Deserialize, Serialize};
use std::{
    ffi::{CString, OsStr},
    fs::{self, File},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::{OsStrExt, OsStringExt},
            fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
        },
    },
    path::{Path, PathBuf},
    sync::Arc,
};
pub const MAX_JOURNALS: usize = 64;
pub const MAX_DOCS: usize = 32;
pub const MAX_DOC_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_TOTAL: usize = 8 * 1024 * 1024;
pub const MAX_JSON: usize = 64 * 1024 * 1024;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub name: String,
    pub path: Option<Vec<u8>>,
    pub device: Option<u64>,
    pub inode: Option<u64>,
    #[serde(default)]
    pub binding: Option<String>,
    pub original_hex: String,
    pub encoding: u8,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub saved_ending: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_ending: Option<u8>,
    pub dirty: bool,
}
impl Record {
    pub(super) fn validate_endings(&self) -> Result<(), String> {
        if self
            .saved_ending
            .is_some_and(|code| super::super::line_endings::decode(code).is_none())
            || self
                .pending_ending
                .is_some_and(|code| super::super::line_endings::decode(code).is_none())
            || (self.pending_ending.is_some() && !self.dirty)
        {
            return Err("Invalid recovery line-ending intent".into());
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReadOnlyRecord {
    pub name: String,
    pub path: Vec<u8>,
    pub encoding: u8,
    pub position: usize,
}
#[derive(Clone, Copy)]
pub enum Tab<'a> {
    Editor(&'a Record),
    ReadOnly(&'a ReadOnlyRecord),
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Session {
    pub version: u32,
    pub active: usize,
    pub width: i32,
    pub height: i32,
    pub documents: Vec<Record>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub read_only_sources: Vec<ReadOnlyRecord>,
    #[serde(default)]
    pub recovery_journals: Vec<Vec<u8>>,
}
pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8] = b"0123456789abcdef";
    let mut result = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        result.push(char::from(DIGITS[(b >> 4) as usize]));
        result.push(char::from(DIGITS[(b & 15) as usize]));
    }
    result
}
pub fn unhex(text: &str) -> Result<Vec<u8>, String> {
    if text.len() > MAX_DOC_BYTES * 2 || !text.len().is_multiple_of(2) {
        return Err("Invalid original byte limit".into());
    }
    fn digit(b: u8) -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            _ => None,
        }
    }
    text.as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| {
            Ok(digit(b[0]).ok_or("Invalid original bytes")? * 16
                + digit(b[1]).ok_or("Invalid original bytes")?)
        })
        .collect()
}
pub fn encoding(value: u8) -> Result<fastra_core::encoding::Encoding, String> {
    use fastra_core::encoding::Encoding::*;
    match value {
        0 => Ok(Utf8),
        1 => Ok(Utf16Le),
        2 => Ok(Utf16Be),
        3 => Ok(Utf32Le),
        4 => Ok(Utf32Be),
        5 => Ok(Windows1252),
        6 => Ok(Latin1),
        7 => Ok(MacRoman),
        _ => Err("Unknown encoding".into()),
    }
}
pub fn encoding_id(value: fastra_core::encoding::Encoding) -> u8 {
    use fastra_core::encoding::Encoding::*;
    match value {
        Utf8 => 0,
        Utf16Le => 1,
        Utf16Be => 2,
        Utf32Le => 3,
        Utf32Be => 4,
        Windows1252 => 5,
        Latin1 => 6,
        MacRoman => 7,
    }
}
impl Session {
    pub fn tab_count(&self) -> usize {
        self.documents
            .len()
            .saturating_add(self.read_only_sources.len())
    }
    pub fn ordered(&self) -> Vec<Tab<'_>> {
        let mut editors = self.documents.iter();
        (0..self.tab_count())
            .filter_map(|position| {
                self.read_only_sources
                    .iter()
                    .find(|record| record.position == position)
                    .map(Tab::ReadOnly)
                    .or_else(|| editors.next().map(Tab::Editor))
            })
            .collect()
    }
    pub fn validate(&self) -> Result<(), String> {
        if !matches!(self.version, 1 | 2)
            || self.version == 1 && !self.read_only_sources.is_empty()
            || self.tab_count() > MAX_DOCS
            || (self.tab_count() > 0 && self.active >= self.tab_count())
            || !(760..=4000).contains(&self.width)
            || !(700..=2400).contains(&self.height)
        {
            return Err("Session schema/window limit".into());
        }
        let mut positions = std::collections::HashSet::new();
        for source in &self.read_only_sources {
            if source.name.len() > 1024
                || source.name.contains('\0')
                || source.path.is_empty()
                || source.path.len() > 4096
                || source.path.contains(&0)
                || !source_path(&source.path).is_absolute()
                || encoding(source.encoding).is_err()
                || source.position >= self.tab_count()
                || !positions.insert(source.position)
            {
                return Err("Invalid read-only source reference".into());
            }
        }
        if self.recovery_journals.len() > MAX_JOURNALS {
            return Err("Recovery journal index limit: 64".into());
        }
        let mut unique = std::collections::HashSet::new();
        for path in &self.recovery_journals {
            if path.is_empty()
                || path.len() > 4096
                || path.contains(&0)
                || !source_path(path).is_absolute()
                || !unique.insert(path)
            {
                return Err("Invalid recovery journal path".into());
            }
        }
        let mut total = 0usize;
        for record in &self.documents {
            record.validate_endings()?;
            if record.name.len() > 1024
                || record.name.contains('\0')
                || record.text.len() > MAX_DOC_BYTES
                || record.text.contains('\0')
            {
                return Err("Session text/name limit".into());
            }
            if let Some(path) = &record.path {
                if path.len() > 4096
                    || path.contains(&0)
                    || !Path::new(OsStr::from_bytes(path)).is_absolute()
                    || record.device.is_none()
                    || record.inode.is_none()
                {
                    return Err("Invalid original source binding".into());
                }
            } else if record.device.is_some() || record.inode.is_some() || record.binding.is_some()
            {
                return Err("Unexpected original identity".into());
            }
            if let Some(binding) = &record.binding {
                if binding.len() != 64 || unhex(binding)?.len() != 32 {
                    return Err("Invalid original snapshot binding".into());
                }
            }
            let original = unhex(&record.original_hex)?;
            let decoded =
                fastra_core::encoding::decode(&original, Some(encoding(record.encoding)?))
                    .map_err(|e| e.to_string())?;
            if !record.dirty && record.text != decoded.text() {
                return Err("Clean session text differs from original bytes".into());
            }
            if decoded.text().contains('\0')
                || decoded.encode(decoded.text()).map_err(|e| e.to_string())? != original
            {
                return Err("Invalid original codec bytes".into());
            }
            total = total
                .checked_add(record.text.len() + original.len())
                .ok_or("Session size overflow")?;
            if total > MAX_TOTAL {
                return Err("Session total limit: 8 MiB".into());
            }
        }
        Ok(())
    }
}
fn error() -> String {
    std::io::Error::last_os_error().to_string()
}
fn c_name(name: &str) -> Result<CString, String> {
    if name.len() > 128
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.')
    {
        return Err("Invalid session filename".into());
    }
    CString::new(name).map_err(|e| e.to_string())
}
fn regular(file: &File) -> Result<(), String> {
    let m = file.metadata().map_err(|e| e.to_string())?;
    if !m.is_file()
        || m.uid() != unsafe { libc::geteuid() }
        || m.nlink() != 1
        || m.mode() & 0o777 != 0o600
    {
        return Err("Session file must be owned, regular, single-link and mode 0600".into());
    }
    Ok(())
}
#[derive(Debug)]
pub struct Directory {
    file: File,
    path: PathBuf,
}
impl Directory {
    pub fn open(base: &Path) -> Result<Arc<Self>, String> {
        if !base.is_absolute() {
            return Err("XDG state directory must be absolute".into());
        }
        fs::create_dir_all(base).map_err(|e| e.to_string())?;
        let path = base.join("fastra");
        match fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e.to_string()),
        }
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&path)
            .map_err(|e| e.to_string())?;
        let m = file.metadata().map_err(|e| e.to_string())?;
        if !m.is_dir() || m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o777 != 0o700 {
            return Err("Session directory must be owned and mode 0700".into());
        }
        Ok(Arc::new(Self { file, path }))
    }
    fn bound(&self) -> Result<(), String> {
        let meta = fs::symlink_metadata(&self.path).map_err(|e| e.to_string())?;
        let held = self.file.metadata().map_err(|e| e.to_string())?;
        if !meta.is_dir() || (meta.dev(), meta.ino()) != (held.dev(), held.ino()) {
            return Err("Session directory changed".into());
        }
        Ok(())
    }
    fn open_file(&self, name: &str, flags: i32) -> Result<File, String> {
        let name = c_name(name)?;
        let fd = unsafe {
            libc::openat(
                self.file.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK | libc::O_NOCTTY,
                0o600,
            )
        };
        if fd < 0 {
            return Err(error());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        regular(&file)?;
        Ok(file)
    }
    fn unlink(&self, name: &str) -> Result<(), String> {
        let name = c_name(name)?;
        if unsafe { libc::unlinkat(self.file.as_raw_fd(), name.as_ptr(), 0) } < 0 {
            return Err(error());
        }
        Ok(())
    }
    fn lease(self: &Arc<Self>, name: String) -> Result<Option<Lease>, String> {
        let file = self.open_file(&format!("{name}.lock"), libc::O_RDWR | libc::O_CREAT)?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::WouldBlock {
                return Ok(None);
            }
            return Err(error.to_string());
        }
        let lease = Lease {
            directory: self.clone(),
            name,
            _file: file,
        };
        lease.bound()?;
        Ok(Some(lease))
    }
    pub fn create(self: &Arc<Self>) -> Result<Lease, String> {
        self.create_with_names(|| format!("session-{}.json", gtk::glib::uuid_string_random()))
    }
    fn create_with_names(
        self: &Arc<Self>,
        mut next: impl FnMut() -> String,
    ) -> Result<Lease, String> {
        for _ in 0..8 {
            self.bound()?;
            let name = next();
            let lock = c_name(&format!("{name}.lock"))?;
            let fd = unsafe {
                libc::openat(
                    self.file.as_raw_fd(),
                    lock.as_ptr(),
                    libc::O_RDWR
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_NONBLOCK
                        | libc::O_CLOEXEC,
                    0o600,
                )
            };
            if fd < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::AlreadyExists {
                    continue;
                }
                return Err(error.to_string());
            }
            let file = unsafe { File::from_raw_fd(fd) };
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } < 0 {
                return Err(error());
            }
            let lease = Lease {
                directory: self.clone(),
                name,
                _file: file,
            };
            lease.bound()?;
            let record = c_name(&lease.name)?;
            if unsafe {
                libc::faccessat(
                    self.file.as_raw_fd(),
                    record.as_ptr(),
                    libc::F_OK,
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } >= 0
            {
                // Auch eine verwaiste JSON ohne Lock ist niemals ein neuer Fensterrecord.
                lease.bound()?;
                self.unlink(&format!("{}.lock", lease.name))?;
                continue;
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::NotFound {
                return Err(error.to_string());
            }
            return Ok(lease);
        }
        Err("Session lease collision limit: 8".into())
    }
    pub fn inactive(self: &Arc<Self>) -> Result<Vec<Archive>, String> {
        self.bound()?;
        let mut archives = Vec::new();
        let mut visited = 0;
        let mut total_json = 0;
        for entry in fs::read_dir(format!("/proc/self/fd/{}", self.file.as_raw_fd()))
            .map_err(|e| e.to_string())?
        {
            visited += 1;
            if visited > 256 {
                return Err("Session directory entry limit: 256".into());
            }
            let entry = entry.map_err(|e| e.to_string())?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                return Err("Unknown session filename".into());
            };
            if let Some(record) = name
                .strip_suffix(".lock")
                .filter(|n| n.starts_with("session-") && n.ends_with(".json"))
            {
                if let Some(lease) = self.lease(record.to_owned())? {
                    let record = c_name(&lease.name)?;
                    if unsafe {
                        libc::faccessat(
                            self.file.as_raw_fd(),
                            record.as_ptr(),
                            libc::F_OK,
                            libc::AT_SYMLINK_NOFOLLOW,
                        )
                    } < 0
                    {
                        let error = std::io::Error::last_os_error();
                        if error.kind() != std::io::ErrorKind::NotFound {
                            return Err(error.to_string());
                        }
                        // Exklusives flock schützt lebende Fenster; es werden nur eigene leere Lease-Dateien entfernt.
                        lease.bound()?;
                        self.unlink(name)?;
                        self.file.sync_all().map_err(|e| e.to_string())?;
                    }
                }
                continue;
            }
            if !name.starts_with("session-") || !name.ends_with(".json") {
                continue;
            }
            if archives.len() >= 16 {
                return Err("Inactive session limit: 16".into());
            }
            let Some(lease) = self.lease(name.to_owned())? else {
                continue;
            };
            let mut file = self.open_file(name, libc::O_RDONLY)?;
            let size = file.metadata().map_err(|e| e.to_string())?.len();
            if size > MAX_JSON as u64 {
                return Err("Session JSON limit: 64 MiB".into());
            }
            total_json += size as usize;
            if total_json > MAX_JSON {
                return Err("Combined session JSON limit: 64 MiB".into());
            }
            let mut bytes = Vec::new();
            Read::by_ref(&mut file)
                .take((MAX_JSON + 1) as u64)
                .read_to_end(&mut bytes)
                .map_err(|e| e.to_string())?;
            if bytes.len() > MAX_JSON {
                return Err("Session JSON grew past limit".into());
            }
            let session: Session = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
            session.validate()?;
            if session.tab_count() == 0 && session.recovery_journals.is_empty() {
                lease.remove()?;
                continue;
            }
            archives.push(Archive { lease, session });
        }
        archives.sort_by(|a, b| a.lease.name.cmp(&b.lease.name));
        self.bound()?;
        Ok(archives)
    }
}
#[derive(Debug)]
pub struct Lease {
    directory: Arc<Directory>,
    pub name: String,
    _file: File,
}
impl Lease {
    fn bound(&self) -> Result<(), String> {
        self.directory.bound()?;
        regular(&self._file)?;
        let named = self
            .directory
            .open_file(&format!("{}.lock", self.name), libc::O_RDONLY)?;
        let held = self._file.metadata().map_err(|e| e.to_string())?;
        let current = named.metadata().map_err(|e| e.to_string())?;
        if held.dev() != current.dev() || held.ino() != current.ino() {
            return Err("Session lock binding changed".into());
        }
        Ok(())
    }
    pub fn read_optional(&self) -> Result<Option<Session>, String> {
        self.bound()?;
        let mut file = match self.directory.open_file(&self.name, libc::O_RDONLY) {
            Ok(file) => file,
            Err(error) => {
                let path =
                    std::ffi::CString::new(self.name.as_bytes()).map_err(|e| e.to_string())?;
                if unsafe {
                    libc::faccessat(
                        self.directory.file.as_raw_fd(),
                        path.as_ptr(),
                        libc::F_OK,
                        libc::AT_SYMLINK_NOFOLLOW,
                    )
                } < 0
                    && std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound
                {
                    return Ok(None);
                }
                return Err(error);
            }
        };
        if file.metadata().map_err(|e| e.to_string())?.len() > MAX_JSON as u64 {
            return Err("Session JSON limit".into());
        }
        let mut bytes = Vec::new();
        Read::by_ref(&mut file)
            .take((MAX_JSON + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > MAX_JSON {
            return Err("Session JSON grew past limit".into());
        }
        let session: Session = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        session.validate()?;
        self.bound()?;
        Ok(Some(session))
    }
    pub fn write(&self, session: &Session) -> Result<(), String> {
        self.bound()?;
        session.validate()?;
        let bytes = serde_json::to_vec(session).map_err(|e| e.to_string())?;
        if bytes.len() > MAX_JSON {
            return Err("Serialized session JSON limit".into());
        }
        let temporary = format!("{}.tmp", self.name);
        let mut file = self
            .directory
            .open_file(&temporary, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL)?;
        let result = (|| {
            file.write_all(&bytes).map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            self.bound()?;
            let from = c_name(&temporary)?;
            let to = c_name(&self.name)?;
            match self.directory.open_file(&self.name, libc::O_RDONLY) {
                Ok(_) => {}
                Err(_)
                    if unsafe {
                        libc::faccessat(
                            self.directory.file.as_raw_fd(),
                            to.as_ptr(),
                            libc::F_OK,
                            libc::AT_SYMLINK_NOFOLLOW,
                        )
                    } < 0
                        && std::io::Error::last_os_error().kind()
                            == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
            if unsafe {
                libc::renameat(
                    self.directory.file.as_raw_fd(),
                    from.as_ptr(),
                    self.directory.file.as_raw_fd(),
                    to.as_ptr(),
                )
            } < 0
            {
                return Err(error());
            }
            self.directory.file.sync_all().map_err(|e| e.to_string())?;
            self.bound()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = self.directory.unlink(&temporary);
        }
        result
    }
    pub fn remove(&self) -> Result<(), String> {
        self.bound()?;
        // Nur eine gehaltene Lease darf die dazugehörige, geprüfte JSON-Datei entfernen.
        self.directory.open_file(&self.name, libc::O_RDONLY)?;
        self.directory.unlink(&self.name)?;
        self.bound()?;
        self.directory.unlink(&format!("{}.lock", self.name))?;
        self.directory.file.sync_all().map_err(|e| e.to_string())
    }
}
#[derive(Debug)]
pub struct Archive {
    pub lease: Lease,
    pub session: Session,
}
pub fn source_path(bytes: &[u8]) -> PathBuf {
    PathBuf::from(std::ffi::OsString::from_vec(bytes.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    #[test]
    fn fresh_leases_never_adopt_existing_json_or_lock_names() {
        let root = tempfile::tempdir().unwrap();
        let directory = Directory::open(root.path()).unwrap();
        let old = directory.create().unwrap();
        old.write(&sample()).unwrap();
        let name = old.name.clone();
        drop(old);
        assert!(directory.create_with_names(|| name.clone()).is_err());
        directory.unlink(&format!("{name}.lock")).unwrap();
        assert!(directory.create_with_names(|| name.clone()).is_err());
        let bytes = std::fs::read(directory.path.join(&name)).unwrap();
        let saved: Session = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(saved.documents[0].text, sample().documents[0].text);
        let mut attempts = 0;
        let fresh = directory
            .create_with_names(|| {
                attempts += 1;
                if attempts == 1 {
                    name.clone()
                } else {
                    "session-fresh.json".into()
                }
            })
            .unwrap();
        assert_eq!(attempts, 2);
        assert_eq!(fresh.name, "session-fresh.json");
        assert!(fresh.read_optional().unwrap().is_none());
    }
    #[test]
    fn lock_replacement_and_open_before_flock_never_publish_an_unbound_copy() {
        let root = tempfile::tempdir().unwrap();
        let directory = Directory::open(root.path()).unwrap();
        let lease = directory.create().unwrap();
        lease.write(&sample()).unwrap();
        directory.unlink(&format!("{}.lock", lease.name)).unwrap();
        let current = directory.lease(lease.name.clone()).unwrap().unwrap();
        let mut newer = sample();
        newer.documents[0].text = "new owner".into();
        current.write(&newer).unwrap();
        assert!(lease.write(&sample()).is_err());
        assert!(lease.remove().is_err());
        assert_eq!(
            current.read_optional().unwrap().unwrap().documents[0].text,
            "new owner"
        );
        let name = "session-before-flock.json".to_owned();
        let file = directory
            .open_file(&format!("{name}.lock"), libc::O_RDWR | libc::O_CREAT)
            .unwrap();
        let archives = directory.inactive().unwrap();
        assert!(archives.is_empty());
        assert_eq!(
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        let interrupted = Lease {
            directory: directory.clone(),
            name,
            _file: file,
        };
        assert!(interrupted.bound().is_err());
        assert!(interrupted.write(&sample()).is_err());
    }
    #[test]
    fn optout_leases_are_cleaned_only_after_the_live_owner_releases_them() {
        let root = tempfile::tempdir().unwrap();
        let directory = Directory::open(root.path()).unwrap();
        let lease = directory.create().unwrap();
        let lock = directory.path.join(format!("{}.lock", lease.name));
        assert!(directory.inactive().unwrap().is_empty());
        assert!(lock.exists());
        drop(lease);
        assert!(directory.inactive().unwrap().is_empty());
        assert!(!lock.exists());
        for _ in 0..300 {
            drop(directory.create().unwrap());
            assert!(directory.inactive().unwrap().is_empty());
        }
        assert_eq!(std::fs::read_dir(&directory.path).unwrap().count(), 0);
    }
    #[test]
    fn journal_metadata_keeps_raw_paths_and_never_needs_editor_text() {
        let root = tempfile::tempdir().unwrap();
        let directory = Directory::open(root.path()).unwrap();
        let lease = directory.create().unwrap();
        assert!(lease.read_optional().unwrap().is_none());
        let mut record = sample();
        record.documents.clear();
        record.recovery_journals = vec![b"/local/project-\xff/.fastra-transaction-test".to_vec()];
        lease.write(&record).unwrap();
        assert_eq!(
            lease.read_optional().unwrap().unwrap().recovery_journals,
            record.recovery_journals
        );
        drop(lease);
        let archives = directory.inactive().unwrap();
        assert_eq!(archives.len(), 1);
        assert!(archives[0].session.documents.is_empty());
        record.recovery_journals = vec![b"relative".to_vec()];
        assert!(record.validate().is_err());
        record.recovery_journals = vec![b"/a\0b".to_vec()];
        assert!(record.validate().is_err());
        record.recovery_journals = vec![b"/a".to_vec(); 65];
        assert!(record.validate().is_err());
        let mut old = serde_json::to_value(sample()).unwrap();
        old.as_object_mut().unwrap().remove("recovery_journals");
        let compatible: Session = serde_json::from_value(old).unwrap();
        assert!(compatible.recovery_journals.is_empty());
    }
    fn sample() -> Session {
        Session {
            read_only_sources: Vec::new(),
            recovery_journals: Vec::new(),
            version: 1,
            active: 0,
            width: 900,
            height: 800,
            documents: vec![Record {
                name: "dirty".into(),
                path: None,
                device: None,
                inode: None,
                binding: None,
                original_hex: hex(b"original"),
                encoding: 0,
                text: "changed café\r\n".into(),
                saved_ending: None,
                pending_ending: None,
                dirty: true,
            }],
        }
    }
    #[test]
    fn readonly_references_preserve_mixed_order_and_reject_ambiguous_archives() {
        let mut session = sample();
        let legacy = serde_json::to_value(&session).unwrap();
        assert!(legacy.get("read_only_sources").is_none());
        assert!(serde_json::from_value::<Session>(legacy)
            .unwrap()
            .validate()
            .is_ok());
        session.read_only_sources = vec![ReadOnlyRecord {
            name: "reader".into(),
            path: b"/source.md".to_vec(),
            encoding: 1,
            position: 0,
        }];
        assert!(
            session.validate().is_err(),
            "V1 must not silently gain reader semantics"
        );
        session.version = 2;
        session.active = 1;
        session.validate().unwrap();
        assert!(matches!(
            session.ordered().as_slice(),
            [Tab::ReadOnly(_), Tab::Editor(_)]
        ));
        let mut invalid = session.clone();
        invalid
            .read_only_sources
            .push(invalid.read_only_sources[0].clone());
        assert!(invalid.validate().is_err(), "duplicate positions");
        for position in [2, usize::MAX] {
            invalid = session.clone();
            invalid.read_only_sources[0].position = position;
            assert!(invalid.validate().is_err());
        }
        for path in [
            b"relative".to_vec(),
            b"/a\0b".to_vec(),
            vec![],
            vec![b'/'; 4097],
        ] {
            invalid = session.clone();
            invalid.read_only_sources[0].path = path;
            assert!(invalid.validate().is_err());
        }
        invalid = session.clone();
        invalid.read_only_sources[0].encoding = 99;
        assert!(invalid.validate().is_err());
        let mut json = serde_json::to_value(&session).unwrap();
        json["read_only_sources"][0]["text"] = "must not carry a cached editable body".into();
        assert!(serde_json::from_value::<Session>(json).is_err());
        session.documents.clear();
        session.active = 0;
        session.validate().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let directory = Directory::open(dir.path()).unwrap();
        let lease = directory.create().unwrap();
        lease.write(&session).unwrap();
        assert!(
            directory.inactive().unwrap().is_empty(),
            "live lease excluded"
        );
        drop(lease);
        let archives = directory.inactive().unwrap();
        assert_eq!(
            archives.len(),
            1,
            "reader-only archive must not be discarded as empty"
        );
        assert_eq!(archives[0].session.tab_count(), 1);
        drop(archives);
        session.read_only_sources = (0..MAX_DOCS)
            .map(|position| ReadOnlyRecord {
                name: "reader".into(),
                path: b"/source".to_vec(),
                encoding: 0,
                position,
            })
            .collect();
        session.validate().unwrap();
        session.read_only_sources.push(ReadOnlyRecord {
            name: "overflow".into(),
            path: b"/extra".to_vec(),
            encoding: 0,
            position: MAX_DOCS,
        });
        assert!(session.validate().is_err());
    }
    #[test]
    fn optional_line_ending_intents_roundtrip_and_invalid_codes_are_rejected() {
        let mut old = sample();
        let legacy = serde_json::to_vec(&old).unwrap();
        assert!(!String::from_utf8(legacy.clone())
            .unwrap()
            .contains("pending_ending"));
        let restored: Session = serde_json::from_slice(&legacy).unwrap();
        assert!(restored.validate().is_ok());
        old.documents[0].saved_ending = Some(1);
        old.documents[0].pending_ending = Some(2);
        let bytes = serde_json::to_vec(&old).unwrap();
        let restored: Session = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(restored.documents[0].saved_ending, Some(1));
        assert_eq!(restored.documents[0].pending_ending, Some(2));
        assert!(restored.validate().is_ok());
        old.documents[0].pending_ending = Some(3);
        assert!(old.validate().is_err());
        old.documents[0].pending_ending = Some(0);
        old.documents[0].saved_ending = Some(255);
        assert!(old.validate().is_err());
        old.documents[0].saved_ending = Some(1);
        old.documents[0].dirty = false;
        assert!(old.validate().is_err());
    }
    #[test]
    fn private_atomic_roundtrip_and_live_lease() {
        let root = tempfile::tempdir().unwrap();
        let dir = Directory::open(root.path()).unwrap();
        let lease = dir.create().unwrap();
        lease.write(&sample()).unwrap();
        assert!(dir.inactive().unwrap().is_empty());
        let name = lease.name.clone();
        drop(lease);
        let archives = dir.inactive().unwrap();
        assert_eq!(archives.len(), 1);
        assert_eq!(archives[0].session.documents[0].text, "changed café\r\n");
        assert_eq!(
            fs::metadata(root.path().join("fastra").join(&name))
                .unwrap()
                .mode()
                & 0o777,
            0o600
        );
        archives[0].lease.remove().unwrap();
    }
    #[test]
    fn rejects_symlinks_hardlinks_permissions_and_unknown_schema() {
        let root = tempfile::tempdir().unwrap();
        let dir = Directory::open(root.path()).unwrap();
        let lease = dir.create().unwrap();
        let path = root.path().join("fastra").join(&lease.name);
        std::os::unix::fs::symlink("/etc/passwd", &path).unwrap();
        assert!(lease.write(&sample()).is_err());
        fs::remove_file(&path).unwrap();
        lease.write(&sample()).unwrap();
        let alias = root.path().join("alias");
        fs::hard_link(&path, &alias).unwrap();
        assert!(lease.write(&sample()).is_err());
        fs::remove_file(alias).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(lease.write(&sample()).is_err());
        let mut json = serde_json::to_value(sample()).unwrap();
        json["unknown"] = serde_json::Value::Bool(true);
        assert!(serde_json::from_value::<Session>(json).is_err());
    }
    #[test]
    fn bounded_and_malformed_records_never_replace_last_backup() {
        let root = tempfile::tempdir().unwrap();
        let dir = Directory::open(root.path()).unwrap();
        let lease = dir.create().unwrap();
        lease.write(&sample()).unwrap();
        let mut bad = sample();
        bad.documents[0].text = "x".repeat(MAX_DOC_BYTES + 1);
        assert!(lease.write(&bad).is_err());
        bad = sample();
        bad.documents[0].original_hex = "xx".into();
        assert!(lease.write(&bad).is_err());
        drop(lease);
        assert_eq!(
            dir.inactive().unwrap()[0].session.documents[0].text,
            "changed café\r\n"
        );
    }
    #[test]
    fn fifo_and_moved_private_root_are_rejected() {
        let root = tempfile::tempdir().unwrap();
        let dir = Directory::open(root.path()).unwrap();
        let lease = dir.create().unwrap();
        let path = root.path().join("fastra").join(&lease.name);
        let c = CString::new(path.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        assert!(lease.write(&sample()).is_err());
        fs::remove_file(&path).unwrap();
        lease.write(&sample()).unwrap();
        fs::rename(root.path().join("fastra"), root.path().join("moved")).unwrap();
        fs::create_dir(root.path().join("fastra")).unwrap();
        assert!(lease.write(&sample()).is_err());
        assert!(dir.inactive().is_err());
    }
}
