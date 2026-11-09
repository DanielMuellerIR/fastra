use crate::{Cancellation, Error, Limits};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::{CStr, CString},
    fs::{self, File},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
    path::{Component, Path, PathBuf},
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRecord {
    pub bytes: u64,
    pub sha256: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum EntryRecord {
    Directory,
    File(FileRecord),
}
pub(crate) type Manifest = BTreeMap<PathBuf, EntryRecord>;
fn io(error: std::io::Error) -> Error {
    Error::Io(error.to_string())
}
fn c_name(name: &Path) -> Result<CString, Error> {
    CString::new(name.as_os_str().as_bytes()).map_err(|_| Error::UnsafeTree("NUL in path"))
}
pub(crate) fn safe_relative(path: &Path) -> Result<(), Error> {
    if path.as_os_str().is_empty()
        || path.to_str().is_none()
        || path
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err(Error::UnsafeTree("not a UTF-8 relative path"));
    }
    Ok(())
}
pub(crate) fn directory(path: &Path) -> Result<File, Error> {
    fastra_io::check_runtime_path(path).map_err(io)?;
    let info = fs::symlink_metadata(path).map_err(io)?;
    if !info.is_dir() {
        return Err(Error::UnsafeTree("directory is not a real directory"));
    }
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(io)?;
    fastra_io::check_runtime_file(&file).map_err(io)?;
    if identity(&file.metadata().map_err(io)?) != identity(&info) {
        return Err(Error::UnsafeTree("directory changed while opening"));
    }
    Ok(file)
}
pub(crate) fn identity(info: &fs::Metadata) -> (u64, u64) {
    (info.dev(), info.ino())
}
fn signature(info: &fs::Metadata) -> (u64, u64, u64, u32, u64, i64, i64, i64, i64) {
    (
        info.dev(),
        info.ino(),
        info.len(),
        info.mode(),
        info.nlink(),
        info.mtime(),
        info.mtime_nsec(),
        info.ctime(),
        info.ctime_nsec(),
    )
}
fn child(parent: &File, name: &Path, dir: bool) -> Result<File, Error> {
    fastra_io::check_runtime_path(&std::path::PathBuf::from(format!("/proc/self/fd/{}", parent.as_raw_fd())).join(name)).map_err(io)?;
    let name = c_name(name)?;
    let mut before: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            &mut before,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(io(std::io::Error::last_os_error()));
    }
    let required = if dir { libc::S_IFDIR } else { libc::S_IFREG };
    if before.st_mode & libc::S_IFMT != required || !dir && before.st_nlink != 1 {
        return Err(Error::UnsafeTree(
            "symlink, special file or hardlink in output",
        ));
    }
    let flags = libc::O_RDONLY
        | libc::O_CLOEXEC
        | libc::O_NOFOLLOW
        | libc::O_NONBLOCK
        | if dir { libc::O_DIRECTORY } else { 0 };
    let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        return Err(io(std::io::Error::last_os_error()));
    }
    let file = unsafe { File::from_raw_fd(fd) };
    fastra_io::check_runtime_file(&file).map_err(io)?;
    let info = file.metadata().map_err(io)?;
    if info.dev() != before.st_dev
        || info.ino() != before.st_ino
        || info.mode() & libc::S_IFMT != required
        || !dir && info.nlink() != 1
    {
        return Err(Error::UnsafeTree("output changed while opening"));
    }
    Ok(file)
}
pub(crate) fn output_directory(parent: &File, name: &str) -> Result<File, Error> {
    child(parent, Path::new(name), true)
}
struct DirectoryStream(*mut libc::DIR);
impl Drop for DirectoryStream {
    fn drop(&mut self) {
        unsafe {
            libc::closedir(self.0);
        }
    }
}
fn names(directory: &File, limit: usize) -> Result<Vec<PathBuf>, Error> {
    let fd = unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
    if fd < 0 {
        return Err(io(std::io::Error::last_os_error()));
    }
    let stream = unsafe { libc::fdopendir(fd) };
    if stream.is_null() {
        unsafe {
            libc::close(fd);
        }
        return Err(io(std::io::Error::last_os_error()));
    }
    let stream = DirectoryStream(stream);
    let mut names = Vec::new();
    loop {
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
        if names.len() >= limit {
            return Err(Error::Limit("entry count"));
        }
        let name =
            std::str::from_utf8(name).map_err(|_| Error::UnsafeTree("non-UTF-8 output name"))?;
        let name = PathBuf::from(name);
        safe_relative(&name)?;
        names.push(name);
    }
    names.sort();
    Ok(names)
}
struct Budget {
    entries: usize,
    bytes: u64,
}
struct CopyState {
    budget: Budget,
    manifest: Manifest,
    device: u64,
}
fn copy_tree(
    source: &File,
    target: &Path,
    prefix: &Path,
    limits: Limits,
    cancel: &Cancellation,
    state: &mut CopyState,
    depth: usize,
) -> Result<(), Error> {
    crate::check_cancel(cancel)?;
    if depth > limits.max_depth {
        return Err(Error::Limit("directory depth"));
    }
    let before = source.metadata().map_err(io)?;
    if before.dev() != state.device {
        return Err(Error::UnsafeTree("output crosses filesystem boundary"));
    }
    for name in names(
        source,
        limits.max_entries.saturating_sub(state.budget.entries),
    )? {
        crate::check_cancel(cancel)?;
        state.budget.entries += 1;
        let c_name = c_name(&name)?;
        let mut info: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe {
            libc::fstatat(
                source.as_raw_fd(),
                c_name.as_ptr(),
                &mut info,
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            return Err(io(std::io::Error::last_os_error()));
        }
        let relative = prefix.join(&name);
        if relative.as_os_str().as_bytes().len() > limits.max_path_bytes {
            return Err(Error::Limit("path length"));
        }
        if info.st_mode & libc::S_IFMT == libc::S_IFDIR {
            let directory = child(source, &name, true)?;
            fs::create_dir(target.join(&name)).map_err(io)?;
            state
                .manifest
                .insert(relative.clone(), EntryRecord::Directory);
            copy_tree(
                &directory,
                &target.join(&name),
                &relative,
                limits,
                cancel,
                state,
                depth + 1,
            )?;
        } else {
            let mut input = child(source, &name, false)?;
            let before = input.metadata().map_err(io)?;
            if before.dev() != state.device {
                return Err(Error::UnsafeTree("file crosses filesystem boundary"));
            }
            if before.len() > limits.max_file_bytes {
                return Err(Error::Limit("file size"));
            }
            let mut output = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(target.join(&name))
                .map_err(io)?;
            let mut digest = Sha256::new();
            let mut count = 0u64;
            let mut buffer = [0u8; 64 * 1024];
            loop {
                crate::check_cancel(cancel)?;
                let read = input.read(&mut buffer).map_err(io)?;
                if read == 0 {
                    break;
                }
                count = count
                    .checked_add(read as u64)
                    .ok_or(Error::Limit("file byte count"))?;
                state.budget.bytes = state
                    .budget
                    .bytes
                    .checked_add(read as u64)
                    .ok_or(Error::Limit("total byte count"))?;
                if count > limits.max_file_bytes || state.budget.bytes > limits.max_total_bytes {
                    return Err(Error::Limit("output bytes"));
                }
                digest.update(&buffer[..read]);
                output.write_all(&buffer[..read]).map_err(io)?;
            }
            if count != before.len()
                || signature(&before) != signature(&input.metadata().map_err(io)?)
            {
                return Err(Error::UnsafeTree("file changed while copying"));
            }
            output.sync_all().map_err(io)?;
            state.manifest.insert(
                relative,
                EntryRecord::File(FileRecord {
                    bytes: count,
                    sha256: format!("{:x}", digest.finalize()),
                }),
            );
        }
    }
    if signature(&before) != signature(&source.metadata().map_err(io)?) {
        return Err(Error::UnsafeTree("directory changed while copying"));
    }
    directory(target)?.sync_all().map_err(io)?;
    Ok(())
}
pub(crate) fn sealed_copy(
    source: &File,
    target: &Path,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Manifest, Error> {
    fs::DirBuilder::new().create(target).map_err(io)?;
    let mut state = CopyState {
        budget: Budget {
            entries: 0,
            bytes: 0,
        },
        manifest: Manifest::new(),
        device: source.metadata().map_err(io)?.dev(),
    };
    copy_tree(source, target, Path::new(""), limits, cancel, &mut state, 0)?;
    Ok(state.manifest)
}
/// Kontrolliert die private Kopie erneut, ohne fremde Pfade als Quelle zu benutzen.
pub(crate) fn verify_tree(
    source: &File,
    limits: Limits,
    cancel: &Cancellation,
) -> Result<Manifest, Error> {
    fn walk(
        source: &File,
        prefix: &Path,
        limits: Limits,
        cancel: &Cancellation,
        budget: &mut Budget,
        manifest: &mut Manifest,
        depth: usize,
    ) -> Result<(), Error> {
        crate::check_cancel(cancel)?;
        if depth > limits.max_depth {
            return Err(Error::Limit("directory depth"));
        }
        let before = source.metadata().map_err(io)?;
        for name in names(source, limits.max_entries.saturating_sub(budget.entries))? {
            budget.entries += 1;
            let relative = prefix.join(&name);
            let path = c_name(&name)?;
            let mut info: libc::stat = unsafe { std::mem::zeroed() };
            if unsafe {
                libc::fstatat(
                    source.as_raw_fd(),
                    path.as_ptr(),
                    &mut info,
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } != 0
            {
                return Err(io(std::io::Error::last_os_error()));
            }
            if info.st_mode & libc::S_IFMT == libc::S_IFDIR {
                let opened = child(source, &name, true)?;
                if opened.metadata().map_err(io)?.dev() != before.dev() {
                    return Err(Error::UnsafeTree(
                        "private directory crosses filesystem boundary",
                    ));
                }
                manifest.insert(relative.clone(), EntryRecord::Directory);
                walk(
                    &opened,
                    &relative,
                    limits,
                    cancel,
                    budget,
                    manifest,
                    depth + 1,
                )?;
            } else {
                let mut file = child(source, &name, false)?;
                let file_info = file.metadata().map_err(io)?;
                if file_info.dev() != before.dev() {
                    return Err(Error::UnsafeTree(
                        "private file crosses filesystem boundary",
                    ));
                }
                let before = file_info;
                if before.len() > limits.max_file_bytes {
                    return Err(Error::Limit("file size"));
                }
                let mut hash = Sha256::new();
                let mut count = 0u64;
                let mut buffer = [0u8; 65536];
                loop {
                    crate::check_cancel(cancel)?;
                    let read = file.read(&mut buffer).map_err(io)?;
                    if read == 0 {
                        break;
                    }
                    count += read as u64;
                    budget.bytes = budget
                        .bytes
                        .checked_add(read as u64)
                        .ok_or(Error::Limit("output bytes"))?;
                    if count > limits.max_file_bytes || budget.bytes > limits.max_total_bytes {
                        return Err(Error::Limit("output bytes"));
                    }
                    hash.update(&buffer[..read]);
                }
                if count != before.len()
                    || signature(&before) != signature(&file.metadata().map_err(io)?)
                {
                    return Err(Error::UnsafeTree("private copy changed"));
                }
                manifest.insert(
                    relative,
                    EntryRecord::File(FileRecord {
                        bytes: count,
                        sha256: format!("{:x}", hash.finalize()),
                    }),
                );
            }
        }
        if signature(&before) != signature(&source.metadata().map_err(io)?) {
            return Err(Error::UnsafeTree("private directory changed"));
        }
        Ok(())
    }
    let mut manifest = Manifest::new();
    walk(
        source,
        Path::new(""),
        limits,
        cancel,
        &mut Budget {
            entries: 0,
            bytes: 0,
        },
        &mut manifest,
        0,
    )?;
    Ok(manifest)
}
pub(crate) fn rename_no_replace(
    source_parent: &File,
    source: &str,
    destination_parent: &File,
    name: &str,
) -> Result<bool, Error> {
    let source = CString::new(source).map_err(|_| Error::UnsafeTree("invalid adoption source"))?;
    let name = CString::new(name).map_err(|_| Error::UnsafeTree("invalid adoption target"))?;
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            source_parent.as_raw_fd(),
            source.as_ptr(),
            destination_parent.as_raw_fd(),
            name.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(true)
    } else {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EEXIST) {
            Ok(false)
        } else {
            Err(io(error))
        }
    }
}

pub(crate) fn read_text(
    root: &File,
    relative: &Path,
    max_bytes: u64,
    cancel: &Cancellation,
) -> Result<String, Error> {
    safe_relative(relative)?;
    let components: Vec<_> = relative.components().collect();
    let mut parent = root.try_clone().map_err(io)?;
    for component in &components[..components.len() - 1] {
        parent = child(&parent, Path::new(component.as_os_str()), true)?;
    }
    let mut file = child(
        &parent,
        Path::new(components[components.len() - 1].as_os_str()),
        false,
    )?;
    let before = file.metadata().map_err(io)?;
    if before.len() > max_bytes {
        return Err(Error::Limit("Markdown bytes"));
    }
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 65536];
    loop {
        crate::check_cancel(cancel)?;
        let read = file.read(&mut buffer).map_err(io)?;
        if read == 0 {
            break;
        }
        if (bytes.len() as u64)
            .checked_add(read as u64)
            .filter(|n| *n <= max_bytes)
            .is_none()
        {
            return Err(Error::Limit("Markdown bytes"));
        }
        bytes.extend_from_slice(&buffer[..read]);
    }
    if signature(&before) != signature(&file.metadata().map_err(io)?)
        || bytes.len() as u64 != before.len()
    {
        return Err(Error::UnsafeTree("Markdown changed while reading"));
    }
    String::from_utf8(bytes).map_err(|_| Error::Protocol("Markdown is not UTF-8".into()))
}
