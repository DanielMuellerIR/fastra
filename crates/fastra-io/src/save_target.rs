//! Gehaltener Zielzustand für „Speichern unter“, ohne Platzhalterdatei.
use super::*;

#[derive(Clone, Debug)]
pub struct Target {
    pub(super) parent: Arc<Directory>,
    name: OsString,
    existing: Option<Snapshot>,
}
impl Target {
    pub fn capture(path: &Path, cancel: &Cancellation) -> Result<Self> {
        cancel.check()?;
        crate::check_runtime_path(path)?;
        let parent = Arc::new(Directory::open(path.parent().ok_or(Error::InvalidPath)?)?);
        parent.supported()?;
        let name = path.file_name().ok_or(Error::InvalidPath)?.to_owned();
        let existing = match parent.regular(&name) {
            Ok(file) => {
                let (bytes, fingerprint) = read_file(file, cancel, MAX_BYTES)?;
                Some(Snapshot {
                    parent: parent.clone(),
                    name: name.clone(),
                    bytes: Arc::new(bytes),
                    fingerprint,
                })
            }
            Err(Error::Io(error)) if error.raw_os_error() == Some(libc::ENOENT) => None,
            Err(error) => return Err(error),
        };
        parent.bound()?;
        Ok(Self {
            parent,
            name,
            existing,
        })
    }
    pub(super) fn from_snapshot(snapshot: Snapshot) -> Result<Self> {
        snapshot.parent.supported()?;
        Ok(Self {
            parent: snapshot.parent.clone(),
            name: snapshot.name.clone(),
            existing: Some(snapshot),
        })
    }
    pub fn path(&self) -> PathBuf {
        self.parent.path.join(&self.name)
    }
    pub fn same_parent(&self, snapshot: &Snapshot) -> bool {
        self.parent.identity == snapshot.parent.identity
    }
    pub fn existing(&self) -> Option<&Snapshot> {
        self.existing.as_ref()
    }
    pub fn verify(&self, cancel: &Cancellation) -> Result<()> {
        cancel.check()?;
        crate::check_runtime_path(&self.path())?;
        self.parent.bound()?;
        if let Some(snapshot) = &self.existing {
            return snapshot.verify(cancel);
        }
        let name = name(&self.name)?;
        let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe {
            libc::fstatat(
                self.parent.file.as_raw_fd(),
                name.as_ptr(),
                &mut metadata,
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } == 0
        {
            return Err(Error::Stale);
        }
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ENOENT) {
            Ok(())
        } else {
            Err(error.into())
        }
    }
    /// Nach Veröffentlichung ist jeder weitere Fehler ein Recoveryzustand; der Aufrufer darf benötigte Assets nicht zurücknehmen.
    pub fn publish(self, bytes: &[u8], cancel: &Cancellation) -> Result<Snapshot> {
        self.publish_checked(bytes, cancel)
            .map_err(|failure| failure.error)
    }
    pub fn publish_checked(
        self,
        bytes: &[u8],
        cancel: &Cancellation,
    ) -> std::result::Result<Snapshot, PublishFailure> {
        self.verify(cancel).map_err(|error| PublishFailure {
            error,
            possibly_published: false,
            journal: None,
        })?;
        let mut journal = None;
        let result = if let Some(snapshot) = self.existing {
            let unchanged = snapshot.clone();
            (|| {
                let transaction =
                    Transaction::save_document(snapshot, bytes, cancel).inspect_err(|error| {
                        if let Error::RecoveryRequired(path) = error {
                            journal = Some(path.clone());
                        }
                    })?;
                if let Some(transaction) = transaction {
                    let recovery = transaction.path().to_owned();
                    journal = Some(recovery.clone());
                    let saved = transaction
                        .saved_document_snapshot(&Cancellation::default())
                        .map_err(|_| Error::RecoveryRequired(recovery.clone()))?;
                    if saved.bytes() != bytes {
                        return Err(Error::RecoveryRequired(recovery));
                    }
                    transaction
                        .finish_document_save(&Cancellation::default())
                        .map_err(|_| Error::RecoveryRequired(recovery))?;
                    Ok(saved)
                } else {
                    Ok(unchanged)
                }
            })()
        } else {
            Transaction::save_new_document_bound(self.parent, self.name, bytes, cancel)
        };
        result.map_err(|error| PublishFailure {
            possibly_published: matches!(error, Error::RecoveryRequired(_)),
            error,
            journal,
        })
    }
}
#[cfg(test)]
#[path = "save_target/tests.rs"]
mod tests;

impl Snapshot {
    pub fn verify_current(&self, cancel: &Cancellation) -> Result<()> {
        self.verify(cancel)
    }
}

#[derive(Debug)]
pub struct PublishFailure {
    pub error: Error,
    pub possibly_published: bool,
    pub journal: Option<PathBuf>,
}

#[cfg(test)]
type RaceHook = Box<dyn FnMut(&str, &Path)>;
#[cfg(test)]
thread_local! {static RACE:std::cell::RefCell<Option<RaceHook>>=const{std::cell::RefCell::new(None)};}
pub(super) fn checkpoint(phase: &str, path: &Path) {
    #[cfg(test)]
    RACE.with(|hook| {
        let callback = hook.borrow_mut().take();
        if let Some(mut callback) = callback {
            callback(phase, path);
            *hook.borrow_mut() = Some(callback);
        }
    });
    #[cfg(not(test))]
    let _ = (phase, path);
}
