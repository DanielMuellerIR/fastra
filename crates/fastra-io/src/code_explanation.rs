//! Paketquellen werden ausschließlich relativ zum gehaltenen Wurzelordner geöffnet.
use fastra_core::{
    code_explanation::{self as model, Id, Manifest},
    Cancellation,
};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::CString,
    fs::{File, OpenOptions},
    io::Read,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
    path::Path,
    sync::Arc,
};

#[derive(Debug)]
pub enum Error {
    Invalid(&'static str),
    Changed,
    HashMismatch,
    TotalLimit,
    Limit,
    Io(std::io::Error),
    Json(serde_json::Error),
    Model(model::Error),
    Cancelled,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
impl From<std::io::Error> for Error {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}
impl From<model::Error> for Error {
    fn from(value: model::Error) -> Self {
        Self::Model(value)
    }
}
fn check(cancel: &Cancellation) -> Result<(), Error> {
    cancel.check().map_err(|_| Error::Cancelled)
}
#[derive(Clone, Debug)]
pub struct Source {
    pub path: String,
    pub sha256: String,
    pub text: Arc<str>,
}
#[derive(Clone, Debug)]
pub struct Package {
    pub manifest: Manifest,
    pub sources: BTreeMap<Id, Source>,
}
fn identity(info: &std::fs::Metadata) -> (u64, u64, u64, i64, i64, i64, i64) {
    (
        info.dev(),
        info.ino(),
        info.size(),
        info.mtime(),
        info.mtime_nsec(),
        info.ctime(),
        info.ctime_nsec(),
    )
}
fn bounded_read(mut file: File, limit: usize, cancel: &Cancellation) -> Result<Vec<u8>, Error> {
    check(cancel)?;
    crate::check_runtime_file(&file)?;
    let before = file.metadata()?;
    if !before.is_file() {
        return Err(Error::Invalid("non-regular file"));
    }
    if before.len() > limit as u64 {
        return Err(Error::Limit);
    }
    let mut bytes = Vec::with_capacity((before.len() as usize).min(limit));
    let mut buffer = [0u8; 16384];
    loop {
        check(cancel)?;
        let capacity = buffer.len().min(limit + 1 - bytes.len());
        let read = file.read(&mut buffer[..capacity])?;
        if read == 0 {
            break;
        }
        bytes.extend_from_slice(&buffer[..read]);
        if bytes.len() > limit {
            return Err(Error::Limit);
        }
    }
    if identity(&before) != identity(&file.metadata()?) {
        return Err(Error::Changed);
    }
    Ok(bytes)
}
fn relative_file(root: &File, path: &str, cancel: &Cancellation) -> Result<File, Error> {
    crate::check_runtime_path(&std::path::PathBuf::from(format!("/proc/self/fd/{}", root.as_raw_fd())).join(path))?;
    if !model::valid_relative_path(path) {
        return Err(Error::Invalid("source path"));
    }
    let mut directory = root.try_clone()?;
    let parts: Vec<_> = path.split('/').collect();
    for (index, part) in parts.iter().enumerate() {
        check(cancel)?;
        let part = CString::new(*part).map_err(|_| Error::Invalid("source path"))?;
        let final_part = index + 1 == parts.len();
        let flags = libc::O_RDONLY
            | libc::O_CLOEXEC
            | libc::O_NOFOLLOW
            | if final_part {
                libc::O_NONBLOCK
            } else {
                libc::O_DIRECTORY
            };
        let fd = unsafe { libc::openat(directory.as_raw_fd(), part.as_ptr(), flags) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        crate::check_runtime_file(&file)?;
        if final_part {
            return Ok(file);
        }
        directory = file;
    }
    Err(Error::Invalid("empty source path"))
}
impl Package {
    pub fn load(path: &Path, cancel: &Cancellation) -> Result<Self, Error> {
        Self::load_detailed(path, cancel).map_err(|error| match error {
            Error::HashMismatch => Error::Changed,
            Error::TotalLimit => Error::Limit,
            other => other,
        })
    }
    /// Der Steuerungsvertrag unterscheidet Inhaltsbindung und Gesamtbudget; alte Aufrufer bleiben unverändert.
    pub fn load_detailed(path: &Path, cancel: &Cancellation) -> Result<Self, Error> {
        check(cancel)?;
        crate::check_runtime_path(path)?;
        if !path.is_absolute() || path.as_os_str().as_bytes().contains(&0) {
            return Err(Error::Invalid("manifest path"));
        }
        let parent = path.parent().ok_or(Error::Invalid("manifest parent"))?;
        let name = path
            .file_name()
            .and_then(|p| p.to_str())
            .ok_or(Error::Invalid("manifest name"))?;
        let root = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(parent)?;
        crate::check_runtime_file(&root)?;
        let raw = bounded_read(
            relative_file(&root, name, cancel)?,
            model::MAX_MANIFEST_BYTES,
            cancel,
        )?;
        let manifest: Manifest = serde_json::from_slice(&raw).map_err(Error::Json)?;
        manifest.validate(cancel)?;
        let mut total = 0usize;
        let mut sources = BTreeMap::new();
        for source in &manifest.sources {
            let bytes = bounded_read(
                relative_file(&root, &source.path, cancel)?,
                model::MAX_SOURCE_BYTES,
                cancel,
            )?;
            total = total.checked_add(bytes.len()).ok_or(Error::TotalLimit)?;
            if total > model::MAX_TOTAL_BYTES {
                return Err(Error::TotalLimit);
            }
            let digest = format!("{:x}", Sha256::digest(&bytes));
            if digest != source.sha256 {
                return Err(Error::HashMismatch);
            }
            let text = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes);
            let text = std::str::from_utf8(text).map_err(|_| Error::Invalid("source UTF-8"))?;
            if text.contains('\0') {
                return Err(Error::Invalid("source NUL"));
            }
            sources.insert(
                source.id.clone(),
                Source {
                    path: source.path.clone(),
                    sha256: digest,
                    text: Arc::from(text),
                },
            );
        }
        for step in &manifest.steps {
            model::validate_range(
                &sources[&step.source_id].text,
                step.location,
                step.length,
                cancel,
            )?;
        }
        check(cancel)?;
        Ok(Self { manifest, sources })
    }
}
