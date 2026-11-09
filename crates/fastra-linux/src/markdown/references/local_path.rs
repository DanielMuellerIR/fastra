use fastra_core::Cancellation;
use std::{
    collections::VecDeque,
    ffi::{CString, OsString},
    fs,
    io::{self, Read},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::ffi::{OsStrExt, OsStringExt},
    },
    path::{Component, Path, PathBuf},
};
#[derive(Debug)]
pub(super) enum Error {
    NonLocal,
    InvalidTable,
    InvalidPath,
    Cancelled,
    Io(io::Error),
}
impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}
#[derive(Clone)]
struct Mount {
    path: PathBuf,
    local: bool,
}
pub(super) struct LocalPaths {
    mounts: Vec<Mount>,
}
fn local_filesystem(kind: &str) -> bool {
    matches!(
        kind,
        "ext2"
            | "ext3"
            | "ext4"
            | "btrfs"
            | "xfs"
            | "zfs"
            | "jfs"
            | "reiserfs"
            | "f2fs"
            | "nilfs2"
            | "tmpfs"
            | "ramfs"
            | "overlay"
            | "squashfs"
            | "erofs"
            | "vfat"
            | "msdos"
            | "exfat"
            | "ntfs"
            | "ntfs3"
            | "iso9660"
            | "udf"
    )
}
fn unescape(value: &[u8]) -> Result<PathBuf, Error> {
    let mut out = Vec::with_capacity(value.len());
    let mut at = 0;
    while at < value.len() {
        if value[at] == b'\\' {
            let code = value.get(at + 1..at + 4).ok_or(Error::InvalidTable)?;
            let byte = match code {
                b"040" => b' ',
                b"011" => b'\t',
                b"012" => b'\n',
                b"134" => b'\\',
                _ => return Err(Error::InvalidTable),
            };
            out.push(byte);
            at += 4;
        } else {
            out.push(value[at]);
            at += 1;
        }
    }
    let path = PathBuf::from(OsString::from_vec(out));
    if !path.is_absolute()
        || path.as_os_str().as_bytes().contains(&0)
        || path.components().any(|c| matches!(c, Component::ParentDir))
    {
        return Err(Error::InvalidTable);
    }
    Ok(path)
}
impl LocalPaths {
    pub fn current(cancel: &Cancellation) -> Result<Self, Error> {
        cancel.check().map_err(|_| Error::Cancelled)?;
        let mut bytes = Vec::new();
        fs::File::open("/proc/self/mountinfo")?
            .take(4 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > 4 * 1024 * 1024 {
            return Err(Error::InvalidTable);
        }
        Self::parse(&bytes, cancel)
    }
    fn parse(bytes: &[u8], cancel: &Cancellation) -> Result<Self, Error> {
        let mut mounts = Vec::new();
        for line in bytes.split(|b| *b == b'\n').filter(|line| !line.is_empty()) {
            cancel.check().map_err(|_| Error::Cancelled)?;
            let fields = line
                .split(|b| b.is_ascii_whitespace())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>();
            let delimiter = fields
                .iter()
                .position(|field| *field == b"-")
                .ok_or(Error::InvalidTable)?;
            if delimiter < 6 || fields.len() < delimiter + 4 || mounts.len() >= 65536 {
                return Err(Error::InvalidTable);
            }
            let path = unescape(fields[4])?;
            let kind =
                std::str::from_utf8(fields[delimiter + 1]).map_err(|_| Error::InvalidTable)?;
            mounts.push(Mount {
                path,
                local: local_filesystem(kind),
            });
        }
        if !mounts.iter().any(|mount| mount.path == Path::new("/")) {
            return Err(Error::InvalidTable);
        }
        Ok(Self { mounts })
    }
    fn is_local(&self, path: &Path) -> bool {
        let depth = self
            .mounts
            .iter()
            .filter(|mount| path.starts_with(&mount.path))
            .map(|mount| mount.path.as_os_str().len())
            .max();
        let Some(depth) = depth else {
            return false;
        };
        // Überlagerte Mounts gleicher Tiefe bleiben bei widersprüchlicher
        // Herkunft ungeprüft; die Reihenfolge der Kernelliste ist keine Freigabe.
        self.mounts
            .iter()
            .filter(|mount| path.starts_with(&mount.path) && mount.path.as_os_str().len() == depth)
            .all(|mount| mount.local)
    }
    fn open(&self, path: &Path, flags: i32, cancel: &Cancellation) -> Result<fs::File, Error> {
        if !path.is_absolute() {
            return Err(Error::InvalidPath);
        }
        if !self.is_local(Path::new("/")) {
            return Err(Error::NonLocal);
        }
        let mut file = fs::File::open("/")?;
        let parts = path
            .components()
            .filter(|c| !matches!(c, Component::RootDir))
            .collect::<Vec<_>>();
        let mut prefix = PathBuf::from("/");
        for (index, part) in parts.iter().enumerate() {
            cancel.check().map_err(|_| Error::Cancelled)?;
            let Component::Normal(name) = part else {
                return Err(Error::InvalidPath);
            };
            prefix.push(name);
            if !self.is_local(&prefix) {
                return Err(Error::NonLocal);
            }
            let name = CString::new(name.as_bytes()).map_err(|_| Error::InvalidPath)?;
            let access = if index + 1 == parts.len() {
                flags
            } else {
                libc::O_PATH | libc::O_DIRECTORY
            };
            let fd = unsafe {
                libc::openat(
                    file.as_raw_fd(),
                    name.as_ptr(),
                    access | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(Error::Io(io::Error::last_os_error()));
            }
            file = unsafe { fs::File::from_raw_fd(fd) };
        }
        fastra_io::check_runtime_file(&file).map_err(|_| Error::InvalidPath)?;
        Ok(file)
    }
    pub fn metadata(&self, path: &Path, cancel: &Cancellation) -> Result<fs::Metadata, Error> {
        Ok(self.open(path, libc::O_PATH, cancel)?.metadata()?)
    }
    pub fn directory(&self, path: &Path, cancel: &Cancellation) -> Result<fs::File, Error> {
        self.open(path, libc::O_RDONLY | libc::O_DIRECTORY, cancel)
    }
    pub fn resolve(&self, path: &Path, cancel: &Cancellation) -> Result<PathBuf, Error> {
        if !path.is_absolute() {
            return Err(Error::InvalidPath);
        }
        if !self.is_local(Path::new("/")) {
            return Err(Error::NonLocal);
        }
        let parts = |path: &Path| {
            path.components()
                .filter_map(|c| match c {
                    Component::Normal(name) => Some(name.to_os_string()),
                    Component::ParentDir => Some(OsString::from("..")),
                    Component::CurDir => Some(OsString::from(".")),
                    _ => None,
                })
                .collect::<VecDeque<_>>()
        };
        let mut pending = parts(path);
        let mut current = PathBuf::from("/");
        let mut links = 0;
        while let Some(component) = pending.pop_front() {
            cancel.check().map_err(|_| Error::Cancelled)?;
            if component == "." {
                continue;
            }
            if component == ".." {
                current.pop();
                if current.as_os_str().is_empty() {
                    current.push("/");
                }
                if !self.is_local(&current) {
                    return Err(Error::NonLocal);
                }
                continue;
            }
            let next = current.join(component);
            if next.as_os_str().len() > 4096 {
                return Err(Error::InvalidPath);
            }
            if !self.is_local(&next) {
                return Err(Error::NonLocal);
            }
            match fs::symlink_metadata(&next) {
                Ok(metadata) if metadata.file_type().is_symlink() => {
                    links += 1;
                    if links > 40 {
                        return Err(Error::Io(io::Error::from_raw_os_error(libc::ELOOP)));
                    }
                    let target = fs::read_link(&next)?;
                    if target.to_str().is_none() {
                        return Err(Error::InvalidPath);
                    }
                    if target.is_absolute() {
                        current = PathBuf::from("/");
                    }
                    let mut expanded = parts(&target);
                    expanded.append(&mut pending);
                    pending = expanded;
                }
                Ok(_) => current = next,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
                    ) =>
                {
                    current = next
                }
                Err(error) => return Err(Error::Io(error)),
            }
        }
        if !self.is_local(&current) {
            return Err(Error::NonLocal);
        }
        Ok(current)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    #[test]
    fn remote_root_is_rejected_even_without_path_components() {
        let c = Cancellation::default();
        let paths = LocalPaths {
            mounts: vec![Mount {
                path: PathBuf::from("/"),
                local: false,
            }],
        };
        assert!(matches!(
            paths.resolve(Path::new("/"), &c),
            Err(Error::NonLocal)
        ));
        assert!(matches!(
            paths.metadata(Path::new("/"), &c),
            Err(Error::NonLocal)
        ));
    }
    #[test]
    fn kernel_mount_fields_escaped_paths_and_remote_boundaries() {
        let table=b"1 0 8:1 / / rw shared:1 - ext4 /dev/root rw\n2 1 0:10 / /remote\\040space rw - nfs4 server:/share rw\n3 1 0:11 / /auto rw - autofs systemd rw\n";
        let paths = LocalPaths::parse(table, &Cancellation::default()).unwrap();
        assert!(paths.is_local(Path::new("/remote space-other/x")));
        for name in ["/remote space/x", "/auto/x"] {
            assert!(!paths.is_local(Path::new(name)));
        }
        assert!(matches!(
            LocalPaths::parse(b"broken\n", &Cancellation::default()),
            Err(Error::InvalidTable)
        ));
        assert!(matches!(
            LocalPaths::parse(
                b"1 0 8:1 / /bad\\000 rw - ext4 disk rw\n",
                &Cancellation::default()
            ),
            Err(Error::InvalidTable)
        ));
    }
    #[test]
    fn symlink_parent_and_unknown_mount_never_bypass_locality() {
        let root = tempfile::tempdir().unwrap();
        let base = root.path();
        fs::create_dir_all(base.join("sub/deep")).unwrap();
        fs::write(base.join("sub/target.md"), "physical").unwrap();
        fs::write(base.join("target.md"), "lexical").unwrap();
        symlink("sub/deep", base.join("link")).unwrap();
        let local = LocalPaths {
            mounts: vec![Mount {
                path: "/".into(),
                local: true,
            }],
        };
        let cancel = Cancellation::default();
        assert_eq!(
            local
                .resolve(&base.join("link/../target.md"), &cancel)
                .unwrap(),
            base.join("sub/target.md")
        );
        let missing = base.join("remote-not-present");
        symlink(&missing, base.join("remote-link")).unwrap();
        let guarded = LocalPaths {
            mounts: vec![
                Mount {
                    path: "/".into(),
                    local: true,
                },
                Mount {
                    path: missing,
                    local: false,
                },
            ],
        };
        assert!(matches!(
            guarded.resolve(&base.join("remote-link/missing.md"), &cancel),
            Err(Error::NonLocal)
        ));
        symlink("cycle", base.join("cycle")).unwrap();
        assert!(
            matches!(local.resolve(&base.join("cycle"),&cancel),Err(Error::Io(error)) if error.raw_os_error()==Some(libc::ELOOP))
        );
        assert_eq!(
            fs::read_to_string(base.join("sub/target.md")).unwrap(),
            "physical"
        );
    }
    #[test]
    fn stacked_unknown_mount_is_conservative_and_cancel_is_visible() {
        let table=b"1 0 8:1 / / rw - ext4 disk rw\n2 1 0:2 / /place rw - tmpfs tmpfs rw\n3 2 0:3 / /place rw - fuse.unknown source rw\n";
        let cancel = Cancellation::default();
        let paths = LocalPaths::parse(table, &cancel).unwrap();
        assert!(!paths.is_local(Path::new("/place/file")));
        cancel.cancel();
        assert!(matches!(
            paths.resolve(Path::new("/file"), &cancel),
            Err(Error::Cancelled)
        ));
        let actual = LocalPaths::current(&Cancellation::default()).unwrap();
        assert!(!actual.mounts.is_empty());
    }
}
