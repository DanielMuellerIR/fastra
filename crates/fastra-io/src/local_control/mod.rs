//! Lokale Snapshotübernahme und benutzereigener Unixsocket; keine Arbeitsdateischreibbefehle.
pub mod transport;
use fastra_core::{
    encoding::{self, Encoding},
    local_control::*,
    Cancellation,
};
use sha2::{Digest, Sha256};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};
pub const NUL_MESSAGE: &str =
    "The source contains U+0000, which the Linux text view cannot display unchanged.";
fn nul_failure() -> Failure {
    Failure {
        code: "sourceUnavailable".into(),
        message: NUL_MESSAGE.into(),
        apple_script_number: -2700,
    }
}
pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
pub fn uuid() -> UUID {
    let mut b = [0u8; 16];
    File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut b))
        .expect("OS random source unavailable");
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    let h = b.iter().map(|v| format!("{v:02X}")).collect::<String>();
    UUID::parse(&format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    ))
    .unwrap()
}
pub fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn source<T>(_: T) -> Failure {
    Failure::new("sourceUnavailable")
}
fn check(cancel: &Cancellation) -> Result<()> {
    cancel.check().map_err(|_| Failure::new("interrupted"))
}
pub fn generation(m: &std::fs::Metadata) -> SourceGeneration {
    SourceGeneration {
        device: m.dev(),
        inode: m.ino(),
        size: m.size(),
        modification_seconds: m.mtime(),
        modification_nanoseconds: m.mtime_nsec(),
        change_seconds: m.ctime(),
        change_nanoseconds: m.ctime_nsec(),
    }
}
fn open(path: &Path) -> Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(source)
}
fn bounded(mut file: File, limit: usize, cancel: &Cancellation) -> Result<Vec<u8>> {
    check(cancel)?;
    let before = file.metadata().map_err(source)?;
    if !before.is_file() || before.len() > limit as u64 {
        return Err(source(()));
    }
    let mut bytes = Vec::with_capacity((before.len() as usize).min(limit));
    let mut block = [0u8; 16384];
    loop {
        check(cancel)?;
        let count = block.len().min(limit + 1 - bytes.len());
        let n = file.read(&mut block[..count]).map_err(source)?;
        if n == 0 {
            break;
        }
        bytes.extend_from_slice(&block[..n]);
        if bytes.len() > limit {
            return Err(source(()));
        }
    }
    if generation(&before) != generation(&file.metadata().map_err(source)?) {
        return Err(Failure::new("stale"));
    }
    Ok(bytes)
}
pub fn foundation_encoding(e: Encoding) -> u64 {
    match e {
        Encoding::Utf8 => 4,
        Encoding::Utf16Le => 0x94000100,
        Encoding::Utf16Be => 0x90000100,
        Encoding::Utf32Le => 0x9c000100,
        Encoding::Utf32Be => 0x98000100,
        Encoding::Windows1252 => 12,
        Encoding::Latin1 => 5,
        Encoding::MacRoman => 30,
    }
}
fn explicit(name: Option<&str>) -> Option<Encoding> {
    match name {
        Some("utf-8") => Some(Encoding::Utf8),
        Some("utf-16-le") => Some(Encoding::Utf16Le),
        Some("utf-16-be") => Some(Encoding::Utf16Be),
        Some("windows-1252") => Some(Encoding::Windows1252),
        Some("iso-8859-1") => Some(Encoding::Latin1),
        Some("mac-roman") => Some(Encoding::MacRoman),
        _ => None,
    }
}
#[derive(Clone, Debug)]
pub struct Loaded {
    pub name: String,
    pub text: Arc<str>,
    pub sha256: String,
    pub text_sha256: String,
    pub byte_count: usize,
    pub encoding: u64,
    pub bom_bytes: usize,
}
impl Loaded {
    pub fn from_bytes(
        bytes: &[u8],
        name: String,
        encoding: Option<&str>,
        selection: &Selection,
        cancel: &Cancellation,
    ) -> Result<Self> {
        check(cancel)?;
        let forced = explicit(encoding);
        let (_, detected) = encoding::detect_bom(bytes);
        if forced.is_some() && detected.is_some() && forced != detected {
            return Err(source(()));
        }
        let decoded = encoding::decode(bytes, forced).map_err(source)?;
        if decoded.text().contains('\0') {
            return Err(nul_failure());
        }
        selection.validate(decoded.text(), cancel)?;
        check(cancel)?;
        Ok(Self {
            name,
            text: Arc::from(decoded.text()),
            sha256: hash(bytes),
            text_sha256: hash(decoded.text().as_bytes()),
            byte_count: bytes.len(),
            encoding: foundation_encoding(decoded.encoding()),
            bom_bytes: decoded.bom().len(),
        })
    }
}
pub fn load(request: &Request, cancel: &Cancellation) -> Result<Loaded> {
    let path = Path::new(request.path.as_deref().ok_or_else(|| source(()))?);
    let bytes = bounded(open(path)?, MAX_SNAPSHOT, cancel)?;
    if Some(hash(&bytes)).as_ref() != request.sha256.as_ref() {
        return Err(Failure::new("stale"));
    }
    Loaded::from_bytes(
        &bytes,
        path.file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        request.text_encoding.as_deref(),
        &request.selection(),
        cancel,
    )
}
fn verify_outer(p: &Provenance, cancel: &Cancellation) -> Result<()> {
    check(cancel)?;
    let path = Path::new(&p.hit_identity.filesystem_path);
    let mut file = open(path)?;
    let before = file.metadata().map_err(source)?;
    if !before.is_file() {
        return Err(source(()));
    }
    if generation(&before) != p.source_generation {
        return Err(Failure::new("stale"));
    }
    if let Some(expected) = &p.outer_sha256 {
        if before.len() > MAX_OUTER as u64 {
            return Err(source(()));
        }
        let mut total = 0usize;
        let mut digest = Sha256::new();
        let mut block = [0u8; 16384];
        loop {
            check(cancel)?;
            let n = file.read(&mut block).map_err(source)?;
            if n == 0 {
                break;
            }
            total = total.checked_add(n).ok_or_else(|| source(()))?;
            if total > MAX_OUTER {
                return Err(source(()));
            }
            digest.update(&block[..n]);
        }
        if generation(&file.metadata().map_err(source)?) != p.source_generation
            || format!("{:x}", digest.finalize()) != *expected
        {
            return Err(Failure::new("stale"));
        }
    }
    Ok(())
}
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Marker {
    schema: u32,
    #[serde(rename = "ownerPID")]
    owner_pid: i32,
    identifier: UUID,
}
pub struct Adopted {
    pub loaded: Loaded,
    pub provenance: Provenance,
    directory: PathBuf,
}
impl Drop for Adopted {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
impl Adopted {
    pub fn adopt(request: &Request, temp_root: &Path, cancel: &Cancellation) -> Result<Self> {
        request.validate(now(), true)?;
        let p = request
            .provenance
            .clone()
            .ok_or_else(|| Failure::new("invalidRequest"))?;
        verify_outer(&p, cancel)?;
        let bytes = bounded(
            open(Path::new(request.path.as_deref().unwrap()))?,
            MAX_SNAPSHOT,
            cancel,
        )?;
        if Some(hash(&bytes)).as_ref() != request.sha256.as_ref() {
            return Err(Failure::new("stale"));
        }
        let name = p
            .hit_identity
            .archive_members
            .last()
            .cloned()
            .unwrap_or_else(|| {
                Path::new(&p.hit_identity.filesystem_path)
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned()
            });
        let loaded = Loaded::from_bytes(
            &bytes,
            name,
            request.text_encoding.as_deref(),
            &request.selection(),
            cancel,
        )?;
        let id = uuid();
        let directory = temp_root.join(format!("FastraSourceSnapshot-v1-{}", id.as_str()));
        let mut builder = std::fs::DirBuilder::new();
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700).create(&directory).map_err(source)?;
        let adopted = Self {
            loaded,
            provenance: p,
            directory,
        };
        let marker = serde_json::to_vec(&Marker {
            schema: 1,
            owner_pid: std::process::id() as i32,
            identifier: id,
        })
        .map_err(source)?;
        let write = |name: &str, bytes: &[u8], mode: u32| -> Result<()> {
            let mut f = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(mode)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(adopted.directory.join(name))
                .map_err(source)?;
            f.write_all(bytes).map_err(source)?;
            f.sync_all().map_err(source)
        };
        write("owner.json", &marker, 0o600)?;
        write("source.snapshot", &bytes, 0o400)?;
        // Die eigene Kopie wird erneut geladen: adopted bestätigt ihre unabhängige Lesbarkeit.
        let copy = bounded(
            open(&adopted.directory.join("source.snapshot"))?,
            MAX_SNAPSHOT,
            cancel,
        )?;
        if copy != bytes {
            return Err(Failure::new("stale"));
        }
        verify_outer(&adopted.provenance, cancel)?;
        check(cancel)?;
        Ok(adopted)
    }
    pub fn path(&self) -> PathBuf {
        self.directory.join("source.snapshot")
    }
}
pub fn prune_abandoned(root: &Path) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let Some(id) = name
            .strip_prefix("FastraSourceSnapshot-v1-")
            .and_then(UUID::parse)
        else {
            continue;
        };
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if !meta.is_dir() || meta.uid() != unsafe { libc::getuid() } {
            continue;
        }
        let marker_path = path.join("owner.json");
        let Ok(meta) = std::fs::symlink_metadata(&marker_path) else {
            continue;
        };
        if !meta.is_file() || meta.uid() != unsafe { libc::getuid() } || meta.len() > 4096 {
            continue;
        }
        let Ok(file) = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&marker_path)
        else {
            continue;
        };
        let Ok(raw) = bounded(file, 4096, &Cancellation::default()) else {
            continue;
        };
        let Ok(marker) = serde_json::from_slice::<Marker>(&raw) else {
            continue;
        };
        if marker.schema != 1 || marker.identifier != id || marker.owner_pid <= 0 {
            continue;
        }
        if unsafe { libc::kill(marker.owner_pid, 0) } == -1
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        {
            let _ = std::fs::remove_dir_all(path);
        }
    }
}

pub fn load_explanation(
    path: &Path,
    cancel: &Cancellation,
) -> Result<crate::code_explanation::Package> {
    use crate::code_explanation::Error as E;
    crate::code_explanation::Package::load_detailed(path, cancel).map_err(|error| {
        Failure::new(match error {
            E::HashMismatch => "stale",
            E::TotalLimit => "capacity",
            E::Cancelled => "interrupted",
            E::Json(_) => "invalidRequest",
            E::Model(fastra_core::code_explanation::Error::Invalid(
                "grapheme range" | "range overflow",
            )) => "invalidRange",
            E::Model(fastra_core::code_explanation::Error::Core(fastra_core::Error::Cancelled)) => {
                "interrupted"
            }
            E::Model(_) => "invalidRequest",
            E::Invalid(
                "manifest path" | "manifest parent" | "manifest name" | "source path"
                | "empty source path",
            ) => "invalidRequest",
            _ => "sourceUnavailable",
        })
    })
}
