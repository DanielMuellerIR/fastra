//! Ausschließlich FD-relative Kopie; das gewählte Original wird weder eingebunden noch verändert.
use super::*;
use std::{
    ffi::OsStr,
    os::{
        fd::AsRawFd,
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        },
    },
};
const ENTRIES: usize = 16_384;
const TOTAL: u64 = 256 * 1024 * 1024;
const FILE: u64 = 32 * 1024 * 1024;
#[derive(Default)]
struct Budget {
    entries: usize,
    bytes: u64,
}
fn open_at(parent: &fs::File, name: &OsStr, directory: bool) -> Result<fs::File, String> {
    use std::os::fd::FromRawFd;
    let name = std::ffi::CString::new(name.as_bytes()).map_err(io)?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY
                | libc::O_NOFOLLOW
                | libc::O_NONBLOCK
                | libc::O_CLOEXEC
                | if directory { libc::O_DIRECTORY } else { 0 },
        )
    };
    if fd < 0 {
        Err(io(std::io::Error::last_os_error()))
    } else {
        Ok(unsafe { fs::File::from_raw_fd(fd) })
    }
}
fn fingerprint(meta: &fs::Metadata) -> (u64, u64, u64, i64, i64) {
    (
        meta.dev(),
        meta.ino(),
        meta.len(),
        meta.ctime(),
        meta.ctime_nsec(),
    )
}
fn walk(
    source: &fs::File,
    destination: &Path,
    depth: usize,
    budget: &mut Budget,
    cancel: &Cancellation,
) -> Result<(), String> {
    check(cancel)?;
    if depth > 32 {
        return Err("Engine copy depth limit: 32".into());
    }
    let before = source.metadata().map_err(io)?;
    let mut entries = fs::read_dir(format!("/proc/self/fd/{}", source.as_raw_fd())).map_err(io)?;
    loop {
        check(cancel)?;
        let Some(entry) = entries.next() else { break };
        budget.entries += 1;
        if budget.entries > ENTRIES {
            return Err("Engine copy entry limit: 16384; no partial run".into());
        }
        let name = entry.map_err(io)?.file_name();
        // Nutzerpräferenzen und VCS-Daten sind kein Enginecode. Insbesondere wird keine Watchdatei kopiert.
        if depth == 0 && (name.as_bytes().starts_with(b"userPreferences.") || name == ".git") {
            continue;
        }
        let item = open_at(source, &name, false)?;
        let meta = item.metadata().map_err(io)?;
        let dest = destination.join(&name);
        if meta.is_dir() {
            let directory = open_at(source, &name, true)?;
            if fingerprint(&directory.metadata().map_err(io)?) != fingerprint(&meta) {
                return Err("Engine directory replaced during copy".into());
            }
            fs::create_dir(&dest).map_err(io)?;
            fs::set_permissions(&dest, fs::Permissions::from_mode(0o700)).map_err(io)?;
            walk(&directory, &dest, depth + 1, budget, cancel)?;
        } else if meta.is_file() {
            if meta.len() > FILE || meta.len() > TOTAL.saturating_sub(budget.bytes) {
                return Err(
                    "Engine copy budget: 32 MiB per file, 256 MiB total; no partial run".into(),
                );
            }
            let mut output = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(if meta.mode() & 0o111 != 0 {
                    0o700
                } else {
                    0o600
                })
                .open(&dest)
                .map_err(io)?;
            let mut input = &item;
            let mut buffer = [0u8; 65536];
            let mut copied = 0u64;
            loop {
                check(cancel)?;
                let n = input.read(&mut buffer).map_err(io)?;
                if n == 0 {
                    break;
                }
                copied += n as u64;
                if copied > meta.len()
                    || copied > FILE
                    || copied > TOTAL.saturating_sub(budget.bytes)
                {
                    return Err("Engine file grew during copy; no partial run".into());
                }
                output.write_all(&buffer[..n]).map_err(io)?;
            }
            if copied != meta.len()
                || fingerprint(&item.metadata().map_err(io)?) != fingerprint(&meta)
            {
                return Err("Engine file changed during copy".into());
            }
            budget.bytes += copied;
        } else {
            return Err("Engine copy accepts only regular files and real directories; symlinks and special files are unsupported".into());
        }
    }
    if fingerprint(&source.metadata().map_err(io)?) != fingerprint(&before) {
        return Err("Engine directory changed during copy".into());
    }
    Ok(())
}
pub(super) fn copy(
    root: &Path,
    destination: &Path,
    cancel: &Cancellation,
) -> Result<PathBuf, String> {
    let source = crate::open_path(root, true)?;
    fs::create_dir(destination).map_err(io)?;
    fs::set_permissions(destination, fs::Permissions::from_mode(0o700)).map_err(io)?;
    walk(&source, destination, 0, &mut Budget::default(), cancel)?;
    let mut candidates = Vec::new();
    for parent in [destination.join("Project"), destination.to_path_buf()] {
        match fs::read_dir(&parent) {
            Ok(entries) => {
                for entry in entries {
                    let path = entry.map_err(io)?.path();
                    if path
                        .extension()
                        .is_some_and(|e| e.eq_ignore_ascii_case("4dproject"))
                        && fs::symlink_metadata(&path).is_ok_and(|m| m.is_file())
                    {
                        candidates.push(path);
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(io(e)),
        }
        if !candidates.is_empty() {
            break;
        }
    }
    if candidates.len() != 1 {
        return Err(
            "Choose an engine root containing exactly one .4DProject file in Project/ or its root"
                .into(),
        );
    }
    let project = candidates.pop().unwrap();
    let method = project
        .parent()
        .unwrap()
        .join("Sources/Methods/MacroRun.4dm");
    if !fs::symlink_metadata(method).is_ok_and(|m| m.is_file()) {
        return Err("The chosen engine project requires Sources/Methods/MacroRun.4dm".into());
    }
    project
        .strip_prefix(destination)
        .map(Path::to_path_buf)
        .map_err(io)
}
