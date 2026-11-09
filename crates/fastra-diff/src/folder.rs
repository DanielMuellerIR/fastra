//! Lesender Ordnervergleich: rohe relative Pfade, gestreamte Inhalte, abschließende Validierung.
use crate::{Cancellation, Error};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::{CStr, CString, OsString},
    fs::{self, File},
    io::Read,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::{OsStrExt, OsStringExt},
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
    path::{Path, PathBuf},
};
#[derive(Debug, Clone, Copy)]
pub struct FolderLimits {
    pub max_entries: usize,
    pub max_visited: usize,
    pub max_depth: usize,
    pub max_path_bytes: usize,
    pub max_file_bytes: u64,
    pub max_total_bytes: u64,
    pub max_memory_bytes: usize,
    pub include_hidden: bool,
}
impl Default for FolderLimits {
    fn default() -> Self {
        Self {
            max_entries: 20_000,
            max_visited: 100_000,
            max_depth: 64,
            max_path_bytes: 4096,
            max_file_bytes: 256 * 1024 * 1024,
            max_total_bytes: 2 * 1024 * 1024 * 1024,
            max_memory_bytes: 128 * 1024 * 1024,
            include_hidden: false,
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    OnlyLeft,
    OnlyRight,
    Identical,
    Different,
    Unavailable,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContentKind {
    Directory,
    Text,
    BinaryOrNonUtf8,
    Special,
    Unknown,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderRow {
    pub relative_path: PathBuf,
    pub status: Status,
    pub kind: ContentKind,
    pub issue: Option<String>,
}
#[derive(Debug)]
pub struct FolderResult {
    pub left_root: PathBuf,
    pub right_root: PathBuf,
    pub rows: Vec<FolderRow>,
    pub issues: Vec<String>,
    pub bytes_read: u64,
}
impl FolderResult {
    pub fn complete(&self) -> bool {
        self.issues.is_empty() && !self.rows.iter().any(|r| r.status == Status::Unavailable)
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct Version {
    dev: u64,
    ino: u64,
    len: u64,
    mode: u32,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}
impl Version {
    fn read(m: &fs::Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            len: m.len(),
            mode: m.mode(),
            mtime: m.mtime(),
            mtime_ns: m.mtime_nsec(),
            ctime: m.ctime(),
            ctime_ns: m.ctime_nsec(),
        }
    }
    fn dir(&self) -> bool {
        self.mode & libc::S_IFMT == libc::S_IFDIR
    }
    fn regular(&self) -> bool {
        self.mode & libc::S_IFMT == libc::S_IFREG
    }
}
struct Entry {
    path: PathBuf,
    version: Option<Version>,
    issue: Option<String>,
}
struct Tree {
    root: PathBuf,
    handle: File,
    version: Version,
    entries: BTreeMap<Vec<u8>, Entry>,
}
struct ScanBudget {
    visited: usize,
    entries: usize,
    memory: usize,
}
fn io(error: std::io::Error) -> Error {
    Error::Io(error.to_string())
}
fn cpath(path: &Path) -> Result<CString, Error> {
    CString::new(path.as_os_str().as_bytes()).map_err(|_| Error::InvalidRange)
}
fn child(parent: &File, name: &Path, directory: bool) -> Result<File, Error> {
    let name = cpath(name)?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY
                | libc::O_NOFOLLOW
                | libc::O_CLOEXEC
                | libc::O_NONBLOCK
                | if directory { libc::O_DIRECTORY } else { 0 },
        )
    };
    if fd < 0 {
        return Err(io(std::io::Error::last_os_error()));
    }
    let file = unsafe { File::from_raw_fd(fd) };
    let version = Version::read(&file.metadata().map_err(io)?);
    if directory && !version.dir() || !directory && !version.regular() {
        return Err(Error::Stale);
    }
    Ok(file)
}
struct Directory(*mut libc::DIR);
impl Drop for Directory {
    fn drop(&mut self) {
        unsafe {
            libc::closedir(self.0);
        }
    }
}
fn scan_directory(
    handle: &File,
    prefix: &Path,
    depth: usize,
    limits: FolderLimits,
    cancel: &Cancellation,
    budget: &mut ScanBudget,
    entries: &mut BTreeMap<Vec<u8>, Entry>,
) -> Result<(), Error> {
    cancel.check()?;
    if depth > limits.max_depth {
        return Err(Error::Limit("folder depth"));
    }
    let cloned = unsafe { libc::fcntl(handle.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
    if cloned < 0 {
        return Err(io(std::io::Error::last_os_error()));
    }
    let stream = unsafe { libc::fdopendir(cloned) };
    if stream.is_null() {
        unsafe {
            libc::close(cloned);
        }
        return Err(io(std::io::Error::last_os_error()));
    }
    let stream = Directory(stream);
    loop {
        cancel.check()?;
        unsafe {
            *libc::__errno_location() = 0;
        }
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(0) {
                return Err(io(error));
            }
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name == b"." || name == b".." {
            continue;
        }
        budget.visited = budget
            .visited
            .checked_add(1)
            .ok_or(Error::Limit("visited folder entries"))?;
        if budget.visited > limits.max_visited {
            return Err(Error::Limit("visited folder entries"));
        }
        if !limits.include_hidden && name.starts_with(b".") {
            continue;
        }
        let name = PathBuf::from(OsString::from_vec(name.to_vec()));
        let relative = prefix.join(&name);
        let key = relative.as_os_str().as_bytes().to_vec();
        if key.len() > limits.max_path_bytes || budget.entries >= limits.max_entries {
            return Err(Error::Limit("folder entry or path count"));
        }
        budget.memory = budget
            .memory
            .checked_add(key.len() * 4 + 512)
            .ok_or(Error::Limit("folder memory"))?;
        if budget.memory > limits.max_memory_bytes {
            return Err(Error::Limit("folder memory"));
        }
        budget.entries += 1;
        let cname = cpath(&name)?;
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        let ok = unsafe {
            libc::fstatat(
                handle.as_raw_fd(),
                cname.as_ptr(),
                &mut stat,
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } == 0;
        let mut item = Entry {
            path: relative.clone(),
            version: None,
            issue: None,
        };
        if ok {
            let file_kind = stat.st_mode & libc::S_IFMT;
            if file_kind == libc::S_IFDIR || file_kind == libc::S_IFREG {
                match child(handle, &name, file_kind == libc::S_IFDIR) {
                    Ok(opened) => {
                        let version = Version::read(&opened.metadata().map_err(io)?);
                        if version.dev != stat.st_dev || version.ino != stat.st_ino {
                            item.issue = Some("entry changed during enumeration".into());
                        } else {
                            item.version = Some(version);
                            if file_kind == libc::S_IFDIR {
                                scan_directory(
                                    &opened,
                                    &relative,
                                    depth + 1,
                                    limits,
                                    cancel,
                                    budget,
                                    entries,
                                )?;
                            }
                        }
                    }
                    Err(error) => item.issue = Some(error.to_string()),
                }
            } else {
                item.issue = Some("symlink or special file is not followed".into());
            }
        } else {
            item.issue = Some(std::io::Error::last_os_error().to_string());
        }
        entries.insert(key, item);
    }
    Ok(())
}
fn scan(
    path: &Path,
    limits: FolderLimits,
    cancel: &Cancellation,
    budget: &mut ScanBudget,
) -> Result<Tree, Error> {
    let root = fs::canonicalize(path).map_err(io)?;
    let handle = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&root)
        .map_err(io)?;
    let version = Version::read(&handle.metadata().map_err(io)?);
    let mut entries = BTreeMap::new();
    scan_directory(
        &handle,
        Path::new(""),
        0,
        limits,
        cancel,
        budget,
        &mut entries,
    )?;
    Ok(Tree {
        root,
        handle,
        version,
        entries,
    })
}
fn open_entry(tree: &Tree, path: &Path, directory: bool) -> Result<File, Error> {
    let components: Vec<_> = path.components().collect();
    let mut parent = tree.handle.try_clone().map_err(io)?;
    for component in &components[..components.len() - 1] {
        parent = child(&parent, Path::new(component.as_os_str()), true)?;
    }
    child(
        &parent,
        Path::new(components[components.len() - 1].as_os_str()),
        directory,
    )
}
fn hash(
    tree: &Tree,
    entry: &Entry,
    limits: FolderLimits,
    cancel: &Cancellation,
    total: &mut u64,
) -> Result<([u8; 32], ContentKind), Error> {
    cancel.check()?;
    let expected = entry.version.as_ref().ok_or(Error::Stale)?;
    let mut file = open_entry(tree, &entry.path, false)?;
    if &Version::read(&file.metadata().map_err(io)?) != expected {
        return Err(Error::Stale);
    }
    if expected.len > limits.max_file_bytes {
        return Err(Error::Limit("folder file bytes"));
    }
    let mut digest = Sha256::new();
    let mut read_total = 0u64;
    let mut buffer = [0u8; 65536];
    let mut binary = false;
    let mut carry = Vec::new();
    loop {
        cancel.check()?;
        let count = file.read(&mut buffer).map_err(io)?;
        if count == 0 {
            break;
        }
        *total = total
            .checked_add(count as u64)
            .ok_or(Error::Limit("folder total bytes"))?;
        read_total += count as u64;
        if read_total > expected.len {
            return Err(Error::Stale);
        }
        if *total > limits.max_total_bytes || read_total > limits.max_file_bytes {
            return Err(Error::Limit("folder read bytes"));
        }
        digest.update(&buffer[..count]);
        if !binary {
            binary = buffer[..count].contains(&0);
            carry.extend_from_slice(&buffer[..count]);
            if let Err(error) = std::str::from_utf8(&carry) {
                if error.error_len().is_some() {
                    binary = true;
                    carry.clear();
                } else {
                    carry.drain(..error.valid_up_to());
                }
            } else {
                carry.clear();
            }
        }
    }
    if &Version::read(&file.metadata().map_err(io)?) != expected || read_total != expected.len {
        return Err(Error::Stale);
    }
    Ok((
        digest.finalize().into(),
        if binary || !carry.is_empty() {
            ContentKind::BinaryOrNonUtf8
        } else {
            ContentKind::Text
        },
    ))
}
pub fn compare_folders(
    left: &Path,
    right: &Path,
    limits: FolderLimits,
    cancel: &Cancellation,
) -> Result<FolderResult, Error> {
    compare_internal(left, right, limits, cancel, || {})
}
fn compare_internal(
    left: &Path,
    right: &Path,
    limits: FolderLimits,
    cancel: &Cancellation,
    before_validation: impl FnOnce(),
) -> Result<FolderResult, Error> {
    let max = FolderLimits::default();
    if limits.max_entries > max.max_entries
        || limits.max_visited > max.max_visited
        || limits.max_depth > max.max_depth
        || limits.max_path_bytes > max.max_path_bytes
        || limits.max_file_bytes > max.max_file_bytes
        || limits.max_total_bytes > max.max_total_bytes
        || limits.max_memory_bytes > max.max_memory_bytes
    {
        return Err(Error::Limit("invalid folder limits"));
    }
    let mut budget = ScanBudget {
        visited: 0,
        entries: 0,
        memory: 0,
    };
    let a = scan(left, limits, cancel, &mut budget)?;
    let b = scan(right, limits, cancel, &mut budget)?;
    let keys: BTreeSet<_> = a.entries.keys().chain(b.entries.keys()).cloned().collect();
    let mut rows = Vec::with_capacity(keys.len());
    let mut bytes_read = 0;
    let mut issues = Vec::new();
    for key in keys {
        cancel.check()?;
        let left = a.entries.get(&key);
        let right = b.entries.get(&key);
        let entry = left.or(right).ok_or(Error::Internal("folder key"))?;
        let mut row = FolderRow {
            relative_path: entry.path.clone(),
            status: Status::Unavailable,
            kind: ContentKind::Unknown,
            issue: None,
        };
        if let Some(issue) = left
            .and_then(|e| e.issue.clone())
            .or_else(|| right.and_then(|e| e.issue.clone()))
        {
            row.issue = Some(issue);
            row.kind = ContentKind::Special;
        } else if let (Some(left), Some(right)) = (left, right) {
            let l = left.version.as_ref().ok_or(Error::Stale)?;
            let r = right.version.as_ref().ok_or(Error::Stale)?;
            if l.dir() != r.dir() {
                row.status = Status::Different;
                row.issue = Some("file and directory at same relative path".into());
            } else if l.dir() {
                row.status = Status::Identical;
                row.kind = ContentKind::Directory;
            } else {
                match hash(&a, left, limits, cancel, &mut bytes_read)
                    .and_then(|x| hash(&b, right, limits, cancel, &mut bytes_read).map(|y| (x, y)))
                {
                    Ok((x, y)) => {
                        row.status = if x.0 == y.0 {
                            Status::Identical
                        } else {
                            Status::Different
                        };
                        row.kind = if x.1 == ContentKind::Text && y.1 == ContentKind::Text {
                            ContentKind::Text
                        } else {
                            ContentKind::BinaryOrNonUtf8
                        };
                    }
                    Err(Error::Cancelled) => return Err(Error::Cancelled),
                    Err(Error::Limit(reason)) => return Err(Error::Limit(reason)),
                    Err(error) => row.issue = Some(error.to_string()),
                }
            }
        } else {
            let missing_tree = if left.is_none() { &a } else { &b };
            let mut parent = entry.path.parent();
            let mut uncertain = false;
            while let Some(path) = parent {
                if path.as_os_str().is_empty() {
                    break;
                }
                if missing_tree
                    .entries
                    .get(path.as_os_str().as_bytes())
                    .is_some_and(|e| e.issue.is_some())
                {
                    uncertain = true;
                    break;
                }
                parent = path.parent();
            }
            if uncertain {
                row.issue = Some("counterpart ancestor is unavailable".into());
                rows.push(row);
                continue;
            }
            row.status = if left.is_some() {
                Status::OnlyLeft
            } else {
                Status::OnlyRight
            };
            row.kind = if entry.version.as_ref().is_some_and(Version::dir) {
                ContentKind::Directory
            } else {
                ContentKind::Unknown
            };
        }
        rows.push(row);
    }
    before_validation();
    // Fehlende Einträge dürfen nach unvollständiger/veränderter Struktur nicht als sicher fehlen gelten.
    let mut tree_changed = false;
    let mut root_replaced = false;
    let mut changed = BTreeSet::new();
    for tree in [&a, &b] {
        cancel.check()?;
        let current_root = fs::symlink_metadata(&tree.root)
            .map(|m| Version::read(&m))
            .ok();
        if current_root.as_ref().is_none_or(|root| {
            root.dev != tree.version.dev || root.ino != tree.version.ino || !root.dir()
        }) {
            root_replaced = true;
        }
        if current_root.as_ref() != Some(&tree.version) {
            tree_changed = true;
            issues.push("comparison root changed".into());
        }
        for (key, entry) in &tree.entries {
            cancel.check()?;
            if let Some(expected) = &entry.version {
                let current = open_entry(tree, &entry.path, expected.dir())
                    .and_then(|f| f.metadata().map_err(io))
                    .map(|m| Version::read(&m));
                if current.as_ref().ok() != Some(expected) {
                    changed.insert(key.clone());
                    tree_changed |= expected.dir();
                }
            }
        }
    }
    for row in &mut rows {
        if root_replaced
            || changed.contains(row.relative_path.as_os_str().as_bytes())
            || tree_changed
                && (matches!(row.status, Status::OnlyLeft | Status::OnlyRight)
                    || row.kind == ContentKind::Directory)
        {
            row.status = Status::Unavailable;
            row.issue = Some("source changed during comparison".into());
        }
    }
    // Pro Kind nur seine Vorfahren besuchen: O(Einträge × Tiefe), kein quadratischer Rollup.
    let indexes: BTreeMap<Vec<u8>, usize> = rows
        .iter()
        .enumerate()
        .map(|(i, row)| (row.relative_path.as_os_str().as_bytes().to_vec(), i))
        .collect();
    for index in (0..rows.len()).rev() {
        cancel.check()?;
        let state = rows[index].status;
        if state == Status::Identical {
            continue;
        }
        let mut parent = rows[index].relative_path.parent().map(Path::to_owned);
        while let Some(path) = parent {
            cancel.check()?;
            if path.as_os_str().is_empty() {
                break;
            }
            if let Some(&target) = indexes.get(path.as_os_str().as_bytes()) {
                if rows[target].kind == ContentKind::Directory {
                    if state == Status::Unavailable {
                        rows[target].status = Status::Unavailable;
                        rows[target]
                            .issue
                            .get_or_insert_with(|| "contains unavailable descendants".into());
                    } else if rows[target].status == Status::Identical {
                        rows[target].status = Status::Different;
                    }
                }
            }
            parent = path.parent().map(Path::to_owned);
        }
    }
    Ok(FolderResult {
        left_root: a.root,
        right_root: b.root,
        rows,
        issues,
        bytes_read,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn pair() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let a = root.path().join("a");
        let b = root.path().join("b");
        fs::create_dir(&a).unwrap();
        fs::create_dir(&b).unwrap();
        (root, a, b)
    }
    fn put(root: &Path, path: &str, bytes: &[u8]) {
        let path = root.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }
    fn row<'a>(result: &'a FolderResult, path: &str) -> &'a FolderRow {
        result
            .rows
            .iter()
            .find(|r| r.relative_path == Path::new(path))
            .unwrap()
    }
    #[test]
    fn folders_compare_binary_missing_and_exact_relative_names_without_writes() {
        let (_root, a, b) = pair();
        put(&a, "same", b"same\r\n");
        put(&b, "same", b"same\r\n");
        put(&a, "dir/different", b"old");
        put(&b, "dir/different", b"new");
        put(&a, "left", b"left");
        put(&b, "right", b"right");
        put(&a, "binary", b"\0\xff");
        put(&b, "binary", b"\0\xfe");
        put(&a, ".hidden", b"left");
        put(&b, ".hidden", b"right");
        let result =
            compare_folders(&a, &b, FolderLimits::default(), &Cancellation::default()).unwrap();
        assert!(result.complete());
        assert_eq!(row(&result, "same").status, Status::Identical);
        assert_eq!(row(&result, "same").kind, ContentKind::Text);
        assert_eq!(row(&result, "dir").status, Status::Different);
        assert_eq!(row(&result, "left").status, Status::OnlyLeft);
        assert_eq!(row(&result, "right").status, Status::OnlyRight);
        assert_eq!(row(&result, "binary").kind, ContentKind::BinaryOrNonUtf8);
        assert_eq!(row(&result, "binary").status, Status::Different);
        assert!(!result
            .rows
            .iter()
            .any(|r| r.relative_path == Path::new(".hidden")));
        assert_eq!(fs::read(a.join("dir/different")).unwrap(), b"old");
    }
    #[test]
    fn byte_distinct_unicode_and_non_utf8_paths_stay_distinct() {
        let (_root, a, b) = pair();
        put(&a, "é", b"same");
        put(&b, "e\u{301}", b"same");
        let name = OsString::from_vec(b"raw\xff\nfile".to_vec());
        fs::write(a.join(&name), b"same").unwrap();
        fs::write(b.join(&name), b"same").unwrap();
        let result =
            compare_folders(&a, &b, FolderLimits::default(), &Cancellation::default()).unwrap();
        assert_eq!(result.rows.len(), 3);
        assert_eq!(row(&result, "é").status, Status::OnlyLeft);
        assert_eq!(row(&result, "e\u{301}").status, Status::OnlyRight);
        assert!(result
            .rows
            .iter()
            .any(|r| r.relative_path.as_os_str() == name && r.status == Status::Identical));
    }
    #[test]
    fn symlinks_and_fifos_are_unavailable_and_never_followed() {
        let (root, a, b) = pair();
        let foreign = root.path().join("foreign");
        fs::create_dir(&foreign).unwrap();
        put(&foreign, "secret", b"foreign");
        std::os::unix::fs::symlink(&foreign, a.join("dir")).unwrap();
        put(&b, "dir/secret", b"other");
        let fifo = cpath(&a.join("fifo")).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        let result =
            compare_folders(&a, &b, FolderLimits::default(), &Cancellation::default()).unwrap();
        assert!(!result.complete());
        assert_eq!(row(&result, "dir").status, Status::Unavailable);
        assert_eq!(row(&result, "dir/secret").status, Status::Unavailable);
        assert_eq!(row(&result, "fifo").status, Status::Unavailable);
        assert_eq!(fs::read(foreign.join("secret")).unwrap(), b"foreign");
    }
    #[test]
    fn directory_rollup_handles_interleaved_prefix_names() {
        let (_root, a, b) = pair();
        put(&a, "a/child", b"old");
        put(&b, "a/child", b"new");
        put(&a, "a!", b"same");
        put(&b, "a!", b"same");
        let result =
            compare_folders(&a, &b, FolderLimits::default(), &Cancellation::default()).unwrap();
        assert_eq!(row(&result, "a").status, Status::Different);
    }
    #[test]
    fn mutations_after_read_are_honest_and_do_not_assert_missing() {
        let (_root, a, b) = pair();
        put(&a, "same", b"same");
        put(&b, "same", b"same");
        put(&a, "left", b"left");
        let result = compare_internal(
            &a,
            &b,
            FolderLimits::default(),
            &Cancellation::default(),
            || {
                fs::write(b.join("same"), b"changed").unwrap();
                put(&b, "new-unenumerated", b"new");
            },
        )
        .unwrap();
        assert!(!result.complete());
        assert_eq!(row(&result, "same").status, Status::Unavailable);
        assert_eq!(row(&result, "left").status, Status::Unavailable);
    }
    #[test]
    fn utf8_detection_spans_chunks_without_misclassifying_unicode() {
        let (_root, a, b) = pair();
        let text = "a".repeat(65535) + "😀é";
        put(&a, "text", text.as_bytes());
        put(&b, "text", text.as_bytes());
        let result =
            compare_folders(&a, &b, FolderLimits::default(), &Cancellation::default()).unwrap();
        assert_eq!(row(&result, "text").kind, ContentKind::Text);
    }
    #[test]
    fn folder_limits_and_precancellation_never_return_partial_success() {
        let (_root, a, b) = pair();
        put(&a, "dir/x", b"12345");
        put(&b, "dir/x", b"12345");
        for limits in [
            FolderLimits {
                max_entries: 1,
                ..FolderLimits::default()
            },
            FolderLimits {
                max_total_bytes: 3,
                ..FolderLimits::default()
            },
            FolderLimits {
                max_file_bytes: 2,
                ..FolderLimits::default()
            },
            FolderLimits {
                max_depth: 0,
                ..FolderLimits::default()
            },
            FolderLimits {
                max_memory_bytes: 1,
                ..FolderLimits::default()
            },
        ] {
            assert!(matches!(
                compare_folders(&a, &b, limits, &Cancellation::default()),
                Err(Error::Limit(_))
            ));
        }
        let cancel = Cancellation::default();
        cancel.cancel();
        assert!(matches!(
            compare_folders(&a, &b, FolderLimits::default(), &cancel),
            Err(Error::Cancelled)
        ));
    }
}

#[cfg(test)]
mod replacement_tests {
    use super::*;
    #[test]
    fn replacing_a_root_invalidates_even_previously_equal_file_rows() {
        let fixture = tempfile::tempdir().unwrap();
        let a = fixture.path().join("a");
        let b = fixture.path().join("b");
        fs::create_dir(&a).unwrap();
        fs::create_dir(&b).unwrap();
        fs::write(a.join("same"), b"old").unwrap();
        fs::write(b.join("same"), b"old").unwrap();
        let result = compare_internal(
            &a,
            &b,
            FolderLimits::default(),
            &Cancellation::default(),
            || {
                fs::rename(&b, fixture.path().join("previous")).unwrap();
                fs::create_dir(&b).unwrap();
                fs::write(b.join("same"), b"new").unwrap();
            },
        )
        .unwrap();
        assert!(!result.complete());
        assert!(result
            .rows
            .iter()
            .all(|row| row.status == Status::Unavailable));
    }
}
