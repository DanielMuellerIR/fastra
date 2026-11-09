//! Optionaler reiner Leseadapter. Die App spricht nur über Pipes mit dem vollständig isolierten Worker.
use fastra_core::Cancellation;
use fastra_process::{self as process, Environment, Policy};
use serde::{Deserialize, Serialize};
use std::{
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};
mod source;
mod worker;
pub use source::SourceIndex;
pub const MAX_SOURCE: usize = 1024 * 1024;
const MAX_JSON: usize = 8 * 1024 * 1024;
const MAX_OUTPUT: usize = 1024 * 1024;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    Cancelled,
    Unavailable,
    Layout,
    Source,
    Stale,
    Limit,
    Protocol,
    NoDiagnostics,
    Isolation,
    Process,
    Io,
    Panic,
    Busy,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Error {
    pub kind: ErrorKind,
    pub detail: String,
}
type Result<T> = std::result::Result<T, Error>;
fn error(kind: ErrorKind, detail: impl Into<String>) -> Error {
    Error {
        kind,
        detail: detail.into(),
    }
}
fn io_error(e: impl std::fmt::Display) -> Error {
    error(ErrorKind::Io, e.to_string())
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.detail)
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Position {
    pub line: u32,
    pub character: u32,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Range {
    pub start: Position,
    pub end: Position,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Diagnostic {
    pub range: Range,
    pub severity: u8,
    pub message: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Signature {
    pub label: String,
    pub documentation: String,
    pub active_parameter: Option<usize>,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Diagnostics,
    Signature,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    runtime: RuntimeProofs,
    root_identity: (u64, u64),
    source_identity: (u64, u64),
    source_bytes: usize,
    source_hash: [u8; 32],
    token: String,
    parent_net: String,
    source: String,
    relative: String,
    operation: Operation,
    cursor: Option<Position>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Response {
    pub token: String,
    pub server: String,
    pub cleanup_forced: bool,
    pub diagnostics: Vec<Diagnostic>,
    pub signatures: Vec<Signature>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    result: std::result::Result<Response, Error>,
}
fn check(cancel: &Cancellation) -> Result<()> {
    cancel
        .check()
        .map_err(|_| error(ErrorKind::Cancelled, "Cancelled"))
}
fn process_error(e: process::Error) -> Error {
    match e {
        process::Error::Cancelled(_) => error(ErrorKind::Cancelled, "Cancelled"),
        process::Error::TimedOut(_) => error(ErrorKind::Limit, "Runtime deadline: 25 s"),
        process::Error::OutputLimit(_) => error(ErrorKind::Limit, "Runtime output limit"),
        process::Error::Unavailable => error(ErrorKind::Unavailable, "prlimit/bwrap missing"),
        process::Error::Capture { message, .. } => error(ErrorKind::Process, message),
        other => error(ErrorKind::Process, other.to_string()),
    }
}
fn text(bytes: &[u8]) -> String {
    let decoded = match std::str::from_utf8(bytes) {
        Ok(s) => s.to_owned(),
        Err(_) => bytes
            .iter()
            .flat_map(|b| std::ascii::escape_default(*b))
            .map(char::from)
            .collect(),
    };
    let mut result: String = decoded
        .chars()
        .take(4096)
        .flat_map(|c| {
            if c == '\n' || c == '\t' || !c.is_control() {
                vec![c]
            } else {
                c.escape_default().collect()
            }
        })
        .collect();
    if decoded.chars().count() > 4096 {
        result.push_str("\n[… runtime output shortened …]");
    }
    result
}

pub fn discover() -> Option<PathBuf> {
    if process::host::is_active().unwrap_or(true) {
        return ["tool4d", "/opt/tool4d/tool4d"]
            .into_iter()
            .find_map(|name| {
                process::host::resolve_program(std::ffi::OsStr::new(name))
                    .ok()
                    .flatten()
            });
    }
    let candidates = std::env::var_os("PATH")
        .map(|p| {
            std::env::split_paths(&p)
                .take(128)
                .map(|p| p.join("tool4d"))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    candidates
        .into_iter()
        .chain([PathBuf::from("/opt/tool4d/tool4d")])
        .find_map(|p| p.is_file().then(|| p.canonicalize().ok()).flatten())
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct RuntimeProof {
    device: u64,
    inode: u64,
    mode: u32,
    bytes: u64,
    ctime: i64,
    ctime_ns: i64,
}
impl RuntimeProof {
    fn of(file: &fs::File, directory: bool) -> Result<Self> {
        use std::os::unix::fs::MetadataExt;
        let meta = file.metadata().map_err(io_error)?;
        let correct_type = if directory {
            meta.is_dir()
        } else {
            meta.is_file()
        };
        if !correct_type {
            return Err(error(
                ErrorKind::Layout,
                "Runtime binding has wrong file type",
            ));
        }
        Ok(Self {
            device: meta.dev(),
            inode: meta.ino(),
            mode: meta.mode(),
            bytes: meta.len(),
            ctime: meta.ctime(),
            ctime_ns: meta.ctime_nsec(),
        })
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RuntimeProofs {
    executable: RuntimeProof,
    resources: RuntimeProof,
    lib: Option<RuntimeProof>,
}
pub(crate) struct RuntimeBinding {
    pub(crate) path: PathBuf,
    _file: fs::File,
    proof: RuntimeProof,
}
fn runtime_open_at(
    parent: &fs::File,
    name: &std::ffi::OsStr,
    directory: bool,
) -> std::io::Result<fs::File> {
    use std::os::{
        fd::{AsRawFd, FromRawFd},
        unix::ffi::OsStrExt,
    };
    let name = std::ffi::CString::new(name.as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let flags = libc::O_RDONLY
        | libc::O_NOFOLLOW
        | libc::O_NONBLOCK
        | libc::O_CLOEXEC
        | if directory { libc::O_DIRECTORY } else { 0 };
    let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(unsafe { fs::File::from_raw_fd(fd) })
    }
}
fn runtime_binding(
    parent: &fs::File,
    parent_path: &Path,
    name: &std::ffi::OsStr,
    directory: bool,
) -> Result<RuntimeBinding> {
    let file = runtime_open_at(parent, name, directory).map_err(io_error)?;
    let proof = RuntimeProof::of(&file, directory)?;
    Ok(RuntimeBinding {
        path: parent_path.join(name),
        _file: file,
        proof,
    })
}
pub(crate) struct Runtime {
    pub(crate) executable: RuntimeBinding,
    pub(crate) resources: RuntimeBinding,
    pub(crate) lib: Option<RuntimeBinding>,
    _parent: fs::File,
}
impl Runtime {
    pub(crate) fn proofs(&self) -> RuntimeProofs {
        RuntimeProofs {
            executable: self.executable.proof.clone(),
            resources: self.resources.proof.clone(),
            lib: self.lib.as_ref().map(|binding| binding.proof.clone()),
        }
    }
}
pub(crate) fn runtime(path: &Path) -> Result<Runtime> {
    use std::os::unix::fs::OpenOptionsExt;
    let executable = path.canonicalize().map_err(io_error)?;
    let parent_path = executable
        .parent()
        .ok_or_else(|| error(ErrorKind::Layout, "Runtime parent missing"))?;
    let parent = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_DIRECTORY)
        .open(parent_path)
        .map_err(io_error)?;
    let executable = runtime_binding(
        &parent,
        parent_path,
        executable
            .file_name()
            .ok_or_else(|| error(ErrorKind::Layout, "Runtime executable name"))?,
        false,
    )?;
    let resources = runtime_binding(
        &parent,
        parent_path,
        std::ffi::OsStr::new("Resources"),
        true,
    )?;
    let lib = match runtime_open_at(&parent, std::ffi::OsStr::new("lib"), true) {
        Ok(file) => {
            let proof = RuntimeProof::of(&file, true)?;
            Some(RuntimeBinding {
                path: parent_path.join("lib"),
                _file: file,
                proof,
            })
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(io_error(e)),
    };
    Ok(Runtime {
        executable,
        resources,
        lib,
        _parent: parent,
    })
}
// Die App lädt vor dieser Prüfung ausschließlich eigene Bibliotheken aus /app/lib.
// Gehaltene Deskriptoren verhindern eine Wiederverwendung freigegebener Inodes.
pub(crate) fn verify_runtime_mounts(base: &Path, proofs: &RuntimeProofs) -> Result<Vec<fs::File>> {
    use std::os::unix::fs::OpenOptionsExt;
    let parent = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_DIRECTORY)
        .open(base)
        .map_err(io_error)?;
    let mut held = Vec::new();
    for (name, directory, expected) in [
        ("tool4d", false, Some(&proofs.executable)),
        ("Resources", true, Some(&proofs.resources)),
        ("lib", true, proofs.lib.as_ref()),
    ] {
        match (
            runtime_open_at(&parent, std::ffi::OsStr::new(name), directory),
            expected,
        ) {
            (Err(e), None) if e.kind() == std::io::ErrorKind::NotFound => {}
            (Ok(file), Some(expected)) if RuntimeProof::of(&file, directory)? == *expected => {
                held.push(file)
            }
            _ => {
                return Err(error(
                    ErrorKind::Stale,
                    format!("Mounted runtime binding changed: {name}"),
                ))
            }
        }
    }
    held.push(parent);
    Ok(held)
}
static ACTIVE: AtomicUsize = AtomicUsize::new(0);
struct Active;
impl Active {
    fn acquire() -> Result<Self> {
        let mut current = ACTIVE.load(Ordering::Acquire);
        loop {
            if current >= 2 {
                return Err(error(ErrorKind::Busy, "At most two runtime queries"));
            }
            match ACTIVE.compare_exchange_weak(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(value) => current = value,
            }
        }
        Ok(Self)
    }
}
impl Drop for Active {
    fn drop(&mut self) {
        ACTIVE.fetch_sub(1, Ordering::AcqRel);
    }
}
/// Nur auf einem Worker aufrufen. Der gespeicherte Snapshot wird niemals durch ungesehene Daten ersetzt.
pub struct Query<'a> {
    pub runtime_path: &'a Path,
    pub root: &'a Path,
    pub root_identity: (u64, u64),
    pub snapshot: &'a fastra_io::Snapshot,
    pub source: &'a str,
    pub operation: Operation,
    pub cursor: usize,
    pub token: String,
    pub cancel: &'a Cancellation,
    pub process_cancel: &'a process::Cancellation,
}
pub fn execute(query: Query<'_>) -> Result<Response> {
    let Query {
        runtime_path,
        root,
        root_identity,
        snapshot,
        source,
        operation,
        cursor,
        token,
        cancel,
        process_cancel,
    } = query;
    let _active = Active::acquire()?;
    check(cancel)?;
    if source.len() > MAX_SOURCE {
        return Err(error(ErrorKind::Limit, "Source: 1 MiB UTF-8"));
    }
    let index = SourceIndex::new(source, cancel)?;
    let path = snapshot.path();
    let relative = path.strip_prefix(root).map_err(|_| {
        error(
            ErrorKind::Source,
            "Document is outside the selected project",
        )
    })?;
    let relative = relative
        .to_str()
        .ok_or_else(|| error(ErrorKind::Source, "Method path must be UTF-8"))?
        .to_owned();
    validate_relative(&relative)?;
    if ![root.join("Project"), root.to_path_buf()]
        .iter()
        .any(|dir| {
            fs::read_dir(dir).ok().is_some_and(|entries| {
                entries
                    .take(256)
                    .filter_map(std::result::Result::ok)
                    .any(|e| e.path().extension().is_some_and(|e| e == "4DProject"))
            })
        })
    {
        return Err(error(
            ErrorKind::Source,
            "No project file in the selected workspace",
        ));
    }
    let verify = || -> Result<()> {
        check(cancel)?;
        let current = fastra_io::Snapshot::read_bounded(&path, snapshot.bytes().len(), cancel)
            .map_err(io_error)?;
        if current.binding_digest().map_err(io_error)?
            != snapshot.binding_digest().map_err(io_error)?
        {
            return Err(error(ErrorKind::Stale, "Saved source basis changed"));
        }
        Ok(())
    };
    verify()?;
    let runtime = runtime(runtime_path)?;
    let (app, app_lib) = crate::worker_layout().map_err(io_error)?;
    for name in [
        "libicuuc.so.78.3",
        "libicui18n.so.78.3",
        "libicudata.so.78.3",
    ] {
        if !app_lib.join(name).is_file() {
            return Err(error(
                ErrorKind::Layout,
                "Packaged application sibling lib/ with ICU 78.3 required",
            ));
        }
    }
    let directory = tempfile::Builder::new()
        .prefix("fastra-4d-")
        .tempdir()
        .map_err(io_error)?;
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };
    let passwd = directory.path().join("passwd");
    let group = directory.path().join("group");
    for (path, content) in [
        (
            &passwd,
            format!("fastra:x:{uid}:{gid}:Fastra:/home/fastra:/nonexistent\n"),
        ),
        (&group, format!("fastra:x:{gid}:\n")),
    ] {
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)
            .map_err(io_error)?
            .write_all(content.as_bytes())
            .map_err(io_error)?;
    }
    let mut args: Vec<OsString> = [
        "--as=2147483648",
        "--cpu=15",
        "--fsize=1048576",
        "--nofile=128",
        "--",
        "/usr/bin/bwrap",
        "--unshare-all",
        "--die-with-parent",
        "--new-session",
        "--cap-drop",
        "ALL",
        "--clearenv",
    ]
    .into_iter()
    .map(Into::into)
    .collect();
    for path in [
        "/usr/lib",
        "/usr/lib64",
        "/lib",
        "/lib64",
        "/etc/ld.so.cache",
        "/usr/share/zoneinfo",
    ] {
        if Path::new(path).exists() {
            args.extend(["--ro-bind".into(), path.into(), path.into()]);
        }
    }
    let bindings: [(&Path, &str); 7] = [
        (&app, "/app/libexec/fastra-linux"),
        (&app_lib, "/app/lib"),
        (&runtime.executable.path, "/runtime/tool4d"),
        (&runtime.resources.path, "/runtime/Resources"),
        (&passwd, "/etc/passwd"),
        (&group, "/etc/group"),
        (root, "/workspace"),
    ];
    for (from, to) in bindings {
        args.extend(["--ro-bind".into(), from.as_os_str().to_owned(), to.into()]);
    }
    if let Some(lib) = &runtime.lib {
        args.extend([
            "--ro-bind".into(),
            lib.path.as_os_str().to_owned(),
            "/runtime/lib".into(),
        ]);
    }
    args.extend(
        [
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--tmpfs",
            "/tmp",
            "--remount-ro",
            "/tmp",
            "--tmpfs",
            "/home/fastra",
            "--dir",
            "/home/fastra/.local/share/tool4d",
            "--remount-ro",
            "/home/fastra",
            "--setenv",
            "HOME",
            "/home/fastra",
            "--setenv",
            "LANG",
            "C.UTF-8",
            "--setenv",
            "LD_LIBRARY_PATH",
            "/app/lib",
            "--chdir",
            "/tmp",
            "--",
            "/app/libexec/fastra-linux",
            "--fastra-4d-worker",
        ]
        .into_iter()
        .map(Into::into),
    );
    use sha2::{Digest, Sha256};
    let original_id = snapshot.file_identity();
    let request = Request {
        runtime: runtime.proofs(),
        root_identity,
        source_identity: (original_id.device, original_id.inode),
        source_bytes: snapshot.bytes().len(),
        source_hash: Sha256::digest(snapshot.bytes()).into(),
        token: token.clone(),
        parent_net: fs::read_link("/proc/self/ns/net")
            .map_err(io_error)?
            .to_string_lossy()
            .into_owned(),
        source: source.into(),
        relative,
        operation,
        cursor: Some(index.position(cursor)?),
    };
    let input = serde_json::to_vec(&request).map_err(io_error)?;
    if input.len() > MAX_JSON {
        return Err(error(ErrorKind::Limit, "Input JSON: 8 MiB"));
    }
    check(cancel)?;
    let output = process::run_with_input(
        Path::new("/usr/bin/prlimit"),
        directory.path(),
        &args,
        &input,
        Policy {
            timeout: Duration::from_secs(25),
            termination_grace: Duration::from_millis(100),
            stdout_bytes: MAX_OUTPUT,
            stderr_bytes: 16 * 1024,
        },
        process_cancel,
        &Environment {
            remove_prefixes: vec!["LD_".into(), "GCONV_PATH".into()],
            set: Vec::new(),
        },
    )
    .map_err(process_error)?;
    check(cancel)?;
    if !output.success() {
        return Err(error(ErrorKind::Isolation, text(&output.stderr)));
    }
    let envelope: Envelope = serde_json::from_slice(&output.stdout).map_err(|_| {
        error(
            ErrorKind::Protocol,
            format!("Invalid worker response: {}", text(&output.stderr)),
        )
    })?;
    if envelope.version != 1 {
        return Err(error(ErrorKind::Protocol, "Worker protocol version"));
    }
    let response = envelope.result?;
    if response.token != token {
        return Err(error(ErrorKind::Protocol, "Foreign worker response"));
    }
    verify()?;
    Ok(response)
}
fn validate_relative(relative: &str) -> Result<()> {
    let path = Path::new(relative);
    if relative.len() > 4096
        || path.is_absolute()
        || path
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
        || !(path.starts_with("Project/Sources") || path.starts_with("Sources"))
    {
        return Err(error(
            ErrorKind::Source,
            "Method must be inside the project Sources folder",
        ));
    }
    if !path.extension().is_some_and(|e| {
        e.to_str()
            .is_some_and(|e| e.eq_ignore_ascii_case("4dm") || e.eq_ignore_ascii_case("4qs"))
    }) {
        return Err(error(ErrorKind::Source, "4dm/4qs source required"));
    }
    Ok(())
}
pub fn worker_entry() -> Option<i32> {
    if std::env::args_os().nth(1).as_deref() != Some(std::ffi::OsStr::new("--fastra-4d-worker")) {
        return None;
    }
    Some(worker::entry())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn relative_paths_never_escape_or_silently_change_format() {
        for path in [
            "/tmp/foreign.4dm",
            "Project/Sources/../foreign.4dm",
            "Project/Sources/Methods/x.txt",
            "outside/x.4dm",
        ] {
            assert!(validate_relative(path).is_err());
        }
        for path in [
            "Project/Sources/Methods/Méthode longue.4dm",
            "Sources/Classes/Customer.4dm",
        ] {
            validate_relative(path).unwrap();
        }
    }
    #[test]
    fn cancelled_and_excessive_sources_never_spawn() {
        let snapshot_root = tempfile::tempdir().unwrap();
        let source = snapshot_root.path().join("x.4dm");
        fs::write(&source, "source").unwrap();
        let cancel = Cancellation::default();
        let snapshot = fastra_io::Snapshot::read(&source, &cancel).unwrap();
        cancel.cancel();
        let result = execute(Query {
            runtime_path: Path::new("/missing"),
            root: snapshot_root.path(),
            root_identity: (0, 0),
            snapshot: &snapshot,
            source: "source",
            operation: Operation::Diagnostics,
            cursor: 0,
            token: "test".into(),
            cancel: &cancel,
            process_cancel: &process::Cancellation::default(),
        });
        assert!(matches!(result.unwrap_err().kind, ErrorKind::Cancelled));
        let fresh = Cancellation::default();
        let huge = "x".repeat(MAX_SOURCE + 1);
        let result = execute(Query {
            runtime_path: Path::new("/missing"),
            root: snapshot_root.path(),
            root_identity: (0, 0),
            snapshot: &snapshot,
            source: &huge,
            operation: Operation::Diagnostics,
            cursor: 0,
            token: "test".into(),
            cancel: &fresh,
            process_cancel: &process::Cancellation::default(),
        });
        assert!(matches!(result.unwrap_err().kind, ErrorKind::Limit));
    }
}

#[cfg(test)]
mod binding_tests {
    use super::*;
    use std::os::unix::fs::symlink;
    fn fixture(root: &Path, lib: bool) -> PathBuf {
        let base = root.join("runtime");
        fs::create_dir(&base).unwrap();
        fs::write(base.join("tool4d"), b"synthetic ELF placeholder").unwrap();
        fs::create_dir(base.join("Resources")).unwrap();
        if lib {
            fs::create_dir(base.join("lib")).unwrap();
        }
        base
    }
    #[test]
    fn held_runtime_bindings_reject_actual_path_swaps_and_wrong_types() {
        use std::os::unix::fs::MetadataExt;
        for name in ["tool4d", "Resources", "lib"] {
            for link in [false, true] {
                let temp = tempfile::tempdir().unwrap();
                let base = fixture(temp.path(), true);
                let approved = runtime(&base.join("tool4d")).unwrap();
                let proof = approved.proofs();
                assert_eq!(verify_runtime_mounts(&base, &proof).unwrap().len(), 4);
                let old = base.join(format!("{name}.held"));
                fs::rename(base.join(name), &old).unwrap();
                let foreign = temp.path().join("foreign");
                if name == "tool4d" {
                    fs::write(&foreign, b"foreign executable").unwrap();
                } else {
                    fs::create_dir(&foreign).unwrap();
                    fs::write(foreign.join("private"), b"never read").unwrap();
                }
                if link {
                    symlink(&foreign, base.join(name)).unwrap();
                } else if name == "tool4d" {
                    fs::write(base.join(name), b"replacement").unwrap();
                } else {
                    fs::create_dir(base.join(name)).unwrap();
                }
                let held = match name {
                    "tool4d" => &approved.executable,
                    "Resources" => &approved.resources,
                    _ => approved.lib.as_ref().unwrap(),
                };
                assert_eq!(
                    (
                        held._file.metadata().unwrap().dev(),
                        held._file.metadata().unwrap().ino()
                    ),
                    (held.proof.device, held.proof.inode)
                );
                assert!(
                    verify_runtime_mounts(&base, &proof).is_err(),
                    "{name} link={link}"
                );
            }
        }
    }
    #[test]
    fn absent_lib_is_absent_and_dangling_symlinks_are_never_missing() {
        let temp = tempfile::tempdir().unwrap();
        let base = fixture(temp.path(), false);
        let approved = runtime(&base.join("tool4d")).unwrap();
        assert!(approved.lib.is_none());
        assert_eq!(
            verify_runtime_mounts(&base, &approved.proofs())
                .unwrap()
                .len(),
            3
        );
        fs::create_dir(base.join("lib")).unwrap();
        assert!(verify_runtime_mounts(&base, &approved.proofs()).is_err());
        fs::remove_dir(base.join("lib")).unwrap();
        symlink(temp.path().join("missing"), base.join("lib")).unwrap();
        assert!(runtime(&base.join("tool4d")).is_err());
        assert!(verify_runtime_mounts(&base, &approved.proofs()).is_err());
    }
    #[test]
    fn mutations_and_fifo_are_controlled_before_any_runtime_launch() {
        let temp = tempfile::tempdir().unwrap();
        let base = fixture(temp.path(), true);
        let approved = runtime(&base.join("tool4d")).unwrap();
        fs::write(base.join("tool4d"), b"changed inode contents").unwrap();
        assert!(verify_runtime_mounts(&base, &approved.proofs()).is_err());
        fs::remove_file(base.join("tool4d")).unwrap();
        use std::os::unix::ffi::OsStrExt;
        let path = std::ffi::CString::new(base.join("tool4d").as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        assert!(runtime(&base.join("tool4d")).is_err());
    }
}
