//! Namensfester Kaltstartanker für die optionalen, explizit per ELF-Loader gestarteten CLIs.
use super::*;
use sha2::{Digest, Sha256};
fn regular(path: &Path, limit: u64, executable: bool) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| err())?;
    let m = file.metadata().map_err(|_| err())?;
    if !m.is_file() || m.len() > limit || (executable && m.mode() & 0o111 == 0) {
        return Err(err());
    }
    Ok(file)
}
fn digest(path: &Path) -> Result<String> {
    let mut file = regular(path, 128 * 1024 * 1024, true)?;
    let before = file.metadata().map_err(|_| err())?;
    let mut hash = Sha256::new();
    let mut block = [0u8; 65536];
    let mut total = 0u64;
    loop {
        let n = file.read(&mut block).map_err(|_| err())?;
        if n == 0 {
            break;
        }
        total += n as u64;
        if total > 128 * 1024 * 1024 {
            return Err(err());
        }
        hash.update(&block[..n]);
    }
    let after = file.metadata().map_err(|_| err())?;
    if total != before.len()
        || (
            before.dev(),
            before.ino(),
            before.len(),
            before.mtime(),
            before.mtime_nsec(),
            before.ctime(),
            before.ctime_nsec(),
        ) != (
            after.dev(),
            after.ino(),
            after.len(),
            after.mtime(),
            after.mtime_nsec(),
            after.ctime(),
            after.ctime_nsec(),
        )
    {
        return Err(err());
    }
    Ok(hash.finalize().iter().map(|b| format!("{b:02x}")).collect())
}
pub(super) fn launcher(expected_name: &str) -> Result<PathBuf> {
    if !matches!(expected_name, "fastra-control" | "fastra-diff") {
        return Err(err());
    }
    // current_exe zeigt beim expliziten Host-ELFloader auf den Loader, nicht auf die CLI.
    let arg0 = std::env::args_os().next().ok_or_else(err)?;
    let arg0 = PathBuf::from(arg0);
    if !arg0.is_absolute() {
        return Err(err());
    }
    let cli = std::fs::canonicalize(arg0).map_err(|_| err())?;
    if cli.file_name() != Some(std::ffi::OsStr::new(expected_name)) {
        return Err(err());
    }
    let libexec = cli.parent().ok_or_else(err)?;
    let app = libexec.parent().ok_or_else(err)?;
    let root = app.parent().ok_or_else(err)?;
    if libexec.file_name() != Some(std::ffi::OsStr::new("libexec"))
        || app.file_name() != Some(std::ffi::OsStr::new("app"))
    {
        return Err(err());
    }
    let mut file = regular(&root.join("native-package.json"), 8 * 1024 * 1024, false)?;
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take(8 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| err())?;
    if bytes.len() > 8 * 1024 * 1024 {
        return Err(err());
    }
    let value: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| err())?;
    if value["format"].as_u64() != Some(1)
        || value["kind"].as_str() != Some("fastra-optional-native-package")
    {
        return Err(err());
    }
    let launcher = root.join("bin/fastra-native");
    for (name, path) in [
        (format!("app/libexec/{expected_name}"), cli),
        ("bin/fastra-native".into(), launcher.clone()),
    ] {
        let expected = value["sha256"][&name].as_str().ok_or_else(err)?;
        if expected.len() != 64
            || !expected.bytes().all(|b| b.is_ascii_hexdigit())
            || digest(&path)? != expected.to_ascii_lowercase()
        {
            return Err(err());
        }
    }
    Ok(launcher)
}
