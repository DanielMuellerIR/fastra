use super::*;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Stamp {
    identity: FileIdentity,
    size: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    modified: [i64; 2],
    changed: [i64; 2],
}
impl Stamp {
    fn capture(file: &File) -> Result<Self> {
        let meta = file.metadata()?;
        if !meta.is_file() {
            return Err(Error::UnsupportedMetadata);
        }
        Ok(Self {
            identity: FileIdentity {
                device: meta.dev(),
                inode: meta.ino(),
            },
            size: meta.len(),
            mode: meta.mode(),
            uid: meta.uid(),
            gid: meta.gid(),
            modified: [meta.mtime(), meta.mtime_nsec()],
            changed: [meta.ctime(), meta.ctime_nsec()],
        })
    }
}

/// Begrenzte, pfadgebundene Lesebasis. Besitzt ausdrücklich keine Schreibfähigkeit:
/// Hardlinks sind lesbar; restaurierbare Attribute werden nicht abgefragt.
#[derive(Debug, Clone)]
pub struct ReadSnapshot {
    parent: Arc<Directory>,
    name: OsString,
    bytes: Arc<Vec<u8>>,
    stamp: Stamp,
}
impl ReadSnapshot {
    pub fn read(path: &Path, cancel: &Cancellation) -> Result<Self> {
        Self::read_bounded(path, MAX_BYTES, cancel)
    }
    pub fn read_bounded(path: &Path, max_bytes: usize, cancel: &Cancellation) -> Result<Self> {
        cancel.check()?;
        if max_bytes > MAX_BYTES {
            return Err(Error::Limit);
        }
        let parent = Arc::new(Directory::open_for_read(
            path.parent().ok_or(Error::InvalidPath)?,
            cancel,
        )?);
        let name = path.file_name().ok_or(Error::InvalidPath)?.to_owned();
        let mut file = parent.regular(&name)?;
        let stamp = Stamp::capture(&file)?;
        if stamp.size > max_bytes as u64 {
            return Err(Error::Limit);
        }
        let mut bytes = Vec::with_capacity(stamp.size as usize);
        let mut block = [0u8; 65536];
        loop {
            cancel.check()?;
            let count = match file.read(&mut block) {
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                result => result?,
            };
            if count == 0 {
                break;
            }
            if bytes.len() + count > max_bytes {
                return Err(Error::Limit);
            }
            bytes.extend_from_slice(&block[..count]);
        }
        if bytes.len() as u64 != stamp.size || Stamp::capture(&file)? != stamp {
            return Err(Error::Stale);
        }
        // Der gehaltene Deskriptor allein erkennt weder einen umbenannten Elternordner
        // noch den Austausch des Dateinamens während des Lesens.
        if Directory::open_for_read(&parent.path, cancel)?.identity != parent.identity
            || Stamp::capture(&parent.regular(&name)?)? != stamp
        {
            return Err(Error::Stale);
        }
        cancel.check()?;
        Ok(Self {
            parent,
            name,
            bytes: Arc::new(bytes),
            stamp,
        })
    }
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
    pub fn path(&self) -> PathBuf {
        self.parent.path.join(&self.name)
    }
    pub fn file_identity(&self) -> FileIdentity {
        self.stamp.identity
    }

    /// Vergleicht erfasste Basen ohne erneuten Plattenzugriff; der Pfad ist Teil
    /// der Identität, auch wenn zwei Namen denselben Hardlink-Inode besitzen.
    pub fn same_source(&self, other: &Self) -> bool {
        self.parent.identity == other.parent.identity
            && self.parent.path == other.parent.path
            && self.name == other.name
            && self.stamp == other.stamp
            && self.bytes == other.bytes
    }
    pub fn verify_current(&self, cancel: &Cancellation) -> Result<()> {
        let current = Self::read_bounded(&self.path(), self.bytes.len(), cancel)?;
        if !self.same_source(&current) {
            return Err(Error::Stale);
        }
        Ok(())
    }
    /// Prüft eine separat erworbene Schreibbasis gegen die gelesenen Daten.
    /// Sie wird hier weder erzeugt noch aus dem Lesesnapshot abgeleitet.
    pub fn matches_writable_snapshot(&self, other: &Snapshot) -> bool {
        self.parent.identity == other.parent.identity
            && self.parent.path == other.parent.path
            && self.name == other.name
            && self.stamp.identity == other.file_identity()
            && self.stamp.size == other.fingerprint.size
            && self.stamp.mode & 0o7777 == other.fingerprint.mode
            && self.stamp.uid == other.fingerprint.uid
            && self.stamp.gid == other.fingerprint.gid
            && self.stamp.modified == other.fingerprint.modified
            && self.bytes == other.bytes
    }
}

#[cfg(test)]
mod tests;
