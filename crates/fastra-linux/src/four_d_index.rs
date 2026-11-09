//! Expliziter, begrenzter Scan der bekannten 4D-Quellordner, ausschließlich auf Workern.
#[cfg(test)]
use std::ffi::CString;
use fastra_core::{
    four_d::{Analysis, Signature},
    Cancellation,
};
use std::{
    fs,
    os::fd::AsRawFd,
    io::Read,
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::{Path, PathBuf},
};
pub(super) type Identity = (u64, u64, i64, i64);
pub(super) struct Entry {
    pub name: String,
    pub key: String,
    pub path: PathBuf,
    pub signature: Signature,
    pub bytes: Vec<u8>,
    pub identity: Identity,
}
pub(super) struct Index {
    pub entries: Vec<Entry>,
    pub warnings: Vec<String>,
}
fn identity(m: &fs::Metadata) -> Identity {
    (m.dev(), m.ino(), m.mtime(), m.mtime_nsec())
}
pub(super) fn unchanged(entry: &Entry, cancel: &Cancellation) -> Result<(), String> {
    let (bytes, id) = read(&entry.path, cancel)?;
    if id != entry.identity || bytes != entry.bytes {
        return Err("Method source changed; refresh index".into());
    }
    Ok(())
}
pub(super) fn matches_loaded(entry: &Entry, loaded: &super::viewer::Loaded) -> bool {
    let (id, path, bytes) = match loaded {
        super::viewer::Loaded::Editor(super::loader::Loaded::Text { snapshot, .. }) => (snapshot.file_identity(), snapshot.path(), snapshot.bytes()),
        super::viewer::Loaded::Editor(super::loader::Loaded::ReadOnlyText(source)) => (source.snapshot().file_identity(), source.path().to_owned(), source.snapshot().bytes()),
        _ => return false,
    };
    (id.device, id.inode) == (entry.identity.0, entry.identity.1)
        && path == entry.path
        && bytes == entry.bytes
}
pub(super) use fastra_four_d_runtime::open_path;

fn read(path: &Path, cancel: &Cancellation) -> Result<(Vec<u8>, Identity), String> {
    read_bounded(path, 1024 * 1024, cancel)
}
pub(super) fn read_bounded(
    path: &Path,
    limit: usize,
    cancel: &Cancellation,
) -> Result<(Vec<u8>, Identity), String> {
    cancel.check().map_err(|e| e.to_string())?;
    let mut file = open_path(path, false)?;
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if !meta.is_file() || meta.len() > limit as u64 {
        return Err(format!("Regular file up to {limit} bytes required"));
    }
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 16384];
    loop {
        cancel.check().map_err(|e| e.to_string())?;
        let n = file.read(&mut chunk).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        if bytes.len() + n > limit {
            return Err(format!("File limit: {limit} bytes"));
        }
        bytes.extend_from_slice(&chunk[..n]);
    }
    let after = file.metadata().map_err(|e| e.to_string())?;
    let current = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !current.is_file()
        || identity(&meta) != identity(&after)
        || identity(&meta) != identity(&current)
        || meta.len() != bytes.len() as u64
    {
        return Err("Source changed during read".into());
    }
    Ok((bytes, identity(&meta)))
}
pub(super) fn scan(root: &Path, cancel: &Cancellation) -> Result<Index, String> {
    let mut index = Index {
        entries: Vec::new(),
        warnings: Vec::new(),
    };
    let mut aggregate = 0usize;
    let mut visited = 0usize;
    for relative in [
        "Project/Sources/Methods",
        "Sources/Methods",
        "Project/Sources/Classes",
        "Sources/Classes",
    ] {
        cancel.check().map_err(|e| e.to_string())?;
        let dir = root.join(relative);
        let mut at = root.to_path_buf();
        let mut missing = false;
        for component in Path::new(relative).components() {
            at.push(component);
            match fs::symlink_metadata(&at) {
                Ok(m) if m.is_dir() => {}
                Ok(_) => {
                    return Err(format!(
                        "Non-directory or symlink source folder: {}",
                        super::project_view::display(&at)
                    ))
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    missing = true;
                    break;
                }
                Err(e) => return Err(e.to_string()),
            }
        }
        if missing {
            continue;
        }
        let directory = open_path(&dir, true)?;
        let files = fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))
            .map_err(|e| e.to_string())?;
        for file in files {
            cancel.check().map_err(|e| e.to_string())?;
            visited += 1;
            if visited > 4000 {
                return Err("4D directory entry limit: 4000".into());
            }
            let path = dir.join(file.map_err(|e| e.to_string())?.file_name());
            if !path
                .extension()
                .is_some_and(|e| e.as_bytes().eq_ignore_ascii_case(b"4dm"))
            {
                continue;
            }
            if index.entries.len() >= 2000 {
                return Err("4D method limit: 2000".into());
            }
            let Some(name) = path.file_stem().and_then(|s| s.to_str()) else {
                index.warnings.push(format!(
                    "Non-UTF-8 method name: {}",
                    super::project_view::display(&path)
                ));
                continue;
            };
            if name.chars().any(char::is_control) {
                index.warnings.push(format!(
                    "Control character in method name: {}",
                    super::project_view::display(&path)
                ));
                continue;
            }
            let (bytes, id) = read(&path, cancel)
                .map_err(|e| format!("{}: {e}", super::project_view::display(&path)))?;
            aggregate += bytes.len();
            if aggregate > 16 * 1024 * 1024 {
                return Err("4D source aggregate limit: 16 MiB".into());
            }
            let source = std::str::from_utf8(&bytes).map_err(|_| {
                format!("Non-UTF-8 source: {}", super::project_view::display(&path))
            })?;
            let analysis = Analysis::build(source, cancel).map_err(|e| format!("{e:?}"))?;
            index.entries.push(Entry {
                name: name.into(),
                key: fastra_core::four_d::method_key(name),
                path,
                signature: analysis.signature,
                bytes,
                identity: id,
            });
        }
    }
    index
        .entries
        .sort_by(|a, b| a.key.cmp(&b.key).then(a.path.cmp(&b.path)));
    Ok(index)
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::{ffi::OsStringExt, fs::symlink};
    #[test]
    fn known_folders_raw_paths_signatures_and_stale_sources() {
        let t = tempfile::tempdir().unwrap();
        let root = t
            .path()
            .join(std::ffi::OsString::from_vec(b"root-\xff".to_vec()));
        let dir = root.join("Project/Sources/Methods");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("Gruß.4DM"),
            "// Header\r\n#DECLARE($name : Text)->$r : Boolean",
        )
        .unwrap();
        fs::write(dir.join("ignored.txt"), "text").unwrap();
        fs::write(
            dir.join(std::ffi::OsString::from_vec(b"raw-\xff.4dm".to_vec())),
            "#DECLARE()",
        )
        .unwrap();
        let c = Cancellation::default();
        let index = scan(&root, &c).unwrap();
        assert_eq!(index.entries.len(), 1);
        assert_eq!(index.warnings.len(), 1);
        assert_eq!(index.entries[0].signature.parameters[0].name, "$name");
        unchanged(&index.entries[0], &c).unwrap();
        fs::write(&index.entries[0].path, "changed").unwrap();
        assert!(unchanged(&index.entries[0], &c).is_err());
    }
    #[test]
    fn links_fifo_and_cancel_are_controlled() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        let dir = root.join("Sources/Methods");
        fs::create_dir_all(&dir).unwrap();
        let outside = root.join("outside");
        fs::write(&outside, "#DECLARE()").unwrap();
        symlink(&outside, dir.join("link.4dm")).unwrap();
        assert!(scan(root, &Cancellation::default()).is_err());
        fs::remove_file(dir.join("link.4dm")).unwrap();
        let fifo = CString::new(dir.join("pipe.4dm").as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        assert!(scan(root, &Cancellation::default()).is_err());
        fs::remove_file(dir.join("pipe.4dm")).unwrap();
        fs::rename(&dir, root.join("real")).unwrap();
        symlink(root.join("real"), &dir).unwrap();
        assert!(scan(root, &Cancellation::default()).is_err());
        let c = Cancellation::default();
        c.cancel();
        assert!(scan(root, &c).is_err());
    }
    #[test]
    fn oversized_method_fails_without_partial_index() {
        let t = tempfile::tempdir().unwrap();
        let dir = t.path().join("Sources/Methods");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("a.4dm"), "#DECLARE()").unwrap();
        fs::write(dir.join("b.4dm"), vec![b' '; 1024 * 1024 + 1]).unwrap();
        assert!(scan(t.path(), &Cancellation::default()).is_err());
    }
}
#[cfg(test)]
mod loaded_tests {
    use super::*;
    #[test]
    fn actual_loaded_snapshot_must_match_index_bytes_identity_and_path() {
        let t = tempfile::tempdir().unwrap();
        let dir = t.path().join("Sources/Methods");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("Method.4dm");
        fs::write(&path, "#DECLARE($a : Text)").unwrap();
        let index = scan(t.path(), &Cancellation::default()).unwrap();
        let loaded =
            super::super::viewer::Loaded::Editor(super::super::loader::read(&path).unwrap());
        assert!(matches_loaded(&index.entries[0], &loaded));
        fs::write(&path, "#DECLARE($b : Text)").unwrap();
        let loaded =
            super::super::viewer::Loaded::Editor(super::super::loader::read(&path).unwrap());
        assert!(!matches_loaded(&index.entries[0], &loaded));
        let other = dir.join("other");
        fs::write(&other, &index.entries[0].bytes).unwrap();
        fs::rename(&other, &path).unwrap();
        let loaded =
            super::super::viewer::Loaded::Editor(super::super::loader::read(&path).unwrap());
        assert!(!matches_loaded(&index.entries[0], &loaded));
    }
}
