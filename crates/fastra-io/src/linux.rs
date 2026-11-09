use fastra_core::{Cancellation, Preview};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    ffi::{CString, OsStr, OsString},
    fs::File,
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::{OsStrExt, OsStringExt},
            fs::MetadataExt,
        },
    },
    path::{Component, Path, PathBuf},
    sync::Arc,
};

const MAX_BYTES: usize = 32 * 1024 * 1024;
const MAX_MANIFEST: usize = 16 * 1024 * 1024;
const MAX_FILES: usize = 10_000;
const MAX_TRANSACTION_BYTES: usize = 256 * 1024 * 1024;

#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    Core(fastra_core::Error),
    Stale,
    InvalidPath,
    UnsupportedFilesystem,
    UnsupportedMetadata,
    UnsupportedEncoding,
    Encoding(fastra_core::encoding::EncodingError),
    InvalidJournal,
    Limit,
    RecoveryRequired(PathBuf),
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<fastra_core::Error> for Error {
    fn from(e: fastra_core::Error) -> Self {
        Self::Core(e)
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
type Result<T> = std::result::Result<T, Error>;

fn name(value: &OsStr) -> Result<CString> {
    let bytes = value.as_bytes();
    if bytes.is_empty() || bytes == b"." || bytes == b".." || bytes.contains(&b'/') {
        return Err(Error::InvalidPath);
    }
    CString::new(bytes).map_err(|_| Error::InvalidPath)
}
fn owned_file(fd: i32) -> Result<File> {
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn syscall(result: i32) -> Result<()> {
    if result < 0 {
        Err(std::io::Error::last_os_error().into())
    } else {
        Ok(())
    }
}

fn random_name(prefix: &str) -> Result<OsString> {
    let mut random = [0u8; 16];
    let mut offset = 0;
    while offset < random.len() {
        let count = unsafe {
            libc::getrandom(
                random[offset..].as_mut_ptr().cast(),
                random.len() - offset,
                0,
            )
        };
        if count < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error.into());
        }
        if count == 0 {
            return Err(std::io::Error::from(std::io::ErrorKind::UnexpectedEof).into());
        }
        offset += count as usize;
    }
    let value: String = random.iter().map(|b| format!("{b:02x}")).collect();
    Ok(format!("{prefix}{value}").into())
}

#[derive(Debug)]
struct Directory {
    file: File,
    path: PathBuf,
    identity: [u64; 2],
}
impl Directory {
    fn open(path: &Path) -> Result<Self> {
        Self::open_with_flags(path, libc::O_RDONLY, None)
    }
    fn open_for_read(path: &Path, cancel: &Cancellation) -> Result<Self> {
        // Ein bekannter Dateiname braucht Such-, aber keine Leserechte am Verzeichnis.
        Self::open_with_flags(path, libc::O_PATH, Some(cancel))
    }
    fn open_with_flags(path: &Path, flags: i32, cancel: Option<&Cancellation>) -> Result<Self> {
        crate::check_runtime_path(path)?;
        if !path.is_absolute() {
            return Err(Error::InvalidPath);
        }
        let mut file = if flags == libc::O_PATH {
            owned_file(unsafe {
                libc::open(c"/".as_ptr(), libc::O_PATH | libc::O_DIRECTORY | libc::O_CLOEXEC)
            })?
        } else {
            File::open("/")?
        };
        for component in path.components() {
            if let Some(cancel) = cancel {
                cancel.check()?;
            }
            match component {
                Component::RootDir => {}
                Component::Normal(value) => {
                    let value = name(value)?;
                    file = owned_file(unsafe {
                        libc::openat(
                            file.as_raw_fd(),
                            value.as_ptr(),
                            flags | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                        )
                    })?;
                }
                _ => return Err(Error::InvalidPath),
            }
        }
        crate::check_runtime_file(&file)?;
        let meta = file.metadata()?;
        Ok(Self {
            file,
            path: path.to_owned(),
            identity: [meta.dev(), meta.ino()],
        })
    }
    fn bound(&self) -> Result<()> {
        if Self::open(&self.path)?.identity != self.identity {
            return Err(Error::Stale);
        }
        Ok(())
    }
    fn regular(&self, value: &OsStr) -> Result<File> {
        crate::check_runtime_path(&self.path.join(value))?;
        let value = name(value)?;
        let file = owned_file(unsafe {
            libc::openat(
                self.file.as_raw_fd(),
                value.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        })?;
        crate::check_runtime_file(&file)?;
        Ok(file)
    }
    fn create(&self, value: &OsStr, mode: u32) -> Result<File> {
        crate::check_runtime_path(&self.path.join(value))?;
        let value = name(value)?;
        owned_file(unsafe {
            libc::openat(
                self.file.as_raw_fd(),
                value.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                mode,
            )
        })
    }
    fn remove(&self, value: &OsStr, directory: bool) -> Result<()> {
        crate::check_runtime_path(&self.path.join(value))?;
        let value = name(value)?;
        syscall(unsafe {
            libc::unlinkat(
                self.file.as_raw_fd(),
                value.as_ptr(),
                if directory { libc::AT_REMOVEDIR } else { 0 },
            )
        })
    }
    fn sync(&self) -> Result<()> {
        self.file.sync_all().map_err(Into::into)
    }
    fn supported(&self) -> Result<()> {
        let mut info: libc::statfs = unsafe { std::mem::zeroed() };
        syscall(unsafe { libc::fstatfs(self.file.as_raw_fd(), &mut info) })?;
        if info.f_type != libc::BTRFS_SUPER_MAGIC && info.f_type != libc::EXT4_SUPER_MAGIC {
            return Err(Error::UnsupportedFilesystem);
        }
        Ok(())
    }
}

mod read;
pub use read::ReadSnapshot;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fingerprint {
    device: u64,
    inode: u64,
    size: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    modified: [i64; 2],
    digest: [u8; 32],
    #[serde(with = "attribute_list")]
    xattrs: BTreeMap<Vec<u8>, Vec<u8>>,
}

mod attribute_list {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        value: &BTreeMap<Vec<u8>, Vec<u8>>,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        value.iter().collect::<Vec<_>>().serialize(serializer)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<BTreeMap<Vec<u8>, Vec<u8>>, D::Error> {
        let values = Vec::<(Vec<u8>, Vec<u8>)>::deserialize(deserializer)?;
        let count = values.len();
        let result: BTreeMap<_, _> = values.into_iter().collect();
        if result.len() != count {
            return Err(serde::de::Error::custom("duplicate xattr"));
        }
        Ok(result)
    }
}

fn attributes(file: &File) -> Result<BTreeMap<Vec<u8>, Vec<u8>>> {
    let fd = file.as_raw_fd();
    let size = unsafe { libc::flistxattr(fd, std::ptr::null_mut(), 0) };
    if size < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if size > 1024 * 1024 {
        return Err(Error::Limit);
    }
    let mut names = vec![0u8; size as usize];
    let count = unsafe { libc::flistxattr(fd, names.as_mut_ptr().cast(), names.len()) };
    if count < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if count as usize > names.len() {
        return Err(Error::Stale);
    }
    let mut result = BTreeMap::new();
    let mut total = 0usize;
    for entry in names[..count as usize]
        .split(|b| *b == 0)
        .filter(|n| !n.is_empty())
    {
        let key = CString::new(entry).map_err(|_| Error::UnsupportedMetadata)?;
        let size = unsafe { libc::fgetxattr(fd, key.as_ptr(), std::ptr::null_mut(), 0) };
        if size < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        total = total.checked_add(size as usize).ok_or(Error::Limit)?;
        if total > 1024 * 1024 {
            return Err(Error::Limit);
        }
        let mut value = vec![0u8; size as usize];
        let count =
            unsafe { libc::fgetxattr(fd, key.as_ptr(), value.as_mut_ptr().cast(), value.len()) };
        if count < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        if count as usize > value.len() {
            return Err(Error::Stale);
        }
        value.truncate(count as usize);
        result.insert(entry.to_vec(), value);
    }
    Ok(result)
}

fn read_file(
    mut file: File,
    cancel: &Cancellation,
    limit: usize,
) -> Result<(Vec<u8>, Fingerprint)> {
    let before = file.metadata()?;
    if !before.is_file() || before.nlink() != 1 {
        return Err(Error::UnsupportedMetadata);
    }
    if before.len() > limit as u64 {
        return Err(Error::Limit);
    }
    let xattrs = attributes(&file)?;
    let mut bytes = Vec::with_capacity(before.len() as usize);
    let mut block = [0u8; 65536];
    loop {
        cancel.check()?;
        let count = file.read(&mut block)?;
        if count == 0 {
            break;
        }
        if bytes.len() + count > limit {
            return Err(Error::Limit);
        }
        bytes.extend_from_slice(&block[..count]);
    }
    let after = file.metadata()?;
    if before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
        || before.mode() != after.mode()
        || before.uid() != after.uid()
        || before.gid() != after.gid()
        || after.nlink() != 1
        || attributes(&file)? != xattrs
    {
        return Err(Error::Stale);
    }
    let fingerprint = Fingerprint {
        device: after.dev(),
        inode: after.ino(),
        size: after.len(),
        mode: after.mode() & 0o7777,
        uid: after.uid(),
        gid: after.gid(),
        modified: [after.mtime(), after.mtime_nsec()],
        digest: Sha256::digest(&bytes).into(),
        xattrs,
    };
    Ok((bytes, fingerprint))
}

fn fingerprint(dir: &Directory, value: &OsStr, cancel: &Cancellation) -> Result<Fingerprint> {
    read_file(dir.regular(value)?, cancel, MAX_BYTES).map(|(_, fingerprint)| fingerprint)
}

#[derive(Debug, Clone)]
pub struct Snapshot {
    parent: Arc<Directory>,
    name: OsString,
    bytes: Arc<Vec<u8>>,
    fingerprint: Fingerprint,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct FileIdentity {
    pub device: u64,
    pub inode: u64,
}

impl Snapshot {
    pub fn read(path: &Path, cancel: &Cancellation) -> Result<Self> {
        Self::read_bounded(path, MAX_BYTES, cancel)
    }

    pub fn read_bounded(path: &Path, max_bytes: usize, cancel: &Cancellation) -> Result<Self> {
        if max_bytes > MAX_BYTES {
            return Err(Error::Limit);
        }
        let parent = Arc::new(Directory::open(path.parent().ok_or(Error::InvalidPath)?)?);
        let name = path.file_name().ok_or(Error::InvalidPath)?.to_owned();
        let (bytes, fingerprint) = read_file(parent.regular(&name)?, cancel, max_bytes)?;
        Ok(Self {
            parent,
            name,
            bytes: Arc::new(bytes),
            fingerprint,
        })
    }
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
    pub fn path(&self) -> PathBuf {
        self.parent.path.join(&self.name)
    }
    pub fn file_identity(&self) -> FileIdentity {
        FileIdentity {
            device: self.fingerprint.device,
            inode: self.fingerprint.inode,
        }
    }
    /// Bindet gespeicherte Basisdaten; liest die Datei nicht erneut und gibt keine Metadaten preis.
    pub fn binding_digest(&self) -> Result<[u8; 32]> {
        let record = (
            self.parent.identity,
            self.parent.path.as_os_str().as_bytes(),
            self.name.as_bytes(),
            &self.fingerprint,
        );
        let bytes = serde_json::to_vec(&record).map_err(|_| Error::UnsupportedMetadata)?;
        let mut digest = Sha256::new();
        digest.update(b"Fastra-Snapshot-Binding-v1\0");
        digest.update(bytes);
        Ok(digest.finalize().into())
    }
    fn verify(&self, cancel: &Cancellation) -> Result<()> {
        self.parent.bound()?;
        if fingerprint(&self.parent, &self.name, cancel)? != self.fingerprint {
            return Err(Error::Stale);
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct Change {
    snapshot: Snapshot,
    replacement: Vec<u8>,
}
impl Change {
    pub fn from_preview(
        snapshot: Snapshot,
        preview: &Preview,
        revision: u64,
        generation: u64,
        approved: &[usize],
        cancel: &Cancellation,
    ) -> Result<Self> {
        let decoded =
            fastra_core::encoding::decode(snapshot.bytes(), None).map_err(Error::Encoding)?;
        let text = preview.apply(decoded.text(), revision, generation, approved, cancel)?;
        let replacement = decoded.encode(&text).map_err(Error::Encoding)?;
        if replacement.len() > MAX_BYTES {
            return Err(Error::Limit);
        }
        Ok(Self {
            snapshot,
            replacement,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Phase {
    Prepared,
    Applying,
    Applied,
    Undoing,
    Undone,
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    parent_path: Vec<u8>,
    parent_identity: [u64; 2],
    name: Vec<u8>,
    original: Fingerprint,
    replacement: Option<Fingerprint>,
    original_copy: Option<Fingerprint>,
}
#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: u32,
    parent: [u64; 2],
    phase: Phase,
    purpose: Purpose,
    entries: Vec<Entry>,
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
enum Purpose {
    Replace,
    SaveDocument,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileState {
    Original,
    Replaced,
    Conflict,
}

#[derive(Debug)]
pub struct RecoveryFile {
    path: PathBuf,
    state: FileState,
    current: Arc<Vec<u8>>,
    original: Arc<Vec<u8>>,
}
impl RecoveryFile {
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn state(&self) -> FileState {
        self.state
    }
    pub fn current_bytes(&self) -> &[u8] {
        &self.current
    }
    pub fn original_bytes(&self) -> &[u8] {
        &self.original
    }
}
#[derive(Debug)]
pub struct RecoveryPreview {
    journal: [u64; 2],
    phase: Phase,
    intent: Fingerprint,
    targets: Vec<Fingerprint>,
    files: Vec<RecoveryFile>,
}
impl RecoveryPreview {
    pub fn files(&self) -> &[RecoveryFile] {
        &self.files
    }
    pub fn phase(&self) -> Phase {
        self.phase
    }
}

#[derive(Debug)]
pub struct Transaction {
    parent: Arc<Directory>,
    parents: Vec<Arc<Directory>>,
    journal: Directory,
    manifest: Manifest,
    keep: bool,
    own_files: Vec<OsString>,
}
impl Drop for Transaction {
    fn drop(&mut self) {
        // Nur selbst angelegte, bekannte Namen entfernen; fremde Zusätze verhindern rmdir.
        if !self.keep {
            for name in &self.own_files {
                let _ = self.journal.remove(name, false);
            }
            if let Some(name) = self.journal.path.file_name() {
                let _ = self.parent.remove(name, true);
            }
            let _ = self.parent.sync();
        }
    }
}

fn stage_name(index: usize) -> OsString {
    format!("replacement-{index}").into()
}
fn copy_name(index: usize) -> OsString {
    format!("original-copy-{index}").into()
}

impl Transaction {
    pub fn path(&self) -> &Path {
        &self.journal.path
    }
    pub fn phase(&self) -> Phase {
        self.manifest.phase
    }

    fn new(parent: Arc<Directory>) -> Result<Self> {
        let basename = random_name(".fastra-transaction-")?;
        let c_name = name(&basename)?;
        syscall(unsafe { libc::mkdirat(parent.file.as_raw_fd(), c_name.as_ptr(), 0o700) })?;
        let file = owned_file(unsafe {
            libc::openat(
                parent.file.as_raw_fd(),
                c_name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        })?;
        let meta = file.metadata()?;
        if meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o777 != 0o700 {
            return Err(Error::InvalidJournal);
        }
        let journal = Directory {
            file,
            path: parent.path.join(&basename),
            identity: [meta.dev(), meta.ino()],
        };
        let manifest = Manifest {
            version: 1,
            parent: parent.identity,
            phase: Phase::Prepared,
            purpose: Purpose::Replace,
            entries: Vec::new(),
        };
        Ok(Self {
            parent,
            journal,
            manifest,
            keep: false,
            parents: Vec::new(),
            own_files: Vec::new(),
        })
    }

    fn write_manifest(&mut self, observe: &mut impl FnMut(&str, usize, &Self)) -> Result<()> {
        struct BoundedManifest(Vec<u8>);
        impl Write for BoundedManifest {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                if self
                    .0
                    .len()
                    .checked_add(bytes.len())
                    .is_none_or(|n| n > MAX_MANIFEST)
                {
                    return Err(std::io::Error::other("manifest limit"));
                }
                self.0.extend_from_slice(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let mut serialized = BoundedManifest(Vec::new());
        serde_json::to_writer(&mut serialized, &self.manifest).map_err(|_| Error::Limit)?;
        let bytes = serialized.0;
        let temporary = OsStr::new("intent.next");
        // Nach einem Abbruch kann die reservierte temporäre Journaldatei
        // übrig sein. Nur eine reguläre, eigene Einzeldatei darf ersetzt werden.
        match self.journal.regular(temporary) {
            Ok(file) => {
                let meta = file.metadata()?;
                if !meta.is_file()
                    || meta.nlink() != 1
                    || meta.uid() != unsafe { libc::geteuid() }
                    || meta.mode() & 0o077 != 0
                    || meta.len() > MAX_MANIFEST as u64
                {
                    return Err(Error::InvalidJournal);
                }
                self.journal.remove(temporary, false)?;
            }
            Err(Error::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let mut file = self.journal.create(temporary, 0o600)?;
        self.own_files.push(temporary.to_owned());
        file.write_all(&bytes)?;
        file.sync_all()?;
        observe("intent-written", self.manifest.phase as usize, self);
        let old = name(temporary)?;
        let new = name(OsStr::new("intent.json"))?;
        syscall(unsafe {
            libc::renameat(
                self.journal.file.as_raw_fd(),
                old.as_ptr(),
                self.journal.file.as_raw_fd(),
                new.as_ptr(),
            )
        })?;
        self.own_files.retain(|n| n != temporary);
        if !self.own_files.iter().any(|n| n == "intent.json") {
            self.own_files.push("intent.json".into());
        }
        self.journal.sync()?;
        self.parent.sync()
    }

    fn stage(
        &mut self,
        index: usize,
        bytes: &[u8],
        original: Option<&Fingerprint>,
        cancel: &Cancellation,
    ) -> Result<Fingerprint> {
        cancel.check()?;
        let basename = if original.is_some() {
            stage_name(index)
        } else {
            copy_name(index)
        };
        let mut file = self.journal.create(&basename, 0o600)?;
        self.own_files.push(basename.clone());
        file.write_all(bytes)?;
        if let Some(original) = original {
            if original.uid != unsafe { libc::geteuid() } || original.mode & 0o7000 != 0 {
                return Err(Error::UnsupportedMetadata);
            }
            syscall(unsafe { libc::fchown(file.as_raw_fd(), original.uid, original.gid) })?;
            syscall(unsafe { libc::fchmod(file.as_raw_fd(), original.mode) })?;
            let existing = attributes(&file)?;
            for (key, value) in &original.xattrs {
                if existing.get(key) == Some(value) {
                    continue;
                }
                let key = CString::new(key.as_slice()).map_err(|_| Error::UnsupportedMetadata)?;
                syscall(unsafe {
                    libc::fsetxattr(
                        file.as_raw_fd(),
                        key.as_ptr(),
                        value.as_ptr().cast(),
                        value.len(),
                        0,
                    )
                })?;
            }
            if attributes(&file)? != original.xattrs {
                return Err(Error::UnsupportedMetadata);
            }
        }
        file.sync_all()?;
        let result = fingerprint(&self.journal, &basename, cancel)?;
        if let Some(original) = original {
            if result.mode != original.mode
                || result.uid != original.uid
                || result.gid != original.gid
            {
                return Err(Error::UnsupportedMetadata);
            }
        }
        Ok(result)
    }

    pub fn apply(changes: Vec<Change>, cancel: &Cancellation) -> Result<Option<Self>> {
        Self::apply_inner(changes, Purpose::Replace, cancel, &mut |_, _, _| {})
    }

    pub fn save_document(
        snapshot: Snapshot,
        edited_bytes: &[u8],
        cancel: &Cancellation,
    ) -> Result<Option<Self>> {
        if edited_bytes.len() > MAX_BYTES {
            return Err(Error::Limit);
        }
        Self::apply_inner(
            vec![Change {
                snapshot,
                replacement: edited_bytes.to_owned(),
            }],
            Purpose::SaveDocument,
            cancel,
            &mut |_, _, _| {},
        )
    }

    /// Neues Dokument ausschließlich an einem noch freien Namen veröffentlichen.
    pub fn save_new_document(
        path: &Path,
        edited_bytes: &[u8],
        cancel: &Cancellation,
    ) -> Result<Snapshot> {
        cancel.check()?;
        if edited_bytes.len() > MAX_BYTES {
            return Err(Error::Limit);
        }
        let parent = Arc::new(Directory::open(path.parent().ok_or(Error::InvalidPath)?)?);
        parent.supported()?;
        let target_name = path.file_name().ok_or(Error::InvalidPath)?.to_owned();
        Self::save_new_document_bound(parent, target_name, edited_bytes, cancel)
    }

    fn save_new_document_bound(
        parent: Arc<Directory>,
        target_name: OsString,
        edited_bytes: &[u8],
        cancel: &Cancellation,
    ) -> Result<Snapshot> {
        cancel.check()?;
        let path = parent.path.join(&target_name);
        crate::check_runtime_path(&path)?;
        parent.supported()?;
        if edited_bytes.len() > MAX_BYTES { return Err(Error::Limit); }
        let target = name(&target_name)?;
        let temporary = random_name(".fastra-new-")?;
        let mut file = parent.create(&temporary, 0o666)?;
        struct Pending {
            parent: Arc<Directory>,
            name: OsString,
            armed: bool,
            file: File,
        }
        impl Drop for Pending {
            fn drop(&mut self) {
                if self.armed {
                    let _ = markdown_assets::remove_temporary(&self.parent,&self.name,&self.file);
                }
            }
        }
        let mut pending = Pending {
            parent: parent.clone(),
            name: temporary.clone(),
            armed: true,
            file:file.try_clone()?,
        };
        for chunk in edited_bytes.chunks(65536) {
            cancel.check()?;
            file.write_all(chunk)?;
        }
        file.sync_all()?;
        save_target::checkpoint("before-new-hash",&parent.path.join(&temporary));
        use std::io::{Seek, SeekFrom};
        file.seek(SeekFrom::Start(0))?;
        let (actual_bytes, expected) = read_file(file.try_clone()?, cancel, MAX_BYTES)?;
        if actual_bytes != edited_bytes || fingerprint(&parent, &temporary, cancel)? != expected {
            return Err(Error::Stale);
        }
        save_target::checkpoint("before-new-publish",&path);
        crate::check_runtime_path(&path)?;
        parent.bound()?;
        cancel.check()?;
        let temporary = name(&temporary)?;
        syscall(unsafe {
            libc::renameat2(
                parent.file.as_raw_fd(),
                temporary.as_ptr(),
                parent.file.as_raw_fd(),
                target.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        })?;
        pending.armed = false;
        // Nach dem atomaren Veröffentlichen ist Abbruch kein Zurücklöschen:
        // Ein fremder Prozess könnte die neue Datei bereits geöffnet haben.
        let postflight = parent
            .sync()
            .and_then(|_| parent.bound())
            .and_then(|_| fingerprint(&parent, &target_name, &Cancellation::default()));
        match postflight {
            Ok(actual) if actual == expected => Ok(Snapshot {
                parent,
                name: target_name,
                bytes: Arc::new(edited_bytes.to_owned()),
                fingerprint: actual,
            }),
            _ => Err(Error::RecoveryRequired(path.to_owned())),
        }
    }

    // Die private Beobachtung erlaubt echte Prozessabbrüche genau an Schreibgrenzen.
    #[cfg(test)]
    fn apply_observing(
        changes: Vec<Change>,
        cancel: &Cancellation,
        observe: &mut impl FnMut(&str, usize, &Self),
    ) -> Result<Option<Self>> {
        Self::apply_inner(changes, Purpose::Replace, cancel, observe)
    }

    fn apply_inner(
        changes: Vec<Change>,
        purpose: Purpose,
        cancel: &Cancellation,
        observe: &mut impl FnMut(&str, usize, &Self),
    ) -> Result<Option<Self>> {
        cancel.check()?;
        if changes.is_empty() {
            return Ok(None);
        }
        if changes.len() > MAX_FILES {
            return Err(Error::Limit);
        }
        let parent = changes[0].snapshot.parent.clone();
        parent.supported()?;
        let mut names = HashSet::new();
        let mut total_bytes = 0usize;
        for change in &changes {
            total_bytes = total_bytes
                .checked_add(change.snapshot.bytes.len())
                .and_then(|n| n.checked_add(change.replacement.len()))
                .ok_or(Error::Limit)?;
            if total_bytes > MAX_TRANSACTION_BYTES {
                return Err(Error::Limit);
            }
            change.snapshot.parent.supported()?;
            if change.snapshot.parent.identity[0] != parent.identity[0]
                || change.snapshot.fingerprint.device != parent.identity[0]
            {
                return Err(Error::UnsupportedFilesystem);
            }
            if !names.insert((
                change.snapshot.parent.identity,
                change.snapshot.name.clone(),
            )) {
                return Err(Error::InvalidPath);
            }
            change.snapshot.verify(cancel)?;
        }
        if changes
            .iter()
            .all(|c| c.snapshot.bytes.as_slice() == c.replacement.as_slice())
        {
            return Ok(None);
        }
        let mut transaction = Self::new(parent)?;
        transaction.manifest.purpose = purpose;
        for (index, change) in changes.iter().enumerate() {
            let original = &change.snapshot.fingerprint;
            let changed = change.snapshot.bytes.as_slice() != change.replacement.as_slice();
            let (replacement, original_copy) = if changed {
                (
                    Some(transaction.stage(index, &change.replacement, Some(original), cancel)?),
                    Some(transaction.stage(index, &change.snapshot.bytes, None, cancel)?),
                )
            } else {
                (None, None)
            };
            transaction.manifest.entries.push(Entry {
                parent_path: change.snapshot.parent.path.as_os_str().as_bytes().to_vec(),
                parent_identity: change.snapshot.parent.identity,
                name: change.snapshot.name.as_bytes().to_vec(),
                original: original.clone(),
                replacement,
                original_copy,
            });
            transaction.parents.push(change.snapshot.parent.clone());
        }
        transaction.write_manifest(observe)?;
        observe("prepared", 0, &transaction);
        // Auch wirkungslose Eingaben bleiben bis zum letzten Preflight gebunden.
        for change in &changes {
            change.snapshot.verify(cancel)?;
        }
        cancel.check()?;
        transaction.manifest.phase = Phase::Applying;
        transaction.write_manifest(observe)?;
        transaction.keep = true;
        for index in 0..changes.len() {
            if transaction.manifest.entries[index].replacement.is_none() {
                continue;
            }
            if cancel.check().is_err() {
                if transaction.undo(&Cancellation::default()).is_ok() {
                    return Err(fastra_core::Error::Cancelled.into());
                }
                return Err(Error::RecoveryRequired(transaction.path().to_owned()));
            }
            let result = transaction
                .exchange(index)
                .and_then(|_| transaction.state(index, &Cancellation::default()));
            if !matches!(result, Ok(FileState::Replaced)) {
                return Err(Error::RecoveryRequired(transaction.path().to_owned()));
            }
            observe("exchanged", index, &transaction);
        }
        let states = transaction.inspect(&Cancellation::default());
        if !states.as_ref().is_ok_and(|states| {
            states
                .iter()
                .zip(&transaction.manifest.entries)
                .all(|(state, entry)| {
                    *state
                        == if entry.replacement.is_some() {
                            FileState::Replaced
                        } else {
                            FileState::Original
                        }
                })
        }) {
            return Err(Error::RecoveryRequired(transaction.path().to_owned()));
        }
        transaction.manifest.phase = Phase::Applied;
        if transaction.write_manifest(observe).is_err() {
            return Err(Error::RecoveryRequired(transaction.path().to_owned()));
        }
        observe("applied", 0, &transaction);
        Ok(Some(transaction))
    }

    fn exchange(&self, index: usize) -> Result<()> {
        self.parent.bound()?;
        self.parents[index].bound()?;
        self.journal.bound()?;
        let target = name(OsStr::from_bytes(&self.manifest.entries[index].name))?;
        let prepared = name(&stage_name(index))?;
        syscall(unsafe {
            libc::renameat2(
                self.parents[index].file.as_raw_fd(),
                target.as_ptr(),
                self.journal.file.as_raw_fd(),
                prepared.as_ptr(),
                libc::RENAME_EXCHANGE,
            )
        })?;
        self.journal.sync()?;
        self.parents[index].sync()
    }

    fn state(&self, index: usize, cancel: &Cancellation) -> Result<FileState> {
        let entry = &self.manifest.entries[index];
        let target = fingerprint(&self.parents[index], OsStr::from_bytes(&entry.name), cancel)?;
        let Some(replacement) = &entry.replacement else {
            return Ok(if target == entry.original {
                FileState::Original
            } else {
                FileState::Conflict
            });
        };
        if fingerprint(&self.journal, &copy_name(index), cancel)?
            != *entry.original_copy.as_ref().ok_or(Error::InvalidJournal)?
        {
            return Ok(FileState::Conflict);
        }
        let prepared = fingerprint(&self.journal, &stage_name(index), cancel)?;
        if target == entry.original && prepared == *replacement {
            Ok(FileState::Original)
        } else if target == *replacement && prepared == entry.original {
            Ok(FileState::Replaced)
        } else {
            Ok(FileState::Conflict)
        }
    }

    pub fn inspect(&self, cancel: &Cancellation) -> Result<Vec<FileState>> {
        self.parent.bound()?;
        self.journal.bound()?;
        for parent in &self.parents {
            parent.bound()?;
        }
        (0..self.manifest.entries.len())
            .map(|i| self.state(i, cancel))
            .collect()
    }

    pub fn undo(&mut self, cancel: &Cancellation) -> Result<()> {
        self.undo_observing(cancel, &mut |_, _, _| {})
    }

    fn undo_observing(
        &mut self,
        cancel: &Cancellation,
        observe: &mut impl FnMut(&str, usize, &Self),
    ) -> Result<()> {
        cancel.check()?;
        let states = self.inspect(cancel)?;
        if states.contains(&FileState::Conflict) {
            return Err(Error::RecoveryRequired(self.path().to_owned()));
        }
        self.manifest.phase = Phase::Undoing;
        self.write_manifest(observe)?;
        for index in (0..states.len()).rev() {
            if states[index] != FileState::Replaced {
                continue;
            }
            if cancel.check().is_err() || self.state(index, cancel)? != FileState::Replaced {
                return Err(Error::RecoveryRequired(self.path().to_owned()));
            }
            if self.exchange(index).is_err()
                || self.state(index, &Cancellation::default())? != FileState::Original
            {
                return Err(Error::RecoveryRequired(self.path().to_owned()));
            }
            observe("undo-exchanged", index, self);
        }
        if !matches!(self.inspect(&Cancellation::default()), Ok(states) if states.iter().all(|state| *state==FileState::Original))
        {
            return Err(Error::RecoveryRequired(self.path().to_owned()));
        }
        self.manifest.phase = Phase::Undone;
        self.write_manifest(observe)
    }

    pub fn reopen(path: &Path) -> Result<Self> {
        let basename = path.file_name().ok_or(Error::InvalidPath)?;
        let prefix = b".fastra-transaction-";
        let bytes = basename.as_bytes();
        if !bytes.starts_with(prefix)
            || bytes.len() != prefix.len() + 32
            || !bytes[prefix.len()..].iter().all(u8::is_ascii_hexdigit)
        {
            return Err(Error::InvalidJournal);
        }
        let parent = Arc::new(Directory::open(path.parent().ok_or(Error::InvalidPath)?)?);
        parent.supported()?;
        let journal = Directory::open(path)?;
        let meta = journal.file.metadata()?;
        if meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o777 != 0o700 {
            return Err(Error::InvalidJournal);
        }
        let mut raw = Vec::new();
        let mut file = journal.regular(OsStr::new("intent.json"))?;
        let meta = file.metadata()?;
        if !meta.is_file() || meta.nlink() != 1 || meta.uid() != unsafe { libc::geteuid() } {
            return Err(Error::InvalidJournal);
        }
        Read::by_ref(&mut file)
            .take(MAX_MANIFEST as u64 + 1)
            .read_to_end(&mut raw)?;
        if raw.len() > MAX_MANIFEST {
            return Err(Error::Limit);
        }
        let manifest: Manifest = serde_json::from_slice(&raw).map_err(|_| Error::InvalidJournal)?;
        if manifest.version != 1
            || manifest.parent != parent.identity
            || manifest.entries.is_empty()
            || manifest.entries.len() > MAX_FILES
        {
            return Err(Error::InvalidJournal);
        }
        let mut total_bytes = 0u64;
        for entry in &manifest.entries {
            total_bytes = total_bytes
                .checked_add(entry.original.size)
                .and_then(|n| {
                    n.checked_add(
                        entry
                            .replacement
                            .as_ref()
                            .map_or(entry.original.size, |r| r.size),
                    )
                })
                .ok_or(Error::InvalidJournal)?;
            if entry.original.size > MAX_BYTES as u64
                || entry
                    .replacement
                    .as_ref()
                    .is_some_and(|r| r.size > MAX_BYTES as u64)
                || total_bytes > MAX_TRANSACTION_BYTES as u64
                || entry.original_copy.as_ref().is_some_and(|copy| {
                    copy.size != entry.original.size || copy.digest != entry.original.digest
                })
            {
                return Err(Error::InvalidJournal);
            }
        }
        let mut names = HashSet::new();
        let mut directories = BTreeMap::new();
        let mut parents = Vec::new();
        for entry in &manifest.entries {
            name(OsStr::from_bytes(&entry.name)).map_err(|_| Error::InvalidJournal)?;
            if !names.insert((entry.parent_identity, &entry.name))
                || entry.replacement.is_some() != entry.original_copy.is_some()
            {
                return Err(Error::InvalidJournal);
            }
            let path = PathBuf::from(OsString::from_vec(entry.parent_path.clone()));
            let directory = if let Some(directory) = directories.get(&path) {
                Arc::clone(directory)
            } else {
                let directory =
                    Arc::new(Directory::open(&path).map_err(|_| Error::InvalidJournal)?);
                directory.supported()?;
                directories.insert(path, directory.clone());
                directory
            };
            if directory.identity != entry.parent_identity
                || directory.identity[0] != parent.identity[0]
                || entry.original.device != parent.identity[0]
            {
                return Err(Error::InvalidJournal);
            }
            parents.push(directory);
        }
        Ok(Self {
            parent,
            journal,
            manifest,
            keep: true,
            parents,
            own_files: Vec::new(),
        })
    }

    /// Gebundene Original- und Ist-Daten, bevor die Oberfläche eine Wiederaufnahme freigibt.
    pub fn recovery_preview(&self, cancel: &Cancellation) -> Result<RecoveryPreview> {
        cancel.check()?;
        self.parent.bound()?;
        self.journal.bound()?;
        let (raw, intent) = read_file(
            self.journal.regular(OsStr::new("intent.json"))?,
            cancel,
            MAX_MANIFEST,
        )?;
        let current: Manifest = serde_json::from_slice(&raw).map_err(|_| Error::InvalidJournal)?;
        if current != self.manifest {
            return Err(Error::Stale);
        }
        let mut files = Vec::new();
        let mut targets = Vec::new();
        let mut bytes = 0usize;
        for (index, entry) in self.manifest.entries.iter().enumerate() {
            cancel.check()?;
            self.parents[index].bound()?;
            let state = self.state(index, cancel)?;
            if state == FileState::Conflict {
                return Err(Error::RecoveryRequired(self.path().to_owned()));
            }
            let (data, target) = read_file(
                self.parents[index].regular(OsStr::from_bytes(&entry.name))?,
                cancel,
                MAX_BYTES,
            )?;
            let expected = if state == FileState::Replaced {
                entry.replacement.as_ref().ok_or(Error::InvalidJournal)?
            } else {
                &entry.original
            };
            if &target != expected {
                return Err(Error::Stale);
            }
            let current = Arc::new(data);
            let original = if state == FileState::Original {
                current.clone()
            } else if let Some(copy) = &entry.original_copy {
                let (data, actual) =
                    read_file(self.journal.regular(&copy_name(index))?, cancel, MAX_BYTES)?;
                if &actual != copy || actual.digest != entry.original.digest {
                    return Err(Error::Stale);
                }
                Arc::new(data)
            } else {
                current.clone()
            };
            bytes = bytes
                .checked_add(current.len())
                .and_then(|n| n.checked_add(original.len()))
                .ok_or(Error::Limit)?;
            if bytes > MAX_TRANSACTION_BYTES {
                return Err(Error::Limit);
            }
            targets.push(target);
            files.push(RecoveryFile {
                path: self.parents[index]
                    .path
                    .join(OsStr::from_bytes(&entry.name)),
                state,
                current,
                original,
            });
        }
        let preview = RecoveryPreview {
            journal: self.journal.identity,
            phase: self.manifest.phase,
            intent,
            targets,
            files,
        };
        self.validate_recovery(&preview, cancel)?;
        Ok(preview)
    }
    fn validate_recovery(&self, preview: &RecoveryPreview, cancel: &Cancellation) -> Result<()> {
        cancel.check()?;
        self.parent.bound()?;
        self.journal.bound()?;
        if preview.journal != self.journal.identity
            || preview.phase != self.manifest.phase
            || preview.targets.len() != self.parents.len()
        {
            return Err(Error::Stale);
        }
        let (_, intent) = read_file(
            self.journal.regular(OsStr::new("intent.json"))?,
            cancel,
            MAX_MANIFEST,
        )?;
        if intent != preview.intent {
            return Err(Error::Stale);
        }
        for ((entry, parent), expected) in self
            .manifest
            .entries
            .iter()
            .zip(&self.parents)
            .zip(&preview.targets)
        {
            cancel.check()?;
            parent.bound()?;
            if &fingerprint(parent, OsStr::from_bytes(&entry.name), cancel)? != expected {
                return Err(Error::Stale);
            }
        }
        Ok(())
    }
    pub fn undo_approved(
        &mut self,
        preview: &RecoveryPreview,
        cancel: &Cancellation,
    ) -> Result<()> {
        self.validate_recovery(preview, cancel)?;
        self.undo(cancel)
    }

    /// Nur nach erfolgreichem Undo: Originale sind wieder am Ziel, bekannte Sicherungen dürfen weg.
    pub fn discard(mut self, cancel: &Cancellation) -> Result<()> {
        if self.manifest.phase != Phase::Undone
            || self
                .inspect(cancel)?
                .iter()
                .any(|s| *s != FileState::Original)
        {
            return Err(Error::RecoveryRequired(self.path().to_owned()));
        }
        self.remove_known_files()
    }

    /// Liefert ausschließlich die durch diese Transaktion bestätigten Dateistände.
    pub fn applied_snapshots(&self, cancel: &Cancellation) -> Result<Vec<Snapshot>> {
        if self.manifest.phase != Phase::Applied {
            return Err(Error::InvalidJournal);
        }
        self.verified_snapshots(false, cancel)
    }

    pub fn restored_snapshots(&self, cancel: &Cancellation) -> Result<Vec<Snapshot>> {
        if self.manifest.phase != Phase::Undone {
            return Err(Error::InvalidJournal);
        }
        self.verified_snapshots(true, cancel)
    }

    fn verified_snapshots(&self, restored: bool, cancel: &Cancellation) -> Result<Vec<Snapshot>> {
        let mut snapshots = Vec::new();
        for (index, entry) in self.manifest.entries.iter().enumerate() {
            let parent = &self.parents[index];
            parent.bound()?;
            let name = OsStr::from_bytes(&entry.name);
            let (bytes, actual) = read_file(parent.regular(name)?, cancel, MAX_BYTES)?;
            let expected = if restored {
                &entry.original
            } else {
                entry.replacement.as_ref().unwrap_or(&entry.original)
            };
            if &actual != expected {
                return Err(Error::RecoveryRequired(self.path().to_owned()));
            }
            snapshots.push(Snapshot {
                parent: parent.clone(),
                name: name.to_owned(),
                bytes: Arc::new(bytes),
                fingerprint: actual,
            });
        }
        Ok(snapshots)
    }

    /// Einzelnes, ausdrücklich gespeichertes Dokument; Suchtransaktionen behalten ihr Undo.
    pub fn saved_document_snapshot(&self, cancel: &Cancellation) -> Result<Snapshot> {
        if self.manifest.purpose != Purpose::SaveDocument
            || self.manifest.phase != Phase::Applied
            || self.manifest.entries.len() != 1
        {
            return Err(Error::InvalidJournal);
        }
        self.parents[0].bound()?;
        let entry = &self.manifest.entries[0];
        let name = OsStr::from_bytes(&entry.name);
        let (bytes, actual) = read_file(self.parents[0].regular(name)?, cancel, MAX_BYTES)?;
        if Some(&actual) != entry.replacement.as_ref() {
            return Err(Error::RecoveryRequired(self.path().to_owned()));
        }
        Ok(Snapshot {
            parent: self.parents[0].clone(),
            name: name.to_owned(),
            bytes: Arc::new(bytes),
            fingerprint: actual,
        })
    }

    /// Erst nach Übernahme des verifizierten Save-Snapshots Sicherungen freigeben.
    pub fn finish_document_save(mut self, cancel: &Cancellation) -> Result<()> {
        if self.manifest.purpose != Purpose::SaveDocument
            || self.manifest.phase != Phase::Applied
            || self.manifest.entries.len() != 1
            || self.inspect(cancel)? != [FileState::Replaced]
        {
            return Err(Error::RecoveryRequired(self.path().to_owned()));
        }
        self.remove_known_files()
    }

    fn remove_known_files(&mut self) -> Result<()> {
        let mut known_files = Vec::new();
        for (index, entry) in self.manifest.entries.iter().enumerate() {
            if entry.replacement.is_some() {
                known_files.extend([stage_name(index), copy_name(index)]);
            }
        }
        known_files.push("intent.json".into());
        for name in known_files {
            self.journal.remove(&name, false)?;
        }
        self.parent.remove(
            self.journal.path.file_name().ok_or(Error::InvalidPath)?,
            true,
        )?;
        self.parent.sync()?;
        self.keep = true;
        Ok(())
    }
}

#[cfg(test)]
mod tests;

#[path = "markdown_assets.rs"]
pub mod markdown_assets;

#[path = "save_target.rs"]
pub mod save_target;
