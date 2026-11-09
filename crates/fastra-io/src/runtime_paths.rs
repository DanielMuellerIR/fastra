//! Die optionale ABI-Umgebung ersetzt vier Hostpfade. Dokument-IO darf diese
//! Ansicht nicht mit der unveränderten Dateisicht des Host-Git vermischen.
use serde::Deserialize;
use std::{
    ffi::OsStr,
    fs::{self, File, OpenOptions},
    io::{self, Read},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::{Component, Path, PathBuf},
    sync::OnceLock,
};

const MAX_MANIFEST: u64 = 16 * 1024;
const MAX_PATH: usize = 4096;
const EXPECTED: [(&str, Kind); 4] = [
    ("/lib64/ld-linux-x86-64.so.2", Kind::File),
    ("/usr/lib/x86_64-linux-gnu/webkitgtk-6.0", Kind::Directory),
    ("/usr/bin/bwrap", Kind::File),
    ("/usr/bin/xdg-dbus-proxy", Kind::File),
];
static POLICY: OnceLock<Result<Option<Policy>, String>> = OnceLock::new();

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum Kind {
    File,
    Directory,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    format: u32,
    scope: String,
    shadowed_paths: Vec<Entry>,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    path: PathBuf,
    canonical_target: PathBuf,
    kind: Kind,
}
#[derive(Debug)]
struct Policy {
    entries: Vec<Entry>,
}

fn denied(detail: impl std::fmt::Display) -> io::Error {
    // Zweisprachig, weil auch Hintergrundfehler ohne GUI-Lokalisierung entstehen.
    io::Error::new(io::ErrorKind::PermissionDenied, format!(
        "Die optionale Laufzeit überlagert diesen Dateipfad; Öffnen, Suchen und Speichern sind dort gesperrt. / The optional runtime shadows this file path; opening, searching and saving there are blocked. ({detail})"
    ))
}
fn invalid(detail: impl std::fmt::Display) -> String {
    format!("Die Dateipfad-Schutzdaten der optionalen Laufzeit fehlen oder sind ungültig. / Optional runtime file-path protection data is missing or invalid. ({detail})")
}
fn absolute_normal(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    path.is_absolute()
        && path.as_os_str().as_bytes().len() <= MAX_PATH
        && path
            .components()
            .all(|p| matches!(p, Component::RootDir | Component::Normal(_)))
        && !path.as_os_str().as_bytes().contains(&0)
}
impl Policy {
    fn parse(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > MAX_MANIFEST as usize {
            return Err(invalid("manifest limit"));
        }
        let manifest: Manifest = serde_json::from_slice(bytes).map_err(invalid)?;
        if manifest.format != 1
            || manifest.scope != "known-runtime-shadow-paths"
            || manifest.shadowed_paths.len() != EXPECTED.len()
        {
            return Err(invalid("manifest format/scope/count"));
        }
        for (path, kind) in EXPECTED {
            let matches: Vec<_> = manifest
                .shadowed_paths
                .iter()
                .filter(|e| e.path == Path::new(path))
                .collect();
            if matches.len() != 1 || matches[0].kind != kind {
                return Err(invalid("shadow path/kind"));
            }
        }
        for entry in &manifest.shadowed_paths {
            if !absolute_normal(&entry.path)
                || !absolute_normal(&entry.canonical_target)
                || entry.canonical_target == Path::new("/")
            {
                return Err(invalid("canonical target"));
            }
            let actual = fs::canonicalize(&entry.path).map_err(invalid)?;
            if actual != entry.canonical_target {
                return Err(invalid("canonical target mismatch"));
            }
            let meta = fs::metadata(&actual).map_err(invalid)?;
            if match entry.kind {
                Kind::File => !meta.is_file(),
                Kind::Directory => !meta.is_dir(),
            } {
                return Err(invalid("target kind mismatch"));
            }
        }
        Ok(Self {
            entries: manifest.shadowed_paths,
        })
    }
    fn check_absolute(&self, path: &Path) -> io::Result<()> {
        for entry in &self.entries {
            for shadow in [&entry.path, &entry.canonical_target] {
                if path == shadow || entry.kind == Kind::Directory && path.starts_with(shadow) {
                    return Err(denied(path.display()));
                }
            }
        }
        Ok(())
    }
    fn check(&self, path: &Path) -> io::Result<()> {
        self.check_depth(path, 0)
    }
    fn check_depth(&self, path: &Path, depth: usize) -> io::Result<()> {
        if depth > 32 {
            return Err(denied("symlink depth limit"));
        }
        use std::os::unix::ffi::OsStrExt;
        if path.as_os_str().as_bytes().len() > MAX_PATH {
            return Err(denied("path limit"));
        }
        let absolute = if path.is_absolute() {
            path.to_owned()
        } else {
            std::env::current_dir()?.join(path)
        };
        // Vor der Auflösung prüfen: Auch ein überlagerter Verzeichnisbestandteil
        // mit anschließendem `..` darf nicht unbemerkt gelesen werden.
        self.check_absolute(&absolute)?;
        let mut prefix = PathBuf::new();
        for (index, component) in absolute.components().enumerate() {
            if index > 128 {
                return Err(denied("path depth limit"));
            }
            prefix.push(component.as_os_str());
            self.check_absolute(&prefix)?;
            match fs::canonicalize(&prefix) {
                Ok(target) => self.check_absolute(&target)?,
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    // Auch ein noch nicht vorhandenes Ziel hinter einem Symlink
                    // kann in einem überlagerten Unterbaum liegen.
                    if let Ok(target) = fs::read_link(&prefix) {
                        let target = if target.is_absolute() {
                            target
                        } else {
                            prefix.parent().unwrap_or(Path::new("/")).join(target)
                        };
                        self.check_depth(&target, depth + 1)?;
                    }
                }
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
}
fn load() -> Result<Option<Policy>, String> {
    let marker = std::env::var_os("FASTRA_NATIVE_RUNTIME");
    let manifest = std::env::var_os("FASTRA_NATIVE_SHADOW_MANIFEST");
    if marker.is_none() && manifest.is_none() {
        return Ok(None);
    }
    if marker.as_deref() != Some(OsStr::new("1")) {
        return Err(invalid("activation marker"));
    }
    let path = PathBuf::from(manifest.ok_or_else(|| invalid("manifest missing"))?);
    if !absolute_normal(&path) {
        return Err(invalid("manifest path"));
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(invalid)?;
    let meta = file.metadata().map_err(invalid)?;
    if !meta.is_file() || meta.len() > MAX_MANIFEST {
        return Err(invalid("manifest type/limit"));
    }
    let mut bytes = Vec::new();
    file.take(MAX_MANIFEST + 1)
        .read_to_end(&mut bytes)
        .map_err(invalid)?;
    Policy::parse(&bytes).map(Some)
}
fn policy() -> io::Result<Option<&'static Policy>> {
    match POLICY.get_or_init(load) {
        Ok(value) => Ok(value.as_ref()),
        Err(message) => Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            message.clone(),
        )),
    }
}
/// Am GUI-Start aufrufen: Eine beschädigte optionale Umgebung startet nie ohne Schutz.
pub fn initialize_runtime_policy() -> io::Result<()> {
    policy().map(|_| ())
}
/// Prüft angeforderten Pfad, vorhandene Komponenten und deren Symlinkziele.
/// Ohne optionale Laufzeit bleibt das bisherige Verhalten vollständig erhalten.
pub fn check_runtime_path(path: &Path) -> io::Result<()> {
    if let Some(policy) = policy()? {
        policy.check(path)?;
    }
    Ok(())
}
/// Nach dem Open und vor dem ersten Lesen prüfen; deckt auch /proc/self/fd-Aliase ab.
pub fn check_runtime_file(file: &File) -> io::Result<()> {
    if let Some(policy) = policy()? {
        let target = fs::read_link(format!("/proc/self/fd/{}", file.as_raw_fd()))?;
        if !target.is_absolute() {
            return Err(denied("unresolved file descriptor"));
        }
        policy.check(&target)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    fn fixture() -> (tempfile::TempDir, Policy) {
        let temp = tempfile::tempdir().unwrap();
        fs::create_dir(temp.path().join("shadow-dir")).unwrap();
        fs::write(temp.path().join("shadow-file"), b"private").unwrap();
        fs::write(temp.path().join("allowed"), b"host").unwrap();
        let entries = [("shadow-dir", Kind::Directory), ("shadow-file", Kind::File)]
            .into_iter()
            .map(|(name, kind)| Entry {
                path: temp.path().join(name),
                canonical_target: temp.path().join(name),
                kind,
            })
            .collect();
        (temp, Policy { entries })
    }
    #[test]
    fn only_exact_files_and_component_directory_descendants_are_blocked() {
        let (root, policy) = fixture();
        assert!(policy.check(&root.path().join("shadow-file")).is_err());
        assert!(policy
            .check(&root.path().join("shadow-dir/new.txt"))
            .is_err());
        assert!(policy.check(&root.path().join("shadow-dir")).is_err());
        assert!(policy
            .check(&root.path().join("shadow-directory/allowed"))
            .is_ok());
        assert!(policy
            .check(&root.path().join("shadow-file-backup"))
            .is_ok());
        assert!(policy.check(root.path()).is_ok());
        assert!(policy.check(Path::new("/usr/include")).is_ok());
    }
    #[test]
    fn requested_path_and_separate_canonical_target_are_blocked() {
        let (root, mut policy) = fixture();
        policy.entries[1].canonical_target = root.path().join("allowed");
        assert!(policy.check(&root.path().join("shadow-file")).is_err());
        assert!(policy.check(&root.path().join("allowed")).is_err());
    }
    #[test]
    fn symlink_and_proc_fd_aliases_cannot_expose_shadow_files() {
        let (root, policy) = fixture();
        symlink(root.path().join("shadow-file"), root.path().join("alias")).unwrap();
        assert!(policy.check(&root.path().join("alias")).is_err());
        let file = File::open(root.path().join("shadow-file")).unwrap();
        let proc = PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd()));
        assert!(policy.check(&proc).is_err());
        let target = fs::read_link(proc).unwrap();
        assert!(policy.check(&target).is_err());
    }
    #[test]
    fn symlink_parent_and_dangling_symlink_cannot_publish_into_shadow_directory() {
        let (root, policy) = fixture();
        symlink(
            root.path().join("shadow-dir"),
            root.path().join("alias-dir"),
        )
        .unwrap();
        symlink(
            root.path().join("shadow-dir/missing"),
            root.path().join("dangling"),
        )
        .unwrap();
        assert!(policy
            .check(&root.path().join("alias-dir/new.txt"))
            .is_err());
        assert!(policy.check(&root.path().join("dangling/new.txt")).is_err());
        assert!(policy
            .check(&root.path().join("shadow-dir/../allowed"))
            .is_err());
    }
    #[test]
    fn malformed_or_incomplete_manifest_is_rejected() {
        for bytes in [
            b"{}".as_slice(),
            b"null",
            br#"{"format":1,"scope":"known-runtime-shadow-paths","shadowed_paths":[]}"#,
        ] {
            assert!(Policy::parse(bytes).is_err());
        }
        assert!(Policy::parse(&vec![b' '; MAX_MANIFEST as usize + 1]).is_err());
        let entries: Vec<_> = EXPECTED.iter().map(|(path, kind)| serde_json::json!({
            "path": path, "canonical_target": path, "kind": if *kind == Kind::File {"file"} else {"directory"}
        })).collect();
        let mut manifest = serde_json::json!({"format":1,"scope":"known-runtime-shadow-paths","shadowed_paths":entries});
        manifest["shadowed_paths"][0]["canonical_target"] = "/".into();
        assert!(Policy::parse(&serde_json::to_vec(&manifest).unwrap()).is_err());
        manifest["shadowed_paths"][0]["kind"] = "directory".into();
        assert!(Policy::parse(&serde_json::to_vec(&manifest).unwrap()).is_err());
    }
}
