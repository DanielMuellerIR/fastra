use std::{
    ffi::CString,
    fs::File,
    os::fd::{AsRawFd, FromRawFd},
    os::unix::ffi::OsStrExt,
    path::Path,
};
pub fn open_path(path: &Path, directory: bool) -> Result<File, String> {
    fastra_io::check_runtime_path(path).map_err(|e| e.to_string())?;
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        return Err("Absolute source path required".into());
    }
    let mut current = File::open("/").map_err(|e| e.to_string())?;
    let parts: Vec<_> = path
        .components()
        .filter_map(|c| match c {
            std::path::Component::Normal(s) => Some(s),
            _ => None,
        })
        .collect();
    for (i, part) in parts.iter().enumerate() {
        let name = CString::new(part.as_bytes()).map_err(|_| "Invalid source path")?;
        let flags = libc::O_RDONLY
            | libc::O_CLOEXEC
            | libc::O_NOFOLLOW
            | libc::O_NONBLOCK
            | if directory || i + 1 < parts.len() {
                libc::O_DIRECTORY
            } else {
                0
            };
        // Gehaltene Eltern-Deskriptoren verhindern das Verfolgen ausgetauschter Symlinks.
        let fd = unsafe { libc::openat(current.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        current = unsafe { File::from_raw_fd(fd) };
    }
    fastra_io::check_runtime_file(&current).map_err(|e| e.to_string())?;
    Ok(current)
}
