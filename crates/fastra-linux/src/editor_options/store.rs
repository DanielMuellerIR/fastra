use serde::{Deserialize, Serialize};
use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
        },
    },
    path::Path,
};

#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Choices {
    version: u32,
    entries: Vec<Choice>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Choice {
    path: Vec<u8>,
    language: String,
}
const BUSY: &str = "Format store is busy; retry the choice";
pub(super) struct Store {
    dir: File,
}
fn name(value: &str) -> CString {
    CString::new(value).unwrap()
}
fn safe(file: &File, directory: bool) -> Result<(), String> {
    let m = file.metadata().map_err(|e| e.to_string())?;
    if m.uid() != unsafe { libc::geteuid() }
        || m.mode() & 0o077 != 0
        || if directory {
            !m.is_dir()
        } else {
            !m.is_file() || m.nlink() != 1
        }
    {
        return Err("Private format store has unsafe permissions or type".into());
    }
    Ok(())
}
impl Store {
    pub(super) fn open(root: &Path) -> Result<Self, String> {
        std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
        let path = root.join("fastra-editor");
        match std::fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(e) => return Err(e.to_string()),
        }
        let dir = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .map_err(|e| e.to_string())?;
        safe(&dir, true)?;
        Ok(Self { dir })
    }
    fn file(&self, path: &str, flags: i32) -> Result<File, std::io::Error> {
        let fd = unsafe {
            libc::openat(
                self.dir.as_raw_fd(),
                name(path).as_ptr(),
                flags | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
                0o600,
            )
        };
        if fd < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(unsafe { File::from_raw_fd(fd) })
        }
    }
    pub(super) fn lock(&self) -> Result<File, String> {
        let file = self
            .file(".lock", libc::O_RDWR | libc::O_CREAT)
            .map_err(|e| e.to_string())?;
        safe(&file, false)?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(BUSY.into());
        }
        self.lock_matches(&file)?;
        Ok(file)
    }
    pub(super) fn wait_lock(&self) -> Result<File, String> {
        for _ in 0..20 {
            match self.lock() {
                Err(error) if error == BUSY => {
                    std::thread::sleep(std::time::Duration::from_millis(10))
                }
                result => return result,
            }
        }
        self.lock()
    }
    fn lock_matches(&self, file: &File) -> Result<(), String> {
        safe(file, false)?;
        let held = file.metadata().map_err(|e| e.to_string())?;
        let current = self
            .file(".lock", libc::O_RDONLY)
            .map_err(|e| e.to_string())?;
        safe(&current, false)?;
        let current = current.metadata().map_err(|e| e.to_string())?;
        if held.dev() != current.dev() || held.ino() != current.ino() {
            return Err("Format store lock changed".into());
        }
        Ok(())
    }
    fn read(&self) -> Result<Choices, String> {
        let Some(bytes) = self.bytes("languages.json")? else {
            return Ok(Choices {
                version: 1,
                entries: Vec::new(),
            });
        };
        let choices: Choices = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        let mut paths = std::collections::HashSet::new();
        if choices.version != 1
            || choices.entries.len() > 300
            || choices.entries.iter().any(|e| {
                e.path.first() != Some(&b'/')
                    || e.path.len() > 4096
                    || e.path.contains(&0)
                    || e.language.len() > 128
                    || e.language.contains('\0')
                    || !paths.insert(e.path.clone())
            })
        {
            return Err("Invalid format store; existing data retained".into());
        }
        Ok(choices)
    }
}
pub(super) fn get(root: &Path, path: &Path) -> Result<Option<String>, String> {
    let store = Store::open(root)?;
    let _lock = store.wait_lock()?;
    Ok(store
        .read()?
        .entries
        .into_iter()
        .find(|e| e.path == path.as_os_str().as_bytes())
        .map(|e| e.language))
}
pub(super) fn set(root: &Path, path: &Path, language: Option<&str>) -> Result<(), String> {
    let store = Store::open(root)?;
    let _lock = store.wait_lock()?;
    let mut choices = store.read()?;
    let path = path.as_os_str().as_bytes();
    if !path.starts_with(b"/")
        || path.len() > 4096
        || path.contains(&0)
        || language.is_some_and(|s| s.len() > 128 || s.contains('\0'))
    {
        return Err("Invalid format choice".into());
    }
    choices.entries.retain(|entry| entry.path != path);
    if let Some(language) = language {
        choices.entries.insert(
            0,
            Choice {
                path: path.to_vec(),
                language: language.to_owned(),
            },
        );
    }
    choices.entries.truncate(300);
    let bytes = serde_json::to_vec(&choices).map_err(|e| e.to_string())?;
    if bytes.len() > 1024 * 1024 {
        return Err("Format store is too large".into());
    }
    store.write("languages.json", &bytes, &_lock)
}
impl Store {
    pub(super) fn bytes(&self, path: &str) -> Result<Option<Vec<u8>>, String> {
        let file = match self.file(path, libc::O_RDONLY) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.to_string()),
        };
        safe(&file, false)?;
        if file.metadata().map_err(|e| e.to_string())?.len() > 1024 * 1024 {
            return Err("Format store is too large".into());
        }
        let mut bytes = Vec::new();
        file.take(1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > 1024 * 1024 {
            return Err("Format store is too large".into());
        }
        Ok(Some(bytes))
    }
    pub(super) fn write(&self, destination: &str, bytes: &[u8], lock: &File) -> Result<(), String> {
        let id =
            std::fs::read_to_string("/proc/sys/kernel/random/uuid").map_err(|e| e.to_string())?;
        let temp = format!(".profile-{}", id.trim());
        let mut created = false;
        let result = (|| {
            let mut file = self
                .file(&temp, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL)
                .map_err(|e| e.to_string())?;
            created = true;
            file.write_all(bytes).map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            self.lock_matches(lock)?;
            if unsafe {
                libc::renameat(
                    self.dir.as_raw_fd(),
                    name(&temp).as_ptr(),
                    self.dir.as_raw_fd(),
                    name(destination).as_ptr(),
                )
            } != 0
            {
                return Err(std::io::Error::last_os_error().to_string());
            }
            self.dir.sync_all().map_err(|e| e.to_string())
        })();
        if result.is_err() && created {
            unsafe { libc::unlinkat(self.dir.as_raw_fd(), name(&temp).as_ptr(), 0) };
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::{ffi::OsStrExt, fs::symlink};
    #[test]
    fn fresh_mutations_preserve_other_windows_and_raw_paths() {
        let dir = tempfile::tempdir().unwrap();
        let a = Path::new(std::ffi::OsStr::from_bytes(b"/a-\xff"));
        set(dir.path(), a, Some("rust")).unwrap();
        set(dir.path(), Path::new("/b"), Some("")).unwrap();
        assert_eq!(get(dir.path(), a).unwrap().as_deref(), Some("rust"));
        assert_eq!(
            get(dir.path(), Path::new("/b")).unwrap().as_deref(),
            Some("")
        );
        set(dir.path(), a, None).unwrap();
        assert_eq!(get(dir.path(), a).unwrap(), None);
        assert_eq!(
            get(dir.path(), Path::new("/b")).unwrap().as_deref(),
            Some("")
        );
    }
    #[test]
    fn corrupt_symlink_and_locked_store_are_retained() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let path = dir.path().join("fastra-editor/languages.json");
        std::fs::write(&path, b"broken").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(set(dir.path(), Path::new("/a"), Some("rust")).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"broken");
        std::fs::remove_file(&path).unwrap();
        symlink("/no-such-target", &path).unwrap();
        assert!(get(dir.path(), Path::new("/a")).is_err());
        std::fs::remove_file(&path).unwrap();
        let _guard = store.lock().unwrap();
        assert!(set(dir.path(), Path::new("/a"), None).is_err());
        std::fs::remove_file(dir.path().join("fastra-editor/.lock")).unwrap();
        let replacement = store
            .file(".lock", libc::O_RDWR | libc::O_CREAT | libc::O_EXCL)
            .unwrap();
        assert!(store.lock_matches(&_guard).is_err());
        assert!(store.lock_matches(&replacement).is_ok());
    }
}
