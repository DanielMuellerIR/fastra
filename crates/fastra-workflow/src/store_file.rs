//! Gemeinsame private Byteablage; Formate und Validierung bleiben bei den Sammlungen.
use crate::{new_id, Error};
use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    },
    path::Path,
};
pub(crate) struct PrivateStore {
    dir: File,
    max_bytes: usize,
}
fn c(s: &str) -> CString {
    CString::new(s).expect("internal filename")
}
fn safe(file: &File, directory: bool) -> Result<(), Error> {
    let m = file.metadata()?;
    if (if directory {
        !m.is_dir()
    } else {
        !m.is_file() || m.nlink() != 1
    }) || m.uid() != unsafe { libc::geteuid() }
        || m.mode() & 0o077 != 0
    {
        return Err(Error::Invalid("private store permissions/type".into()));
    }
    Ok(())
}
impl PrivateStore {
    pub(crate) fn open(
        config_root: &Path,
        directory: &str,
        max_bytes: usize,
    ) -> Result<Self, Error> {
        std::fs::create_dir_all(config_root)?;
        let path = config_root.join(directory);
        match std::fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(e) => return Err(e.into()),
        }
        let dir = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        safe(&dir, true)?;
        Ok(Self { dir, max_bytes })
    }
    fn open_at(&self, name: &str, flags: i32) -> Result<File, Error> {
        let fd = unsafe {
            libc::openat(
                self.dir.as_raw_fd(),
                c(name).as_ptr(),
                flags | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    fn lock(&self) -> Result<File, Error> {
        let file = self.open_at(".lock", libc::O_CREAT | libc::O_RDWR | libc::O_NONBLOCK)?;
        safe(&file, false)?;
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                return Ok(file);
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(error.into());
            }
        }
    }
    fn bytes(&self) -> Result<Option<Vec<u8>>, Error> {
        let file = match self.open_at("library.json", libc::O_RDONLY | libc::O_NONBLOCK) {
            Ok(f) => f,
            Err(Error::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e),
        };
        safe(&file, false)?;
        if file.metadata()?.len() > self.max_bytes as u64 {
            return Err(Error::Limit);
        }
        let mut bytes = Vec::new();
        file.take(self.max_bytes as u64 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > self.max_bytes {
            return Err(Error::Limit);
        }
        Ok(Some(bytes))
    }
    pub(crate) fn load_bytes(&self) -> Result<Option<Vec<u8>>, Error> {
        let _lock = self.lock()?;
        self.bytes()
    }
    pub(crate) fn save_bytes(
        &self,
        expected: &Option<Vec<u8>>,
        bytes: &[u8],
        validate_current: impl FnOnce(Option<Vec<u8>>) -> Result<(), Error>,
    ) -> Result<(), Error> {
        if bytes.len() > self.max_bytes {
            return Err(Error::Limit);
        }
        let _lock = self.lock()?;
        let current = self.bytes()?;
        if &current != expected {
            return Err(Error::Stale);
        }
        validate_current(current)?;
        let temp = format!(".library-{}", new_id()?);
        let result = (|| {
            let mut file = self.open_at(&temp, libc::O_CREAT | libc::O_EXCL | libc::O_WRONLY)?;
            file.write_all(bytes)?;
            file.sync_all()?;
            if unsafe {
                libc::renameat(
                    self.dir.as_raw_fd(),
                    c(&temp).as_ptr(),
                    self.dir.as_raw_fd(),
                    c("library.json").as_ptr(),
                )
            } != 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            self.dir.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            unsafe { libc::unlinkat(self.dir.as_raw_fd(), c(&temp).as_ptr(), 0) };
        }
        result
    }
}
