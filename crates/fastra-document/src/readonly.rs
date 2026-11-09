use super::*;

/// Vollständiger Text für Analyse/Vergleich, ohne Save- oder Transaktionsbasis.
#[derive(Debug)]
pub struct ReadOnlyTextDocument {
    decoded: Arc<Decoded>,
    snapshot: fastra_io::ReadSnapshot,
    source: Arc<Source>,
}
impl ReadOnlyTextDocument {
    pub fn open(path: &Path, explicit: Option<Encoding>, cancel: &Cancellation) -> Result<Self> {
        Self::open_bounded(path, explicit, EDITABLE_BYTES, cancel)
    }
    pub fn open_bounded(
        path: &Path,
        explicit: Option<Encoding>,
        max_bytes: usize,
        cancel: &Cancellation,
    ) -> Result<Self> {
        check(cancel)?;
        if max_bytes > EDITABLE_BYTES {
            return Err(Error::Limit);
        }
        let source = Arc::new(Source::open(path, cancel)?);
        let snapshot = fastra_io::ReadSnapshot::read_bounded(&source.target, max_bytes, cancel)?;
        if snapshot.bytes().len() as u64 != source.identity.size
            || snapshot.file_identity().device != source.identity.device
            || snapshot.file_identity().inode != source.identity.inode
        {
            return Err(Error::Stale);
        }
        source.verify(cancel)?;
        let decoded =
            encoding::decode(snapshot.bytes(), explicit).map_err(|error| match error {
                EncodingError::Binary => Error::NotText,
                error => error.into(),
            })?;
        if decoded.text().len() > EDITABLE_BYTES {
            return Err(Error::Limit);
        }
        if decoded.text().contains('\0')
            || decoded
                .text()
                .split(['\r', '\n'])
                .any(|line| line.len() > TEXT_SECTION_BYTES)
        {
            return Err(Error::NotText);
        }
        check(cancel)?;
        Ok(Self {
            decoded: Arc::new(decoded),
            snapshot,
            source,
        })
    }
    pub(super) fn from_parts(
        decoded: Decoded,
        snapshot: fastra_io::ReadSnapshot,
        source: Arc<Source>,
    ) -> Self {
        Self {
            decoded: Arc::new(decoded),
            snapshot,
            source,
        }
    }
    pub fn text(&self) -> &str {
        self.decoded.text()
    }
    pub fn decoded(&self) -> &Decoded {
        &self.decoded
    }
    /// Große dekodierte Texte zwischen Leseansicht und Editorformat gemeinsam halten.
    pub fn shared_decoded(&self) -> Arc<Decoded> {
        self.decoded.clone()
    }
    pub fn snapshot(&self) -> &fastra_io::ReadSnapshot {
        &self.snapshot
    }
    pub fn identity(&self) -> &SourceIdentity {
        &self.source.identity
    }
    pub fn path(&self) -> &Path {
        &self.source.target
    }
    pub fn verify_current(&self, cancel: &Cancellation) -> Result<()> {
        self.source.verify(cancel)?;
        self.snapshot.verify_current(cancel)?;
        self.source.verify(cancel)
    }
    /// Leichter Änderungshinweis ohne Byteprüfung; ersetzt keine Ergebnis- oder Schreibprüfung.
    pub fn verify_identity(&self, cancel: &Cancellation) -> Result<()> {
        self.source.verify(cancel)
    }
}
