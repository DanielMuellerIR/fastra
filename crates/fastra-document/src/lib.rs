//! Linux-Dokumentbasis; aufrufende Hosts führen synchrone Dateioperationen im Hintergrund aus.
#![cfg(target_os = "linux")]

use fastra_core::{
    encoding::{self, Decoded, Encoding, EncodingError, LineEnding},
    Cancellation,
};
use fastra_io::Snapshot;
use std::{
    fs::{self, File, Metadata, OpenOptions},
    io,
    ops::Range,
    os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};

mod readonly;
pub use readonly::ReadOnlyTextDocument;

pub const EDITABLE_BYTES: usize = 32 * 1024 * 1024;
pub const TEXT_SECTION_BYTES: usize = 64 * 1024;
pub const HEX_SECTION_BYTES: usize = 256 * 1024;
pub const CLASSIFICATION_BYTES: usize = 1024 * 1024;
const BINARY_PROBE_BYTES: usize = 8 * 1024;

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Snapshot(fastra_io::Error),
    Encoding(EncodingError),
    Cancelled,
    Stale,
    NotRegular,
    Limit,
    InvalidOffset,
    NotText,
}
impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<fastra_io::Error> for Error {
    fn from(e: fastra_io::Error) -> Self {
        match e {
            fastra_io::Error::Core(fastra_core::Error::Cancelled) => Self::Cancelled,
            other => Self::Snapshot(other),
        }
    }
}
impl From<EncodingError> for Error {
    fn from(e: EncodingError) -> Self {
        Self::Encoding(e)
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
type Result<T> = std::result::Result<T, Error>;
fn check(cancel: &Cancellation) -> Result<()> {
    cancel.check().map_err(|_| Error::Cancelled)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceIdentity {
    device: u64,
    inode: u64,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
    mode: u32,
    uid: u32,
    gid: u32,
}
impl SourceIdentity {
    fn from_metadata(meta: &Metadata) -> Self {
        Self {
            device: meta.dev(),
            inode: meta.ino(),
            size: meta.len(),
            modified: (meta.mtime(), meta.mtime_nsec()),
            changed: (meta.ctime(), meta.ctime_nsec()),
            mode: meta.mode(),
            uid: meta.uid(),
            gid: meta.gid(),
        }
    }
    pub fn size(&self) -> u64 {
        self.size
    }
    pub fn device(&self) -> u64 {
        self.device
    }
    pub fn inode(&self) -> u64 {
        self.inode
    }
}

#[derive(Debug)]
struct Source {
    file: File,
    requested: PathBuf,
    target: PathBuf,
    identity: SourceIdentity,
}
impl Source {
    fn open(path: &Path, cancel: &Cancellation) -> Result<Self> {
        check(cancel)?;
        fastra_io::check_runtime_path(path)?;
        let requested = if path.is_absolute() {
            path.to_owned()
        } else {
            std::env::current_dir()?.join(path)
        };
        let target = fs::canonicalize(&requested)?;
        // O_NONBLOCK verhindert schon beim Öffnen das Warten auf einen FIFO-Schreiber.
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&target)?;
        fastra_io::check_runtime_file(&file)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() {
            return Err(Error::NotRegular);
        }
        let source = Self {
            file,
            requested,
            target,
            identity: SourceIdentity::from_metadata(&metadata),
        };
        source.verify(cancel)?;
        Ok(source)
    }
    fn verify(&self, cancel: &Cancellation) -> Result<()> {
        check(cancel)?;
        fastra_io::check_runtime_path(&self.requested)?;
        fastra_io::check_runtime_file(&self.file)?;
        if SourceIdentity::from_metadata(&self.file.metadata()?) != self.identity
            || fs::canonicalize(&self.requested).map_err(|_| Error::Stale)? != self.target
            || SourceIdentity::from_metadata(&fs::metadata(&self.target).map_err(|_| Error::Stale)?)
                != self.identity
        {
            return Err(Error::Stale);
        }
        Ok(())
    }
    fn read(
        &self,
        offset: u64,
        length: usize,
        bound: usize,
        cancel: &Cancellation,
    ) -> Result<Vec<u8>> {
        if length > bound {
            return Err(Error::Limit);
        }
        if offset > self.identity.size {
            return Err(Error::InvalidOffset);
        }
        self.verify(cancel)?;
        let count = (self.identity.size - offset).min(length as u64) as usize;
        let mut bytes = vec![0; count];
        let mut done = 0;
        while done < count {
            check(cancel)?;
            let end = count.min(done + TEXT_SECTION_BYTES);
            let read = self
                .file
                .read_at(&mut bytes[done..end], offset + done as u64)?;
            if read == 0 {
                return Err(Error::Stale);
            }
            done += read;
        }
        self.verify(cancel)?;
        Ok(bytes)
    }
}

#[derive(Debug)]
pub struct TextDocument {
    decoded: Decoded,
    snapshot: Snapshot,
    source: Arc<Source>,
}
impl TextDocument {
    pub fn decoded(&self) -> &Decoded {
        &self.decoded
    }
    pub fn text(&self) -> &str {
        self.decoded.text()
    }
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }
    pub fn identity(&self) -> &SourceIdentity {
        &self.source.identity
    }
    pub fn path(&self) -> &Path {
        &self.source.target
    }
    pub fn line_ending(&self) -> LineEnding {
        LineEnding::detect(self.text())
    }
    pub fn encode(&self, text: &str) -> std::result::Result<Vec<u8>, EncodingError> {
        self.decoded.encode(text)
    }
    pub fn verify_current(&self, cancel: &Cancellation) -> Result<()> {
        self.source.verify(cancel)
    }
}

#[derive(Debug, Clone)]
pub struct SectionDocument {
    source: Arc<Source>,
    encoding: Option<Encoding>,
    bom: Vec<u8>,
    allow_nul: bool,
}
#[derive(Debug, PartialEq, Eq)]
pub struct TextSection {
    pub byte_range: Range<u64>,
    pub text: String,
    pub next_offset: u64,
}
#[derive(Debug, PartialEq, Eq)]
pub struct HexSection {
    pub byte_range: Range<u64>,
    pub bytes: Vec<u8>,
}
impl SectionDocument {
    pub fn identity(&self) -> &SourceIdentity {
        &self.source.identity
    }
    pub fn path(&self) -> &Path {
        &self.source.target
    }
    pub fn encoding(&self) -> Option<Encoding> {
        self.encoding
    }
    pub fn bom(&self) -> &[u8] {
        &self.bom
    }
    pub fn verify_current(&self, cancel: &Cancellation) -> Result<()> {
        self.source.verify(cancel)
    }
    pub fn read_hex(
        &self,
        offset: u64,
        length: usize,
        cancel: &Cancellation,
    ) -> Result<HexSection> {
        let bytes = self
            .source
            .read(offset, length, HEX_SECTION_BYTES, cancel)?;
        Ok(HexSection {
            byte_range: offset..offset + bytes.len() as u64,
            bytes,
        })
    }
    /// Der Start rückt höchstens drei Bytes zurück; next_offset setzt lückenlos fort.
    pub fn read_text(&self, offset: u64, cancel: &Cancellation) -> Result<TextSection> {
        let encoding = self.encoding.ok_or(Error::NotText)?;
        let size = self.source.identity.size;
        if offset > size {
            return Err(Error::InvalidOffset);
        }
        let wanted = offset.max(self.bom.len() as u64);
        if wanted == size {
            self.source.verify(cancel)?;
            return Ok(TextSection {
                byte_range: size..size,
                text: String::new(),
                next_offset: size,
            });
        }
        let width = match encoding {
            Encoding::Utf16Le | Encoding::Utf16Be => 2,
            Encoding::Utf32Le | Encoding::Utf32Be => 4,
            _ => 1,
        };
        let payload_offset = wanted - self.bom.len() as u64;
        let aligned = wanted - payload_offset % width;
        let start = aligned.saturating_sub(4).max(self.bom.len() as u64);
        let bytes = self.source.read(
            start,
            TEXT_SECTION_BYTES + 16,
            TEXT_SECTION_BYTES + 16,
            cancel,
        )?;
        let mut first = (aligned - start) as usize;
        if encoding == Encoding::Utf8 {
            let mut back = 0;
            while first > 0 && bytes[first] & 0xc0 == 0x80 && back < 3 {
                first -= 1;
                back += 1;
            }
        } else if width == 2 && first >= 2 && first + 2 <= bytes.len() {
            let unit = unit16(&bytes[first..first + 2], encoding);
            if (0xdc00..=0xdfff).contains(&unit) {
                first -= 2;
            }
        }
        let mut end = bytes.len().min(first + TEXT_SECTION_BYTES);
        if encoding == Encoding::Utf8 {
            let mut extra = 0;
            while end < bytes.len() && bytes[end] & 0xc0 == 0x80 && extra < 3 {
                end += 1;
                extra += 1;
            }
        } else if width == 2 {
            if end < bytes.len() {
                end -= (end - first) % 2;
            }
            if end >= first + 2
                && end + 2 <= bytes.len()
                && (0xd800..=0xdbff).contains(&unit16(&bytes[end - 2..end], encoding))
            {
                end += 2;
            }
        } else if width == 4 && end < bytes.len() {
            end -= (end - first) % 4;
        }
        if !self.allow_nul && bytes[first..end].contains(&0) {
            return Err(Error::Encoding(EncodingError::Binary));
        }
        let mut text = encoding::decode_payload(&bytes[first..end], encoding)?;
        // Ein Single-Byte-Abschnitt kann in UTF-8 dreimal so groß werden. Auch
        // die an den Editor übergebene Seite bleibt deshalb auf 64 KiB begrenzt.
        if text.len() > TEXT_SECTION_BYTES {
            let mut boundary = TEXT_SECTION_BYTES;
            while !text.is_char_boundary(boundary) {
                boundary -= 1;
            }
            text.truncate(boundary);
            let consumed = match encoding {
                Encoding::Utf8 => text.len(),
                Encoding::Utf16Le | Encoding::Utf16Be => text.encode_utf16().count() * 2,
                Encoding::Utf32Le | Encoding::Utf32Be => text.chars().count() * 4,
                _ => text.chars().count(),
            };
            end = first + consumed;
        }
        let absolute_start = start + first as u64;
        let next = start + end as u64;
        Ok(TextSection {
            byte_range: absolute_start..next,
            text,
            next_offset: next,
        })
    }
}
fn unit16(bytes: &[u8], encoding: Encoding) -> u16 {
    if encoding == Encoding::Utf16Le {
        u16::from_le_bytes([bytes[0], bytes[1]])
    } else {
        u16::from_be_bytes([bytes[0], bytes[1]])
    }
}

#[derive(Debug)]
pub enum Document {
    Text(TextDocument),
    ReadOnlyText(ReadOnlyTextDocument),
    Sections(SectionDocument),
    Hex(SectionDocument),
}
enum TextBasis {
    Writable(Snapshot),
    ReadOnly(fastra_io::ReadSnapshot),
}
impl TextBasis {
    fn bytes(&self) -> &[u8] {
        match self {
            Self::Writable(snapshot) => snapshot.bytes(),
            Self::ReadOnly(snapshot) => snapshot.bytes(),
        }
    }
    fn file_identity(&self) -> fastra_io::FileIdentity {
        match self {
            Self::Writable(snapshot) => snapshot.file_identity(),
            Self::ReadOnly(snapshot) => snapshot.file_identity(),
        }
    }
}
impl Document {
    pub fn open_hex(path: &Path, cancel: &Cancellation) -> Result<SectionDocument> {
        Ok(SectionDocument {
            source: Arc::new(Source::open(path, cancel)?),
            encoding: None,
            bom: Vec::new(),
            allow_nul: false,
        })
    }
    pub fn open(path: &Path, explicit: Option<Encoding>, cancel: &Cancellation) -> Result<Self> {
        let source = Arc::new(Source::open(path, cancel)?);
        if source.identity.size <= EDITABLE_BYTES as u64 {
            if explicit.is_none() {
                let probe = source.read(0, BINARY_PROBE_BYTES, BINARY_PROBE_BYTES, cancel)?;
                let (_, encoding) = encoding::detect_bom(&probe);
                if probe.contains(&0)
                    && !matches!(
                        encoding,
                        Some(
                            Encoding::Utf16Le
                                | Encoding::Utf16Be
                                | Encoding::Utf32Le
                                | Encoding::Utf32Be
                        )
                    )
                {
                    return Ok(Self::Hex(SectionDocument {
                        source,
                        encoding: None,
                        bom: Vec::new(),
                        allow_nul: false,
                    }));
                }
            }
            let snapshot = match Snapshot::read_bounded(&source.target, EDITABLE_BYTES, cancel) {
                Ok(snapshot) => TextBasis::Writable(snapshot),
                // Die Lesebasis wiederholt Datei- und Größenprüfung ohne Schreibmetadaten.
                // Auch deren eigenes Limit darf keine lesbare Datei sperren; Abbruch
                // und bereits als veraltet erkannte Quellen bleiben Fehler.
                Err(
                    fastra_io::Error::UnsupportedMetadata
                    | fastra_io::Error::UnsupportedFilesystem
                    | fastra_io::Error::Io(_)
                    | fastra_io::Error::Limit,
                ) => TextBasis::ReadOnly(fastra_io::ReadSnapshot::read_bounded(
                    &source.target,
                    EDITABLE_BYTES,
                    cancel,
                )?),
                Err(error) => return Err(error.into()),
            };
            if snapshot.bytes().len() as u64 != source.identity.size
                || snapshot.file_identity().device != source.identity.device
                || snapshot.file_identity().inode != source.identity.inode
            {
                return Err(Error::Stale);
            }
            // Gleicher Inhalt allein genügt nicht: Ein neuer Inode wäre eine andere Save-Basis.
            source.verify(cancel)?;
            match encoding::decode(snapshot.bytes(), explicit) {
                Ok(decoded) => {
                    if decoded.text().len() > EDITABLE_BYTES
                        || decoded
                            .text()
                            .split(['\r', '\n'])
                            .any(|line| line.len() > TEXT_SECTION_BYTES)
                    {
                        return Ok(Self::Sections(SectionDocument {
                            source,
                            encoding: Some(decoded.encoding()),
                            bom: decoded.bom().to_vec(),
                            allow_nul: explicit.is_some()
                                || matches!(
                                    decoded.encoding(),
                                    Encoding::Utf16Le
                                        | Encoding::Utf16Be
                                        | Encoding::Utf32Le
                                        | Encoding::Utf32Be
                                ),
                        }));
                    }
                    Ok(match snapshot {
                        TextBasis::Writable(snapshot) => Self::Text(TextDocument {
                            decoded,
                            snapshot,
                            source,
                        }),
                        TextBasis::ReadOnly(snapshot) => Self::ReadOnlyText(
                            ReadOnlyTextDocument::from_parts(decoded, snapshot, source),
                        ),
                    })
                }
                Err(EncodingError::Binary) => Ok(Self::Hex(SectionDocument {
                    source,
                    encoding: None,
                    bom: Vec::new(),
                    allow_nul: false,
                })),
                Err(error) => Err(error.into()),
            }
        } else {
            let sample = source.read(
                0,
                CLASSIFICATION_BYTES + 3,
                CLASSIFICATION_BYTES + 3,
                cancel,
            )?;
            let (bom, detected) = encoding::detect_bom(&sample);
            let bom = bom.to_vec();
            let encoding = if let Some(encoding) = explicit {
                Some(encoding)
            } else if matches!(
                detected,
                Some(Encoding::Utf16Le | Encoding::Utf16Be | Encoding::Utf32Le | Encoding::Utf32Be)
            ) {
                detected
            } else {
                let mut end = sample.len();
                if let Err(error) = std::str::from_utf8(&sample[bom.len()..]) {
                    if error.error_len().is_none() && source.identity.size > sample.len() as u64 {
                        end = bom.len() + error.valid_up_to();
                    }
                }
                match encoding::decode(&sample[..end], None) {
                    Ok(decoded) => Some(decoded.encoding()),
                    Err(EncodingError::Binary) => None,
                    Err(error) => return Err(error.into()),
                }
            };
            let sections = SectionDocument {
                source,
                encoding,
                bom,
                allow_nul: explicit.is_some()
                    || matches!(
                        encoding,
                        Some(
                            Encoding::Utf16Le
                                | Encoding::Utf16Be
                                | Encoding::Utf32Le
                                | Encoding::Utf32Be
                        )
                    ),
            };
            Ok(if encoding.is_some() {
                Self::Sections(sections)
            } else {
                Self::Hex(sections)
            })
        }
    }
}
